import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/logging/logger.dart';

/// Pesapal v3 payment gateway client.
///
/// Handles authentication, IPN registration, order submission, and
/// transaction status queries. Tokens and the IPN ID are cached in memory.
///
/// Required env vars:
///   PESAPAL_CONSUMER_KEY, PESAPAL_CONSUMER_SECRET
///   PESAPAL_BASE_URL  (https://cybqa.pesapal.com/pesapalv3 for sandbox,
///                      https://pay.pesapal.com/v3 for production)
class PesapalService {
  String? _cachedToken;
  DateTime? _tokenExpiresAt;
  String? _cachedIpnId;

  String get _base => AppConfig.pesapalBaseUrl;

  // ── Auth token ────────────────────────────────────────────────────────────────

  Future<String> _getToken() async {
    if (_cachedToken != null &&
        _tokenExpiresAt != null &&
        DateTime.now().isBefore(_tokenExpiresAt!)) {
      return _cachedToken!;
    }

    final response = await http.post(
      Uri.parse('$_base/api/Auth/RequestToken'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'consumer_key': AppConfig.pesapalConsumerKey,
        'consumer_secret': AppConfig.pesapalConsumerSecret,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Pesapal auth failed: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['status'] != '200') {
      throw Exception('Pesapal auth error: ${data['message']}');
    }

    _cachedToken = data['token'] as String;
    // Pesapal tokens expire after 5 minutes; cache for 4 to avoid edge cases.
    _tokenExpiresAt = DateTime.now().add(const Duration(minutes: 4));
    log.info('Pesapal: token refreshed');
    return _cachedToken!;
  }

  // ── IPN registration ──────────────────────────────────────────────────────────

  Future<String> _getIpnId() async {
    if (_cachedIpnId != null) return _cachedIpnId!;

    final token = await _getToken();
    final ipnUrl = '${AppConfig.publicUrl}/v1/webhooks/pesapal';

    final response = await http.post(
      Uri.parse('$_base/api/URLSetup/RegisterIPN'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'url': ipnUrl,
        'ipn_notification_type': 'POST',
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Pesapal IPN registration failed: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _cachedIpnId = data['ipn_id'] as String;
    log.info('Pesapal: IPN registered id=$_cachedIpnId at $ipnUrl');
    return _cachedIpnId!;
  }

  // ── Submit order ──────────────────────────────────────────────────────────────

  /// Creates a Pesapal hosted checkout order.
  /// [merchantReference] must be unique per order — use the deposit UUID.
  /// Returns a map with 'orderTrackingId' and 'redirectUrl'.
  Future<Map<String, dynamic>> submitOrder({
    required String merchantReference,
    required int amountShillings,
    required String description,
    required String callbackUrl,
    String customerName = 'Lifecare Patient',
    String customerPhone = '',
  }) async {
    final token = await _getToken();
    final ipnId = await _getIpnId();

    final nameParts = customerName.trim().split(' ');
    final firstName = nameParts.first.isEmpty ? 'Lifecare' : nameParts.first;
    final lastName =
        nameParts.length > 1 ? nameParts.sublist(1).join(' ') : 'Patient';

    final response = await http.post(
      Uri.parse('$_base/api/Transactions/SubmitOrderRequest'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'id': merchantReference,
        'currency': 'UGX',
        'amount': amountShillings,
        'description': description,
        'callback_url': callbackUrl,
        'notification_id': ipnId,
        'billing_address': {
          'email_address': '${merchantReference.substring(0, 8)}@lifecare.app',
          'phone_number': customerPhone,
          'first_name': firstName,
          'last_name': lastName,
        },
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Pesapal submitOrder failed: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null && data['error'].toString().isNotEmpty) {
      throw Exception('Pesapal order error: ${data['error']}');
    }

    final trackingId = data['order_tracking_id'] as String?;
    final redirectUrl = data['redirect_url'] as String?;
    if (trackingId == null || redirectUrl == null) {
      throw Exception('Pesapal returned incomplete order data: ${response.body}');
    }

    log.info('Pesapal: order submitted ref=$merchantReference tracking=$trackingId');
    return {'orderTrackingId': trackingId, 'redirectUrl': redirectUrl};
  }

  // ── Transaction status ────────────────────────────────────────────────────────

  /// Returns 'COMPLETED', 'FAILED', or 'PENDING'.
  /// Pesapal status_code: 0=INVALID, 1=COMPLETED, 2=FAILED, 3=REVERSED.
  Future<String> getTransactionStatus(String orderTrackingId) async {
    final token = await _getToken();

    final response = await http.get(
      Uri.parse(
          '$_base/api/Transactions/GetTransactionStatus?orderTrackingId=$orderTrackingId'),
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Pesapal status check failed: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final statusCode = (data['status_code'] as num?)?.toInt() ?? 0;

    switch (statusCode) {
      case 1:
        return 'COMPLETED';
      case 2:
      case 3:
        return 'FAILED';
      default:
        return 'PENDING';
    }
  }
}

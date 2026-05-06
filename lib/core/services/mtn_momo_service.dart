import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/logging/logger.dart';

/// MTN Mobile Money Collection API client.
///
/// Sandbox provisioning (API user/key creation) uses sandbox.momoapi.mtn.com.
/// All actual API calls (token + requesttopay) use ericssonbasicapi2.azure-api.net.
///
/// Required env vars:
///   MTN_SUBSCRIPTION_KEY, MTN_API_USER, MTN_API_KEY,
///   MTN_TARGET_ENV (sandbox | mtnuganda),
///   MTN_BASE_URL   (https://ericssonbasicapi2.azure-api.net for sandbox)
class MtnMomoService {
  String? _cachedToken;
  DateTime? _tokenExpiresAt;

  // ── Token ────────────────────────────────────────────────────────────────────

  Future<String> _getToken() async {
    if (_cachedToken != null &&
        _tokenExpiresAt != null &&
        DateTime.now().isBefore(_tokenExpiresAt!)) {
      return _cachedToken!;
    }

    final credentials = base64Encode(
      utf8.encode('${AppConfig.mtnApiUser}:${AppConfig.mtnApiKey}'),
    );

    final response = await http.post(
      Uri.parse('${AppConfig.mtnBaseUrl}/collection/token/'),
      headers: {
        'Authorization': 'Basic $credentials',
        'Ocp-Apim-Subscription-Key': AppConfig.mtnSubscriptionKey,
        'Content-Length': '0',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('MTN token fetch failed: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _cachedToken = data['access_token'] as String;
    final expiresIn = (data['expires_in'] as int?) ?? 3600;
    // Expire 60 s early to account for clock skew.
    _tokenExpiresAt = DateTime.now().add(Duration(seconds: expiresIn - 60));
    log.info('MTN MoMo: token refreshed, expires in ${expiresIn}s');
    return _cachedToken!;
  }

  // ── Initiate payment ─────────────────────────────────────────────────────────

  /// Sends a Request-to-Pay to [phone].
  /// [referenceId] must be a UUID — it is used as X-Reference-Id and is what
  /// MTN echoes back in the webhook, so we store it as [provider_ref].
  /// [amountShillings] is in full Uganda Shillings (UGX has no sub-unit).
  /// Throws on non-202 response.
  Future<void> requestToPay({
    required String referenceId,
    required int amountShillings,
    required String phone,
  }) async {
    final token = await _getToken();
    final callbackUrl = '${AppConfig.publicUrl}/v1/webhooks/mtn';

    // MTN expects MSISDN without the leading +
    final msisdn = phone.startsWith('+') ? phone.substring(1) : phone;

    final body = jsonEncode({
      'amount': amountShillings.toString(),
      'currency': 'UGX',
      'externalId': referenceId,
      'payer': {'partyIdType': 'MSISDN', 'partyId': msisdn},
      'payerMessage': 'Lifecare wallet top-up',
      'payeeNote': 'Lifecare wallet deposit',
    });

    final response = await http.post(
      Uri.parse('${AppConfig.mtnBaseUrl}/collection/v1_0/requesttopay'),
      headers: {
        'Authorization': 'Bearer $token',
        'X-Reference-Id': referenceId,
        'X-Target-Environment': AppConfig.mtnTargetEnv,
        'Ocp-Apim-Subscription-Key': AppConfig.mtnSubscriptionKey,
        'X-Callback-Url': callbackUrl,
        'Content-Type': 'application/json',
      },
      body: body,
    );

    if (response.statusCode != 202) {
      throw Exception(
          'MTN requesttopay failed: ${response.statusCode} ${response.body}');
    }
    log.info('MTN MoMo: requesttopay accepted for ref=$referenceId');
  }

  // ── Poll status (used when webhook hasn't arrived yet) ───────────────────────

  /// Returns a map with at least the key [status]: 'SUCCESSFUL' | 'FAILED' | 'PENDING'.
  Future<Map<String, dynamic>> getTransactionStatus(String referenceId) async {
    final token = await _getToken();

    final response = await http.get(
      Uri.parse(
          '${AppConfig.mtnBaseUrl}/collection/v1_0/requesttopay/$referenceId'),
      headers: {
        'Authorization': 'Bearer $token',
        'X-Target-Environment': AppConfig.mtnTargetEnv,
        'Ocp-Apim-Subscription-Key': AppConfig.mtnSubscriptionKey,
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
          'MTN status check failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

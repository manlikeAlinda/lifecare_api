import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/logging/logger.dart';

/// Flutterwave Standard (hosted checkout) integration for card payments.
///
/// Flow:
///   1. Call [createPaymentLink] → get a hosted checkout URL.
///   2. Flutter app opens the URL in a WebView / in-app browser.
///   3. Flutterwave POSTs the result to /v1/webhooks/flutterwave.
///   4. Webhook handler calls [verifyTransaction] to confirm the amount before
///      crediting the wallet.
///
/// Required env vars:
///   FLUTTERWAVE_SECRET_KEY   — from dashboard.flutterwave.com → Settings → API
///   FLUTTERWAVE_SECRET_HASH  — from dashboard → Settings → Webhooks → Secret hash
class FlutterwaveService {
  static const _baseUrl = 'https://api.flutterwave.com/v3';

  // ── Create hosted payment link ────────────────────────────────────────────────

  /// Returns the Flutterwave hosted checkout URL.
  /// [txRef] is your unique reference — use the [depositId].
  /// [redirectUrl] is where Flutterwave sends the user after payment
  ///   (use a deep-link like `lifecare://payment-done` in the Flutter app).
  Future<String> createPaymentLink({
    required String txRef,
    required int amountShillings,
    required String customerPhone,
    required String customerName,
    required String redirectUrl,
  }) async {
    final body = jsonEncode({
      'tx_ref': txRef,
      'amount': amountShillings,
      'currency': 'UGX',
      'redirect_url': redirectUrl,
      'customer': {
        // Flutterwave requires an email field; synthesise one if not available.
        'email': '${txRef.substring(0, 8)}@lifecare.app',
        'phonenumber': customerPhone,
        'name': customerName.isNotEmpty ? customerName : 'Lifecare Patient',
      },
      'customizations': {
        'title': 'Lifecare Wallet Top-up',
        'description': 'Deposit UGX ${_formatAmount(amountShillings)} to your Lifecare wallet',
      },
    });

    final response = await http.post(
      Uri.parse('$_baseUrl/payments'),
      headers: {
        'Authorization': 'Bearer ${AppConfig.flutterwaveSecretKey}',
        'Content-Type': 'application/json',
      },
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Flutterwave payment init failed: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['status'] != 'success') {
      throw Exception('Flutterwave error: ${data['message']}');
    }

    final link = data['data']?['link'] as String?;
    if (link == null) throw Exception('Flutterwave returned no payment link');

    log.info('Flutterwave: payment link created for txRef=$txRef');
    return link;
  }

  // ── Verify webhook authenticity ───────────────────────────────────────────────

  /// Returns true if the [secretHash] header from the webhook request
  /// matches the configured FLUTTERWAVE_SECRET_HASH.
  bool verifyWebhookSignature(String? secretHash) {
    final expected = AppConfig.flutterwaveSecretHash;
    if (expected.isEmpty) return false; // not configured — reject all
    return secretHash == expected;
  }

  // ── Verify transaction with Flutterwave (after webhook) ───────────────────────

  /// Calls Flutterwave to independently confirm a transaction.
  /// Returns the transaction map, or null if not found / status is not successful.
  Future<Map<String, dynamic>?> verifyTransaction(String transactionId) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/transactions/$transactionId/verify'),
      headers: {'Authorization': 'Bearer ${AppConfig.flutterwaveSecretKey}'},
    );

    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['status'] != 'success') return null;

    final tx = data['data'] as Map<String, dynamic>?;
    if (tx == null) return null;
    if ((tx['status'] as String?)?.toLowerCase() != 'successful') return null;
    return tx;
  }

  String _formatAmount(int shillings) =>
      shillings.toString().replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]},',
      );
}

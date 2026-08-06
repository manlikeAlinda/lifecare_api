import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/logging/logger.dart';

/// Smile Identity Enhanced KYC client. Ported from the NestJS reference —
/// same request shape, same HMAC-SHA256 `sec_key` scheme: base64-encoded
/// HMAC over `timestamp + partnerId + "sid_request"`, keyed by the Smile
/// API key. Verify this construction against Smile's current webhook docs
/// before relying on it in production — ported as-is, not independently
/// re-verified against Smile's API.
class SmileIdentityService {
  String get _base => AppConfig.smileBaseUrl;

  /// Submits an Enhanced KYC job. Returns the provider job ID on success,
  /// or null on any failure — callers treat null as "queue for manual
  /// review" and never let an exception escape this method.
  Future<String?> submitEnhancedKyc({
    required String kycId,
    required String patientId,
    required String nationalId,
    required String fullName,
    required String dateOfBirth,
    required String callbackUrl,
  }) async {
    try {
      final nameParts = fullName.trim().split(' ');
      final firstName = nameParts.isNotEmpty ? nameParts.first : '';
      final lastName =
          nameParts.length > 1 ? nameParts.sublist(1).join(' ') : firstName;
      final timestamp = DateTime.now().toUtc().toIso8601String();

      final body = jsonEncode({
        'source_sdk': 'rest_api',
        'source_sdk_version': '1.0.0',
        'partner_id': AppConfig.smilePartnerId,
        'partner_params': {
          'job_id': kycId,
          'user_id': patientId,
          'job_type': 1, // Enhanced KYC
        },
        'id_info': {
          'first_name': firstName,
          'last_name': lastName,
          'country': 'UG',
          'id_type': 'NATIONAL_ID',
          'id_number': nationalId,
          'dob': dateOfBirth,
          'entered': true,
        },
        'options': {
          'return_job_status': true,
          'return_history': false,
          'return_image_links': false,
          'signature': true,
          'callback_url': callbackUrl,
        },
        'sec_key': _buildSignature(timestamp),
        'timestamp': timestamp,
      });

      final response = await http
          .post(
            Uri.parse('$_base/async_id_verification'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode >= 400) {
        log.warning(
          'Smile Identity submission failed: ${response.statusCode} ${response.body}',
        );
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      log.info('Smile Identity job submitted: $data');
      return data['job_id'] as String? ?? kycId;
    } catch (e) {
      log.warning('Smile Identity submission error: $e');
      return null;
    }
  }

  String _buildSignature(String timestamp) {
    final data = '$timestamp${AppConfig.smilePartnerId}sid_request';
    final hmac = Hmac(sha256, utf8.encode(AppConfig.smileApiKey));
    return base64.encode(hmac.convert(utf8.encode(data)).bytes);
  }

  /// Verifies an inbound webhook's signature + a 5-minute freshness window.
  /// Fails closed (returns false, including on any malformed input) if the
  /// provider isn't configured — an unconfigured provider has no legitimate
  /// webhook to accept.
  bool verifyWebhookSignature(Map<String, dynamic> payload) {
    if (!AppConfig.smileConfigured) return false;

    final signature =
        payload['signature'] as String? ?? payload['sec_key'] as String?;
    final timestamp = payload['timestamp'] as String?;
    if (signature == null || timestamp == null) return false;

    final receivedAt = DateTime.tryParse(timestamp);
    if (receivedAt == null) return false;
    final skew = DateTime.now().toUtc().difference(receivedAt).abs();
    if (skew > const Duration(minutes: 5)) return false;

    final data = '$timestamp${AppConfig.smilePartnerId}sid_request';
    final hmac = Hmac(sha256, utf8.encode(AppConfig.smileApiKey));
    final expectedBytes = hmac.convert(utf8.encode(data)).bytes;

    List<int> receivedBytes;
    try {
      receivedBytes = base64.decode(signature);
    } catch (_) {
      return false;
    }

    if (expectedBytes.length != receivedBytes.length) return false;
    var diff = 0;
    for (var i = 0; i < expectedBytes.length; i++) {
      diff |= expectedBytes[i] ^ receivedBytes[i];
    }
    return diff == 0;
  }
}

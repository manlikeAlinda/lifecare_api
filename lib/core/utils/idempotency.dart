import 'package:lifecare_api/core/errors/api_error.dart';

final _keyPattern = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

/// Validates an optional client-supplied idempotency key (the desktop sends
/// one UUID per form, reused on every retry of that form). A write repeated
/// with the same key returns the original result instead of applying twice —
/// see migration 047. Null when the client sent none.
String? parseIdempotencyKey(Object? raw) {
  if (raw == null || (raw is String && raw.trim().isEmpty)) return null;
  if (raw is! String || !_keyPattern.hasMatch(raw.trim())) {
    throw ApiError.validationError(
      'idempotency_key must be 8–64 letters, digits, "-" or "_"',
      details: [
        {'field': 'idempotency_key', 'message': 'Invalid idempotency key'},
      ],
    );
  }
  return raw.trim();
}

/// True when [error] is MariaDB's duplicate-key error (1062) — the
/// convention already used by CheckoutService and PatientRepository.
bool isDuplicateKeyError(Object error) => error.toString().contains('1062');

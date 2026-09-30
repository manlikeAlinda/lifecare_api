import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/idempotency.dart';

void main() {
  group('parseIdempotencyKey', () {
    test('absent or blank means no key', () {
      expect(parseIdempotencyKey(null), isNull);
      expect(parseIdempotencyKey(''), isNull);
      expect(parseIdempotencyKey('   '), isNull);
    });

    test('accepts a UUID', () {
      expect(parseIdempotencyKey('0b9d6f2e-3c1a-4c8e-9f0a-1d2e3f4a5b6c'),
          '0b9d6f2e-3c1a-4c8e-9f0a-1d2e3f4a5b6c');
    });

    test('rejects a non-string, too-short, too-long or odd-character key', () {
      for (final bad in [42, 'short', 'x' * 65, 'has space in it', "quote'key-123"]) {
        expect(() => parseIdempotencyKey(bad), throwsA(isA<ApiError>()), reason: '$bad');
      }
    });
  });
}

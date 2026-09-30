import 'package:test/test.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/middleware/rate_limit_middleware.dart';

void main() {
  group('RateLimiter', () {
    test('allows up to the limit per key, then refuses', () {
      final l = RateLimiter(maxRequests: 3, window: const Duration(minutes: 1));
      expect([for (var i = 0; i < 4; i++) l.tryConsume('a')], [true, true, true, false]);
      expect(l.tryConsume('b'), isTrue, reason: 'keys are independent');
    });

    test('drops buckets whose window has passed, so memory stays bounded', () async {
      final l = RateLimiter(
        maxRequests: 5,
        window: const Duration(milliseconds: 20),
        pruneAbove: 10,
      );
      for (var i = 0; i < 50; i++) {
        l.tryConsume('spoofed-$i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      l.tryConsume('fresh');
      expect(l.bucketCount, lessThanOrEqualTo(10));
    });
  });

  group('enforceAccountLimit', () {
    test('caps attempts per account however many IPs they come from', () {
      final l = RateLimiter(maxRequests: 2, window: const Duration(minutes: 15));
      enforceAccountLimit(l, 'staff:Admin@Clinic.ug ');
      enforceAccountLimit(l, 'staff:admin@clinic.ug');
      expect(() => enforceAccountLimit(l, 'staff:ADMIN@clinic.ug'),
          throwsA(isA<ApiError>().having((e) => e.statusCode, 'status', 429)));
    });
  });
}

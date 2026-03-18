import 'dart:collection';
import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/middleware/request_id_middleware.dart';

class _SlidingWindow {
  final Queue<DateTime> _timestamps = Queue();
  final int maxRequests;
  final Duration window;

  _SlidingWindow({required this.maxRequests, required this.window});

  bool tryConsume() {
    final now = DateTime.now();
    final cutoff = now.subtract(window);
    while (_timestamps.isNotEmpty && _timestamps.first.isBefore(cutoff)) {
      _timestamps.removeFirst();
    }
    if (_timestamps.length >= maxRequests) return false;
    _timestamps.addLast(now);
    return true;
  }
}

class RateLimiter {
  final int maxRequests;
  final Duration window;
  final _buckets = <String, _SlidingWindow>{};

  RateLimiter({required this.maxRequests, required this.window});

  bool tryConsume(String key) {
    final bucket = _buckets.putIfAbsent(
      key,
      () => _SlidingWindow(maxRequests: maxRequests, window: window),
    );
    return bucket.tryConsume();
  }
}

// Shared rate limiter instances (per spec)
final loginLimiter = RateLimiter(maxRequests: 10, window: Duration(minutes: 1));
final refreshLimiter = RateLimiter(maxRequests: 20, window: Duration(minutes: 1));
final generalLimiter = RateLimiter(maxRequests: 300, window: Duration(minutes: 1));
final reportLimiter = RateLimiter(maxRequests: 5, window: Duration(minutes: 1));

Middleware rateLimitMiddleware(RateLimiter limiter) {
  return (Handler inner) {
    return (Request request) {
      final requestId = getRequestId(request);
      final ip = _clientIp(request);
      if (!limiter.tryConsume(ip)) {
        return errorResponse(ApiError.rateLimited(), requestId);
      }
      return inner(request);
    };
  };
}

String _clientIp(Request request) =>
    request.headers['x-forwarded-for']?.split(',').first.trim() ??
    request.headers['x-real-ip'] ??
    'unknown';

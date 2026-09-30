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

  void _expire(DateTime now) {
    final cutoff = now.subtract(window);
    while (_timestamps.isNotEmpty && _timestamps.first.isBefore(cutoff)) {
      _timestamps.removeFirst();
    }
  }

  bool tryConsume() {
    final now = DateTime.now();
    _expire(now);
    if (_timestamps.length >= maxRequests) return false;
    _timestamps.addLast(now);
    return true;
  }

  bool isIdle(DateTime now) {
    _expire(now);
    return _timestamps.isEmpty;
  }
}

class RateLimiter {
  final int maxRequests;
  final Duration window;

  /// Once more than this many keys are tracked, keys with no requests left
  /// in their window are dropped — otherwise every distinct key (e.g. a
  /// rotated, spoofed X-Forwarded-For value) stays in memory forever.
  final int pruneAbove;
  final _buckets = <String, _SlidingWindow>{};

  RateLimiter({
    required this.maxRequests,
    required this.window,
    this.pruneAbove = 10000,
  });

  int get bucketCount => _buckets.length;

  bool tryConsume(String key) {
    if (_buckets.length > pruneAbove) {
      final now = DateTime.now();
      _buckets.removeWhere((_, b) => b.isIdle(now));
    }
    final bucket = _buckets.putIfAbsent(
      key,
      () => _SlidingWindow(maxRequests: maxRequests, window: window),
    );
    return bucket.tryConsume();
  }
}

// Shared rate limiter instances (per spec).
// NOTE: These are in-process only — state resets on restart and is not shared across
// multiple instances. For multi-instance deployments, replace with a Redis-backed
// implementation keyed on IP + action.
final loginLimiter = RateLimiter(maxRequests: 10, window: Duration(minutes: 1));
final refreshLimiter = RateLimiter(maxRequests: 20, window: Duration(minutes: 1));
final generalLimiter = RateLimiter(maxRequests: 300, window: Duration(minutes: 1));
final reportLimiter = RateLimiter(maxRequests: 5, window: Duration(minutes: 1));
// /v1/patient/analytics/* — each call runs several DB queries; the shared
// generalLimiter (300/min, whole API) doesn't stop one caller from driving
// unbounded concurrent load against the heaviest queries in the codebase.
final analyticsLimiter = RateLimiter(maxRequests: 20, window: Duration(minutes: 1));

/// Login attempts per ACCOUNT (not per IP): 10 per 15 minutes. The IP-keyed
/// limiters above trust the client-supplied X-Forwarded-For header, so an
/// attacker rotating that header gets unlimited guesses; this cap holds no
/// matter how many addresses the attempts come from.
final accountLoginLimiter =
    RateLimiter(maxRequests: 10, window: Duration(minutes: 15));

/// Throws 429 once [key] (e.g. 'staff:<email>', 'patient:<phone>') has used
/// up its attempts in [limiter]. Keys are normalised (trimmed, lower-cased)
/// so case or whitespace variations share one budget.
void enforceAccountLimit(RateLimiter limiter, String key) {
  if (!limiter.tryConsume(key.trim().toLowerCase())) {
    throw ApiError.rateLimited();
  }
}

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

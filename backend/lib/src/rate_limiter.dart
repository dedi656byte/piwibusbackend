import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'redis_realtime.dart';

class RateLimiter {
  RateLimiter({
    required this.limitPerMinute,
    required RedisRealtime? redis,
    this.trustProxyHeaders = false,
  }) : _redis = redis;

  final int limitPerMinute;
  final RedisRealtime? _redis;
  final bool trustProxyHeaders;
  final Map<String, _RateLimitBucket> _buckets = <String, _RateLimitBucket>{};

  Middleware middleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        if (_isSkipped(request)) {
          return innerHandler(request);
        }
        final allowed = await _check(request);
        if (!allowed) {
          return Response(
            429,
            body: '{"error":"Trop de requetes. Reessayez plus tard."}',
            headers: const <String, String>{
              HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
              'Retry-After': '60',
            },
          );
        }
        return innerHandler(request);
      };
    };
  }

  bool _isSkipped(Request request) {
    return limitPerMinute <= 0 ||
        request.method == 'OPTIONS' ||
        request.url.path == 'health' ||
        request.url.path == 'ready' ||
        request.url.path == 'metrics';
  }

  Future<bool> _check(Request request) async {
    final key = _clientKey(request);
    final redis = _redis;
    if (redis != null) {
      final minute = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 60000;
      final count = await redis.incrementRateLimit(
        key: 'piwibus:rate:$minute:$key',
        window: const Duration(seconds: 75),
      );
      if (count != null) return count <= limitPerMinute;
    }
    return _checkInMemory(key);
  }

  bool _checkInMemory(String key) {
    final now = DateTime.now();
    final bucket = _buckets.putIfAbsent(key, () => _RateLimitBucket());
    bucket.removeExpired(now);
    if (bucket.hits.length >= limitPerMinute) return false;
    bucket.hits.add(now);
    if (_buckets.length > 2000) {
      _buckets.removeWhere((_, value) => value.isExpired(now));
    }
    return true;
  }

  String _clientKey(Request request) {
    if (trustProxyHeaders) {
      final forwardedFor = request.headers['x-forwarded-for']
          ?.split(',')
          .first
          .trim();
      final explicit = forwardedFor?.isNotEmpty == true
          ? forwardedFor
          : request.headers['x-real-ip']?.trim();
      if (explicit != null && explicit.isNotEmpty) return explicit;
    }
    final connectionInfo = request.context['shelf.io.connection_info'];
    if (connectionInfo is HttpConnectionInfo) {
      return connectionInfo.remoteAddress.address;
    }
    return 'unknown';
  }
}

class _RateLimitBucket {
  final List<DateTime> hits = <DateTime>[];

  void removeExpired(DateTime now) {
    hits.removeWhere((hit) => now.difference(hit) > const Duration(minutes: 1));
  }

  bool isExpired(DateTime now) {
    removeExpired(now);
    return hits.isEmpty;
  }
}

import 'package:piwibus_backend/src/rate_limiter.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test(
    'authentication limits remain active when the general limit is off',
    () async {
      final limiter = RateLimiter(
        limitPerMinute: 0,
        redis: null,
        pathLimitsPerMinute: const <String, int>{'auth/sign-in': 1},
      );
      final handler = const Pipeline()
          .addMiddleware(limiter.middleware())
          .addHandler((_) => Response.ok('ok'));

      final firstResponse = await handler(
        Request('POST', Uri.parse('http://localhost/auth/sign-in')),
      );
      final secondResponse = await handler(
        Request('POST', Uri.parse('http://localhost/auth/sign-in')),
      );

      expect(firstResponse.statusCode, 200);
      expect(secondResponse.statusCode, 429);
    },
  );

  test(
    'additional account limits reject requests over their threshold',
    () async {
      final limiter = RateLimiter(limitPerMinute: 180, redis: null);

      expect(
        await limiter.checkAdditionalKey(key: 'user-login:account', limit: 1),
        isTrue,
      );
      expect(
        await limiter.checkAdditionalKey(key: 'user-login:account', limit: 1),
        isFalse,
      );
    },
  );
}

import 'package:jose/jose.dart';
import 'package:piwibus_backend/src/google_id_token_verifier.dart';
import 'package:test/test.dart';

void main() {
  group('GoogleIdTokenVerifier', () {
    late JsonWebKey signingKey;
    late Map<String, dynamic> jwks;
    late GoogleIdTokenVerifier verifier;

    setUpAll(() {
      final generated = JsonWebKey.generate('RS256', keyBitLength: 2048);
      final keyJson = <String, dynamic>{
        ...generated.toJson(),
        'kid': 'test-key',
        'alg': 'RS256',
        'use': 'sig',
      };
      signingKey = JsonWebKey.fromJson(keyJson);
      jwks = <String, dynamic>{
        'keys': <Map<String, dynamic>>[
          <String, dynamic>{
            'kty': 'RSA',
            'kid': 'test-key',
            'alg': 'RS256',
            'use': 'sig',
            'n': keyJson['n'],
            'e': keyJson['e'],
          },
        ],
      };
    });

    setUp(() {
      verifier = GoogleIdTokenVerifier(
        audiences: const <String>{'piwibus-client'},
        jwksLoader: () async => jwks,
      );
    });

    test(
      'verifies the signature and returns trusted identity claims',
      () async {
        final identity = await verifier.verify(await _signedToken(signingKey));

        expect(identity.subject, 'google-subject');
        expect(identity.email, 'user@example.com');
        expect(identity.fullName, 'Google User');
      },
    );

    test('rejects a signature that does not match the Google key', () async {
      final otherKey = JsonWebKey.generate('RS256', keyBitLength: 2048);

      await expectLater(
        verifier.verify(await _signedToken(otherKey)),
        throwsA(isA<GoogleIdTokenVerificationException>()),
      );
    });

    test('rejects a token for an unconfigured audience', () async {
      await expectLater(
        verifier.verify(
          await _signedToken(signingKey, <String, dynamic>{
            'aud': 'other-client',
          }),
        ),
        throwsA(isA<GoogleIdTokenVerificationException>()),
      );
    });

    test('rejects an invalid issuer', () async {
      await expectLater(
        verifier.verify(
          await _signedToken(signingKey, <String, dynamic>{
            'iss': 'https://attacker.example',
          }),
        ),
        throwsA(isA<GoogleIdTokenVerificationException>()),
      );
    });

    test('rejects expired or unverified identities', () async {
      await expectLater(
        verifier.verify(
          await _signedToken(signingKey, <String, dynamic>{
            'exp':
                DateTime.now()
                    .toUtc()
                    .subtract(const Duration(minutes: 5))
                    .millisecondsSinceEpoch ~/
                1000,
          }),
        ),
        throwsA(isA<GoogleIdTokenVerificationException>()),
      );
      await expectLater(
        verifier.verify(
          await _signedToken(signingKey, <String, dynamic>{
            'email_verified': false,
          }),
        ),
        throwsA(isA<GoogleIdTokenVerificationException>()),
      );
    });

    test('rejects missing configuration and malformed tokens', () async {
      final disabledVerifier = GoogleIdTokenVerifier(
        audiences: const <String>{},
        jwksLoader: () async => jwks,
      );

      await expectLater(
        disabledVerifier.verify('not-a-token'),
        throwsA(isA<GoogleIdTokenVerificationException>()),
      );
      await expectLater(
        verifier.verify('not-a-token'),
        throwsA(isA<GoogleIdTokenVerificationException>()),
      );
    });
  });
}

Future<String> _signedToken(
  JsonWebKey key, [
  Map<String, dynamic> overrides = const <String, dynamic>{},
]) async {
  final now = DateTime.now().toUtc();
  final claims = <String, dynamic>{
    'iss': 'https://accounts.google.com',
    'aud': 'piwibus-client',
    'sub': 'google-subject',
    'email': 'user@example.com',
    'email_verified': true,
    'name': 'Google User',
    'iat': now.millisecondsSinceEpoch ~/ 1000,
    'exp': now.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000,
    ...overrides,
  };
  final builder = JsonWebSignatureBuilder()..jsonContent = claims;
  builder
    ..setProtectedHeader('kid', 'test-key')
    ..addRecipient(key, algorithm: 'RS256');
  return builder.build().toCompactSerialization();
}

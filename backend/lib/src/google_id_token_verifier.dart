import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';

class VerifiedGoogleIdentity {
  const VerifiedGoogleIdentity({
    required this.subject,
    required this.email,
    this.fullName,
  });

  final String subject;
  final String email;
  final String? fullName;
}

class GoogleIdTokenVerificationException implements Exception {
  const GoogleIdTokenVerificationException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef GoogleJwksLoader = Future<Map<String, dynamic>> Function();

class GoogleIdTokenVerifier {
  GoogleIdTokenVerifier({
    required Set<String> audiences,
    http.Client? client,
    GoogleJwksLoader? jwksLoader,
    DateTime Function()? clock,
    Duration jwksCacheDuration = const Duration(hours: 1),
  }) : _audiences = audiences
           .map((audience) => audience.trim())
           .where((audience) => audience.isNotEmpty)
           .toSet(),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _jwksLoader = jwksLoader,
       _clock = clock ?? DateTime.now,
       _jwksCacheDuration = jwksCacheDuration;

  static const int maxTokenLength = 16 * 1024;
  static final Uri _jwksUri = Uri(
    scheme: 'https',
    host: 'www.googleapis.com',
    path: '/oauth2/v3/certs',
  );
  static const Duration _requestTimeout = Duration(seconds: 10);
  static const int _maxJwksBytes = 64 * 1024;

  final Set<String> _audiences;
  final http.Client _client;
  final bool _ownsClient;
  final GoogleJwksLoader? _jwksLoader;
  final DateTime Function() _clock;
  final Duration _jwksCacheDuration;

  Map<String, dynamic>? _cachedJwks;
  DateTime? _jwksExpiresAt;

  bool get isConfigured => _audiences.isNotEmpty;

  Future<VerifiedGoogleIdentity> verify(String rawToken) async {
    if (!isConfigured) {
      throw const GoogleIdTokenVerificationException(
        'La connexion Google n’est pas configurée.',
      );
    }

    final token = rawToken.trim();
    if (token.isEmpty || token.length > maxTokenLength) {
      throw const GoogleIdTokenVerificationException('Jeton Google invalide.');
    }

    late final JsonWebSignature signature;
    try {
      signature = JsonWebSignature.fromCompactSerialization(token);
    } on Object {
      throw const GoogleIdTokenVerificationException('Jeton Google invalide.');
    }

    final header = signature.commonProtectedHeader;
    final keyId = header.keyId;
    if (header.algorithm != 'RS256' || keyId == null || keyId.isEmpty) {
      throw const GoogleIdTokenVerificationException('Jeton Google invalide.');
    }

    var jwks = await _loadJwks();
    var key = _findSigningKey(jwks, keyId);
    if (key == null) {
      jwks = await _loadJwks(forceRefresh: true);
      key = _findSigningKey(jwks, keyId);
    }
    if (key == null) {
      throw const GoogleIdTokenVerificationException('Jeton Google invalide.');
    }

    final keyStore = JsonWebKeyStore()..addKey(key);
    late final JsonWebToken verifiedToken;
    try {
      verifiedToken = await JsonWebToken.decodeAndVerify(
        token,
        keyStore,
        allowedArguments: const <String>['RS256'],
      );
    } on Object {
      throw const GoogleIdTokenVerificationException('Jeton Google invalide.');
    }

    final claims = verifiedToken.claims;
    final now = _clock().toUtc();
    final expiry = claims.expiry?.toUtc();
    final notBefore = claims.notBefore?.toUtc();
    final audiences = claims.audience?.toSet() ?? const <String>{};
    final authorizedParty = _stringClaim(claims['azp']);
    final email = (_stringClaim(claims['email']) ?? '').trim().toLowerCase();
    final emailVerified = claims['email_verified'];

    if (!_isGoogleIssuer(claims.issuer?.toString()) ||
        expiry == null ||
        expiry.isBefore(now.subtract(const Duration(seconds: 60))) ||
        (notBefore != null &&
            notBefore.isAfter(now.add(const Duration(seconds: 60)))) ||
        audiences.intersection(_audiences).isEmpty ||
        (audiences.length > 1 &&
            (authorizedParty == null ||
                !_audiences.contains(authorizedParty))) ||
        (authorizedParty != null && !_audiences.contains(authorizedParty)) ||
        verifiedToken.claims.subject == null ||
        verifiedToken.claims.subject!.isEmpty ||
        emailVerified != true ||
        !_isValidEmail(email)) {
      throw const GoogleIdTokenVerificationException(
        'Le compte Google ne peut pas être vérifié.',
      );
    }

    final name = (_stringClaim(claims['name']) ?? '').trim();
    return VerifiedGoogleIdentity(
      subject: verifiedToken.claims.subject!,
      email: email,
      fullName: name.isEmpty ? null : name,
    );
  }

  Future<Map<String, dynamic>> _loadJwks({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedJwks != null &&
        _jwksExpiresAt != null &&
        _jwksExpiresAt!.isAfter(_clock())) {
      return _cachedJwks!;
    }

    try {
      final jwks = _jwksLoader == null
          ? await _fetchJwks()
          : await _jwksLoader().timeout(_requestTimeout);
      if (jwks['keys'] is! List) {
        throw const FormatException('Invalid JWKS response.');
      }
      _cachedJwks = jwks;
      _jwksExpiresAt = _clock().add(_jwksCacheDuration);
      return jwks;
    } on Object {
      throw const GoogleIdTokenVerificationException(
        'La vérification Google est temporairement indisponible.',
      );
    }
  }

  Future<Map<String, dynamic>> _fetchJwks() async {
    final request = http.Request('GET', _jwksUri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    final response = await _client.send(request).timeout(_requestTimeout);
    if (response.statusCode != HttpStatus.ok ||
        (response.contentLength != null &&
            response.contentLength! > _maxJwksBytes)) {
      throw const HttpException('Unable to load Google public keys.');
    }

    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(_requestTimeout)) {
      if (bytes.length + chunk.length > _maxJwksBytes) {
        throw const FormatException('JWKS response is too large.');
      }
      bytes.add(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid JWKS response.');
    }
    return decoded;
  }

  JsonWebKey? _findSigningKey(Map<String, dynamic> jwks, String keyId) {
    final rawKeys = jwks['keys'];
    if (rawKeys is! List) return null;
    for (final rawKey in rawKeys) {
      if (rawKey is! Map) continue;
      final keyJson = Map<String, dynamic>.from(rawKey);
      if (keyJson['kid'] != keyId ||
          keyJson['kty'] != 'RSA' ||
          (keyJson['alg'] != null && keyJson['alg'] != 'RS256') ||
          (keyJson['use'] != null && keyJson['use'] != 'sig')) {
        continue;
      }
      try {
        return JsonWebKey.fromJson(keyJson);
      } on Object {
        return null;
      }
    }
    return null;
  }

  String? _stringClaim(Object? value) => value is String ? value : null;

  bool _isGoogleIssuer(String? issuer) =>
      issuer == 'https://accounts.google.com' ||
      issuer == 'accounts.google.com';

  bool _isValidEmail(String email) {
    final at = email.indexOf('@');
    return at > 0 && at == email.lastIndexOf('@') && at < email.length - 1;
  }

  Future<void> close() async {
    if (_ownsClient) _client.close();
  }
}

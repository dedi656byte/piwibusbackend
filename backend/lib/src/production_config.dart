import 'dart:io';

class ProductionConfig {
  ProductionConfig._({
    required this.environment,
    required this.databaseUrl,
    required this.redisUrl,
    required this.corsOrigin,
    required this.jwtSecret,
    required this.allowDevDefaults,
  });

  final String environment;
  final String databaseUrl;
  final String redisUrl;
  final String corsOrigin;
  final String jwtSecret;
  final bool allowDevDefaults;

  bool get isProduction => environment == 'production';

  factory ProductionConfig.fromEnvironment() {
    return ProductionConfig._(
      environment: (Platform.environment['PIWIBUS_ENV'] ?? 'development')
          .trim()
          .toLowerCase(),
      databaseUrl:
          (Platform.environment['PIWIBUS_DATABASE_URL'] ??
                  Platform.environment['DATABASE_URL'] ??
                  '')
              .trim(),
      redisUrl:
          (Platform.environment['PIWIBUS_REDIS_URL'] ??
                  Platform.environment['REDIS_URL'] ??
                  '')
              .trim(),
      corsOrigin: (Platform.environment['PIWIBUS_CORS_ORIGIN'] ?? '*').trim(),
      jwtSecret:
          (Platform.environment['PIWIBUS_JWT_SECRET'] ??
                  Platform.environment['JWT_SECRET'] ??
                  '')
              .trim(),
      allowDevDefaults:
          (Platform.environment['PIWIBUS_ALLOW_DEV_DEFAULTS'] ?? '')
              .trim()
              .toLowerCase() ==
          'true',
    );
  }

  void validateOrThrow() {
    if (!isProduction || allowDevDefaults) return;

    final failures = <String>[];
    if (databaseUrl.isEmpty) {
      failures.add('PIWIBUS_DATABASE_URL est requis en production.');
    }
    if (redisUrl.isEmpty) {
      failures.add(
        'PIWIBUS_REDIS_URL est requis en production multi-instance.',
      );
    }
    if (corsOrigin.isEmpty || corsOrigin == '*') {
      failures.add('PIWIBUS_CORS_ORIGIN doit etre restreint en production.');
    }
    if (jwtSecret.length < 32 ||
        jwtSecret == 'piwibus-development-secret-change-me') {
      failures.add('PIWIBUS_JWT_SECRET doit contenir au moins 32 caracteres.');
    }
    if (failures.isNotEmpty) {
      throw StateError(failures.join(' '));
    }
  }
}

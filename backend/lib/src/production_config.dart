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

  factory ProductionConfig.fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final env = environment ?? Platform.environment;
    return ProductionConfig._(
      environment: (env['PIWIBUS_ENV'] ?? 'development')
          .trim()
          .toLowerCase(),
      databaseUrl:
          (env['PIWIBUS_DATABASE_URL'] ??
                  env['DATABASE_URL'] ??
                  '')
              .trim(),
      redisUrl:
          (env['PIWIBUS_REDIS_URL'] ??
                  env['REDIS_URL'] ??
                  '')
              .trim(),
      corsOrigin: (env['PIWIBUS_CORS_ORIGIN'] ?? '*').trim(),
      jwtSecret:
          (env['PIWIBUS_JWT_SECRET'] ??
                  env['JWT_SECRET'] ??
                  '')
              .trim(),
      allowDevDefaults: (env['PIWIBUS_ALLOW_DEV_DEFAULTS'] ?? '')
              .trim()
              .toLowerCase() ==
          'true',
    );
  }

  void validateOrThrow() {
    const supportedEnvironments = <String>{
      'development',
      'test',
      'production',
    };
    if (!supportedEnvironments.contains(environment)) {
      throw StateError(
        'PIWIBUS_ENV invalide. Valeurs acceptees : '
        '${supportedEnvironments.join(', ')}.',
      );
    }
    if (!isProduction) return;

    final failures = <String>[];
    if (allowDevDefaults) {
      failures.add(
        'PIWIBUS_ALLOW_DEV_DEFAULTS ne peut pas etre active en production.',
      );
    }
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

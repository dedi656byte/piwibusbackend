import 'package:piwibus_backend/src/production_config.dart';
import 'package:test/test.dart';

void main() {
  group('ProductionConfig', () {
    test('rejects unknown environments', () {
      final config = ProductionConfig.fromEnvironment(<String, String>{
        'PIWIBUS_ENV': 'prod',
      });

      expect(config.validateOrThrow, throwsStateError);
    });

    test('does not allow development defaults in production', () {
      final config = ProductionConfig.fromEnvironment(<String, String>{
        'PIWIBUS_ENV': 'production',
        'PIWIBUS_ALLOW_DEV_DEFAULTS': 'true',
        'PIWIBUS_DATABASE_URL': 'postgres://localhost/piwibus',
        'PIWIBUS_REDIS_URL': 'redis://localhost:6379',
        'PIWIBUS_CORS_ORIGIN': 'https://piwibus.example',
        'PIWIBUS_JWT_SECRET': 'a-production-secret-longer-than-32-characters',
      });

      expect(config.validateOrThrow, throwsStateError);
    });

    test('accepts an explicit development environment', () {
      final config = ProductionConfig.fromEnvironment(<String, String>{
        'PIWIBUS_ENV': 'development',
        'PIWIBUS_ALLOW_DEV_DEFAULTS': 'true',
      });

      expect(config.validateOrThrow, returnsNormally);
    });
  });
}

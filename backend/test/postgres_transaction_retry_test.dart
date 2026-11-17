import 'package:postgres/postgres.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:test/test.dart';

void main() {
  group('PostgreSQL transaction deadlock retry', () {
    test(
      'retries a deadlocked transaction and returns its successful result',
      () async {
        var attempts = 0;

        final result = await runPostgresTransactionWithDeadlockRetry<int>(
          () async {
            attempts += 1;
            if (attempts < 3) {
              throw _TestServerException('40P01');
            }
            return 42;
          },
        );

        expect(result, 42);
        expect(attempts, 3);
      },
    );

    test('does not retry non-deadlock PostgreSQL errors', () async {
      var attempts = 0;
      final failure = _TestServerException('23505');

      await expectLater(
        runPostgresTransactionWithDeadlockRetry<void>(() async {
          attempts += 1;
          throw failure;
        }),
        throwsA(same(failure)),
      );

      expect(attempts, 1);
    });
  });
}

class _TestServerException implements ServerException {
  _TestServerException(this.code);

  @override
  final String? code;

  @override
  Severity get severity => Severity.error;

  @override
  String get message => 'Test PostgreSQL error.';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'dart:async';
import 'dart:convert';

import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  group('PostgreSQL pool pressure', () {
    test('coalesces readiness probes and caches success briefly', () async {
      final persistence = _ProbeCountingPersistence();
      final store = await PiwibusStore.openWithPersistence(
        persistence,
        bootstrapAdminEnvironment: const <String, String>{},
      );
      addTearDown(store.close);

      await Future.wait(
        List<Future<void>>.generate(8, (_) => store.checkReady()),
      );
      expect(persistence.readinessChecks, 1);

      await store.checkReady();
      expect(persistence.readinessChecks, 1);

      await Future<void>.delayed(const Duration(milliseconds: 1050));
      await store.checkReady();
      expect(persistence.readinessChecks, 2);
    });

    test('does not cache failed readiness probes', () async {
      final persistence = _ProbeCountingPersistence()
        ..failNextReadinessCheck = true;
      final store = await PiwibusStore.openWithPersistence(
        persistence,
        bootstrapAdminEnvironment: const <String, String>{},
      );
      addTearDown(store.close);

      await expectLater(store.checkReady(), throwsA(isA<StateError>()));
      await store.checkReady();

      expect(persistence.readinessChecks, 2);
    });

    test('coalesces concurrent session revision probes', () async {
      final persistence = _ProbeCountingPersistence();
      final store = await PiwibusStore.openWithPersistence(
        persistence,
        bootstrapAdminEnvironment: const <String, String>{},
      );
      addTearDown(store.close);
      final sessionId = await store.ensureSession('pool-test-session');
      await Future<void>.delayed(const Duration(milliseconds: 1050));
      persistence.externalRevisionChecks = 0;

      await Future.wait(
        List<Future<String>>.generate(8, (_) => store.ensureSession(sessionId)),
      );

      expect(persistence.externalRevisionChecks, 1);
    });

    test(
      'external-change notifications bypass the revision-check cache',
      () async {
        final persistence = _ProbeCountingPersistence();
        final store = await PiwibusStore.openWithPersistence(
          persistence,
          bootstrapAdminEnvironment: const <String, String>{},
        );
        addTearDown(store.close);
        await store.ensureSession('pool-test-session');
        final checksBeforeRefresh = persistence.externalRevisionChecks;
        final revisionBeforeRefresh = store.sharedRevision;
        persistence.externalChanges = true;

        await store.refreshFromPersistence();

        expect(persistence.externalRevisionChecks, checksBeforeRefresh + 1);
        expect(store.sharedRevision, greaterThan(revisionBeforeRefresh));
      },
    );
  });
}

class _ProbeCountingPersistence extends StatePersistence {
  Map<String, dynamic>? state;
  int readinessChecks = 0;
  int externalRevisionChecks = 0;
  bool externalChanges = false;
  bool failNextReadinessCheck = false;

  @override
  String get name => 'probe-counting-test';

  @override
  Future<Map<String, dynamic>?> loadState() async {
    final currentState = state;
    return currentState == null
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(jsonEncode(currentState)) as Map,
          );
  }

  @override
  Future<void> saveState(Map<String, dynamic> state) async {
    this.state = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(state)) as Map,
    );
  }

  @override
  Future<void> checkReady() async {
    readinessChecks += 1;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (failNextReadinessCheck) {
      failNextReadinessCheck = false;
      throw StateError('Test readiness failure.');
    }
  }

  @override
  Future<bool> hasExternalChanges() async {
    externalRevisionChecks += 1;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return externalChanges;
  }
}

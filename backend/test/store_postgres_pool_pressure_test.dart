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

    test('waits for external refreshes before closing persistence', () async {
      final persistence = _BlockingRefreshPersistence();
      final store = await PiwibusStore.openWithPersistence(
        persistence,
        bootstrapAdminEnvironment: const <String, String>{},
      );
      final refresh = store.refreshFromPersistence();
      await persistence.refreshStarted.future;

      final close = store.close();
      await Future<void>.delayed(Duration.zero);
      final closedWhileRefreshing = persistence.closed;

      persistence.releaseRefresh.complete();
      await expectLater(refresh, completes);
      await close;

      expect(closedWhileRefreshing, isFalse);
      expect(persistence.closed, isTrue);
    });

    test(
      'waits for deferred external reloads after writes before closing',
      () async {
        final persistence = _BlockingMutationPersistence();
        final store = await PiwibusStore.openWithPersistence(
          persistence,
          bootstrapAdminEnvironment: const <String, String>{},
        );
        final session = store.ensureSession('close-race-session');
        await persistence.mutationStarted.future;

        persistence.externalChanges = true;
        await store.refreshFromPersistence();
        final close = store.close();
        await Future<void>.delayed(Duration.zero);
        final closedWhileWriting = persistence.closed;

        persistence.releaseMutation.complete();
        await expectLater(session, completes);
        await close;

        expect(closedWhileWriting, isFalse);
        expect(persistence.closed, isTrue);
      },
    );
  });
}

class _BlockingRefreshPersistence extends _ProbeCountingPersistence {
  final Completer<void> refreshStarted = Completer<void>();
  final Completer<void> releaseRefresh = Completer<void>();
  bool closed = false;

  @override
  Future<bool> hasExternalChanges() async {
    refreshStarted.complete();
    await releaseRefresh.future;
    return true;
  }

  @override
  Future<Map<String, dynamic>?> loadState() {
    if (closed) {
      throw StateError('Persistence was closed before refresh completed.');
    }
    return super.loadState();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _BlockingMutationPersistence extends _ProbeCountingPersistence {
  final Completer<void> mutationStarted = Completer<void>();
  final Completer<void> releaseMutation = Completer<void>();
  bool closed = false;
  bool _blockNextMutation = true;

  @override
  Future<void> applyMutations({
    required Map<String, dynamic> state,
    required StateMutationBatch batch,
  }) async {
    if (_blockNextMutation) {
      _blockNextMutation = false;
      mutationStarted.complete();
      await releaseMutation.future;
    }
    await super.applyMutations(state: state, batch: batch);
  }

  @override
  Future<Map<String, dynamic>?> loadState() {
    if (closed) {
      throw StateError('Persistence was closed before write completed.');
    }
    return super.loadState();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
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

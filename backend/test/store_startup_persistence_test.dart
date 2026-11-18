import 'dart:convert';

import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  group('Store startup persistence', () {
    test('keeps the bootstrap admin hash stable between startups', () async {
      final persistence = _ConcurrentMutationPersistence(conflictsRemaining: 0);
      const environment = <String, String>{
        'PIWIBUS_ADMIN_EMAIL': 'bootstrap@example.test',
        'PIWIBUS_ADMIN_PASSWORD': 'bootstrap-password-123',
      };

      final firstStore = await PiwibusStore.openWithPersistence(
        persistence,
        bootstrapAdminEnvironment: environment,
      );
      final firstAdmin = (persistence.persistedState['users'] as List)
          .cast<Map<String, dynamic>>()
          .single;
      final firstHash = firstAdmin['passwordHash'];
      firstAdmin.addAll(<String, dynamic>{
        'nameChangedAt': null,
        'googleSubject': '',
        'passwordResetHash': '',
        'passwordResetRequestedAt': null,
        'passwordResetExpiresAt': null,
        'passwordResetAttempts': 0,
        'activityReadAt': null,
      });
      firstAdmin.remove('isSuperAdmin');
      (persistence.persistedState['sessions']
          as Map)['admin-session'] = <String, dynamic>{
        'currentUser': <String, dynamic>{
          'id': firstAdmin['id'],
          'primaryRole': 'administrateur',
          'status': 'actif',
        },
        'activeRole': 'administrateur',
        'section': 'accueil',
        'isOnline': false,
        'searchQuery': '',
        'selectedLineCode': null,
        'selectedTripId': null,
        'favoriteLineCodes': <String>[],
        'currentLocation': null,
        'createdAt': '2026-01-01T00:00:00.000Z',
        'lastSeenAt': '2026-01-01T00:00:00.000Z',
      };
      await firstStore.close();

      final databaseStateBeforeSecondStart =
          jsonDecode(jsonEncode(persistence.persistedState))
              as Map<String, dynamic>;
      final secondStore = await PiwibusStore.openWithPersistence(
        persistence,
        bootstrapAdminEnvironment: environment,
      );
      addTearDown(secondStore.close);

      final secondAdmin = (persistence.persistedState['users'] as List)
          .cast<Map<String, dynamic>>()
          .single;
      expect(secondAdmin['passwordHash'], firstHash);
      final secondPersistedAdmin = Map<String, dynamic>.from(secondAdmin)
        ..remove('isSuperAdmin');
      expect(secondPersistedAdmin, equals(firstAdmin));
      expect(
        persistence.persistedState,
        equals(databaseStateBeforeSecondStart),
      );
      expect(persistence.saveCount, 1);
    });

    test('does not rewrite an already normalized database state', () async {
      final persistence = _ConcurrentMutationPersistence(conflictsRemaining: 0);

      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(store.close);

      expect(persistence.loadCount, 1);
      expect(persistence.saveCount, 0);
    });

    test('publishes shared changes after persistence succeeds', () async {
      final persistence = _ConcurrentMutationPersistence(conflictsRemaining: 0);
      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(store.close);
      final savesBeforeChange = persistence.saveCount;
      final localChange = store.sharedChanges.first.timeout(
        const Duration(seconds: 1),
      );
      var publishedChanges = 0;
      store.attachChangePublisher(() async {
        expect(persistence.saveCount, greaterThan(savesBeforeChange));
        publishedChanges += 1;
      });

      await store.publishActivity(
        title: 'Test',
        subtitle: 'Persist before publish',
        iconKey: 'info',
        colorValue: 0,
      );

      expect(publishedChanges, 1);
      expect(await localChange, 1);
    });

    test('does not notify clients when persistence fails', () async {
      final persistence = _ConcurrentMutationPersistence(conflictsRemaining: 0);
      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(store.close);
      var localChanges = 0;
      store.sharedChanges.listen((_) => localChanges += 1);
      persistence.failNextSave = true;

      await expectLater(
        store.publishActivity(
          title: 'Test',
          subtitle: 'Do not publish before commit',
          iconKey: 'info',
          colorValue: 0,
        ),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(localChanges, 0);
    });

    test(
      'retries session touch after a concurrent database mutation',
      () async {
        final persistence = _ConcurrentMutationPersistence(
          conflictsRemaining: 0,
        );
        final firstStore = await PiwibusStore.openWithPersistence(persistence);
        final sessionId = await firstStore.ensureSession(null);
        await firstStore.register(sessionId, <String, dynamic>{
          'fullName': 'Events User',
          'email': 'events-user@example.test',
          'password': 'events-user-password-123',
        });
        await firstStore.close();

        final sessions =
            persistence.persistedState['sessions'] as Map<String, dynamic>;
        final session = Map<String, dynamic>.from(sessions[sessionId] as Map)
          ..['lastSeenAt'] = DateTime.utc(2020).toIso8601String();
        sessions[sessionId] = session;
        final store = await PiwibusStore.openWithPersistence(persistence);
        addTearDown(store.close);
        persistence.conflictsRemaining = 1;

        expect(await store.ensureSession(sessionId), sessionId);
        expect(persistence.conflictsRemaining, 0);
        expect(
          (persistence.persistedState['activity'] as List)
              .cast<Map<String, dynamic>>()
              .single['id'],
          'concurrent-activity',
        );
        final persistedSession =
            (persistence.persistedState['sessions']
                    as Map<String, dynamic>)[sessionId]
                as Map<String, dynamic>;
        expect(
          DateTime.parse(persistedSession['lastSeenAt'] as String),
          isNot(DateTime.utc(2020)),
        );
      },
    );

    test('reloads and retries after a concurrent database mutation', () async {
      final persistence = _ConcurrentMutationPersistence(conflictsRemaining: 1);
      persistence.persistedState = _nonCanonicalState();
      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(store.close);

      expect(persistence.loadCount, 2);
      expect(persistence.saveCount, 2);
      expect(
        (persistence.persistedState['activity'] as List)
            .cast<Map<String, dynamic>>()
            .single['id'],
        'concurrent-activity',
      );
    });

    test('recovers after a burst of concurrent database mutations', () async {
      final persistence = _ConcurrentMutationPersistence(conflictsRemaining: 4);
      persistence.persistedState = _nonCanonicalState();

      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(store.close);

      expect(persistence.loadCount, 5);
      expect(persistence.saveCount, 5);
      expect(
        (persistence.persistedState['activity'] as List)
            .cast<Map<String, dynamic>>()
            .single['id'],
        'concurrent-activity',
      );
    });

    test('recovers after sustained concurrent database mutations', () async {
      final persistence = _ConcurrentMutationPersistence(conflictsRemaining: 6);
      persistence.persistedState = _nonCanonicalState();

      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(store.close);

      expect(persistence.loadCount, 7);
      expect(persistence.saveCount, 7);
      expect(
        (persistence.persistedState['activity'] as List)
            .cast<Map<String, dynamic>>()
            .single['id'],
        'concurrent-activity',
      );
    });

    test('fails safely when startup retry budget is exhausted', () async {
      final persistence = _ConcurrentMutationPersistence(
        conflictsRemaining: 11,
      );
      persistence.persistedState = _nonCanonicalState();

      await expectLater(
        PiwibusStore.openWithPersistence(persistence),
        throwsA(isA<StateError>()),
      );

      expect(persistence.loadCount, 11);
      expect(persistence.saveCount, 11);
      expect(
        (persistence.persistedState['activity'] as List)
            .cast<Map<String, dynamic>>()
            .single['id'],
        'concurrent-activity',
      );
    });
  });
}

Map<String, dynamic> _nonCanonicalState() => <String, dynamic>{
  'sessions': <String, dynamic>{
    'startup-session': <String, dynamic>{'activeRole': 'invalid'},
  },
  'users': <dynamic>[],
  'trips': <dynamic>[],
  'reports': <dynamic>[],
  'pushTokens': <dynamic>[],
  'activity': <dynamic>[],
  'messageConversations': <dynamic>[],
};

class _ConcurrentMutationPersistence extends StatePersistence {
  _ConcurrentMutationPersistence({required this.conflictsRemaining});

  int conflictsRemaining;
  bool failNextSave = false;
  int loadCount = 0;
  int saveCount = 0;
  Map<String, dynamic> persistedState = <String, dynamic>{
    'sessions': <String, dynamic>{},
    'users': <dynamic>[],
    'trips': <dynamic>[],
    'reports': <dynamic>[],
    'pushTokens': <dynamic>[],
    'activity': <dynamic>[],
    'messageConversations': <dynamic>[],
  };

  @override
  String get name => 'concurrent-mutation-test';

  @override
  bool get isDatabaseBacked => true;

  @override
  Future<Map<String, dynamic>?> loadState() async {
    loadCount += 1;
    return Map<String, dynamic>.from(
      jsonDecode(jsonEncode(persistedState)) as Map,
    );
  }

  @override
  Future<void> saveState(Map<String, dynamic> state) async {
    saveCount += 1;
    if (failNextSave) {
      failNextSave = false;
      throw StateError('Test persistence failure.');
    }
    if (conflictsRemaining > 0) {
      conflictsRemaining -= 1;
      if (conflictsRemaining == 0) {
        persistedState['activity'] = <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'concurrent-activity',
            'title': 'Concurrent update',
            'subtitle': 'Added while the backend was starting',
            'timestamp': DateTime.utc(2026, 11, 2).toIso8601String(),
            'iconKey': 'info',
            'colorValue': 0,
            'audienceSessionIds': <String>[],
            'audienceUserIds': <String>[],
          },
        ];
      }
      throw const ConcurrentStateMutationException();
    }

    persistedState = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(state)) as Map,
    );
  }
}

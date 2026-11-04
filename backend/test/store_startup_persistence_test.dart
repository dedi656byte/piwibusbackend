import 'dart:convert';

import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  group('Store startup persistence', () {
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

    test('reloads and retries after a concurrent database mutation', () async {
      final persistence = _ConcurrentMutationPersistence(conflictsRemaining: 1);
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

    test('fails safely after three startup retries are exhausted', () async {
      final persistence = _ConcurrentMutationPersistence(conflictsRemaining: 4);

      await expectLater(
        PiwibusStore.openWithPersistence(persistence),
        throwsA(isA<StateError>()),
      );

      expect(persistence.loadCount, 4);
      expect(persistence.saveCount, 4);
      expect(
        (persistence.persistedState['activity'] as List)
            .cast<Map<String, dynamic>>()
            .single['id'],
        'concurrent-activity',
      );
    });
  });
}

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

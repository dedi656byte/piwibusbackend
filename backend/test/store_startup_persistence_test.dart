import 'dart:convert';

import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  group('Store startup persistence', () {
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

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  group('Message persistence retry', () {
    late Directory tempDir;
    late File stateFile;
    late _FailOnceMessagePersistence persistence;
    late PiwibusStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'piwibus-message-persistence-retry',
      );
      stateFile = File(p.join(tempDir.path, 'state.json'));
      persistence = _FailOnceMessagePersistence(stateFile);
      store = await PiwibusStore.openWithPersistence(persistence);
    });

    tearDown(() async {
      await store.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('retry persists a message after the first write fails', () async {
      await store.register('sender-session', <String, dynamic>{
        'fullName': 'Sender',
        'email': 'sender@example.com',
        'password': 'password123',
      });
      await store.register('recipient-session', <String, dynamic>{
        'fullName': 'Recipient',
        'email': 'recipient@example.com',
        'password': 'password123',
      });
      final recipientId =
          (store.snapshot('recipient-session')['currentUser']
                  as Map<String, dynamic>)['id']
              as String;
      final conversationResult = await store.startMessageConversation(
        'sender-session',
        <String, dynamic>{'peerUserId': recipientId},
      );
      final conversationId =
          (conversationResult['conversation'] as Map<String, dynamic>)['id']
              as String;

      var publishedChanges = 0;
      store.attachChangePublisher(() async {
        publishedChanges += 1;
      });
      persistence.failNextMessageWrite = true;
      final messageBody = <String, dynamic>{
        'body': 'Persist me after retry',
        'messageId': 'retryable-message',
      };

      await expectLater(
        store.sendMessageItem('sender-session', conversationId, messageBody),
        throwsA(isA<StateError>()),
      );
      expect(publishedChanges, 0);
      expect(
        store.conversationMessages('sender-session', conversationId),
        isEmpty,
      );

      final retry = await store.sendMessageItem(
        'sender-session',
        conversationId,
        messageBody,
      );
      expect(
        (retry['message'] as Map<String, dynamic>)['id'],
        'retryable-message',
      );
      expect(publishedChanges, 1);

      await store.close();
      store = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(stateFile),
      );
      expect(
        store.conversationMessages('sender-session', conversationId),
        hasLength(1),
      );
    });

    test(
      'concurrent sends persist both messages with distinct sequences',
      () async {
        await store.register('concurrent-sender-session', <String, dynamic>{
          'fullName': 'Concurrent Sender',
          'email': 'concurrent-sender@example.com',
          'password': 'password123',
        });
        await store.register('concurrent-recipient-session', <String, dynamic>{
          'fullName': 'Concurrent Recipient',
          'email': 'concurrent-recipient@example.com',
          'password': 'password123',
        });
        final recipientId =
            (store.snapshot('concurrent-recipient-session')['currentUser']
                    as Map<String, dynamic>)['id']
                as String;
        final conversationResult = await store.startMessageConversation(
          'concurrent-sender-session',
          <String, dynamic>{'peerUserId': recipientId},
        );
        final conversationId =
            (conversationResult['conversation'] as Map<String, dynamic>)['id']
                as String;

        final results = await Future.wait(<Future<Map<String, dynamic>>>[
          store.sendMessageItem(
            'concurrent-sender-session',
            conversationId,
            <String, dynamic>{
              'body': 'First concurrent message',
              'messageId': 'concurrent-message-1',
            },
          ),
          store.sendMessageItem(
            'concurrent-sender-session',
            conversationId,
            <String, dynamic>{
              'body': 'Second concurrent message',
              'messageId': 'concurrent-message-2',
            },
          ),
        ]);

        expect(results, hasLength(2));
        final messages = store.conversationMessages(
          'concurrent-sender-session',
          conversationId,
        );
        expect(messages.map((message) => message['id']).toSet(), {
          'concurrent-message-1',
          'concurrent-message-2',
        });
        expect(messages.map((message) => message['sequence']).toSet(), {1, 2});

        await store.close();
        store = await PiwibusStore.openWithPersistence(
          JsonFileStatePersistence(stateFile),
        );
        final restoredMessages = store.conversationMessages(
          'concurrent-sender-session',
          conversationId,
        );
        expect(restoredMessages, hasLength(2));
        expect(restoredMessages.map((message) => message['sequence']).toSet(), {
          1,
          2,
        });
      },
    );
  });
}

class _FailOnceMessagePersistence extends JsonFileStatePersistence {
  _FailOnceMessagePersistence(super.stateFile);

  bool failNextMessageWrite = false;

  @override
  Future<void> applyMutations({
    required Map<String, dynamic> state,
    required StateMutationBatch batch,
  }) {
    if (batch.messageConversations && failNextMessageWrite) {
      failNextMessageWrite = false;
      throw StateError('Simulated message persistence failure.');
    }
    return super.applyMutations(state: state, batch: batch);
  }
}

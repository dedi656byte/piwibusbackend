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

      persistence.failNextMessageWrite = true;
      final messageBody = <String, dynamic>{
        'body': 'Persist me after retry',
        'messageId': 'retryable-message',
      };

      await expectLater(
        store.sendMessageItem('sender-session', conversationId, messageBody),
        throwsA(isA<StateError>()),
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

      await store.close();
      store = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(stateFile),
      );
      expect(
        store.conversationMessages('sender-session', conversationId),
        hasLength(1),
      );
    });
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

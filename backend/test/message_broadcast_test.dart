import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'broadcasts to registered accounts including suspended users without replies',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'piwibus-message-broadcast-',
      );
      addTearDown(() async {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });

      const adminEmail = 'broadcast-admin@example.com';
      const adminPassword = 'broadcast-admin-password';
      final passwordHash =
          'bcrypt:${BCrypt.hashpw('$adminEmail::$adminPassword', BCrypt.gensalt(logRounds: 4))}';
      final stateFile = File(p.join(tempDir.path, 'state.json'));
      await stateFile.writeAsString(
        jsonEncode(<String, dynamic>{
          'sessions': <String, dynamic>{},
          'users': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'broadcast-admin',
              'fullName': 'Broadcast Administrator',
              'email': adminEmail,
              'phone': '',
              'primaryRole': 'administrateur',
              'status': 'actif',
              'isSuperAdmin': true,
              'createdAt': '2026-01-01T00:00:00.000Z',
              'lastSeenAt': '2026-01-01T00:00:00.000Z',
              'passwordHash': passwordHash,
              'readAlertIds': <String>[],
              'starTripIds': <String>[],
              'followedTripIds': <String>[],
            },
          ],
          'trips': <dynamic>[],
          'reports': <dynamic>[],
          'pushTokens': <dynamic>[],
          'activity': <dynamic>[],
          'messageConversations': <dynamic>[],
        }),
      );
      final store = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(stateFile),
      );
      addTearDown(store.close);

      await store.signIn('broadcast-admin-session', <String, dynamic>{
        'email': adminEmail,
        'password': adminPassword,
      });
      await store.switchRole('broadcast-admin-session', 'administrateur');
      await store.register('active-recipient-session', <String, dynamic>{
        'fullName': 'Active Recipient',
        'email': 'active-recipient@example.com',
        'password': 'password123',
      });
      await store.register('suspended-recipient-session', <String, dynamic>{
        'fullName': 'Suspended Recipient',
        'email': 'suspended-recipient@example.com',
        'password': 'password123',
      });
      final adminId =
          (store.snapshot('broadcast-admin-session')['currentUser']
                  as Map)['id']
              as String;
      final activeRecipientId =
          (store.snapshot('active-recipient-session')['currentUser']
                  as Map)['id']
              as String;
      final suspendedRecipientId =
          (store.snapshot('suspended-recipient-session')['currentUser']
                  as Map)['id']
              as String;
      await store.toggleUserStatus(
        'broadcast-admin-session',
        suspendedRecipientId,
      );

      final result = await store.sendBroadcastMessage(
        'broadcast-admin-session',
        <String, dynamic>{'body': 'Information pour tous.'},
      );
      final conversation = result['conversation'] as Map<String, dynamic>;
      final conversationId = conversation['id'] as String;

      expect(conversation['kind'], 'broadcast');
      expect(conversation['participantIds'], <String>[adminId]);
      final activeRecipientConversation = store
          .messageConversationsForSession('active-recipient-session')
          .single;
      expect(activeRecipientConversation['title'], 'piwibus');
      expect(activeRecipientConversation['participantIds'], <String>[
        activeRecipientId,
      ]);
      final suspendedRecipientConversation = store
          .messageConversationsForSession('suspended-recipient-session')
          .single;
      expect(suspendedRecipientConversation['title'], 'piwibus');
      expect(suspendedRecipientConversation['participantIds'], <String>[
        suspendedRecipientId,
      ]);
      final receivedMessage = store
          .conversationMessages('active-recipient-session', conversationId)
          .single;
      expect(receivedMessage['senderName'], 'piwibus');
      expect(receivedMessage['body'], 'Information pour tous.');

      final updateResult = await store
          .sendBroadcastMessage('broadcast-admin-session', <String, dynamic>{
            'type': 'app_update',
            'appVersion': '8.42.1+3076',
            'body': 'Texte fourni par le client à ignorer.',
          });
      final updateMessage = updateResult['message'] as Map<String, dynamic>;
      expect(updateMessage['senderName'], 'piwibus');
      expect(
        updateMessage['body'],
        'télécharger la nouvelle version en cliquant sur ce message',
      );
      expect(updateMessage['type'], 'app_update');
      expect(updateMessage['appVersion'], '8.42.1+3076');
      final updateConversation =
          updateResult['conversation'] as Map<String, dynamic>;
      expect(updateConversation['id'], conversationId);
      expect(
        store
            .messageConversationsForSession('active-recipient-session')
            .where((item) => item['kind'] == 'broadcast'),
        hasLength(1),
      );
      final receivedUpdate = store
          .conversationMessages('active-recipient-session', conversationId)
          .last;
      expect(receivedUpdate['type'], 'app_update');
      expect(receivedUpdate['appVersion'], '8.42.1+3076');
      expect(
        store
            .conversationMessages('active-recipient-session', conversationId)
            .map((item) => item['sequence']),
        <int>[1, 2],
      );

      await expectLater(
        store.sendBroadcastMessage('broadcast-admin-session', <String, dynamic>{
          'type': 'app_update',
          'appVersion': 'version invalide',
        }),
        throwsA(isA<StateError>()),
      );

      final persistedState =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      final persistedConversations =
          persistedState['messageConversations'] as List;
      final canonicalConversation = Map<String, dynamic>.from(
        persistedConversations.single as Map,
      );
      final originalMessages = canonicalConversation['messages'] as List;
      final originalMessage = Map<String, dynamic>.from(
        originalMessages.first as Map,
      );
      final legacyUpdateMessage = Map<String, dynamic>.from(
        originalMessages.last as Map,
      );
      final conversationParticipants = List<String>.from(
        canonicalConversation['participantIds'] as List,
      );
      final oldReadSequences = Map<String, int>.from(
        canonicalConversation['readSequences'] as Map,
      );
      final originalConversation = <String, dynamic>{
        ...canonicalConversation,
        'messageCursor': 1,
        'messageRevision': 1,
        'lastMessageId': originalMessage['id'],
        'lastSenderId': originalMessage['senderId'],
        'lastMessagePreview': originalMessage['body'],
        'readSequences': <String, int>{
          for (final participantId in conversationParticipants)
            participantId: oldReadSequences[participantId] == 1 ? 1 : 0,
        },
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            ...originalMessage,
            'conversationId': conversationId,
            'sequence': 1,
            'updateRevision': 1,
          },
        ],
      };
      final legacyUpdateId = 'legacy-update-broadcast';
      final legacyUpdateConversation = <String, dynamic>{
        ...canonicalConversation,
        'id': legacyUpdateId,
        'messageCursor': 1,
        'messageRevision': 1,
        'createdAt': legacyUpdateMessage['createdAt'],
        'updatedAt': legacyUpdateMessage['createdAt'],
        'lastMessageId': legacyUpdateMessage['id'],
        'lastSenderId': legacyUpdateMessage['senderId'],
        'lastMessagePreview': legacyUpdateMessage['body'],
        'readSequences': <String, int>{
          for (final participantId in conversationParticipants)
            participantId: oldReadSequences[participantId] == 2 ? 1 : 0,
        },
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            ...legacyUpdateMessage,
            'conversationId': legacyUpdateId,
            'sequence': 1,
            'updateRevision': 1,
          },
        ],
      };
      persistedState['messageConversations'] = <Map<String, dynamic>>[
        legacyUpdateConversation,
        originalConversation,
      ];
      await stateFile.writeAsString(jsonEncode(persistedState));

      final migratedStore = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(stateFile),
      );
      addTearDown(migratedStore.close);
      final migratedConversation = migratedStore
          .messageConversationsForSession('active-recipient-session')
          .single;
      expect(migratedConversation['id'], conversationId);
      expect(migratedConversation['unreadCount'], 2);
      expect(
        migratedStore
            .conversationMessages('active-recipient-session', conversationId)
            .map((item) => item['body']),
        <String>[
          'Information pour tous.',
          'télécharger la nouvelle version en cliquant sur ce message',
        ],
      );
      final concurrentFollowUps = await Future.wait(<Future<JsonMap>>[
        migratedStore.sendBroadcastMessage(
          'broadcast-admin-session',
          <String, dynamic>{'body': 'Prochaine information A'},
        ),
        migratedStore.sendBroadcastMessage(
          'broadcast-admin-session',
          <String, dynamic>{'body': 'Prochaine information B'},
        ),
      ]);
      expect(
        concurrentFollowUps.map(
          (result) => (result['conversation'] as Map<String, dynamic>)['id'],
        ),
        everyElement(conversationId),
      );
      expect(
        concurrentFollowUps
            .map(
              (result) =>
                  (result['message'] as Map<String, dynamic>)['sequence'],
            )
            .toSet(),
        <int>{3, 4},
      );
      expect(
        migratedStore
            .conversationMessages('active-recipient-session', conversationId)
            .map((message) => message['sequence']),
        <int>[1, 2, 3, 4],
      );

      await expectLater(
        store.sendMessageItem(
          'active-recipient-session',
          conversationId,
          <String, dynamic>{'body': 'Réponse interdite.'},
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        store.sendMessageItem(
          'broadcast-admin-session',
          conversationId,
          <String, dynamic>{'body': 'Second message non confirmé.'},
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        store.sendBroadcastMessage(
          'active-recipient-session',
          <String, dynamic>{'body': 'Annonce non autorisée.'},
        ),
        throwsA(isA<StateError>()),
      );
    },
  );
}

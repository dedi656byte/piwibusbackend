import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/ops_logger.dart';
import 'package:piwibus_backend/src/push_notifications.dart';
import 'package:piwibus_backend/src/push_outbox_worker.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  group('PushNotificationService', () {
    test(
      'reports unregistered tokens separately from retryable failures',
      () async {
        final service = _pushService((request) async {
          final token = _tokenFromRequest(request);
          if (token == 'unregistered-token') {
            return http.Response(jsonEncode(_unregisteredTokenResponse), 404);
          }
          return http.Response('{}', 200);
        });
        addTearDown(service.close);

        final result = await service.sendToTokensWithResult(
          tokens: const ['unregistered-token', 'delivered-token'],
          title: 'Trajet démarré',
          body: 'Une ligne est proche.',
        );

        expect(result.invalidTokens, {'unregistered-token'});
        expect(result.hasRetryableFailures, isFalse);
      },
    );

    test('keeps transient FCM failures retryable', () async {
      final service = _pushService((request) async {
        final token = _tokenFromRequest(request);
        if (token == 'unregistered-token') {
          return http.Response(jsonEncode(_unregisteredTokenResponse), 404);
        }
        return http.Response('{}', 503);
      });
      addTearDown(service.close);

      final result = await service.sendToTokensWithResult(
        tokens: const ['unregistered-token', 'temporarily-unavailable-token'],
        title: 'Trajet démarré',
        body: 'Une ligne est proche.',
      );

      expect(result.invalidTokens, {'unregistered-token'});
      expect(result.hasRetryableFailures, isTrue);
    });

    test('does not classify an unrelated 404 as an invalid token', () async {
      final service = _pushService(
        (_) async => http.Response(
          jsonEncode(<String, Object>{
            'error': <String, Object>{
              'status': 'NOT_FOUND',
              'message': 'A different resource was not found.',
            },
          }),
          404,
        ),
      );
      addTearDown(service.close);

      final result = await service.sendToTokensWithResult(
        tokens: const ['push-token'],
        title: 'Trajet démarré',
        body: 'Une ligne est proche.',
      );

      expect(result.invalidTokens, isEmpty);
      expect(result.hasRetryableFailures, isTrue);
    });
  });

  test(
    'worker disables unregistered tokens and acknowledges the push event',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'piwibus-push-outbox-',
      );
      addTearDown(() async {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });
      final persistence = _PushWorkerPersistence(
        File(p.join(tempDir.path, 'state.json')),
      );
      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(store.close);

      await store.register('push-owner-session', <String, dynamic>{
        'fullName': 'Push Owner',
        'email': 'push-owner@example.com',
        'password': 'password123',
      });
      await store.registerPushToken('push-owner-session', <String, dynamic>{
        'token': 'unregistered-push-token-1234567890',
        'platform': 'android',
      });
      final currentUser =
          store.snapshot('push-owner-session')['currentUser'] as Map;
      final event = StateOutboxEvent(
        id: 'push:test-unregistered-token',
        type: 'push_notification',
        payload: <String, dynamic>{
          'title': 'Trajet démarré',
          'body': 'Une ligne est proche.',
          'recipientUserIds': <String>[currentUser['id'].toString()],
          'data': <String, String>{'eventId': 'test-unregistered-token'},
        },
      );
      persistence.event = event;

      final service = _pushService(
        (_) async => http.Response(jsonEncode(_unregisteredTokenResponse), 404),
      );
      addTearDown(service.close);
      final worker = PushOutboxWorker(
        store: store,
        pushNotifications: service,
        logger: const OpsLogger(),
        workerId: 'push-worker-test',
      );
      worker.start();
      await persistence.published.future.timeout(const Duration(seconds: 2));
      await worker.close();

      expect(persistence.publishedEventId, event.id);
      expect(persistence.retryCount, 0);
      expect(store.pushTokensForOutboxEvent(event.payload), isEmpty);

      final reloadedStore = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(persistence.stateFile),
      );
      addTearDown(reloadedStore.close);
      expect(reloadedStore.pushTokensForOutboxEvent(event.payload), isEmpty);
    },
  );

  test(
    'failed token disable persistence leaves the token active for retry',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'piwibus-push-token-persistence-',
      );
      addTearDown(() async {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });
      final persistence = _PushWorkerPersistence(
        File(p.join(tempDir.path, 'state.json')),
      );
      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(store.close);

      await store.register('push-owner-session', <String, dynamic>{
        'fullName': 'Push Owner',
        'email': 'push-owner@example.com',
        'password': 'password123',
      });
      await store.registerPushToken('push-owner-session', <String, dynamic>{
        'token': 'unregistered-push-token-1234567890',
        'platform': 'android',
      });
      persistence.failNextSave = true;

      await expectLater(
        store.disablePushTokens(const ['unregistered-push-token-1234567890']),
        throwsA(isA<StateError>()),
      );
      expect(
        store.pushTokensForOutboxEvent(const {
          'recipientSessionIds': ['push-owner-session'],
        }),
        ['unregistered-push-token-1234567890'],
      );

      expect(
        await store.disablePushTokens(const [
          'unregistered-push-token-1234567890',
        ]),
        1,
      );
      expect(
        store.pushTokensForOutboxEvent(const {
          'recipientSessionIds': ['push-owner-session'],
        }),
        isEmpty,
      );
    },
  );
}

PushNotificationService _pushService(
  Future<http.Response> Function(http.Request) handler,
) {
  return PushNotificationService.forTesting(
    projectId: 'piwibus-test',
    logger: const OpsLogger(),
    authorizedClient: MockClient(handler),
  );
}

String _tokenFromRequest(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  return ((body['message'] as Map<String, dynamic>)['token'] as String);
}

const _unregisteredTokenResponse = <String, Object>{
  'error': <String, Object>{
    'code': 404,
    'message': 'NotRegistered',
    'status': 'NOT_FOUND',
    'details': <Object>[
      <String, Object>{
        '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError',
        'errorCode': 'UNREGISTERED',
      },
    ],
  },
};

class _PushWorkerPersistence extends JsonFileStatePersistence {
  _PushWorkerPersistence(this.stateFile) : super(stateFile);

  final File stateFile;
  final Completer<void> published = Completer<void>();
  StateOutboxEvent? event;
  String? publishedEventId;
  int retryCount = 0;
  bool _claimed = false;
  bool failNextSave = false;

  @override
  Future<void> saveState(Map<String, dynamic> state) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('Test persistence failure.');
    }
    await super.saveState(state);
  }

  @override
  Future<List<StateOutboxEvent>> claimOutboxEvents({
    required String workerId,
    required String type,
    int limit = 50,
    Duration lease = const Duration(seconds: 30),
  }) async {
    if (_claimed || event == null || type != 'push_notification') {
      return const <StateOutboxEvent>[];
    }
    _claimed = true;
    return <StateOutboxEvent>[event!];
  }

  @override
  Future<void> markOutboxEventPublished({
    required String workerId,
    required String eventId,
  }) async {
    publishedEventId = eventId;
    if (!published.isCompleted) published.complete();
  }

  @override
  Future<void> retryOutboxEvent({
    required String workerId,
    required String eventId,
    required String error,
    Duration delay = const Duration(seconds: 5),
    int maxAttempts = 8,
  }) async {
    retryCount += 1;
  }
}

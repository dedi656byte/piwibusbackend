import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/route_proximity.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  group('trip chat conversations', () {
    test('notifies the trip owner when a new like is added', () async {
      final store = await _openTempStore('piwibus-trip-like');
      final line = store.lines().first;
      final lineCode = _string(line['code']);

      await store.register('owner-session', <String, dynamic>{
        'fullName': 'Trip Owner',
        'email': 'owner@example.com',
        'password': 'password123',
      });
      await store.register('liker-session', <String, dynamic>{
        'fullName': 'Trip Liker',
        'email': 'liker@example.com',
        'password': 'password123',
      });
      await store.startTrip('owner-session', <String, dynamic>{
        'tripId': 'trip-like-test',
        'lineCode': lineCode,
        'liveLocation': _routePointLocation(line),
      });
      await store.selectTrip('liker-session', 'trip-like-test');

      final result = await store.setTripLike(
        'liker-session',
        'trip-like-test',
        true,
      );
      expect(result['tripLikeChanged'], isTrue);
      final ownerActivity = store.snapshot('owner-session')['activity'] as List;
      expect(
        ownerActivity.any(
          (item) => item is Map && item['title'] == "Nouveau j'aime",
        ),
        isTrue,
      );

      final duplicate = await store.setTripLike(
        'liker-session',
        'trip-like-test',
        true,
      );
      expect(duplicate['tripLikeChanged'], isFalse);
      final activityCount =
          (store.snapshot('owner-session')['activity'] as List)
              .where(
                (item) => item is Map && item['title'] == "Nouveau j'aime",
              )
              .length;
      expect(activityCount, 1);
    });

    test(
      'creates a shared trip conversation and exposes it to participants',
      () async {
        final store = await _openTempStore('piwibus-trip-chat');

        final line = store.lines().first;
        final lineCode = _string(line['code']);
        final tripId = 'trip-chat-group-test';
        await store.register('test-session-1', <String, dynamic>{
          'fullName': 'Alice Owner',
          'email': 'alice@example.com',
          'password': 'password123',
        });
        await store.register('test-session-2', <String, dynamic>{
          'fullName': 'Bob Observer',
          'email': 'bob@example.com',
          'password': 'password123',
        });
        await store.startTrip('test-session-1', <String, dynamic>{
          'tripId': tripId,
          'lineCode': lineCode,
          'liveLocation': _routePointLocation(line),
        });

        final ownerConversations = store.messageConversationsForSession(
          'test-session-1',
        );
        final tripConversation = ownerConversations.firstWhere(
          (conversation) =>
              conversation['kind'] == 'trip' &&
              conversation['tripId'] == tripId,
          orElse: () => <String, dynamic>{},
        );
        expect(tripConversation, isNotEmpty);

        await store.selectTrip('test-session-2', tripId);
        final observerConversations = store.messageConversationsForSession(
          'test-session-2',
        );
        final observerTripConversation = observerConversations.firstWhere(
          (conversation) =>
              conversation['kind'] == 'trip' &&
              conversation['tripId'] == tripId,
          orElse: () => <String, dynamic>{},
        );
        expect(observerTripConversation, isNotEmpty);

        final sent = await store.sendMessageItem(
          'test-session-2',
          _string(observerTripConversation['id']),
          <String, dynamic>{'body': 'Bonjour tout le monde'},
        );
        expect(sent['conversation']['kind'], 'trip');
        expect(sent['conversation']['tripId'], tripId);
      },
    );

    test('nearby message peers are compact and limited by default', () async {
      final store = await _openTempStore('piwibus-peer-candidates');
      final line = store.lines().first;
      final lineCode = _string(line['code']);
      final location = _routePointLocation(line);

      await store.register('finder-session', <String, dynamic>{
        'fullName': 'Finder User',
        'email': 'finder@example.com',
        'password': 'password123',
      });
      await store.updateSessionLocation('finder-session', <String, dynamic>{
        'location': location,
      }, includeSnapshot: false);

      for (var i = 0; i < 3; i += 1) {
        await store.register('peer-session-$i', <String, dynamic>{
          'fullName': 'Peer $i',
          'email': 'peer$i@example.com',
          'password': 'password123',
          'profilePhotoDataUrl': _tinyPngDataUrl,
        });
        await store.updateSessionLocation('peer-session-$i', <String, dynamic>{
          'location': location,
        }, includeSnapshot: false);
      }

      final candidates = store.messagePeerCandidatesForLine(
        'finder-session',
        lineCode: lineCode,
        radiusMeters: 200,
        limit: 2,
      );

      expect(candidates, hasLength(2));
      final user = candidates.first['user'] as Map<String, dynamic>;
      expect(user['id'], isNotEmpty);
      expect(user['fullName'], startsWith('Peer'));
      expect(user.containsKey('email'), isFalse);
      expect(user.containsKey('phone'), isFalse);
      expect(user.containsKey('readAlertIds'), isFalse);
      expect(user.containsKey('profilePhotoDataUrl'), isFalse);
    });
  });
}

String _string(Object? value) => value?.toString() ?? '';

Future<PiwibusStore> _openTempStore(String prefix) async {
  final tempDir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  final stateFile = File(p.join(tempDir.path, 'state.json'));
  return PiwibusStore.openWithPersistence(JsonFileStatePersistence(stateFile));
}

Map<String, dynamic> _routePointLocation(JsonMap line) {
  final segments = routeSegmentsFromGeometry(
    geometry: _string(line['geometry']),
    shape: _string(line['shape']),
  );
  final firstSegment = segments.isEmpty ? null : segments.first;
  final firstPoint = firstSegment == null || firstSegment.isEmpty
      ? null
      : firstSegment.first;
  return <String, dynamic>{
    'lat': firstPoint?.lat ?? 5.34,
    'lng': firstPoint?.lng ?? -4.01,
    'accuracy': 10,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
  };
}

const String _tinyPngDataUrl =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+'
    'M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/route_proximity.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test('activity IDs make repeated events idempotent', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'piwibus-activity-idempotency',
    );
    final persistence = _CapturingStatePersistence(
      File(p.join(tempDir.path, 'state.json')),
    );
    final store = await PiwibusStore.openWithPersistence(persistence);
    addTearDown(() async {
      await store.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    await store.register('activity-session', <String, dynamic>{
      'fullName': 'Activity Owner',
      'email': 'activity-owner@example.com',
      'password': 'password123',
    });
    await store.register('nearby-session', <String, dynamic>{
      'fullName': 'Nearby User',
      'email': 'nearby-user@example.com',
      'password': 'password123',
    });
    await store.publishActivity(
      title: 'Nouveau bus sur la ligne',
      subtitle: 'Un nouveau bus vient d’apparaître sur la ligne 12.',
      iconKey: 'bus',
      colorValue: 0xFF0F766E,
      audienceSessionIds: const <String>['activity-session'],
      activityId: 'trip-started:trip-123',
    );
    await store.publishActivity(
      title: 'Nouveau bus sur la ligne',
      subtitle: 'Un nouveau bus vient d’apparaître sur la ligne 12.',
      iconKey: 'bus',
      colorValue: 0xFF0F766E,
      audienceSessionIds: const <String>['activity-session'],
      activityId: 'trip-started:trip-123',
    );

    expect(_activityCount(store, 'activity-session'), 1);

    await store.publishActivity(
      title: 'Nouveau bus sur la ligne',
      subtitle: 'Un nouveau bus vient d’apparaître sur la ligne 12.',
      iconKey: 'bus',
      colorValue: 0xFF0F766E,
      audienceSessionIds: const <String>['activity-session'],
      activityId: 'trip-started:trip-456',
    );

    expect(_activityCount(store, 'activity-session'), 2);
    final reportLine = store.lines().firstWhere(
      (line) => _text(line['code']) == '12',
    );
    await store.startTrip('activity-session', <String, dynamic>{
      'tripId': 'report-nearby-trip',
      'lineCode': '12',
      'liveLocation': _routePointLocation(reportLine),
    });
    await store.startTrip('nearby-session', <String, dynamic>{
      'tripId': 'nearby-report-audience-trip',
      'lineCode': '12',
      'liveLocation': _routePointLocation(reportLine),
    });
    expect(
      store.notificationAudienceNearLine('12').sessionIds,
      contains('nearby-session'),
    );

    final report = <String, dynamic>{
      'reportId': 'report-123',
      'busNumber': '777',
      'lineCode': '12',
      'location': <String, double>{'lat': 5.34, 'lng': -4.01},
      'note': 'Accident',
    };
    await store.createReport('activity-session', report);
    await store.createReport('activity-session', report);

    final snapshot = store.snapshot('activity-session');
    expect(
      (snapshot['reports'] as List)
          .whereType<Map>()
          .where((entry) => entry['id'] == 'report-123')
          .length,
      1,
    );
    expect(
      (snapshot['activity'] as List)
          .whereType<Map>()
          .where((entry) => entry['title'] == 'Signalement enregistré')
          .length,
      1,
    );
    final reportActivity = (snapshot['activity'] as List)
        .whereType<Map>()
        .firstWhere((entry) => entry['title'] == 'Signalement enregistré');
    expect(reportActivity['subtitle'], contains('Bus 777'));
    expect(reportActivity['subtitle'], contains('ligne 12'));
    final reportPush = persistence.outboxEvents
        .map((event) => event.payload)
        .firstWhere(
          (payload) => (payload['data'] as Map)['type'] == 'report_created',
        );
    expect(reportPush['body'], contains('Bus 777'));
    expect(reportPush['body'], contains('ligne 12'));

    await store.createReport('activity-session', <String, dynamic>{
      'reportId': 'report-without-line',
      'busNumber': '812',
      'lineCode': '',
      'location': <String, double>{'lat': 5.34, 'lng': -4.01},
      'note': 'Bus sans ligne renseignée',
    });
    final unassignedReportActivity =
        (store.snapshot('activity-session')['activity'] as List)
            .whereType<Map>()
            .firstWhere(
              (entry) =>
                  entry['title'] == 'Signalement enregistré' &&
                  (entry['subtitle'] as String).contains('Bus 812'),
            );
    expect(unassignedReportActivity['subtitle'], isNot(contains('ligne')));
    final restoredStore = await PiwibusStore.openWithPersistence(
      JsonFileStatePersistence(File(p.join(tempDir.path, 'state.json'))),
    );
    addTearDown(restoredStore.close);
    final restoredReport =
        (restoredStore.snapshot('activity-session')['reports'] as List)
            .whereType<Map>()
            .firstWhere((entry) => entry['id'] == 'report-without-line');
    expect(restoredReport['busNumber'], '812');
    expect(restoredReport['lineCode'], '');
  });

  test(
    'like notification IDs are stable for retries and unique for new likes',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'piwibus-like-notification-idempotency',
      );
      final persistence = JsonFileStatePersistence(
        File(p.join(tempDir.path, 'state.json')),
      );
      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(() async {
        await store.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      await store.register('like-owner-session', <String, dynamic>{
        'fullName': 'Trip Owner',
        'email': 'like-owner@example.com',
        'password': 'password123',
      });
      await store.register('like-observer-session', <String, dynamic>{
        'fullName': 'Trip Observer',
        'email': 'like-observer@example.com',
        'password': 'password123',
      });
      final line = store.lines().first;
      const tripId = 'trip-like-notification';
      await store.startTrip('like-owner-session', <String, dynamic>{
        'tripId': tripId,
        'lineCode': _text(line['code']),
        'liveLocation': _routePointLocation(line),
      });
      await store.selectTrip('like-observer-session', tripId);

      final firstLike = await store.setTripLike(
        'like-observer-session',
        tripId,
        true,
      );
      final firstEventId = _text(firstLike['tripLikeActivityId']);
      expect(firstEventId, startsWith('trip-liked:$tripId:'));

      final repeatedLike = await store.setTripLike(
        'like-observer-session',
        tripId,
        true,
      );
      expect(repeatedLike['tripLikeChanged'], isFalse);
      expect(_activityCount(store, 'like-owner-session', 'Nouveau j\'aime'), 1);

      await store.setTripLike('like-observer-session', tripId, false);
      final secondLike = await store.setTripLike(
        'like-observer-session',
        tripId,
        true,
      );
      expect(_text(secondLike['tripLikeActivityId']), isNot(firstEventId));
      expect(_activityCount(store, 'like-owner-session', 'Nouveau j\'aime'), 2);
    },
  );
}

int _activityCount(PiwibusStore store, String sessionId, [String? title]) {
  final snapshot = store.snapshot(sessionId);
  return (snapshot['activity'] as List)
      .whereType<Map>()
      .where((activity) => title == null || activity['title'] == title)
      .length;
}

class _CapturingStatePersistence extends JsonFileStatePersistence {
  _CapturingStatePersistence(super.stateFile);

  final List<StateOutboxEvent> outboxEvents = <StateOutboxEvent>[];

  @override
  Future<void> applyMutations({
    required Map<String, dynamic> state,
    required StateMutationBatch batch,
  }) async {
    outboxEvents.addAll(batch.outboxEvents);
    await super.applyMutations(state: state, batch: batch);
  }
}

String _text(Object? value) => value?.toString() ?? '';

Map<String, dynamic> _routePointLocation(JsonMap line) {
  final segments = routeSegmentsFromGeometry(
    geometry: _text(line['geometry']),
    shape: _text(line['shape']),
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

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/route_proximity.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'stopping a trip repeatedly is idempotent and remains owner-only',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'piwibus-trip-stop',
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

      await store.register('trip-owner-session', <String, dynamic>{
        'fullName': 'Trip Owner',
        'email': 'trip-owner@example.com',
        'password': 'password123',
      });
      await store.register('other-user-session', <String, dynamic>{
        'fullName': 'Other User',
        'email': 'other-user@example.com',
        'password': 'password123',
      });

      final line = store.lines().first;
      const tripId = 'trip-stop-idempotency';
      await store.startTrip('trip-owner-session', <String, dynamic>{
        'tripId': tripId,
        'lineCode': _text(line['code']),
        'liveLocation': _routePointLocation(line),
      });
      await store.selectTrip('other-user-session', tripId);

      final firstStop = await store.stopTrip('trip-owner-session', tripId);
      final firstTrip = _tripFromSnapshot(firstStop, tripId);
      expect(firstTrip['status'], 'termine');
      final stoppedAt = firstTrip['lastUpdatedAt'];
      expect(_stopActivityCount(firstStop), 1);
      expect(_stopActivityId(firstStop), 'trip-stopped:$tripId');

      final duplicateStop = await store.stopTrip('trip-owner-session', tripId);
      final duplicateTrip = _tripFromSnapshot(duplicateStop, tripId);
      expect(duplicateTrip['status'], 'termine');
      expect(duplicateTrip['lastUpdatedAt'], stoppedAt);
      expect(_stopActivityCount(duplicateStop), 1);

      await expectLater(
        store.stopTrip('other-user-session', tripId),
        throwsStateError,
      );
    },
  );

  test('manual owner stop exposes an accurate reason to observers', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'piwibus-trip-manual-stop',
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

    await store.register('manual-stop-owner-session', <String, dynamic>{
      'fullName': 'Trip Owner',
      'email': 'manual-stop-owner@example.com',
      'password': 'password123',
    });
    await store.register('manual-stop-observer-session', <String, dynamic>{
      'fullName': 'Trip Observer',
      'email': 'manual-stop-observer@example.com',
      'password': 'password123',
    });
    final line = store.lines().first;
    const tripId = 'trip-manual-stop-reason';
    await store.startTrip('manual-stop-owner-session', <String, dynamic>{
      'tripId': tripId,
      'lineCode': _text(line['code']),
      'liveLocation': _routePointLocation(line),
    });
    await store.selectTrip('manual-stop-observer-session', tripId);

    await store.stopTrip('manual-stop-owner-session', tripId);

    const expectedReason = 'L’Étoile a arrêté la diffusion de ce trajet.';
    final observerStatus = store.tripStatusForSession(
      'manual-stop-observer-session',
      tripId,
    );
    expect(observerStatus?['status'], 'termine');
    expect(observerStatus?['lastSystemMessage'], expectedReason);

    final observerSnapshot = store.snapshot('manual-stop-observer-session');
    final stoppedTrip = _tripFromSnapshot(observerSnapshot, tripId);
    expect(stoppedTrip['lastSystemMessage'], expectedReason);
    final stopActivity = (observerSnapshot['activity'] as List)
        .whereType<Map>()
        .firstWhere((value) => value['title'] == 'Trajet arrêté');
    expect(stopActivity['subtitle'], expectedReason);
  });
}

String _text(Object? value) => value?.toString() ?? '';

Map<String, dynamic> _tripFromSnapshot(
  Map<String, dynamic> snapshot,
  String tripId,
) {
  final trips = snapshot['trips'] as List;
  final trip = trips
      .whereType<Map>()
      .map((value) => Map<String, dynamic>.from(value))
      .firstWhere((value) => value['id'] == tripId);
  return trip;
}

int _stopActivityCount(Map<String, dynamic> snapshot) {
  final activity = snapshot['activity'] as List;
  return activity
      .whereType<Map>()
      .where((value) => value['title'] == 'Trajet arrêté')
      .length;
}

String _stopActivityId(Map<String, dynamic> snapshot) {
  final activity = snapshot['activity'] as List;
  return _text(
    activity.whereType<Map>().firstWhere(
      (value) => value['title'] == 'Trajet arrêté',
    )['id'],
  );
}

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

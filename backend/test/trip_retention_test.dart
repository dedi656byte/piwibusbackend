import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/route_proximity.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'keeps completed trips beyond the former age and count limits',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'piwibus-trip-retention',
      );
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final persistence = JsonFileStatePersistence(
        File(p.join(tempDir.path, 'state.json')),
      );
      final store = await PiwibusStore.openWithPersistence(persistence);
      final line = store.lines().first;
      final lineCode = _text(line['code']);
      const sessionId = 'retention-test-session';
      const templateTripId = 'retention-template-trip';

      await store.startTrip(sessionId, <String, dynamic>{
        'tripId': templateTripId,
        'lineCode': lineCode,
        'liveLocation': _routePointLocation(line),
      });

      final state = await persistence.loadState();
      expect(state, isNotNull);
      final trips = state!['trips'] as List;
      final template = Map<String, dynamic>.from(trips.single as Map);
      final oldTimestamp = DateTime.utc(2020).toIso8601String();
      await persistence.saveState(<String, dynamic>{
        ...state,
        'trips': List<Map<String, dynamic>>.generate(501, (index) {
          return <String, dynamic>{
            ...template,
            'id': index == 0 ? templateTripId : 'old-completed-trip-$index',
            'status': 'termine',
            'startedAt': oldTimestamp,
            'lastUpdatedAt': oldTimestamp,
            'messages': <Map<String, dynamic>>[],
          };
        }),
      });

      final reloadedStore = await PiwibusStore.openWithPersistence(persistence);
      await reloadedStore.pruneRetainedHistory();
      final retainedTrips =
          reloadedStore.snapshot(sessionId, includeLines: false)['trips']
              as List;

      expect(retainedTrips, hasLength(501));
      expect(
        retainedTrips.any(
          (trip) =>
              trip is Map<String, dynamic> &&
              trip['id'] == 'old-completed-trip-500',
        ),
        isTrue,
      );
    },
  );
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

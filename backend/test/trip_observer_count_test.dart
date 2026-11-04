import 'dart:convert';

import 'package:piwibus_backend/src/route_proximity.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test('counts fresh live followers in observer and reporter roles', () async {
    final store = await PiwibusStore.openWithPersistence(
      _MemoryStatePersistence(),
    );
    addTearDown(store.close);

    final line = store.lines().first;
    await store.register('owner-session', <String, dynamic>{
      'fullName': 'Trip Owner',
      'email': 'observer-count-owner@example.com',
      'password': 'password123',
    });
    await store.register('observer-session', <String, dynamic>{
      'fullName': 'Observer',
      'email': 'observer-count-observer@example.com',
      'password': 'password123',
    });
    await store.register('reporter-session', <String, dynamic>{
      'fullName': 'Reporter',
      'email': 'observer-count-reporter@example.com',
      'password': 'password123',
    });

    await store.startTrip('owner-session', <String, dynamic>{
      'tripId': 'observer-count-trip',
      'lineCode': line['code'],
      'liveLocation': _routePointLocation(line),
    });
    await store.switchRole('observer-session', 'observateur');
    await store.switchRole('reporter-session', 'reporteur');
    await store.selectTrip('observer-session', 'observer-count-trip');
    await store.selectTrip('reporter-session', 'observer-count-trip');

    final ownerSnapshot = store.snapshot('owner-session');
    final trip = (ownerSnapshot['trips'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((trip) => trip['id'] == 'observer-count-trip');

    expect(trip['observers'], 2);
    expect(store.snapshot('reporter-session')['activeRole'], 'reporteur');

    store.setSessionLastSeenAtForTesting(
      'reporter-session',
      DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 7))
          .toIso8601String(),
    );
    final snapshotWithStaleReporter = store.snapshot('owner-session');
    final tripWithStaleReporter = (snapshotWithStaleReporter['trips'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((trip) => trip['id'] == 'observer-count-trip');
    expect(tripWithStaleReporter['observers'], 1);
  });
}

class _MemoryStatePersistence extends StatePersistence {
  Map<String, dynamic>? _state;

  @override
  String get name => 'observer-count-test';

  @override
  Future<Map<String, dynamic>?> loadState() async {
    final state = _state;
    return state == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(jsonEncode(state)) as Map);
  }

  @override
  Future<void> saveState(Map<String, dynamic> state) async {
    _state = Map<String, dynamic>.from(jsonDecode(jsonEncode(state)) as Map);
  }
}

String _string(Object? value) => value?.toString() ?? '';

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

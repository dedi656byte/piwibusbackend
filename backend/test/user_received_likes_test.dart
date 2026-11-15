import 'dart:convert';

import 'package:piwibus_backend/src/route_proximity.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'snapshot reports persisted likes across active and completed trips after reconnect',
    () async {
      final persistence = _MemoryStatePersistence();
      late PiwibusStore store;
      store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(() async => store.close());

      const ownerEmail = 'likes-owner@example.com';
      const ownerPassword = 'password123';
      await store.register('likes-owner-session', <String, dynamic>{
        'fullName': 'Trip Owner',
        'email': ownerEmail,
        'password': ownerPassword,
      });
      await store.register('likes-first-session', <String, dynamic>{
        'fullName': 'First Liker',
        'email': 'likes-first@example.com',
        'password': 'password123',
      });
      await store.register('likes-second-session', <String, dynamic>{
        'fullName': 'Second Liker',
        'email': 'likes-second@example.com',
        'password': 'password123',
      });

      final line = store.lines().first;
      final lineCode = _text(line['code']);
      await store.startTrip('likes-owner-session', <String, dynamic>{
        'tripId': 'likes-completed-trip',
        'lineCode': lineCode,
        'liveLocation': _routePointLocation(line),
      });
      await store.setTripLike(
        'likes-first-session',
        'likes-completed-trip',
        true,
      );
      await store.startTrip('likes-owner-session', <String, dynamic>{
        'tripId': 'likes-active-trip',
        'lineCode': lineCode,
        'liveLocation': _routePointLocation(line),
      });
      await store.setTripLike(
        'likes-second-session',
        'likes-active-trip',
        true,
      );

      var snapshot = await store.signIn('likes-owner-reconnected-session', {
        'email': ownerEmail,
        'password': ownerPassword,
      });
      expect(snapshot['currentUserReceivedLikeCount'], 2);

      await store.close();
      store = await PiwibusStore.openWithPersistence(persistence);
      snapshot = await store.signIn('likes-owner-reinstalled-session', {
        'email': ownerEmail,
        'password': ownerPassword,
      });

      expect(snapshot['currentUserReceivedLikeCount'], 2);
      final trips = (snapshot['trips'] as List).cast<Map<String, dynamic>>();
      expect(
        trips.singleWhere(
          (trip) => trip['id'] == 'likes-completed-trip',
        )['status'],
        'termine',
      );
      expect(
        trips.singleWhere(
          (trip) => trip['id'] == 'likes-active-trip',
        )['status'],
        'actif',
      );
    },
  );
}

class _MemoryStatePersistence extends StatePersistence {
  Map<String, dynamic>? _state;

  @override
  String get name => 'user-received-likes-test';

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

String _text(Object? value) => value?.toString() ?? '';

Map<String, dynamic> _routePointLocation(Map<String, dynamic> line) {
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

import 'dart:async';
import 'dart:convert';

import 'package:piwibus_backend/src/route_proximity.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test('stale trip expiry can retry after a persistence failure', () async {
    final persistence = _FailOnceTripExpiryPersistence();
    final store = await _openStoreWithStaleTrip(persistence);
    addTearDown(() => store.close());

    persistence.failNextTripWrite = true;
    persistence.tripWriteStarted = Completer<void>();
    persistence.releaseTripWrite = Completer<void>();
    persistence.blockNextTripWrite = true;
    final failedExpiry = store.expireStaleActiveTrips(
      timeout: const Duration(seconds: 1),
    );
    await persistence.tripWriteStarted!.future;
    await store.publishActivity(
      title: 'Activite concurrente',
      subtitle: 'A conserver',
      iconKey: 'info',
      colorValue: 0xFF000000,
      activityId: 'concurrent-activity',
      audienceSessionIds: const <String>['stale-trip-session'],
    );
    persistence.releaseTripWrite!.complete();
    await expectLater(failedExpiry, throwsA(isA<StateError>()));
    expect(_tripStatus(store, 'stale-live-trip'), 'actif');
    final activity = store.snapshot('stale-trip-session')['activity'] as List;
    expect(
      activity.where(
        (item) => _text((item as Map)['id']) == 'concurrent-activity',
      ),
      isNotEmpty,
    );
    expect(_tripStatusInState(persistence.state!, 'stale-live-trip'), 'actif');
    expect(
      (persistence.state!['activity'] as List).where(
        (item) =>
            _text((item as Map)['id']) == 'trip-interrupted:stale-live-trip',
      ),
      isEmpty,
    );

    final notices = await store.expireStaleActiveTrips(
      timeout: const Duration(seconds: 1),
    );

    expect(notices, hasLength(1));
    expect(_tripStatus(store, 'stale-live-trip'), 'termine');
    expect(
      _tripStatusInState(persistence.state!, 'stale-live-trip'),
      'termine',
    );
  });

  test('stale trip expiry preserves concurrent session changes', () async {
    final persistence = _FailOnceTripExpiryPersistence();
    final store = await _openStoreWithStaleTrip(persistence);
    addTearDown(() => store.close());
    persistence.tripWriteStarted = Completer<void>();
    persistence.releaseTripWrite = Completer<void>();
    persistence.blockNextTripWrite = true;

    final expiry = store.expireStaleActiveTrips(
      timeout: const Duration(seconds: 1),
    );
    await persistence.tripWriteStarted!.future;
    try {
      await store.publishActivity(
        title: 'Activite concurrente',
        subtitle: 'A conserver',
        iconKey: 'info',
        colorValue: 0xFF000000,
        activityId: 'concurrent-activity',
        audienceSessionIds: const <String>['stale-trip-session'],
      );
      await store.setSearchQuery(
        'stale-trip-session',
        'mise a jour pendant expiration',
      );
    } finally {
      persistence.releaseTripWrite!.complete();
    }
    await expiry;

    expect(
      store.snapshot('stale-trip-session')['searchQuery'],
      'mise a jour pendant expiration',
    );
    final visibleActivity =
        store.snapshot('stale-trip-session')['activity'] as List;
    expect(
      visibleActivity.any(
        (item) => _text((item as Map)['id']) == 'concurrent-activity',
      ),
      isTrue,
    );
    final persistedActivity = persistence.state!['activity'] as List;
    expect(
      persistedActivity.any(
        (item) =>
            _text((item as Map)['id']) == 'trip-interrupted:stale-live-trip',
      ),
      isTrue,
    );
    expect(
      persistedActivity.any(
        (item) => _text((item as Map)['id']) == 'concurrent-activity',
      ),
      isTrue,
    );
    expect(_tripStatus(store, 'stale-live-trip'), 'termine');
  });
}

class _FailOnceTripExpiryPersistence extends StatePersistence {
  Map<String, dynamic>? state;
  bool failNextTripWrite = false;
  bool blockNextTripWrite = false;
  Completer<void>? tripWriteStarted;
  Completer<void>? releaseTripWrite;

  @override
  String get name => 'stale-trip-expiry-test';

  @override
  Future<Map<String, dynamic>?> loadState() async {
    final currentState = state;
    return currentState == null ? null : _copyState(currentState);
  }

  @override
  Future<void> saveState(Map<String, dynamic> state) async {
    this.state = _copyState(state);
  }

  @override
  Future<void> applyMutations({
    required Map<String, dynamic> state,
    required StateMutationBatch batch,
    bool priority = false,
  }) async {
    if (batch.trips && blockNextTripWrite) {
      blockNextTripWrite = false;
      tripWriteStarted!.complete();
      await releaseTripWrite!.future;
    }
    if (batch.trips && failNextTripWrite) {
      failNextTripWrite = false;
      throw StateError('Simulated stale-trip persistence failure.');
    }
    await super.applyMutations(state: state, batch: batch, priority: priority);
  }
}

Future<PiwibusStore> _openStoreWithStaleTrip(
  _FailOnceTripExpiryPersistence persistence,
) async {
  var store = await PiwibusStore.openWithPersistence(persistence);
  await store.register('stale-trip-session', <String, dynamic>{
    'fullName': 'Trip Owner',
    'email': 'stale-trip@example.com',
    'password': 'password123',
  });
  final line = store.lines().first;
  await store.startTrip('stale-trip-session', <String, dynamic>{
    'tripId': 'stale-live-trip',
    'lineCode': _text(line['code']),
    'liveLocation': _routePointLocation(line),
  });
  await store.close();

  final persistedState = persistence.state!;
  final trips = (persistedState['trips'] as List)
      .map((trip) => Map<String, dynamic>.from(trip as Map))
      .toList();
  trips.single['lastUpdatedAt'] = DateTime.utc(2020).toIso8601String();
  persistence.state = _copyState(<String, dynamic>{
    ...persistedState,
    'trips': trips,
  });
  return PiwibusStore.openWithPersistence(persistence);
}

String _text(Object? value) => value?.toString() ?? '';

String _tripStatus(PiwibusStore store, String tripId) =>
    _tripStatusInState(store.snapshot('stale-trip-session'), tripId);

String _tripStatusInState(Map<String, dynamic> state, String tripId) {
  final trips = (state['trips'] as List).whereType<Map>();
  return _text(
    trips.firstWhere((trip) => _text(trip['id']) == tripId)['status'],
  );
}

Map<String, dynamic> _copyState(Map<String, dynamic> state) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(state)) as Map);

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

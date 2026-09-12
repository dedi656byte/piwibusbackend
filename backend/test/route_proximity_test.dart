import 'package:piwibus_backend/src/route_proximity.dart';
import 'package:test/test.dart';

void main() {
  group('route proximity helpers', () {
    test('selects only fresh peer search locations', () {
      final now = DateTime.utc(2026, 7, 5, 12);
      final location = selectPeerSearchLocation(
        sessionLocation: <String, dynamic>{
          'lat': 5.347,
          'lng': -4.024,
          'timestamp': now
              .subtract(const Duration(minutes: 2))
              .toIso8601String(),
        },
        now: now,
        freshness: const Duration(minutes: 5),
      );

      expect(location, isNotNull);
      expect(location!.lat, 5.347);

      final stale = selectPeerSearchLocation(
        sessionLocation: <String, dynamic>{
          'lat': 5.347,
          'lng': -4.024,
          'timestamp': now
              .subtract(const Duration(minutes: 8))
              .toIso8601String(),
        },
        now: now,
        freshness: const Duration(minutes: 5),
      );

      expect(stale, isNull);
    });

    test('normalizes peer search radius bounds', () {
      expect(normalizePeerSearchRadiusMeters(10), minPeerSearchRadiusMeters);
      expect(normalizePeerSearchRadiusMeters(120), 120);
      expect(normalizePeerSearchRadiusMeters(900), maxPeerSearchRadiusMeters);
      expect(
        normalizePeerSearchRadiusMeters(double.nan),
        defaultPeerSearchRadiusMeters,
      );
    });

    test('parses route geometry and computes route distance', () {
      final segments = routeSegmentsFromGeometry(
        geometry:
            '{"type":"LineString","coordinates":[[-4.03,5.34],[-4.02,5.35]]}',
        shape: '',
      );

      expect(segments, hasLength(1));
      expect(segments.single, hasLength(2));
      final nearDistance = distanceMetersToRouteSegments(
        5.345,
        -4.025,
        segments,
      );
      final farDistance = distanceMetersToRouteSegments(5.5, -4.3, segments);

      expect(nearDistance, lessThan(200));
      expect(farDistance, greaterThan(10000));
    });

    test('throttles peer location persistence by time and distance', () {
      final now = DateTime.utc(2026, 7, 5, 12);
      final previous = <String, dynamic>{
        'lat': 5.347,
        'lng': -4.024,
        'timestamp': now
            .subtract(const Duration(seconds: 10))
            .toIso8601String(),
      };
      final tinyMove = <String, dynamic>{
        'lat': 5.34701,
        'lng': -4.02401,
        'timestamp': now.toIso8601String(),
      };
      final largerMove = <String, dynamic>{
        'lat': 5.348,
        'lng': -4.024,
        'timestamp': now.toIso8601String(),
      };

      expect(
        shouldPersistNearbyLocationUpdate(
          previousLocation: previous,
          nextLocation: tinyMove,
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldPersistNearbyLocationUpdate(
          previousLocation: previous,
          nextLocation: largerMove,
          now: now,
        ),
        isTrue,
      );
    });
  });
}

import 'dart:convert';
import 'dart:math' as math;

const double minPeerSearchRadiusMeters = 50;
const double defaultPeerSearchRadiusMeters = 200;
const double maxPeerSearchRadiusMeters = 200;
const Duration defaultPeerSearchFreshness = Duration(minutes: 5);
const Duration minPeerLocationUpdateInterval = Duration(seconds: 30);
const double minPeerLocationDistanceMeters = 25;

bool isPeerPresenceFresh({
  required Object? lastSeenAt,
  required DateTime now,
  required Duration freshness,
}) {
  final timestamp = _readTimestamp(lastSeenAt);
  if (timestamp == null) return false;
  return now.difference(timestamp.toUtc()) <= freshness;
}

class NearbyLocationCandidate {
  const NearbyLocationCandidate({
    required this.lat,
    required this.lng,
    required this.timestamp,
  });

  final double lat;
  final double lng;
  final DateTime timestamp;
}

typedef NearbyRoutePoint = ({double lat, double lng});

NearbyLocationCandidate? selectPeerSearchLocation({
  required Object? sessionLocation,
  required DateTime now,
  required Duration freshness,
}) {
  return _extractLocationCandidate(sessionLocation, now, freshness);
}

double normalizePeerSearchRadiusMeters(double radiusMeters) {
  if (!radiusMeters.isFinite) {
    return defaultPeerSearchRadiusMeters;
  }
  return radiusMeters.clamp(
    minPeerSearchRadiusMeters,
    maxPeerSearchRadiusMeters,
  );
}

List<List<NearbyRoutePoint>> routeSegmentsFromGeometry({
  required String geometry,
  required String shape,
}) {
  try {
    final decoded = jsonDecode(geometry.trim());
    if (decoded is! Map) throw const FormatException('Invalid geometry');
    final coordinates = decoded['coordinates'];
    if (coordinates is! List) {
      throw const FormatException('Invalid geometry coordinates');
    }

    List<NearbyRoutePoint> parseSegment(List segment) {
      final points = <NearbyRoutePoint>[];
      for (final point in segment.whereType<List>()) {
        if (point.length < 2) continue;
        final lng = _readDouble(point[0]);
        final lat = _readDouble(point[1]);
        if (!_isFiniteLatLng(lat, lng)) continue;
        points.add((lat: lat, lng: lng));
      }
      return points;
    }

    final type = (decoded['type']?.toString().trim().toLowerCase() ?? '');
    final lineStringSegment = parseSegment(coordinates);
    final looksLikeLineString =
        coordinates.isNotEmpty &&
        coordinates.first is List &&
        _readDouble((coordinates.first as List).firstOrNull).isFinite;
    if ((type == 'linestring' || (type.isEmpty && looksLikeLineString)) &&
        lineStringSegment.length > 1) {
      return <List<NearbyRoutePoint>>[lineStringSegment];
    }

    final segments = coordinates
        .whereType<List>()
        .map(parseSegment)
        .where((segment) => segment.length > 1)
        .toList(growable: false);
    if (segments.isNotEmpty) return segments;
  } catch (_) {
    // Fall back to WKT below.
  }
  return routeSegmentsFromWkt(shape);
}

List<List<NearbyRoutePoint>> routeSegmentsFromWkt(String shape) {
  final text = shape.trim();
  if (text.isEmpty) return const [];
  final upper = text.toUpperCase();
  if (upper.startsWith('MULTILINESTRING')) {
    final start = text.indexOf('((');
    final end = text.lastIndexOf('))');
    if (start < 0 || end <= start) return const [];
    return text
        .substring(start + 2, end)
        .split(RegExp(r'\)\s*,\s*\('))
        .map(_wktPointList)
        .where((segment) => segment.length > 1)
        .toList(growable: false);
  }
  if (upper.startsWith('LINESTRING')) {
    final start = text.indexOf('(');
    final end = text.lastIndexOf(')');
    if (start < 0 || end <= start) return const [];
    final segment = _wktPointList(text.substring(start + 1, end));
    return segment.length > 1 ? <List<NearbyRoutePoint>>[segment] : const [];
  }
  return const [];
}

double distanceMetersToRouteSegments(
  double lat,
  double lng,
  List<List<NearbyRoutePoint>> segments,
) {
  var best = double.infinity;
  for (final segment in segments) {
    for (var index = 0; index < segment.length - 1; index++) {
      final distance = _distanceMetersToSegment(
        lat,
        lng,
        segment[index],
        segment[index + 1],
      );
      if (distance < best) best = distance;
    }
  }
  return best;
}

bool shouldPersistNearbyLocationUpdate({
  required Object? previousLocation,
  required Object? nextLocation,
  required DateTime now,
  Duration minInterval = minPeerLocationUpdateInterval,
  double minDistanceMeters = minPeerLocationDistanceMeters,
}) {
  final previousCandidate = _extractLocationCandidate(
    previousLocation,
    now,
    const Duration(days: 365),
  );
  final nextCandidate = _extractLocationCandidate(
    nextLocation,
    now,
    const Duration(days: 365),
  );
  if (previousCandidate == null || nextCandidate == null) return true;
  final elapsed = now.difference(previousCandidate.timestamp.toUtc());
  if (elapsed < minInterval) {
    final distance = _distanceMeters(
      previousCandidate.lat,
      previousCandidate.lng,
      nextCandidate.lat,
      nextCandidate.lng,
    );
    if (distance < minDistanceMeters) return false;
  }
  return true;
}

NearbyLocationCandidate? _extractLocationCandidate(
  Object? candidate,
  DateTime now,
  Duration freshness,
) {
  if (candidate is! Map) return null;
  final lat = _readDouble(candidate['lat'] ?? candidate['latitude']);
  final lng = _readDouble(candidate['lng'] ?? candidate['longitude']);
  if (!_isFiniteLatLng(lat, lng)) return null;
  final timestamp = _readTimestamp(
    candidate['timestamp'] ?? candidate['updatedAt'],
  );
  if (timestamp == null) return null;
  if (now.difference(timestamp.toUtc()) > freshness) return null;
  return NearbyLocationCandidate(lat: lat, lng: lng, timestamp: timestamp);
}

List<NearbyRoutePoint> _wktPointList(String text) {
  return text
      .split(',')
      .map((rawPoint) {
        final parts = rawPoint
            .trim()
            .split(RegExp(r'\s+'))
            .where((part) => part.isNotEmpty)
            .toList(growable: false);
        if (parts.length < 2) return (lat: double.nan, lng: double.nan);
        return (lat: _readDouble(parts[1]), lng: _readDouble(parts[0]));
      })
      .where((point) => _isFiniteLatLng(point.lat, point.lng))
      .toList(growable: false);
}

double _readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String && value.trim().isNotEmpty) {
    return double.tryParse(value) ?? double.nan;
  }
  return double.nan;
}

DateTime? _readTimestamp(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  return DateTime.tryParse(text)?.toUtc();
}

bool _isFiniteLatLng(double lat, double lng) {
  return lat.isFinite &&
      lng.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lng >= -180 &&
      lng <= 180;
}

double _distanceMetersToSegment(
  double lat,
  double lng,
  NearbyRoutePoint a,
  NearbyRoutePoint b,
) {
  final midLatRad = ((a.lat + b.lat) / 2) * math.pi / 180;
  final kmPerLat = 110.574;
  final kmPerLng = 111.320 * math.cos(midLatRad);
  final bx = (b.lng - a.lng) * kmPerLng;
  final by = (b.lat - a.lat) * kmPerLat;
  final px = (lng - a.lng) * kmPerLng;
  final py = (lat - a.lat) * kmPerLat;
  final denom = bx * bx + by * by;
  final fraction = denom == 0
      ? 0.0
      : ((px * bx + py * by) / denom).clamp(0.0, 1.0);
  final projectedLat = a.lat + (b.lat - a.lat) * fraction;
  final projectedLng = a.lng + (b.lng - a.lng) * fraction;
  return _distanceMeters(lat, lng, projectedLat, projectedLng);
}

double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthRadiusMeters = 6371000.0;
  final lat1Rad = lat1 * 3.141592653589793 / 180;
  final lat2Rad = lat2 * 3.141592653589793 / 180;
  final deltaLat = (lat2 - lat1) * 3.141592653589793 / 180;
  final deltaLng = (lng2 - lng1) * 3.141592653589793 / 180;
  final sinLat = math.sin(deltaLat / 2);
  final sinLng = math.sin(deltaLng / 2);
  final a =
      sinLat * sinLat + math.cos(lat1Rad) * math.cos(lat2Rad) * sinLng * sinLng;
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}

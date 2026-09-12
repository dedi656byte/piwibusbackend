import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:csv/csv.dart';
import 'package:crypto/crypto.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:path/path.dart' as p;

import 'route_proximity.dart';
import 'state_persistence.dart';

typedef JsonMap = Map<String, dynamic>;
typedef PasswordResetCodeSender =
    Future<void> Function({
      required String email,
      required String code,
      required DateTime expiresAt,
    });

JsonMap publicUserFromState(
  JsonMap user,
  Map<String, JsonMap> sessions, {
  DateTime? now,
  Map<String, bool>? sessionOnlineById,
}) {
  final userId = PiwibusStore._text(user['id']);
  final userSessions = sessions.values.where((session) {
    final currentUser = session['currentUser'];
    if (currentUser is! Map) return false;
    return PiwibusStore._text(currentUser['id']) == userId;
  });

  final lastSeenAtStr = PiwibusStore._text(user['lastSeenAt']);
  final parsedLastSeenAt = DateTime.tryParse(lastSeenAtStr);
  final sessionLastSeenAts = userSessions
      .map(
        (session) =>
            DateTime.tryParse(PiwibusStore._text(session['lastSeenAt'])),
      )
      .whereType<DateTime>()
      .toList(growable: false);
  final mostRecentSessionLastSeenAt = sessionLastSeenAts.isEmpty
      ? null
      : sessionLastSeenAts.reduce((a, b) => a.isAfter(b) ? a : b);
  final latestLastSeenAt =
      <DateTime?>[parsedLastSeenAt, mostRecentSessionLastSeenAt]
          .whereType<DateTime>()
          .toList(growable: false)
          .fold<DateTime?>(null, (previous, current) {
            if (previous == null) return current;
            return current.isAfter(previous) ? current : previous;
          });

  final explicitOnline =
      sessionOnlineById != null &&
      sessions.entries.any((entry) {
        final currentUser = entry.value['currentUser'];
        if (currentUser is! Map) return false;
        return PiwibusStore._text(currentUser['id']) == userId &&
            sessionOnlineById[entry.key] == true;
      });

  final userStatusActif = PiwibusStore._text(user['status']) == 'actif';
  final isOnline = userStatusActif && explicitOnline;

  return <String, dynamic>{
    'id': PiwibusStore._text(user['id']),
    'fullName': PiwibusStore._text(user['fullName']),
    'email': PiwibusStore._text(user['email']),
    'phone': PiwibusStore._text(user['phone']),
    'profilePhotoDataUrl': PiwibusStore._nullableText(
      user['profilePhotoDataUrl'],
    ),
    'nameChangedAt': PiwibusStore._nullableText(user['nameChangedAt']),
    'primaryRole': PiwibusStore._text(user['primaryRole']),
    'status': PiwibusStore._text(user['status']),
    'isOnline': isOnline,
    'createdAt': PiwibusStore._text(user['createdAt']),
    'lastSeenAt': latestLastSeenAt == null
        ? PiwibusStore._text(user['lastSeenAt'])
        : latestLastSeenAt.toUtc().toIso8601String(),
    'activityReadAt': PiwibusStore._nullableText(user['activityReadAt']),
  };
}

class SystemTripCancellationException implements Exception {
  const SystemTripCancellationException(this.message, {required this.notice});

  final String message;
  final JsonMap notice;

  @override
  String toString() => message;
}

class _LineCatalog {
  const _LineCatalog({required this.lines, required this.lineDataVersion});

  final List<JsonMap> lines;
  final String lineDataVersion;
}

class _NearbyPlaceLabel {
  const _NearbyPlaceLabel({
    required this.name,
    required this.subtitle,
    required this.kind,
    required this.lat,
    required this.lng,
  });

  final String name;
  final String subtitle;
  final String kind;
  final double lat;
  final double lng;
}

enum _TripNetworkResponseKind { compact, snapshot }

class PiwibusStore {
  PiwibusStore._({
    required List<JsonMap> lines,
    required String lineDataVersion,
    required List<_NearbyPlaceLabel> nearbyPlaceLabels,
    required StatePersistence persistence,
  }) : _lines = lines,
       _lineDataVersion = lineDataVersion,
       _nearbyPlaceLabels = nearbyPlaceLabels,
       _persistence = persistence;

  final List<JsonMap> _lines;
  final String _lineDataVersion;
  final List<_NearbyPlaceLabel> _nearbyPlaceLabels;
  final StatePersistence _persistence;
  // Authenticated sessions are intentionally persistent: the user remains
  // connected until an explicit logout. These limits only clean up anonymous
  // sessions that never became attached to an account.
  static const Duration _anonymousSessionIdleTimeout = Duration(days: 30);
  static const Duration _anonymousSessionAbsoluteTimeout = Duration(days: 30);
  static const Duration _sessionRotationInterval = Duration(days: 7);
  static const Duration _sessionTouchInterval = Duration(minutes: 5);
  static const Duration _observerSessionFreshness = Duration(minutes: 6);
  static const Duration _currentLocationFreshness = Duration(minutes: 5);
  static const Duration _completedTripRetention = Duration(days: 30);
  static const Duration _tripMessageRetention = Duration(days: 30);
  static const Duration _reportRetention = Duration(days: 30);
  static const int _maxRetainedCompletedTrips = 500;
  static const int _maxRetainedMessagesPerTrip = 80;
  static const int _maxRetainedReports = 500;
  static const Duration _liveLocationMaxSampleAge = Duration(seconds: 60);
  static const Duration _liveLocationMaxFutureSkew = Duration(minutes: 2);
  static const double _liveLocationMaxAccuracyMeters = 100;
  static const double _liveLocationMaxPlausibleSpeedMetersPerSecond = 45;
  static const double _liveLocationJumpGraceMeters = 120;
  static const int _estimatedTripRequestEnvelopeBytes = 1200;
  static const int _estimatedTripCompactResponseBytes = 900;
  static const int _estimatedTripSnapshotResponseBytes = 6500;
  static const double _liveOffRouteBaseToleranceMeters = 120;
  static const Duration _liveOffRoutePersistenceDuration = Duration(minutes: 2);
  static const Duration _passwordResetCodeLifetime = Duration(minutes: 15);
  static const int _passwordResetMaxAttempts = 5;
  static const int _maxNameLength = 120;
  static const int _maxEmailLength = 254;
  static const int _maxPhoneLength = 32;
  static const int _maxPasswordLength = 256;
  static const int _maxProfilePhotoDataUrlLength = 360000;
  static const int _maxProfilePhotoBytes = 256 * 1024;
  static const int _profileNameChangeCooldownMonths = 3;
  static const int _maxSearchQueryLength = 120;
  static const int _maxLineCodeLength = 32;
  static const int _maxNoteLength = 500;
  static const int _maxBusNumberLength = 32;
  static const int _maxLineLabelLength = 160;
  static const int _maxMessageLength = 1000;
  static const int _maxMessagePageLimit = 80;
  static const int _defaultMessagePageLimit = 40;
  static const int _defaultMessagePeerCandidateLimit = 20;
  static const int _maxMessagePeerCandidateLimit = 50;
  static const int _maxClientIdLength = 80;
  static const int _maxPushTokenLength = 4096;
  static const int _maxDeviceMetadataLength = 120;
  final StreamController<int> _sharedChanges =
      StreamController<int>.broadcast();
  int _sharedRevision = 0;
  Future<void> Function()? _publishSharedChange;
  StreamSubscription<void>? _externalChangeSubscription;

  JsonMap _state = <String, dynamic>{};
  final Map<String, int> _sessionConnectionCounts = <String, int>{};
  final Map<String, bool> _sessionOnline = <String, bool>{};

  Stream<int> get sharedChanges => _sharedChanges.stream;
  int get sharedRevision => _sharedRevision;
  String get storageBackend => _persistence.name;
  bool get isDatabaseBacked => _persistence.isDatabaseBacked;
  bool get supportsGeospatialQueries => _persistence.supportsGeospatialQueries;
  Future<void> checkReady() => _persistence.checkReady();

  void setSessionOnline(String sessionId) {
    _setSessionOnline(sessionId, true);
  }

  void setSessionOffline(String sessionId) {
    _setSessionOnline(sessionId, false);
  }

  void _setSessionOnline(String sessionId, bool online) {
    final currentCount = _sessionConnectionCounts[sessionId] ?? 0;
    if (online) {
      _sessionConnectionCounts[sessionId] = currentCount + 1;
      if (currentCount > 0) return;
      _sessionOnline[sessionId] = true;
    } else {
      final nextCount = currentCount - 1;
      if (nextCount > 0) {
        _sessionConnectionCounts[sessionId] = nextCount;
        return;
      }
      _sessionConnectionCounts.remove(sessionId);
      if (currentCount == 0) return;
      _sessionOnline.remove(sessionId);
    }

    final sessions = _sessions();
    final rawSession = sessions[sessionId];
    if (rawSession != null) {
      final normalized = _normalizeSession(rawSession);
      normalized['lastSeenAt'] = _nowIso();
      normalized['isOnline'] = online;
      _putSession(sessionId, normalized);
    }

    _notifySharedChange();
  }

  void attachChangePublisher(Future<void> Function() publishSharedChange) {
    _publishSharedChange = publishSharedChange;
  }

  void listenToExternalChanges(Stream<void> changes) {
    _externalChangeSubscription?.cancel();
    _externalChangeSubscription = changes.listen((_) async {
      await _reloadStateFromPersistence();
      _notifySharedChange(publishExternal: false);
    });
  }

  static Future<PiwibusStore> load() async {
    final backendDir = _findBackendDirectory();
    final workspaceRoot = backendDir.parent;
    final csvFile = _findCsvFile(workspaceRoot, backendDir);
    final catalog = await _loadLines(csvFile);
    final nearbyPlaceLabels = await _loadNearbyPlaceLabels(
      _findMapLabelsFile(workspaceRoot, backendDir),
    );
    final stateFile = File(p.join(backendDir.path, 'data', 'state.json'));
    final seedStateFile = File(
      p.join(backendDir.path, 'data', 'seed_state.json'),
    );
    final persistence = await StatePersistence.open(
      backendDir: backendDir,
      stateFile: stateFile,
    );
    final store = PiwibusStore._(
      lines: catalog.lines,
      lineDataVersion: catalog.lineDataVersion,
      nearbyPlaceLabels: nearbyPlaceLabels,
      persistence: persistence,
    );
    await store._loadOrSeedState(seedStateFile);
    return store;
  }

  static Future<PiwibusStore> openWithPersistence(
    StatePersistence persistence,
  ) async {
    final backendDir = _findBackendDirectory();
    final workspaceRoot = backendDir.parent;
    final csvFile = _findCsvFile(workspaceRoot, backendDir);
    final catalog = await _loadLines(csvFile);
    final nearbyPlaceLabels = await _loadNearbyPlaceLabels(
      _findMapLabelsFile(workspaceRoot, backendDir),
    );
    final seedStateFile = File(
      p.join(backendDir.path, 'data', 'seed_state.json'),
    );
    final store = PiwibusStore._(
      lines: catalog.lines,
      lineDataVersion: catalog.lineDataVersion,
      nearbyPlaceLabels: nearbyPlaceLabels,
      persistence: persistence,
    );
    await store._loadOrSeedState(seedStateFile);
    return store;
  }

  static Directory _findBackendDirectory() {
    final envPath = Platform.environment['PIWIBUS_BACKEND_DIR'];
    if (envPath != null && envPath.trim().isNotEmpty) {
      final envDir = Directory(envPath.trim());
      if (envDir.existsSync()) return envDir;
    }

    final current = Directory.current;
    if (_isBackendDirectory(current)) return current;

    final scriptDir = File.fromUri(Platform.script).parent;
    if (_isBackendDirectory(scriptDir)) return scriptDir;
    if (_isBackendDirectory(scriptDir.parent)) return scriptDir.parent;

    final runtimeBackend = Directory('/app/backend');
    if (runtimeBackend.existsSync()) return runtimeBackend;

    throw StateError('Unable to locate backend directory.');
  }

  static bool _isBackendDirectory(Directory directory) {
    return File(p.join(directory.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(directory.path, 'lib')).existsSync();
  }

  static File _findCsvFile(Directory workspaceRoot, Directory backendDir) {
    final envPath = Platform.environment['PIWIBUS_CSV_PATH'];
    final candidates = <File>[
      if (envPath != null && envPath.trim().isNotEmpty) File(envPath.trim()),
      File(p.join(workspaceRoot.path, 'abidjantransport-lignes-sotra.csv')),
      File(
        p.join(
          workspaceRoot.path,
          'piwibus_app',
          'assets',
          'abidjantransport-lignes-sotra.csv',
        ),
      ),
      File(p.join(backendDir.path, 'abidjantransport-lignes-sotra.csv')),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) {
        return candidate;
      }
    }
    throw StateError(
      'Impossible de trouver le fichier CSV des lignes SOTRA. '
      'Renseignez PIWIBUS_CSV_PATH si besoin.',
    );
  }

  static File? _findMapLabelsFile(
    Directory workspaceRoot,
    Directory backendDir,
  ) {
    final envPath = Platform.environment['PIWIBUS_MAP_LABELS_PATH'];
    final candidates = <File>[
      if (envPath != null && envPath.trim().isNotEmpty) File(envPath.trim()),
      File(
        p.join(
          workspaceRoot.path,
          'piwibus_app',
          'assets',
          'maps',
          'cote_divoire_labels.json',
        ),
      ),
      File(
        p.join(backendDir.path, 'assets', 'maps', 'cote_divoire_labels.json'),
      ),
      File(p.join(backendDir.path, 'cote_divoire_labels.json')),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }

  static Future<List<_NearbyPlaceLabel>> _loadNearbyPlaceLabels(
    File? labelsFile,
  ) async {
    if (labelsFile == null) return const <_NearbyPlaceLabel>[];
    try {
      final raw = await labelsFile.readAsString();
      final decoded = jsonDecode(raw);
      final labels = decoded is Map ? decoded['labels'] : null;
      if (labels is! List) return const <_NearbyPlaceLabel>[];
      final result = <_NearbyPlaceLabel>[];
      final seen = <String>{};
      for (final label in labels) {
        if (label is! Map) continue;
        final name = _text(label['name']);
        if (name.isEmpty) continue;
        final lat = _double(label['lat']);
        final lng = _double(label['lng']);
        if (!_isStaticValidLatLng(lat, lng)) continue;
        final kind = _text(label['kind']);
        final key =
            '$name|$kind|${lat.toStringAsFixed(5)}|'
            '${lng.toStringAsFixed(5)}';
        if (!seen.add(key)) continue;
        result.add(
          _NearbyPlaceLabel(
            name: name,
            subtitle: _text(label['subtitle']),
            kind: kind,
            lat: lat,
            lng: lng,
          ),
        );
      }
      return List<_NearbyPlaceLabel>.unmodifiable(result);
    } catch (_) {
      return const <_NearbyPlaceLabel>[];
    }
  }

  static Future<_LineCatalog> _loadLines(File csvFile) async {
    final bytes = await csvFile.readAsBytes();
    final raw = utf8.decode(bytes);
    final rows = Csv(fieldDelimiter: ';', autoDetect: false).decode(raw);
    if (rows.isEmpty) {
      return _LineCatalog(
        lines: const <JsonMap>[],
        lineDataVersion: sha256.convert(bytes).toString(),
      );
    }
    final headers = rows.first.map((cell) => cell.toString().trim()).toList();
    final result = <JsonMap>[];
    for (final row in rows.skip(1)) {
      if (row.isEmpty) continue;
      final map = <String, String>{};
      for (var i = 0; i < headers.length; i++) {
        final key = _normalizeHeader(headers[i]);
        final value = i < row.length ? row[i]?.toString().trim() ?? '' : '';
        map[key] = value;
      }
      result.add(<String, dynamic>{
        'line_id': map['line_id'] ?? '',
        'name': map['name'] ?? '',
        'code': map['code'] ?? '',
        'colour': map['colour'] ?? '',
        'operator': map['operator'] ?? '',
        'network': map['network'] ?? '',
        'mode': map['mode'] ?? '',
        'frequency': map['frequency'] ?? '',
        'opening_hours': map['opening_hours'] ?? '',
        'frequency_exceptions': map['frequency_exceptions'] ?? '',
        'shape': map['shape'] ?? '',
        'geometry': map['geometry'] ?? '',
      });
    }
    result.sort(
      (a, b) => _compareCodes(
        a['code']?.toString() ?? '',
        b['code']?.toString() ?? '',
      ),
    );
    return _LineCatalog(
      lines: result,
      lineDataVersion: sha256.convert(bytes).toString(),
    );
  }

  Future<void> _loadOrSeedState(File seedStateFile) async {
    final persisted = await _persistence.loadState();
    if (persisted != null) {
      try {
        _state = _normalizeState(persisted);
        _ensureBootstrapAdminFromEnv();
        _enforceNoDefaultAdminPassword();
        if (!_needsReseed(_state)) {
          await _saveState();
          return;
        }
      } catch (error) {
        if (_persistence.isDatabaseBacked) {
          throw StateError(
            'Etat PostgreSQL existant invalide ou impossible a normaliser. '
            'Demarrage interrompu pour eviter de remplacer les donnees par le seed. '
            'Cause: $error',
          );
        }
        // Fall through to reseed for local JSON development state only.
      }
    }

    if (_persistence.isDatabaseBacked && await seedStateFile.exists()) {
      try {
        final decoded = jsonDecode(await seedStateFile.readAsString());
        if (decoded is Map) {
          _state = _normalizeState(
            Map<String, dynamic>.from(decoded),
            pruneLegacyFixtures: true,
          );
          _ensureBootstrapAdminFromEnv();
          _enforceNoDefaultAdminPassword();
          if (!_needsReseed(_state) && !_stateHasNoRecords(_state)) {
            await _saveState();
            return;
          }
        }
      } catch (_) {
        // Fall through to a clean seed.
      }
    }

    _state = _normalizeState(_seedState());
    _ensureBootstrapAdminFromEnv();
    _enforceNoDefaultAdminPassword();
    await _saveState();
  }

  Future<void> _reloadStateFromPersistence() async {
    final persisted = await _persistence.loadState();
    if (persisted == null) return;
    _state = _normalizeState(persisted);
    if (_ensureBootstrapAdminFromEnv()) {
      await _saveState();
    }
    _enforceNoDefaultAdminPassword();
  }

  bool _needsReseed(JsonMap state) {
    final trips = _mapList(state['trips']);
    if (trips.isNotEmpty &&
        trips.every((trip) => _text(trip['line_code']).isEmpty)) {
      return true;
    }
    return false;
  }

  bool _stateHasNoRecords(JsonMap state) {
    return _sessionsFromRaw(state['sessions']).isEmpty &&
        _mapList(state['users']).isEmpty &&
        _mapList(state['trips']).isEmpty &&
        _mapList(state['reports']).isEmpty &&
        _mapList(state['pushTokens']).isEmpty &&
        _mapList(state['activity']).isEmpty;
  }

  Future<String> ensureSession(String? sessionId) async {
    final candidate = sessionId?.trim() ?? '';
    String effectiveSessionId;
    final sessions = _sessions();
    var changed = _pruneExpiredSessions(sessions);
    if (candidate.isEmpty) {
      effectiveSessionId = _newSessionId();
      sessions[effectiveSessionId] = _defaultSessionState();
      changed = true;
    } else {
      final existing = sessions[candidate];
      if (existing == null) {
        effectiveSessionId = _newSessionId();
        sessions[effectiveSessionId] = _defaultSessionState();
        changed = true;
      } else {
        final normalized = _normalizeSession(existing);
        if (_sessionIsExpired(normalized)) {
          sessions.remove(candidate);
          _state['sessions'] = sessions;
          effectiveSessionId = _newSessionId();
          sessions[effectiveSessionId] = _defaultSessionState();
          changed = true;
        } else if (_sessionNeedsRotation(candidate, normalized)) {
          sessions.remove(candidate);
          effectiveSessionId = _newSessionId();
          normalized['lastSeenAt'] = _nowIso();
          sessions[effectiveSessionId] = normalized;
          _state['sessions'] = sessions;
          changed = true;
        } else {
          effectiveSessionId = candidate;
          if (_sessionNeedsTouch(normalized)) {
            normalized['lastSeenAt'] = _nowIso();
            sessions[candidate] = normalized;
            changed = true;
          }
        }
      }
    }
    _state['sessions'] = sessions;
    if (changed) {
      await _persist(const StateMutationBatch(sessions: true));
    }
    return effectiveSessionId;
  }

  JsonMap snapshot(String sessionId, {bool includeLines = true}) {
    _state = _normalizeState(_state);
    final session = _session(sessionId);
    final currentUser = _currentUser(session);
    final refreshedCurrentUser = currentUser == null
        ? null
        : _refreshPublicUser(currentUser);
    final canViewAll = _sessionUserCanAdmin(session);
    final allTrips = _tripsWithObserverCounts(_trips());
    final visibleTrips = allTrips
        .map(
          (trip) => _publicTripForSession(
            trip,
            sessionId,
            includeAdminTelemetry: canViewAll,
          ),
        )
        .toList(growable: false);
    final allReports = _reports();
    final visibleReports = canViewAll
        ? allReports
        : allReports
              .where((report) => _text(report['status']) != 'refuse')
              .map(_publicReport)
              .toList(growable: false);
    final visibleActivity = _activityItems()
        .where((activity) => _activityVisibleToSession(activity, sessionId))
        .toList(growable: false);
    final visibleUsers = canViewAll
        ? _users().map(_publicUser).toList(growable: false)
        : refreshedCurrentUser == null
        ? <JsonMap>[]
        : <JsonMap>[refreshedCurrentUser];
    final visibleMessageConversations = _messageConversationsForSession(
      currentUser,
    );

    return <String, dynamic>{
      'sessionId': sessionId,
      'currentUser': refreshedCurrentUser,
      'activeRole': session['activeRole'],
      'section': session['section'],
      'searchQuery': session['searchQuery'],
      'selectedLineCode': session['selectedLineCode'],
      'selectedTripId': session['selectedTripId'],
      'favoriteLineCodes': List<String>.from(
        session['favoriteLineCodes'] as List,
      ),
      'revision': _sharedRevision,
      'lineDataVersion': _lineDataVersion,
      'lineCount': _lines.length,
      'lines': includeLines ? _lines : const <JsonMap>[],
      'users': visibleUsers,
      'trips': visibleTrips,
      'messageConversations': visibleMessageConversations,
      'reports': visibleReports,
      'activity': visibleActivity,
    };
  }

  JsonMap realtimeScope(String sessionId) {
    final session = _session(sessionId);
    return <String, dynamic>{
      'sessionId': sessionId,
      'canViewAll': _sessionUserCanAdmin(session),
      'activeRole': session['activeRole'],
      'selectedLineCode': session['selectedLineCode'],
      'selectedTripId': session['selectedTripId'],
      'favoriteLineCodes': List<String>.from(
        session['favoriteLineCodes'] as List,
      ),
      'currentLocation': session['currentLocation'],
    };
  }

  /// Photo de profil brute (data URL base64) d'un utilisateur, utilisee
  /// uniquement par la route de service dediee `GET /users/<id>/photo` afin
  /// de ne plus avoir a embarquer ce contenu dans chaque snapshot JSON.
  String? rawProfilePhotoDataUrlForUser(String userId) {
    final normalizedId = _text(userId);
    if (normalizedId.isEmpty) return null;
    for (final user in _users()) {
      if (_text(user['id']) == normalizedId) {
        return _nullableText(user['profilePhotoDataUrl']);
      }
    }
    return null;
  }

  JsonMap _snapshotWithSystemTripCancellationNotices(
    String sessionId,
    List<JsonMap> notices, {
    bool includeLines = true,
  }) {
    final result = snapshot(sessionId, includeLines: includeLines);
    if (notices.isNotEmpty) {
      result['_systemTripCancellationNotices'] = notices;
    }
    return result;
  }

  List<JsonMap> lines([String? query]) {
    final q = query?.trim().toLowerCase() ?? '';
    if (q.isEmpty) {
      return List<JsonMap>.from(_lines);
    }
    return _lines
        .where((line) {
          final code = line['code']?.toString().toLowerCase() ?? '';
          final name = line['name']?.toString().toLowerCase() ?? '';
          final operator = line['operator']?.toString().toLowerCase() ?? '';
          final network = line['network']?.toString().toLowerCase() ?? '';
          final openingHours =
              line['opening_hours']?.toString().toLowerCase() ?? '';
          return code.contains(q) ||
              name.contains(q) ||
              operator.contains(q) ||
              network.contains(q) ||
              openingHours.contains(q);
        })
        .toList(growable: false);
  }

  JsonMap lineMetadata() {
    return <String, dynamic>{
      'lineDataVersion': _lineDataVersion,
      'lineCount': _lines.length,
    };
  }

  ({List<String> tokens, Set<String> sessionIds}) notificationAudienceNearLine(
    String lineCode, {
    double radiusMeters = 200,
  }) {
    final line = lineByCode(lineCode);
    if (line == null) {
      return (tokens: const <String>[], sessionIds: <String>{});
    }
    final sessionIds = _sessionsNearLine(line, radiusMeters: radiusMeters);
    final tokens = _mapList(_state['pushTokens'])
        .where((token) => _text(token['status']) != 'disabled')
        .where((token) => sessionIds.contains(_text(token['sessionId'])))
        .map((token) => _text(token['token']))
        .where((token) => token.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return (tokens: tokens, sessionIds: sessionIds);
  }

  ({List<String> tokens, Set<String> sessionIds}) notificationAudienceForTrip(
    String tripId, {
    String? excludeOwnerId,
  }) {
    final normalizedTripId = _text(tripId);
    if (normalizedTripId.isEmpty) {
      return (tokens: const <String>[], sessionIds: <String>{});
    }
    final trip = _trips()
        .where((candidate) => _text(candidate['id']) == normalizedTripId)
        .firstOrNull;
    final ownerSessionMarker = _text(trip?['owner_session_id']);
    final ownerSessionId = ownerSessionMarker.startsWith('session-')
        ? ownerSessionMarker.substring('session-'.length)
        : '';
    final ownerId = _text(trip?['owner_id']);
    final excludedOwnerId = _text(excludeOwnerId);
    final sessionIds = _sessions().entries
        .where((entry) {
          final currentUser = entry.value['currentUser'];
          final currentUserId = currentUser is Map
              ? _text(currentUser['id'])
              : '';
          final selectedTrip =
              _text(entry.value['selectedTripId']) == normalizedTripId;
          final ownsSession =
              ownerSessionId.isNotEmpty && entry.key == ownerSessionId;
          final ownsAnonymousTrip =
              ownerId.isNotEmpty && ownerId == 'session-${entry.key}';
          final ownsUser = ownerId.isNotEmpty && currentUserId == ownerId;
          if (!selectedTrip &&
              !ownsSession &&
              !ownsAnonymousTrip &&
              !ownsUser) {
            return false;
          }
          if (excludedOwnerId.isEmpty) return true;
          return entry.key != excludedOwnerId &&
              'session-${entry.key}' != excludedOwnerId &&
              currentUserId != excludedOwnerId;
        })
        .map((entry) => entry.key)
        .toSet();
    final tokens = _mapList(_state['pushTokens'])
        .where((token) => _text(token['status']) != 'disabled')
        .where((token) => sessionIds.contains(_text(token['sessionId'])))
        .map((token) => _text(token['token']))
        .where((token) => token.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return (tokens: tokens, sessionIds: sessionIds);
  }

  ({List<String> tokens, Set<String> sessionIds})
  notificationAudienceForTripOwner(String tripId) {
    final trip = _trips()
        .where((candidate) => _text(candidate['id']) == _text(tripId))
        .firstOrNull;
    if (trip == null) {
      return (tokens: const <String>[], sessionIds: <String>{});
    }
    final ownerId = _text(trip['owner_id']);
    if (ownerId.isNotEmpty && !ownerId.startsWith('session-')) {
      return notificationAudienceForUser(ownerId);
    }
    final ownerMarker = _text(trip['owner_session_id']);
    final ownerSessionId = ownerMarker.startsWith('session-')
        ? ownerMarker.substring('session-'.length)
        : '';
    if (ownerSessionId.isEmpty) {
      return (tokens: const <String>[], sessionIds: <String>{});
    }
    final tokens = _mapList(_state['pushTokens'])
        .where((token) => _text(token['status']) != 'disabled')
        .where((token) => _text(token['sessionId']) == ownerSessionId)
        .map((token) => _text(token['token']))
        .where((token) => token.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return (tokens: tokens, sessionIds: <String>{ownerSessionId});
  }

  /// Retourne les tokens push et sessionIds pour un utilisateur donné.
  ({List<String> tokens, Set<String> sessionIds}) notificationAudienceForUser(
    String userId,
  ) {
    final normalizedUserId = _text(userId);
    if (normalizedUserId.isEmpty)
      return (tokens: const <String>[], sessionIds: <String>{});
    final sessionIds = _sessions().entries
        .where((entry) {
          final currentUser = entry.value['currentUser'];
          final currentUserId = currentUser is Map
              ? _text(currentUser['id'])
              : '';
          return currentUserId == normalizedUserId;
        })
        .map((entry) => entry.key)
        .toSet();
    final tokens = _mapList(_state['pushTokens'])
        .where((token) => _text(token['status']) != 'disabled')
        .where((token) => sessionIds.contains(_text(token['sessionId'])))
        .map((token) => _text(token['token']))
        .where((token) => token.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return (tokens: tokens, sessionIds: sessionIds);
  }

  JsonMap? lastMessageForConversation(String conversationId) {
    final convId = _text(conversationId);
    if (convId.isEmpty) return null;
    final conv = _messageConversations().firstWhere(
      (c) => _text(c['id']) == convId,
      orElse: () => <String, dynamic>{},
    );
    if (conv.isEmpty) return null;
    final messages = _mapList(conv['messages']);
    if (messages.isEmpty) return null;
    return Map<String, dynamic>.from(messages.last);
  }

  JsonMap? lineByCode(String code) {
    for (final line in _lines) {
      if (_normalizeCode(line['code']) == _normalizeCode(code)) {
        return line;
      }
    }
    return null;
  }

  JsonMap adminMapData(String sessionId) {
    _requireAdmin(sessionId);
    double? minLat;
    double? minLng;
    double? maxLat;
    double? maxLng;

    final lines = <JsonMap>[];
    for (final line in _lines) {
      final code = _normalizeCode(line['code']);
      if (code.isEmpty) continue;
      final segments = _lineSegments(line);
      if (segments.isEmpty) continue;
      for (final segment in segments) {
        for (final point in segment) {
          minLat = minLat == null ? point.lat : math.min(minLat, point.lat);
          minLng = minLng == null ? point.lng : math.min(minLng, point.lng);
          maxLat = maxLat == null ? point.lat : math.max(maxLat, point.lat);
          maxLng = maxLng == null ? point.lng : math.max(maxLng, point.lng);
        }
      }
      final routeDistanceKm = segments
          .map(_pathDistanceKm)
          .fold<double>(0, (best, distance) => math.max(best, distance));
      lines.add(<String, dynamic>{
        'lineCode': code,
        'displayCode': _displayCode(code),
        'title': _routeTitle(line),
        'colorValue': _colorValue(line['colour'], code),
        'routeDistanceKm': routeDistanceKm,
        'segments': segments
            .map(
              (segment) => segment
                  .map(
                    (point) => <String, dynamic>{
                      'lat': point.lat,
                      'lng': point.lng,
                    },
                  )
                  .toList(growable: false),
            )
            .toList(growable: false),
      });
    }

    return <String, dynamic>{
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'bounds': <String, dynamic>{
        if (minLat != null) 'minLat': minLat,
        if (minLng != null) 'minLng': minLng,
        if (maxLat != null) 'maxLat': maxLat,
        if (maxLng != null) 'maxLng': maxLng,
      },
      'lines': lines,
    };
  }

  Future<List<JsonMap>> nearbyTrips({
    required double lat,
    required double lng,
    double radiusMeters = 1000,
    int limit = 20,
  }) async {
    if (!_isValidLatLng(lat, lng)) {
      throw StateError('Les coordonnées GPS sont invalides.');
    }
    final boundedRadius = radiusMeters.clamp(1, 50000).toDouble();
    final boundedLimit = limit.clamp(1, 100).toInt();
    final tripsById = {for (final trip in _trips()) _text(trip['id']): trip};

    if (_persistence.supportsGeospatialQueries) {
      final rows = await _persistence.nearbyActiveTrips(
        lat: lat,
        lng: lng,
        radiusMeters: boundedRadius,
        limit: boundedLimit,
      );
      final result = <JsonMap>[];
      for (final row in rows) {
        final tripId = _text(row['trip_id']);
        final trip = tripsById[tripId];
        if (trip == null) continue;
        result.add(<String, dynamic>{
          ..._publicNearbyTrip(trip),
          'distanceMeters': _double(row['distance_meters']),
        });
      }
      return result;
    }

    final result = <JsonMap>[];
    for (final trip in _trips()) {
      if (_text(trip['status']) != 'actif') continue;
      final liveLocation = trip['liveLocation'];
      if (liveLocation is! Map) continue;
      final tripLat = _double(liveLocation['lat'] ?? liveLocation['latitude']);
      final tripLng = _double(liveLocation['lng'] ?? liveLocation['longitude']);
      if (!_isValidLatLng(tripLat, tripLng)) continue;
      final distanceMeters = _distanceMeters(lat, lng, tripLat, tripLng);
      if (distanceMeters > boundedRadius) continue;
      result.add(<String, dynamic>{
        ..._publicNearbyTrip(trip),
        'distanceMeters': distanceMeters,
      });
    }
    result.sort(
      (a, b) =>
          _double(a['distanceMeters']).compareTo(_double(b['distanceMeters'])),
    );
    return result.take(boundedLimit).toList(growable: false);
  }

  Future<List<JsonMap>> nearbyTripLineCounts({
    required double lat,
    required double lng,
    double radiusMeters = 1000,
    int limit = 20,
  }) async {
    final nearby = await nearbyTrips(
      lat: lat,
      lng: lng,
      radiusMeters: radiusMeters,
      limit: limit,
    );
    final counts = <String, int>{};
    for (final trip in nearby) {
      final lineCode = _normalizeCode(
        _text(trip['line_code']).isEmpty
            ? _text(trip['lineCode'])
            : _text(trip['line_code']),
      );
      if (lineCode.isEmpty) continue;
      counts[lineCode] = (counts[lineCode] ?? 0) + 1;
    }
    return counts.entries
        .map(
          (entry) => <String, dynamic>{
            'lineCode': entry.key,
            'line_code': entry.key,
            'lineLabel': _displayCode(entry.key),
            'liveCount': entry.value,
          },
        )
        .toList(growable: false);
  }

  JsonMap? tripStatusForSession(String sessionId, String tripId) {
    _state = _normalizeState(_state);
    final normalizedTripId = _text(tripId);
    if (normalizedTripId.isEmpty) return null;
    final allTrips = _tripsWithObserverCounts(_trips());
    for (final trip in allTrips) {
      if (_text(trip['id']) != normalizedTripId) continue;
      final public = _publicTripForSession(
        trip,
        sessionId,
        includeAdminTelemetry: _sessionUserCanAdmin(_session(sessionId)),
      );
      final lineCode = _text(public['line_code']);
      return <String, dynamic>{
        'id': _text(public['id']),
        'status': _text(public['status']),
        'lineCode': lineCode,
        'line_code': lineCode,
        'lastUpdatedAt': _text(public['lastUpdatedAt']),
        'liveLocation': public['liveLocation'],
        'lastSystemMessage': _lastSystemMessage(public),
      };
    }
    return null;
  }

  Future<JsonMap> adminSignIn(String sessionId, JsonMap body) async {
    final now = _nowIso();
    final email = _boundedText(
      body['email'],
      _maxEmailLength,
      fieldName: 'Email',
    ).toLowerCase();
    final password = _boundedText(
      body['password'],
      _maxPasswordLength,
      fieldName: 'Mot de passe',
    );
    if (!_isValidEmail(email)) {
      throw StateError('Adresse email invalide.');
    }
    if (password.isEmpty) {
      throw StateError('Mot de passe requis.');
    }

    final users = _users();
    final index = users.indexWhere(
      (user) => _text(user['email']).toLowerCase() == email,
    );
    if (index < 0) {
      throw StateError('Compte administrateur introuvable.');
    }

    final user = users[index];
    if (!_verifyPassword(email, password, _text(user['passwordHash']))) {
      throw StateError('Mot de passe invalide.');
    }
    if (_text(user['status']) == 'suspendu') {
      throw StateError('Ce compte est suspendu.');
    }
    if (!_userCanAdmin(user)) {
      throw StateError('Acces administrateur requis.');
    }

    user['passwordHash'] = _hashPassword(email, password);
    user['lastSeenAt'] = now;
    _state['users'] = users;

    final session = _session(sessionId);
    session['currentUser'] = _publicUser(user);
    session['activeRole'] = 'administrateur';
    session['section'] = 'administration';
    session['lastSeenAt'] = now;
    _putSession(sessionId, session);
    // admin sign-in updates session info; presence is driven by active
    // realtime connections rather than auth POSTs.
    addActivity(
      title: 'Connexion admin',
      subtitle: 'Interface web admin ouverte par ${_text(user['fullName'])}.',
      iconKey: 'admin',
      colorValue: 0xFF1F2937,
      audienceSessionIds: <String>[sessionId],
    );
    _notifySharedChange();
    await _persist(
      const StateMutationBatch(users: true, sessions: true, activity: true),
    );
    return adminDashboard(sessionId);
  }

  bool sessionCanAdmin(String sessionId) {
    final session = _session(sessionId);
    return _text(session['activeRole']) == 'administrateur' &&
        _sessionUserCanAdmin(session);
  }

  JsonMap adminDashboard(
    String sessionId, {
    JsonMap metrics = const <String, dynamic>{},
  }) {
    _requireAdmin(sessionId);
    _state = _normalizeState(_state);
    final now = DateTime.now().toUtc();
    final sessions = _sessions();
    final users = _users();
    final trips = _tripsWithObserverCounts(_trips());
    final reports = _reports();
    final activity = _activityItems();
    final pushTokens = _mapList(_state['pushTokens']);

    bool seenWithin(JsonMap item, Duration window) {
      final lastSeenAt = DateTime.tryParse(_text(item['lastSeenAt']));
      return lastSeenAt != null && now.difference(lastSeenAt.toUtc()) <= window;
    }

    bool dateWithin(Object? value, Duration window) {
      final parsed = DateTime.tryParse(_text(value));
      return parsed != null && now.difference(parsed.toUtc()) <= window;
    }

    bool tripMessageContains(JsonMap trip, String needle) {
      return _mapList(trip['messages']).any(
        (message) => _text(message['content']).toLowerCase().contains(needle),
      );
    }

    bool isSystemStopped(JsonMap trip) {
      if (_text(trip['status']) == 'actif') return false;
      return tripMessageContains(trip, 'automatiquement') ||
          tripMessageContains(trip, 'hors trace') ||
          tripMessageContains(trip, 'ne communique plus') ||
          tripMessageContains(trip, 'nouveau trajet');
    }

    double tripDurationMinutes(JsonMap trip) {
      final startedAt = DateTime.tryParse(_text(trip['startedAt']));
      final endedAt = DateTime.tryParse(_text(trip['lastUpdatedAt']));
      if (startedAt == null || endedAt == null) return 0;
      return endedAt.toUtc().difference(startedAt.toUtc()).inSeconds / 60;
    }

    double average(List<double> values) {
      if (values.isEmpty) return 0;
      return values.reduce((a, b) => a + b) / values.length;
    }

    Map<String, int> countBy(Iterable<JsonMap> items, String key) {
      final counts = <String, int>{};
      for (final item in items) {
        final value = _text(item[key]).isEmpty ? 'inconnu' : _text(item[key]);
        counts[value] = (counts[value] ?? 0) + 1;
      }
      return counts;
    }

    final connectedSessions = sessions.entries
        .where((entry) => seenWithin(entry.value, const Duration(minutes: 6)))
        .toList(growable: false);
    final activeTrips = trips
        .where((trip) => _text(trip['status']) == 'actif')
        .toList(growable: false);
    final offRouteTrips = activeTrips
        .where((trip) => _text(trip['offRouteSince']).isNotEmpty)
        .toList(growable: false);
    final publicReports = reports
        .where((report) => _text(report['status']) != 'refuse')
        .toList(growable: false);
    final systemStoppedTrips = trips
        .where(isSystemStopped)
        .toList(growable: false);
    final completedTrips = trips
        .where((trip) => _text(trip['status']) != 'actif')
        .toList(growable: false);

    final activeLocationAges = <double>[];
    final accuracies = <double>[];
    for (final trip in activeTrips) {
      final liveLocation = trip['liveLocation'];
      if (liveLocation is! Map) continue;
      final location = Map<String, dynamic>.from(liveLocation);
      final timestamp = DateTime.tryParse(_text(location['timestamp']));
      if (timestamp != null) {
        activeLocationAges.add(
          now.difference(timestamp.toUtc()).inSeconds.toDouble(),
        );
      }
      final accuracy = _double(location['accuracy']);
      if (accuracy > 0) accuracies.add(accuracy);
    }

    final completedDurations = completedTrips
        .map(tripDurationMinutes)
        .where((duration) => duration > 0)
        .toList(growable: false);
    final completedDistancesKm = completedTrips
        .map(_tripTravelledDistanceKm)
        .where((distance) => distance > 0)
        .toList(growable: false);
    final totalCompletedDistanceKm = completedDistancesKm.fold<double>(
      0,
      (sum, distance) => sum + distance,
    );
    final ratedTrips = trips
        .where((trip) => _int(trip['ratingCount']) > 0)
        .toList(growable: false);
    final totalRatingCount = ratedTrips.fold<int>(
      0,
      (sum, trip) => sum + _int(trip['ratingCount']),
    );
    final totalRatingScore = ratedTrips.fold<double>(
      0,
      (sum, trip) =>
          sum + (_double(trip['ratingAverage']) * _int(trip['ratingCount'])),
    );
    final totalTripNetworkBytes = trips.fold<int>(
      0,
      (sum, trip) => sum + _int(trip['networkUsageBytes']),
    );
    final activeTripNetworkBytes = activeTrips.fold<int>(
      0,
      (sum, trip) => sum + _int(trip['networkUsageBytes']),
    );

    final usersById = <String, int>{};
    for (final session in sessions.values) {
      final user = session['currentUser'];
      if (user is! Map) continue;
      final userId = _text(user['id']);
      if (userId.isEmpty) continue;
      usersById[userId] = (usersById[userId] ?? 0) + 1;
    }

    final lineStats = _adminLineStats(trips, reports);
    final liveUsers = <JsonMap>[];
    for (final entry in sessions.entries) {
      final sessionState = entry.value;
      final currentUser = sessionState['currentUser'];
      if (currentUser is! Map) continue;
      final userId = _text(currentUser['id']);
      if (userId.isEmpty) continue;
      final locationCandidate = selectPeerSearchLocation(
        sessionLocation: sessionState['currentLocation'],
        now: now,
        freshness: const Duration(minutes: 5),
      );
      if (locationCandidate == null) continue;
      final publicUser = _publicUser(Map<String, dynamic>.from(currentUser));
      liveUsers.add(<String, dynamic>{
        ...publicUser,
        'sessionId': entry.key,
        'connected': seenWithin(sessionState, const Duration(minutes: 6)),
        'lastSeenAt': _text(sessionState['lastSeenAt']),
        'location': <String, dynamic>{
          'lat': locationCandidate.lat,
          'lng': locationCandidate.lng,
          'timestamp': locationCandidate.timestamp.toIso8601String(),
        },
      });
    }

    return <String, dynamic>{
      'generatedAt': now.toIso8601String(),
      'currentAdmin': _session(sessionId)['currentUser'],
      'overview': <String, dynamic>{
        'connectedUsers': connectedSessions.length,
        'activeTrips': activeTrips.length,
        'broadcastingStars': activeTrips
            .map((trip) => _text(trip['owner_id']))
            .where((owner) => owner.isNotEmpty)
            .toSet()
            .length,
        'publicReports': publicReports.length,
        'offRouteTrips': offRouteTrips.length,
        'systemStoppedTrips': systemStoppedTrips.length,
        'pushTokens': pushTokens
            .where((token) => _text(token['status']) != 'disabled')
            .length,
      },
      'backend': <String, dynamic>{
        'storage': storageBackend,
        'databaseBacked': isDatabaseBacked,
        'geospatialQueries': supportsGeospatialQueries,
        'metrics': metrics,
      },
      'gpsQuality': <String, dynamic>{
        'trackedActiveTrips': activeTrips.length,
        'averageAccuracyMeters': average(accuracies),
        'averageLocationAgeSeconds': average(activeLocationAges),
        'staleLocations': activeLocationAges
            .where((age) => age > _liveLocationMaxSampleAge.inSeconds)
            .length,
        'offRouteTrips': offRouteTrips.map(_adminTrip).toList(growable: false),
      },
      'stats': <String, dynamic>{
        'activeUsers': <String, dynamic>{
          'day': users
              .where(
                (user) =>
                    dateWithin(user['lastSeenAt'], const Duration(days: 1)),
              )
              .length,
          'week': users
              .where(
                (user) =>
                    dateWithin(user['lastSeenAt'], const Duration(days: 7)),
              )
              .length,
          'month': users
              .where(
                (user) =>
                    dateWithin(user['lastSeenAt'], const Duration(days: 30)),
              )
              .length,
        },
        'registrations': <String, dynamic>{
          'day': users
              .where(
                (user) =>
                    dateWithin(user['createdAt'], const Duration(days: 1)),
              )
              .length,
          'week': users
              .where(
                (user) =>
                    dateWithin(user['createdAt'], const Duration(days: 7)),
              )
              .length,
          'month': users
              .where(
                (user) =>
                    dateWithin(user['createdAt'], const Duration(days: 30)),
              )
              .length,
        },
        'appOpeningsApprox': <String, dynamic>{
          'day': sessions.values
              .where(
                (session) =>
                    dateWithin(session['lastSeenAt'], const Duration(days: 1)),
              )
              .length,
          'week': sessions.values
              .where(
                (session) =>
                    dateWithin(session['lastSeenAt'], const Duration(days: 7)),
              )
              .length,
          'month': sessions.values
              .where(
                (session) =>
                    dateWithin(session['lastSeenAt'], const Duration(days: 30)),
              )
              .length,
        },
        'trips': <String, dynamic>{
          'startedDay': trips
              .where(
                (trip) =>
                    dateWithin(trip['startedAt'], const Duration(days: 1)),
              )
              .length,
          'startedWeek': trips
              .where(
                (trip) =>
                    dateWithin(trip['startedAt'], const Duration(days: 7)),
              )
              .length,
          'startedMonth': trips
              .where(
                (trip) =>
                    dateWithin(trip['startedAt'], const Duration(days: 30)),
              )
              .length,
          'active': activeTrips.length,
          'ended': completedTrips.length,
          'cancelledBySystem': systemStoppedTrips.length,
          'offRouteStops': trips
              .where((trip) => tripMessageContains(trip, 'hors trace'))
              .length,
          'connectionLossStops': trips
              .where((trip) => tripMessageContains(trip, 'ne communique plus'))
              .length,
          'averageDurationMinutes': average(completedDurations),
          'completedDistanceKm': totalCompletedDistanceKm,
          'averageDistanceKm': average(completedDistancesKm),
        },
        'reports': <String, dynamic>{
          'total': reports.length,
          'byStatus': countBy(reports, 'status'),
          'byLine': countBy(reports, 'lineCode'),
        },
        'notifications': <String, dynamic>{
          'registeredDevices': pushTokens.length,
          'activeDevices': pushTokens
              .where((token) => _text(token['status']) != 'disabled')
              .length,
          'byPlatform': countBy(pushTokens, 'platform'),
        },
        'networkApprox': <String, dynamic>{
          'backendRequests': metrics['requestsTotal'] ?? 0,
          'backendResponses': metrics['responsesTotal'] ?? 0,
          'errors4xx': metrics['responses4xx'] ?? 0,
          'errors5xx': metrics['responses5xx'] ?? 0,
          'mapTileTraffic':
              'gere par le fournisseur de tuiles, non mesure par le backend',
        },
        'ratings': <String, dynamic>{
          'ratedTrips': ratedTrips.length,
          'totalRatings': totalRatingCount,
          'average': totalRatingCount == 0
              ? 0
              : totalRatingScore / totalRatingCount,
          'lowRatedTrips': ratedTrips
              .where((trip) => _double(trip['ratingAverage']) < 3.5)
              .length,
        },
        'networkUsage': <String, dynamic>{
          'tripEstimateBytes': totalTripNetworkBytes,
          'activeTripEstimateBytes': activeTripNetworkBytes,
          'averageTripBytes': trips.isEmpty
              ? 0
              : totalTripNetworkBytes / trips.length,
        },
        'deviceVersions': <String, dynamic>{
          'byPlatform': countBy(pushTokens, 'platform'),
          'androidAbi': countBy(pushTokens, 'androidAbi'),
          'appVersions': countBy(pushTokens, 'appVersion'),
          'androidSdk': countBy(pushTokens, 'sdkInt'),
          'models': countBy(pushTokens, 'deviceModel'),
        },
      },
      'liveTrips': activeTrips.map(_adminTrip).toList(growable: false),
      'liveUsers': liveUsers.toList(growable: false),
      'trips': trips.map(_adminTrip).toList(growable: false),
      'users': users
          .map((user) {
            final public = _publicUser(user);
            final userId = _text(public['id']);
            return <String, dynamic>{
              ...public,
              'sessionCount': usersById[userId] ?? 0,
              'connected': sessions.values.any((session) {
                final current = session['currentUser'];
                return current is Map &&
                    _text(current['id']) == userId &&
                    seenWithin(session, const Duration(minutes: 6));
              }),
            };
          })
          .toList(growable: false),
      'reports': reports.map(_adminReport).toList(growable: false),
      'lineStats': lineStats.take(120).toList(growable: false),
      'catalog': <String, dynamic>{
        'lines': _adminCatalogLines(),
        'layers': const <JsonMap>[
          {
            'id': 'sotraStops',
            'name': 'Arrets SOTRA',
            'source': 'assets/abidjan_gtfs_stops.json',
            'scope': 'APK mobile',
          },
          {
            'id': 'localContextPlaces',
            'name': 'Reperes et zones importantes',
            'source': 'lib/src/map_context_layers.dart',
            'scope': 'APK mobile',
          },
          {
            'id': 'liveTrips',
            'name': 'Trajets live',
            'source': 'backend',
            'scope': 'temps reel',
          },
        ],
      },
      'events': activity.toList(growable: false),
    };
  }

  ({List<String> tokens, Set<String> sessionIds}) adminNotificationAudience({
    required String targetType,
    String targetId = '',
    String lineCode = '',
    double radiusMeters = 2000,
  }) {
    final normalizedType = _text(targetType).toLowerCase();
    final normalizedTargetId = _text(targetId);
    final normalizedLineCode = _normalizeCode(
      lineCode.isEmpty ? targetId : lineCode,
    );

    if (normalizedType == 'trip') {
      return notificationAudienceForTrip(normalizedTargetId);
    }
    if (normalizedType == 'line') {
      return notificationAudienceNearLine(
        normalizedLineCode,
        radiusMeters: radiusMeters,
      );
    }

    bool sessionMatchesTarget(MapEntry<String, JsonMap> entry) {
      if (normalizedType == 'session') {
        return entry.key == normalizedTargetId;
      }
      if (normalizedType == 'user') {
        final user = entry.value['currentUser'];
        return user is Map && _text(user['id']) == normalizedTargetId;
      }
      return true;
    }

    final targetSessionIds = _sessions().entries
        .where(sessionMatchesTarget)
        .map((entry) => entry.key)
        .where((id) => id.isNotEmpty)
        .toSet();

    final targetTokens = _mapList(_state['pushTokens'])
        .where((token) => _text(token['status']) != 'disabled')
        .where((token) {
          if (normalizedType == 'user') {
            return _text(token['userId']) == normalizedTargetId ||
                targetSessionIds.contains(_text(token['sessionId']));
          }
          if (normalizedType == 'session') {
            return _text(token['sessionId']) == normalizedTargetId;
          }
          return targetSessionIds.contains(_text(token['sessionId']));
        })
        .toList(growable: false);
    return (
      tokens: targetTokens
          .map((token) => _text(token['token']))
          .where((token) => token.isNotEmpty)
          .toSet()
          .toList(growable: false),
      sessionIds: targetTokens
          .map((token) => _text(token['sessionId']))
          .where((id) => id.isNotEmpty)
          .followedBy(targetSessionIds)
          .toSet(),
    );
  }

  Future<JsonMap> recordAdminNotification({
    required String sessionId,
    required String title,
    required String body,
    required String targetLabel,
    Iterable<String> audienceSessionIds = const <String>[],
  }) async {
    _requireAdmin(sessionId);
    addActivity(
      title: 'Notification admin',
      subtitle: '$targetLabel - $title - $body',
      iconKey: 'notification',
      colorValue: 0xFF0F8B8D,
      audienceSessionIds: audienceSessionIds,
    );
    _notifySharedChange();
    await _persist(const StateMutationBatch(activity: true));
    return adminDashboard(sessionId);
  }

  Future<JsonMap> signIn(String sessionId, JsonMap body) async {
    final now = _nowIso();
    final email = _boundedText(
      body['email'],
      _maxEmailLength,
      fieldName: 'Email',
    ).toLowerCase();
    final password = _boundedText(
      body['password'],
      _maxPasswordLength,
      fieldName: 'Mot de passe',
    );
    if (!_isValidEmail(email)) {
      throw StateError('Adresse email invalide.');
    }
    if (password.isEmpty) {
      throw StateError('Mot de passe requis.');
    }
    final users = _users();
    final hashed = _hashPassword(email, password);
    final index = users.indexWhere(
      (user) => _text(user['email']).toLowerCase() == email,
    );

    if (index < 0) {
      throw StateError(
        'Compte introuvable. Créez un compte avant de vous connecter.',
      );
    }

    final user = users[index];
    final existingHash = _text(user['passwordHash']);
    if (!_verifyPassword(email, password, existingHash)) {
      throw StateError('Mot de passe invalide pour cet utilisateur.');
    }
    if (_text(user['status']) == 'suspendu') {
      throw StateError('Ce compte est suspendu.');
    }
    user['passwordHash'] = hashed;
    user['lastSeenAt'] = now;

    _state['users'] = users;
    final session = _session(sessionId);
    session['currentUser'] = _publicUser(user);
    session['activeRole'] = _initialActiveRoleFor(user);
    final adoptedTrips = _adoptSessionStarTrips(sessionId, user);
    session['currentUser'] = _publicUser(_storedUserOr(user));
    _putSession(sessionId, session);
    // If there is already an active realtime connection for this session,
    // ensure the normalized session reflects the fresh lastSeenAt and
    // online status. Do not alter connection counts here.
    final currentCount = _sessionConnectionCounts[sessionId] ?? 0;
    if (currentCount > 0) {
      final sessions = _sessions();
      final rawSession = sessions[sessionId];
      if (rawSession != null) {
        final normalized = _normalizeSession(rawSession);
        normalized['lastSeenAt'] = _nowIso();
        normalized['isOnline'] = true;
        _putSession(sessionId, normalized);
      }
    }
    _notifySharedChange();
    await _persist(
      StateMutationBatch(users: true, sessions: true, trips: adoptedTrips),
    );
    return snapshot(sessionId);
  }

  Future<JsonMap> register(String sessionId, JsonMap body) async {
    final now = _nowIso();
    final fullName = _boundedText(
      body['fullName'],
      _maxNameLength,
      fieldName: 'Nom complet',
    );
    final email = _boundedText(
      body['email'],
      _maxEmailLength,
      fieldName: 'Email',
    ).toLowerCase();
    final password = _boundedText(
      body['password'],
      _maxPasswordLength,
      fieldName: 'Mot de passe',
    );
    final phone = _boundedText(
      body['phone'],
      _maxPhoneLength,
      fieldName: 'Telephone',
    );
    final profilePhotoDataUrl = _profilePhotoDataUrlFrom(
      body['profilePhotoDataUrl'] ?? body['profile_photo_data_url'],
    );
    if (fullName.isEmpty) {
      throw StateError('Nom complet requis.');
    }
    if (!_isValidEmail(email)) {
      throw StateError('Adresse email invalide.');
    }
    if (password.length < 8) {
      throw StateError('Mot de passe trop court (8 caractères minimum).');
    }

    final users = _users();
    final exists = users.any(
      (user) => _text(user['email']).toLowerCase() == email,
    );
    if (exists) {
      throw StateError('Un compte existe déjà  avec cette adresse email.');
    }

    if (_userNameExists(users, fullName)) {
      throw StateError("Ce nom d'utilisateur est deja pris.");
    }

    final user = _user(
      id: _newEntityId('u'),
      fullName: fullName,
      email: email,
      phone: phone,
      profilePhotoDataUrl: profilePhotoDataUrl,
      role: 'etoile',
      status: 'actif',
      passwordHash: _hashPassword(email, password),
      createdAt: now,
      lastSeenAt: now,
    );
    users.insert(0, user);
    _state['users'] = users;

    final session = _session(sessionId);
    session['currentUser'] = _publicUser(user);
    session['activeRole'] = _initialActiveRoleFor(user);
    final adoptedTrips = _adoptSessionStarTrips(sessionId, user);
    session['currentUser'] = _publicUser(_storedUserOr(user));
    _putSession(sessionId, session);
    // registration updates session info; presence is driven by active
    // realtime connections rather than auth POSTs.
    _notifySharedChange();
    await _persist(
      StateMutationBatch(users: true, sessions: true, trips: adoptedTrips),
    );
    return snapshot(sessionId);
  }

  Future<JsonMap> updateProfile(String sessionId, JsonMap body) async {
    final session = _session(sessionId);
    final currentUser = _currentUser(session);
    final currentUserId = _text(currentUser?['id']);
    if (currentUserId.isEmpty) {
      throw StateError('Connectez-vous pour modifier votre profil.');
    }

    final users = _users();
    final index = users.indexWhere(
      (user) => _text(user['id']) == currentUserId,
    );
    if (index < 0) {
      throw StateError('Compte introuvable.');
    }

    final user = users[index];
    final fullName = _boundedText(
      body['fullName'] ?? user['fullName'],
      _maxNameLength,
      fieldName: 'Nom complet',
    );
    if (fullName.isEmpty) {
      throw StateError('Nom complet requis.');
    }
    final nameChanged = !_userNameMatches(fullName, _text(user['fullName']));
    if (nameChanged) {
      if (_userNameExists(users, fullName, exceptId: currentUserId)) {
        throw StateError("Ce nom d'utilisateur est deja pris.");
      }
      final nextAllowedNameChangeAt = _nextAllowedProfileNameChangeAt(
        user['nameChangedAt'],
      );
      final now = DateTime.now().toUtc();
      if (nextAllowedNameChangeAt != null &&
          now.isBefore(nextAllowedNameChangeAt)) {
        throw StateError(
          "Vous ne pouvez changer votre nom d'utilisateur qu'une fois tous les "
          '3 mois. Prochain changement possible le '
          '${_profileNameChangeDateLabel(nextAllowedNameChangeAt)}.',
        );
      }
    }

    final hasPhotoInput =
        body.containsKey('profilePhotoDataUrl') ||
        body.containsKey('profile_photo_data_url');
    final photoInput = body.containsKey('profilePhotoDataUrl')
        ? body['profilePhotoDataUrl']
        : body['profile_photo_data_url'];
    final profilePhotoDataUrl = hasPhotoInput
        ? _profilePhotoDataUrlFrom(photoInput)
        : _nullableText(user['profilePhotoDataUrl']);
    user['fullName'] = fullName;
    if (nameChanged) {
      user['nameChangedAt'] = DateTime.now().toUtc().toIso8601String();
    }
    user['profilePhotoDataUrl'] = profilePhotoDataUrl;
    users[index] = user;
    _state['users'] = users;
    _refreshUserInSessions(user);
    final updatedSession = _session(sessionId);
    updatedSession['section'] = 'carte';
    _putSession(sessionId, updatedSession);
    final tripsChanged = _refreshUserOwnedTripProfiles(user);
    _notifySharedChange();
    await _persist(
      StateMutationBatch(users: true, sessions: true, trips: tripsChanged),
    );
    return snapshot(sessionId);
  }

  List<JsonMap> messagePeerCandidatesForLine(
    String sessionId, {
    required String lineCode,
    double radiusMeters = 200,
    Duration? freshness,
    int limit = _defaultMessagePeerCandidateLimit,
    bool includeProfilePhotoDataUrl = false,
  }) {
    final currentUserId = _authenticatedUserId(sessionId);
    final line = lineByCode(lineCode);
    if (line == null) {
      throw StateError('Ligne introuvable.');
    }
    final normalizedRadius = normalizePeerSearchRadiusMeters(radiusMeters);
    final lineSegments = _lineSegments(line);
    if (lineSegments.isEmpty) return const <JsonMap>[];
    final sessions = _sessions();
    final now = DateTime.now();
    final effectiveFreshness = freshness ?? _currentLocationFreshness;
    final normalizedLimit = limit
        .clamp(1, _maxMessagePeerCandidateLimit)
        .toInt();
    final usersById = <String, JsonMap>{
      for (final user in _users())
        if (_text(user['id']).isNotEmpty) _text(user['id']): user,
    };
    final seenUserIds = <String>{currentUserId};
    final items = <JsonMap>[];
    for (final entry in sessions.entries) {
      final nearbySession = entry.value;
      if (!isPeerPresenceFresh(
        lastSeenAt: nearbySession['lastSeenAt'],
        now: now,
        freshness: effectiveFreshness,
      )) {
        continue;
      }
      final locationCandidate = selectPeerSearchLocation(
        sessionLocation: nearbySession['currentLocation'],
        now: now,
        freshness: effectiveFreshness,
      );
      if (locationCandidate == null) continue;
      final lat = locationCandidate.lat;
      final lng = locationCandidate.lng;
      final distance = _isValidLatLng(lat, lng)
          ? _distanceMetersToSegments(lat, lng, lineSegments)
          : double.nan;
      if (!distance.isFinite || distance > normalizedRadius) continue;
      final currentUser = nearbySession['currentUser'];
      if (currentUser is! Map) continue;
      final userId = _text(currentUser['id']);
      if (userId.isEmpty || !seenUserIds.add(userId)) continue;
      final sessionUser = Map<String, dynamic>.from(currentUser);
      final storedUser = usersById[userId];
      final user = storedUser ?? sessionUser;
      final publicUser = _publicMessagingPeerUser(
        user,
        includeProfilePhotoDataUrl: includeProfilePhotoDataUrl,
      );
      final place = _isValidLatLng(lat, lng)
          ? _nearestPlaceLabel(lat, lng)
          : null;
      items.add(<String, dynamic>{
        'user': publicUser,
        'lineCode': _text(line['code']),
        'lineLabel': _displayCode(_text(line['code'])),
        'distanceMeters': distance.isFinite ? distance : 0,
        if (place != null) ...<String, dynamic>{
          'placeName': place.label.name,
          'placeSubtitle': place.label.subtitle,
          'placeDistanceMeters': place.distanceMeters,
        },
        'lastSeenAt': _text(nearbySession['lastSeenAt']),
      });
    }
    items.sort(
      (a, b) =>
          _double(a['distanceMeters']).compareTo(_double(b['distanceMeters'])),
    );
    return items.take(normalizedLimit).toList(growable: false);
  }

  ({_NearbyPlaceLabel label, double distanceMeters})? _nearestPlaceLabel(
    double lat,
    double lng,
  ) {
    if (_nearbyPlaceLabels.isEmpty) return null;
    const maxDistanceMeters = 1600.0;
    const roughDegreePadding = 0.018;
    _NearbyPlaceLabel? bestLabel;
    var bestDistance = double.infinity;
    for (final label in _nearbyPlaceLabels) {
      if ((label.lat - lat).abs() > roughDegreePadding ||
          (label.lng - lng).abs() > roughDegreePadding) {
        continue;
      }
      final distance = _distanceMeters(lat, lng, label.lat, label.lng);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestLabel = label;
      }
    }
    if (bestLabel == null || bestDistance > maxDistanceMeters) return null;
    return (label: bestLabel, distanceMeters: bestDistance);
  }

  List<JsonMap> messageConversationsForSession(String sessionId) {
    final currentUser = _currentUser(_session(sessionId));
    return _messageConversationsForSession(currentUser);
  }

  Future<JsonMap> startMessageConversation(
    String sessionId,
    JsonMap body,
  ) async {
    final currentUserId = _authenticatedUserId(sessionId);
    final requestedTripId = _clientIdOrEmpty(
      _text(body['tripId'] ?? body['trip_id']),
      fieldName: 'Identifiant trajet',
    );
    if (requestedTripId.isNotEmpty) {
      final trip = _activeTripById(requestedTripId);
      if (trip == null) {
        throw StateError('Trajet introuvable.');
      }
      final conversation = _ensureTripConversationForUser(currentUserId, trip);
      return <String, dynamic>{
        'conversation': _publicMessageConversation(
          conversation,
          currentUserId: currentUserId,
          usersById: _usersById(),
        ),
      };
    }
    final peerUserId = _text(body['peerUserId'] ?? body['peer_user_id']);
    if (peerUserId.isEmpty || peerUserId == currentUserId) {
      throw StateError('Destinataire invalide.');
    }
    final users = _users();
    users.firstWhere(
      (user) => _text(user['id']) == currentUserId,
      orElse: () => throw StateError('Utilisateur introuvable.'),
    );
    users.firstWhere(
      (user) => _text(user['id']) == peerUserId,
      orElse: () => throw StateError('Destinataire introuvable.'),
    );
    final participantIds = [currentUserId, peerUserId]..sort();
    final conversations = _messageConversations();
    final existing = conversations.firstWhere(
      (conversation) =>
          _text(conversation['kind']) == 'direct' &&
          _stringList(
            conversation['participantIds'],
          ).toSet().containsAll(participantIds) &&
          _stringList(conversation['participantIds']).length ==
              participantIds.length,
      orElse: () => <String, dynamic>{},
    );
    JsonMap conversation = existing;
    if (conversation.isEmpty) {
      final now = _nowIso();
      conversation = <String, dynamic>{
        'id': _newEntityId('msgc'),
        'kind': 'direct',
        'participantIds': participantIds,
        'title': '',
        'subtitle': '',
        'lastMessagePreview': '',
        'lastMessageId': null,
        'lastSenderId': null,
        'messageCursor': 0,
        'readSequences': <String, int>{
          for (final participantId in participantIds) participantId: 0,
        },
        'createdAt': now,
        'updatedAt': now,
        'messages': <JsonMap>[],
      };
      conversations.insert(0, conversation);
      _state['messageConversations'] = conversations;
      _notifySharedChange();
      await _persist(const StateMutationBatch(messageConversations: true));
    }
    final usersById = _usersById();
    return <String, dynamic>{
      'conversation': _publicMessageConversation(
        conversation,
        currentUserId: currentUserId,
        usersById: usersById,
      ),
    };
  }

  JsonMap _ensureTripConversationForUser(String currentUserId, JsonMap trip) {
    final tripId = _text(trip['id']);
    if (currentUserId.trim().isEmpty || tripId.isEmpty) {
      throw StateError('Conversation trajet invalide.');
    }
    final conversations = _messageConversations();
    final existingIndex = conversations.indexWhere(
      (conversation) =>
          _text(conversation['kind']) == 'trip' &&
          _text(conversation['tripId']) == tripId,
    );
    final lineCode = _text(trip['line_code']);
    final title = _text(trip['title']).isNotEmpty
        ? _text(trip['title'])
        : 'Chat du trajet ${_displayCode(lineCode)}';
    final subtitle =
        '${_text(trip['originLabel']).isEmpty ? 'Départ' : _text(trip['originLabel'])} → ${_text(trip['destinationLabel']).isEmpty ? 'Arrivée' : _text(trip['destinationLabel'])}';
    final now = _nowIso();
    if (existingIndex >= 0) {
      final conversation = conversations[existingIndex];
      final participantIds = _stringList(
        conversation['participantIds'],
      ).toSet();
      participantIds.add(currentUserId);
      final ownerUserId = _tripConversationOwnerUserId(trip);
      if (ownerUserId.isNotEmpty) participantIds.add(ownerUserId);
      for (final entry in _sessions().entries) {
        final userId = _text(entry.value['currentUser']?['id']);
        if (userId.isEmpty) continue;
        if (_text(entry.value['selectedTripId']) == tripId) {
          participantIds.add(userId);
        }
      }
      final normalizedParticipantIds = participantIds.toList(growable: false)
        ..sort();
      final readSequences = _sequenceMap(conversation['readSequences']);
      for (final participantId in normalizedParticipantIds) {
        readSequences.putIfAbsent(
          participantId,
          () => _int(conversation['messageCursor']),
        );
      }
      conversation['participantIds'] = normalizedParticipantIds;
      conversation['title'] = title;
      conversation['subtitle'] = subtitle;
      conversation['tripId'] = tripId;
      conversation['readSequences'] = readSequences;
      conversation['updatedAt'] = now;
      conversations[existingIndex] = conversation;
      _state['messageConversations'] = conversations;
      return conversation;
    }

    final participantIds = <String>{currentUserId};
    final ownerUserId = _tripConversationOwnerUserId(trip);
    if (ownerUserId.isNotEmpty) participantIds.add(ownerUserId);
    for (final entry in _sessions().entries) {
      final userId = _text(entry.value['currentUser']?['id']);
      if (userId.isEmpty) continue;
      if (_text(entry.value['selectedTripId']) == tripId) {
        participantIds.add(userId);
      }
    }
    final normalizedParticipantIds = participantIds.toList(growable: false)
      ..sort();
    final conversation = <String, dynamic>{
      'id': _newEntityId('msgc'),
      'kind': 'trip',
      'participantIds': normalizedParticipantIds,
      'tripId': tripId,
      'title': title,
      'subtitle': subtitle,
      'lastMessagePreview': '',
      'lastMessageId': null,
      'lastSenderId': null,
      'messageCursor': 0,
      'readSequences': <String, int>{
        for (final participantId in normalizedParticipantIds) participantId: 0,
      },
      'createdAt': now,
      'updatedAt': now,
      'messages': <JsonMap>[],
    };
    conversations.insert(0, conversation);
    _state['messageConversations'] = conversations;
    return conversation;
  }

  String _tripConversationOwnerUserId(JsonMap trip) {
    final ownerId = _text(trip['owner_id']);
    if (ownerId.isEmpty || ownerId.startsWith('session-')) return '';
    return ownerId;
  }

  List<JsonMap> conversationMessages(
    String sessionId,
    String conversationId, {
    int afterSequence = 0,
    int beforeSequence = 0,
    int limit = _defaultMessagePageLimit,
  }) {
    final currentUserId = _authenticatedUserId(sessionId);
    final conversation = _messageConversationForParticipant(
      conversationId,
      currentUserId,
    );
    if (conversation == null) return const <JsonMap>[];
    final normalizedLimit = limit.clamp(1, _maxMessagePageLimit).toInt();
    final messages = _mapList(conversation['messages'])
      ..sort((a, b) {
        final sequenceOrder = _int(
          a['sequence'],
        ).compareTo(_int(b['sequence']));
        if (sequenceOrder != 0) return sequenceOrder;
        return _text(a['createdAt']).compareTo(_text(b['createdAt']));
      });
    Iterable<JsonMap> filtered = messages;
    if (afterSequence > 0) {
      filtered = filtered.where(
        (message) => _int(message['sequence']) > afterSequence,
      );
    } else if (beforeSequence > 0) {
      filtered = filtered.where(
        (message) => _int(message['sequence']) < beforeSequence,
      );
    }
    var result = filtered.toList(growable: false);
    if (beforeSequence > 0 && result.length > normalizedLimit) {
      result = result.sublist(result.length - normalizedLimit);
    } else if (result.length > normalizedLimit) {
      result = result.take(normalizedLimit).toList(growable: false);
    }
    return result.map(_publicMessageItem).toList(growable: false);
  }

  Future<JsonMap> sendMessageItem(
    String sessionId,
    String conversationId,
    JsonMap body,
  ) async {
    final currentUserId = _authenticatedUserId(sessionId);
    final conversations = _messageConversations();
    final index = conversations.indexWhere(
      (conversation) => _text(conversation['id']) == conversationId,
    );
    if (index < 0) throw StateError('Conversation introuvable.');
    final conversation = conversations[index];
    final participantIds = _stringList(conversation['participantIds']);
    if (!participantIds.contains(currentUserId)) {
      throw StateError('Acces refuse pour cette conversation.');
    }
    final text = _boundedText(
      body['body'] ?? body['text'] ?? body['message'],
      _maxMessageLength,
      fieldName: 'Message',
    );
    if (text.trim().isEmpty) throw StateError('Le message est vide.');
    final user = _currentUser(_session(sessionId));
    final requestedMessageId = _clientIdOrEmpty(
      body['messageId'] ?? body['message_id'],
      fieldName: 'Identifiant message',
    );
    final effectiveMessageId = requestedMessageId.isEmpty
        ? _newEntityId('msg')
        : requestedMessageId;
    final createdAt = _clientTimestampOrNow(
      _text(body['createdAt'] ?? body['created_at']),
      fieldName: 'Date du message',
    );
    final messages = List<JsonMap>.from(
      conversation['messages'] as List? ?? const [],
    );
    final duplicate = messages.firstWhere(
      (message) => _text(message['id']) == effectiveMessageId,
      orElse: () => <String, dynamic>{},
    );
    if (duplicate.isNotEmpty) {
      return <String, dynamic>{
        'message': _publicMessageItem(duplicate),
        'conversation': _publicMessageConversation(
          conversation,
          currentUserId: currentUserId,
          usersById: _usersById(),
        ),
        'recipientUserIds': participantIds
            .where((participantId) => participantId != currentUserId)
            .toList(growable: false),
      };
    }
    final nextSequence =
        math.max(
          _int(conversation['messageCursor']),
          messages.fold<int>(
            0,
            (max, message) => math.max(max, _int(message['sequence'])),
          ),
        ) +
        1;
    final message = <String, dynamic>{
      'id': effectiveMessageId,
      'conversationId': conversationId,
      'senderId': currentUserId,
      'senderName': _text(user?['fullName']).isEmpty
          ? 'Utilisateur Piwibus'
          : _text(user?['fullName']),
      'body': text.trim(),
      'sequence': nextSequence,
      'createdAt': createdAt,
    };
    messages.add(message);
    final readSequences = _sequenceMap(conversation['readSequences']);
    readSequences[currentUserId] = nextSequence;
    conversation['messages'] = messages;
    conversation['messageCursor'] = nextSequence;
    conversation['readSequences'] = readSequences;
    conversation['lastMessagePreview'] = _messagePreview(text);
    conversation['lastMessageId'] = effectiveMessageId;
    conversation['lastSenderId'] = currentUserId;
    conversation['updatedAt'] = createdAt;
    conversations[index] = conversation;
    _state['messageConversations'] = conversations;
    _notifySharedChange();
    await _persist(const StateMutationBatch(messageConversations: true));
    return <String, dynamic>{
      'message': _publicMessageItem(message),
      'conversation': _publicMessageConversation(
        conversation,
        currentUserId: currentUserId,
        usersById: _usersById(),
      ),
      'recipientUserIds': participantIds
          .where((participantId) => participantId != currentUserId)
          .toList(growable: false),
    };
  }

  Future<JsonMap> markMessageConversationRead(
    String sessionId,
    String conversationId,
    JsonMap body,
  ) async {
    final currentUserId = _authenticatedUserId(sessionId);
    final conversations = _messageConversations();
    final index = conversations.indexWhere(
      (conversation) => _text(conversation['id']) == conversationId,
    );
    if (index < 0) {
      return <String, dynamic>{'conversationId': conversationId, 'ok': true};
    }
    final conversation = conversations[index];
    if (!_stringList(conversation['participantIds']).contains(currentUserId)) {
      throw StateError('Acces refuse pour cette conversation.');
    }
    final requestedThroughSequence = _int(
      body['throughSequence'] ?? body['through_sequence'],
    );
    final throughSequence = requestedThroughSequence > 0
        ? requestedThroughSequence
        : _int(conversation['messageCursor']);
    final readSequences = _sequenceMap(conversation['readSequences']);
    final currentReadSequence = readSequences[currentUserId] ?? 0;
    if (throughSequence <= currentReadSequence) {
      return <String, dynamic>{'conversationId': conversationId, 'ok': true};
    }
    readSequences[currentUserId] = throughSequence;
    conversation['readSequences'] = readSequences;
    conversations[index] = conversation;
    _state['messageConversations'] = conversations;
    _notifySharedChange();
    await _persist(const StateMutationBatch(messageConversations: true));
    return <String, dynamic>{'conversationId': conversationId, 'ok': true};
  }

  Future<JsonMap> requestPasswordReset(
    JsonMap body, {
    bool includeResetCode = false,
    PasswordResetCodeSender? sendCode,
  }) async {
    final email = _boundedText(
      body['email'],
      _maxEmailLength,
      fieldName: 'Email',
    ).toLowerCase();
    if (!_isValidEmail(email)) {
      throw StateError('Adresse email invalide.');
    }

    final users = _users();
    final index = users.indexWhere(
      (user) => _text(user['email']).toLowerCase() == email,
    );
    final generic = <String, dynamic>{
      'email': email,
      'message':
          'Si un compte Piwibus existe avec cet email, un code de reinitialisation a ete genere.',
    };
    if (index < 0) return generic;

    final user = users[index];
    if (_text(user['status']) == 'suspendu') {
      return generic;
    }
    final code = _newPasswordResetCode();
    final now = DateTime.now().toUtc();
    final expiresAtDate = now.add(_passwordResetCodeLifetime);
    final expiresAt = expiresAtDate.toIso8601String();
    user['passwordResetHash'] = _hashPassword(email, code);
    user['passwordResetRequestedAt'] = now.toIso8601String();
    user['passwordResetExpiresAt'] = expiresAt;
    user['passwordResetAttempts'] = 0;
    _state['users'] = users;
    await _persist(const StateMutationBatch(users: true));
    try {
      if (sendCode != null) {
        await sendCode(email: email, code: code, expiresAt: expiresAtDate);
      } else if (!includeResetCode) {
        throw StateError('Service email de reinitialisation non configure.');
      }
    } catch (_) {
      _clearPasswordReset(user);
      _state['users'] = users;
      await _persist(const StateMutationBatch(users: true));
      rethrow;
    }
    addActivity(
      title: 'Code mot de passe',
      subtitle: 'Un code de reinitialisation a ete envoye a $email.',
      iconKey: 'auth',
      colorValue: 0xFF0F8B8D,
      audienceSessionIds: _sessionIdsForUser(user),
    );
    _notifySharedChange();
    await _persist(const StateMutationBatch(activity: true));
    return <String, dynamic>{
      ...generic,
      'expiresAt': expiresAt,
      if (includeResetCode) 'resetCode': code,
    };
  }

  Future<JsonMap> confirmPasswordReset(String sessionId, JsonMap body) async {
    final email = _boundedText(
      body['email'],
      _maxEmailLength,
      fieldName: 'Email',
    ).toLowerCase();
    final code = _text(body['code']).replaceAll(RegExp(r'\s+'), '');
    final password = _boundedText(
      body['password'],
      _maxPasswordLength,
      fieldName: 'Mot de passe',
    );
    if (!_isValidEmail(email)) {
      throw StateError('Adresse email invalide.');
    }
    if (code.length != 6 || int.tryParse(code) == null) {
      throw StateError('Code de reinitialisation invalide.');
    }
    if (password.length < 8) {
      throw StateError('Mot de passe trop court (8 caracteres minimum).');
    }

    final users = _users();
    final index = users.indexWhere(
      (user) => _text(user['email']).toLowerCase() == email,
    );
    if (index < 0) {
      throw StateError('Code de reinitialisation invalide ou expire.');
    }
    final user = users[index];
    final expiresAt = DateTime.tryParse(_text(user['passwordResetExpiresAt']));
    final attempts = _int(user['passwordResetAttempts']);
    final resetHash = _text(user['passwordResetHash']);
    if (resetHash.isEmpty ||
        expiresAt == null ||
        DateTime.now().toUtc().isAfter(expiresAt.toUtc()) ||
        attempts >= _passwordResetMaxAttempts) {
      _clearPasswordReset(user);
      _state['users'] = users;
      await _persist(const StateMutationBatch(users: true));
      throw StateError('Code de reinitialisation invalide ou expire.');
    }
    if (!_verifyPassword(email, code, resetHash)) {
      user['passwordResetAttempts'] = attempts + 1;
      _state['users'] = users;
      await _persist(const StateMutationBatch(users: true));
      throw StateError('Code de reinitialisation invalide ou expire.');
    }
    if (_text(user['status']) == 'suspendu') {
      throw StateError('Ce compte est suspendu.');
    }

    final now = _nowIso();
    user['passwordHash'] = _hashPassword(email, password);
    user['lastSeenAt'] = now;
    _clearPasswordReset(user);
    _state['users'] = users;

    final session = _session(sessionId);
    session['currentUser'] = _publicUser(user);
    session['activeRole'] = _initialActiveRoleFor(user);
    session['section'] = 'carte';
    _putSession(sessionId, session);
    addActivity(
      title: 'Mot de passe reinitialise',
      subtitle: 'Le compte $email peut se reconnecter.',
      iconKey: 'auth',
      colorValue: 0xFF0F8B8D,
      audienceSessionIds: _sessionIdsForUser(user)..add(sessionId),
    );
    _notifySharedChange();
    await _persist(
      const StateMutationBatch(users: true, sessions: true, activity: true),
    );
    return snapshot(sessionId);
  }

  Future<JsonMap> logout(String sessionId) async {
    final session = _session(sessionId);
    final stoppedOwnedTripNotices = _stopActiveTripsOwnedBySession(
      sessionId,
      session,
      notificationType: 'trip_stopped_logout',
      reason:
          "Trajet live arrêté automatiquement : l\'Etoile s'est déconnectée.",
    );
    session['currentUser'] = null;
    session['activeRole'] = 'etoile';
    session['section'] = 'accueil';
    session['selectedTripId'] = null;
    session['selectedLineCode'] = null;
    final rotatedSessionId = _rotateSessionId(
      sessionId,
      session,
      clearCurrentUser: true,
    );
    if (stoppedOwnedTripNotices.isNotEmpty) {
      _notifySharedChange();
    }
    await _persist(
      StateMutationBatch(
        sessions: true,
        trips: stoppedOwnedTripNotices.isNotEmpty,
        activity: stoppedOwnedTripNotices.isNotEmpty,
      ),
    );
    return _snapshotWithSystemTripCancellationNotices(
      rotatedSessionId,
      stoppedOwnedTripNotices,
    );
  }

  Future<JsonMap> switchRole(String sessionId, String role) async {
    final session = _session(sessionId);
    final nextRole = _normalizeRole(role);
    if (nextRole == 'administrateur' && !_sessionUserCanAdmin(session)) {
      throw StateError('Accès administrateur requis.');
    }
    session['activeRole'] = nextRole;
    _putSession(sessionId, session);
    await _persist(const StateMutationBatch(sessions: true));
    return snapshot(sessionId);
  }

  Future<JsonMap> updateSessionLocation(
    String sessionId,
    JsonMap body, {
    bool includeSnapshot = true,
  }) async {
    final location = body['location'] ?? body;
    if (location is! Map) {
      throw StateError('La position courante est invalide.');
    }
    final parsed = _parseLatLngOrThrow(location);
    final session = _session(sessionId);
    final nextLocation = <String, dynamic>{
      'lat': parsed['lat'],
      'lng': parsed['lng'],
      'accuracy': _double(location['accuracy']),
      'timestamp': _normalizedCurrentLocationTimestamp(location['timestamp']),
    };
    final now = _nowIso();
    final shouldPersist = shouldPersistNearbyLocationUpdate(
      previousLocation: session['currentLocation'],
      nextLocation: nextLocation,
      now: DateTime.now(),
    );
    session['currentLocation'] = nextLocation;
    session['lastSeenAt'] = now;

    final currentUser = _currentUser(session);
    if (currentUser != null) {
      final currentUserId = _text(currentUser['id']);
      if (currentUserId.isNotEmpty) {
        final users = _users();
        final userIndex = users.indexWhere(
          (user) => _text(user['id']) == currentUserId,
        );
        if (userIndex >= 0) {
          final user = Map<String, dynamic>.from(users[userIndex]);
          user['lastSeenAt'] = now;
          users[userIndex] = user;
          _state['users'] = users;
          _refreshUserInSessions(user);
          session['currentUser'] = _publicUser(user);
        }
      }
    }

    _putSession(sessionId, session);
    if (shouldPersist) {
      await _persist(const StateMutationBatch(sessions: true, users: true));
      // Ne notifier les abonnés temps réel / la révision partagée que pour les
      // mises à jour de position jugées significatives (voir
      // shouldPersistNearbyLocationUpdate). Cela évite qu'un simple bruit GPS
      // ambiant, envoyé par chaque utilisateur en continu, ne casse le
      // raccourci "rien n'a changé" du polling /snapshot et ne déclenche un
      // recalcul + renvoi de delta temps réel à tous les clients connectés.
      _notifySharedChange();
    }
    return includeSnapshot
        ? snapshot(sessionId)
        : <String, dynamic>{'sessionId': sessionId};
  }

  Future<JsonMap> setSection(String sessionId, String section) async {
    final sessionState = _session(sessionId);
    final nextSection = _normalizeSection(section);
    if (nextSection == 'administration' &&
        !_sessionUserCanAdmin(sessionState)) {
      sessionState['section'] = 'accueil';
    } else {
      sessionState['section'] = nextSection;
    }
    _putSession(sessionId, sessionState);
    await _persist(const StateMutationBatch(sessions: true));
    return snapshot(sessionId);
  }

  Future<JsonMap> setSearchQuery(String sessionId, String query) async {
    final session = _session(sessionId);
    session['searchQuery'] = _boundedText(
      query,
      _maxSearchQueryLength,
      fieldName: 'Recherche',
    );
    _putSession(sessionId, session);
    await _persist(const StateMutationBatch(sessions: true));
    return snapshot(sessionId);
  }

  Future<JsonMap> selectLine(String sessionId, String lineCode) async {
    final session = _session(sessionId);
    final requestedLineCode = _boundedText(
      lineCode,
      _maxLineCodeLength,
      fieldName: 'Ligne',
    );
    if (requestedLineCode.trim().isEmpty) {
      session['selectedLineCode'] = null;
      session['selectedTripId'] = null;
      _putSession(sessionId, session);
      await _persist(const StateMutationBatch(sessions: true));
    } else if (lineByCode(requestedLineCode) != null) {
      session['selectedLineCode'] = _normalizeCode(requestedLineCode);
      _putSession(sessionId, session);
      await _persist(const StateMutationBatch(sessions: true));
    }
    return snapshot(sessionId);
  }

  Future<JsonMap> selectTrip(String sessionId, String tripId) async {
    final session = _session(sessionId);
    final normalizedTripId = _clientIdOrEmpty(
      tripId,
      fieldName: 'Identifiant trajet',
    );
    if (normalizedTripId.isEmpty) {
      session['selectedTripId'] = null;
    } else {
      final trip = _activeTripById(normalizedTripId);
      session['selectedTripId'] = trip == null ? null : normalizedTripId;
      if (trip != null) {
        session['selectedLineCode'] = _text(trip['line_code']);
      }
    }
    final selectedTrip = session['selectedTripId'] == null
        ? null
        : _activeTripById(_text(session['selectedTripId']));
    final followedTripChanged = selectedTrip == null
        ? false
        : _rememberFollowedTripForUser(sessionId, session, selectedTrip);
    final currentUserId = _text(_currentUser(session)?['id']);
    var tripConversationChanged = false;
    if (selectedTrip != null && currentUserId.isNotEmpty) {
      _ensureTripConversationForUser(currentUserId, selectedTrip);
      tripConversationChanged = true;
    }
    _putSession(sessionId, session);
    await _persist(
      StateMutationBatch(
        sessions: true,
        users: followedTripChanged,
        messageConversations: tripConversationChanged,
      ),
    );
    return snapshot(sessionId);
  }

  Future<JsonMap> toggleFavorite(String sessionId, String lineCode) async {
    final session = _session(sessionId);
    final code = _normalizeCode(
      _boundedText(lineCode, _maxLineCodeLength, fieldName: 'Ligne'),
    );
    final favorites = _favoriteCodes(session);
    if (favorites.contains(code)) {
      favorites.removeWhere((value) => _normalizeCode(value) == code);
    } else {
      favorites.add(code);
    }
    session['favoriteLineCodes'] = favorites.toList();
    _putSession(sessionId, session);
    await _persist(const StateMutationBatch(sessions: true));
    return snapshot(sessionId);
  }

  JsonMap? _activeTripById(String tripId) {
    final normalizedTripId = _text(tripId);
    if (normalizedTripId.isEmpty) return null;
    for (final trip in _trips()) {
      if (_text(trip['id']) == normalizedTripId &&
          _text(trip['status']) == 'actif') {
        return trip;
      }
    }
    return null;
  }

  bool _rememberFollowedTripForUser(
    String sessionId,
    JsonMap session,
    JsonMap trip,
  ) {
    final tripId = _text(trip['id']);
    if (tripId.isEmpty) return false;
    final ownerSessionId = _text(trip['owner_session_id']);
    if (ownerSessionId == 'session-$sessionId') return false;
    if (_sessionOwnsOwnerId(sessionId, session, _text(trip['owner_id']))) {
      return false;
    }
    final currentUser = _currentUser(session);
    final currentUserId = _text(currentUser?['id']);
    if (currentUserId.isEmpty) return false;
    final users = _users();
    final index = users.indexWhere(
      (user) => _text(user['id']) == currentUserId,
    );
    if (index < 0) return false;
    final followedTripIds = _stringList(users[index]['followedTripIds']);
    if (followedTripIds.contains(tripId)) return false;
    followedTripIds.add(tripId);
    users[index] = {...users[index], 'followedTripIds': followedTripIds};
    _state['users'] = users;
    _refreshUserInSessions(users[index]);
    return true;
  }

  bool _isStarHistoryTrip(JsonMap trip) {
    final role = _text(trip['owner_role'] ?? trip['ownerRole']);
    return role == 'etoile' || role == 'administrateur';
  }

  bool _rememberStarTripForUserId(String userId, String tripId) {
    final normalizedUserId = _text(userId);
    final normalizedTripId = _text(tripId);
    if (normalizedUserId.isEmpty || normalizedTripId.isEmpty) return false;
    final users = _users();
    final index = users.indexWhere(
      (user) => _text(user['id']) == normalizedUserId,
    );
    if (index < 0) return false;
    final starTripIds = _stringList(users[index]['starTripIds']);
    if (starTripIds.contains(normalizedTripId)) return false;
    starTripIds.add(normalizedTripId);
    users[index] = {...users[index], 'starTripIds': starTripIds};
    _state['users'] = users;
    _refreshUserInSessions(users[index]);
    return true;
  }

  bool _rememberStarTripForOwner(JsonMap trip) {
    if (!_isStarHistoryTrip(trip)) return false;
    return _rememberStarTripForUserId(
      _text(trip['owner_id']),
      _text(trip['id']),
    );
  }

  bool _rememberStarTripForSessionOwner(
    String sessionId,
    JsonMap session,
    JsonMap trip,
  ) {
    if (!_isStarHistoryTrip(trip)) return false;
    final sessionOwnerId = 'session-$sessionId';
    final ownerSessionId = _text(trip['owner_session_id']);
    if (ownerSessionId != sessionOwnerId &&
        !_sessionOwnsOwnerId(sessionId, session, _text(trip['owner_id']))) {
      return false;
    }
    return _rememberStarTripForUserId(
      _text(_currentUser(session)?['id']),
      _text(trip['id']),
    );
  }

  Future<JsonMap> registerPushToken(String sessionId, JsonMap body) async {
    final session = _session(sessionId);
    final token = _boundedText(
      body['token'],
      _maxPushTokenLength,
      fieldName: 'Token push',
    );
    final platformInput = _boundedText(
      body['platform'],
      32,
      fieldName: 'Plateforme',
    );
    final platform = platformInput.isEmpty ? 'unknown' : platformInput;
    final appVersion = _boundedText(
      body['appVersion'],
      64,
      fieldName: 'Version application',
    );
    final buildNumber = _boundedText(
      body['buildNumber'],
      32,
      fieldName: 'Build application',
    );
    final androidAbi = _boundedText(
      body['androidAbi'],
      64,
      fieldName: 'ABI Android',
    );
    final sdkInt = _int(body['sdkInt']);
    final is64BitProcess = body['is64BitProcess'] == true;
    final deviceModel = _boundedText(
      body['deviceModel'],
      _maxDeviceMetadataLength,
      fieldName: 'Modele appareil',
    );
    if (token.length < 20) {
      throw StateError('Token push invalide.');
    }
    final now = _nowIso();
    final currentUser = _currentUser(session);
    final pushTokens = _mapList(_state['pushTokens']);
    final existingIndex = pushTokens.indexWhere(
      (candidate) => _text(candidate['token']) == token,
    );
    final entry = <String, dynamic>{
      'id': existingIndex >= 0
          ? _text(pushTokens[existingIndex]['id'])
          : _newEntityId('push'),
      'token': token,
      'platform': platform,
      'sessionId': sessionId,
      'userId': _text(currentUser?['id']),
      'status': 'active',
      'appVersion': appVersion,
      'buildNumber': buildNumber,
      'androidAbi': androidAbi,
      'sdkInt': sdkInt,
      'is64BitProcess': is64BitProcess,
      'deviceModel': deviceModel,
      'createdAt': existingIndex >= 0
          ? _text(pushTokens[existingIndex]['createdAt'])
          : now,
      'lastSeenAt': now,
    };
    if (existingIndex >= 0) {
      pushTokens[existingIndex] = entry;
    } else {
      pushTokens.insert(0, entry);
    }
    _state['pushTokens'] = pushTokens.take(20000).toList(growable: false);
    await _persist(const StateMutationBatch(pushTokens: true));
    return snapshot(sessionId);
  }

  Future<JsonMap> startTrip(String sessionId, JsonMap body) async {
    final session = _session(sessionId);
    final lineCode = _normalizeCode(
      _boundedText(body['lineCode'], _maxLineCodeLength, fieldName: 'Ligne'),
    );
    final line = lineByCode(lineCode);
    if (line == null) {
      throw StateError('Ligne introuvable.');
    }
    final now = _nowIso();
    final routeTitle = _routeTitle(line);
    final split = _routeSplit(routeTitle);
    final owner = _currentUser(session);
    final ownerId = _text(owner?['id']).isEmpty
        ? 'session-$sessionId'
        : _text(owner?['id']);
    final requestedTripId = _clientIdOrEmpty(
      body['tripId'],
      fieldName: 'Identifiant trajet',
    );
    final tripId = requestedTripId.isEmpty
        ? _newEntityId('trip-$lineCode')
        : requestedTripId;
    final startedAt = _clientTimestampOrNow(
      body['startedAt'],
      fieldName: 'Date de debut',
    );
    final trips = _trips();
    final existingTrip = trips
        .where((trip) => _text(trip['id']) == tripId)
        .firstOrNull;
    if (existingTrip != null) {
      if (!_canManageTrip(sessionId, session, existingTrip)) {
        throw StateError('Accès refusé pour ce trajet.');
      }
      if (_text(existingTrip['status']) == 'actif') {
        session['selectedTripId'] = tripId;
        session['selectedLineCode'] = _text(existingTrip['line_code']);
      } else if (_text(session['selectedTripId']) == tripId) {
        session['selectedTripId'] = null;
      }
      _putSession(sessionId, session);
      await _persist(const StateMutationBatch(sessions: true));
      return snapshot(sessionId);
    }
    final liveLocationInput =
        body['liveLocation'] ?? body['live_location'] ?? body['location'];
    if (liveLocationInput == null) {
      throw StateError('Une position GPS initiale est requise.');
    }
    final liveLocation = _parseLiveLocationOrThrow(liveLocationInput);
    _validateLiveLocationOnRouteOrThrow(line, liveLocation);
    final lastUpdatedAt = now;
    final stoppedOwnedTripNotices = <JsonMap>[];
    final starTripIdsToRemember = <String>{};
    for (final trip in trips) {
      if (_text(trip['status']) != 'actif') continue;
      if (_text(trip['owner_id']) != ownerId) continue;
      final stoppedTripId = _text(trip['id']);
      starTripIdsToRemember.add(stoppedTripId);
      final reason =
          "Trajet live arrete automatiquement : l\'Etoile a demarre un nouveau trajet.";
      final notice = _systemTripCancellationNotice(
        trip,
        reason: reason,
        notificationType: 'trip_stopped_replaced',
      );
      _markTripStoppedBySystem(
        trip,
        tripId: stoppedTripId,
        reason: reason,
        stoppedAt: now,
      );
      stoppedOwnedTripNotices.add(notice);
    }
    trips.removeWhere((trip) => _text(trip['id']) == tripId);

    final sameLineActiveCount = trips
        .where(
          (trip) =>
              _normalizeCode(trip['line_code']) == lineCode &&
              _text(trip['status']) == 'actif',
        )
        .length;
    final fallbackProgress = _initialProgressForLineLive(sameLineActiveCount);
    final progress = body['progress'] == null
        ? fallbackProgress
        : _double(body['progress']).clamp(0.0, 1.0);
    final speedMetersPerSecond = _double(liveLocation['speed']);
    final note = _boundedText(body['note'], _maxNoteLength, fieldName: 'Note');
    final trip = <String, dynamic>{
      'id': tripId,
      'line_code': lineCode,
      'owner_id': ownerId,
      'owner_session_id': 'session-$sessionId',
      'owner_name': owner?['fullName'] ?? 'Conducteur live',
      'owner_photo_data_url': owner?['profilePhotoDataUrl'],
      'owner_role': _text(session['activeRole']),
      'status': 'actif',
      'startedAt': startedAt,
      'lastUpdatedAt': lastUpdatedAt,
      'progress': progress,
      'traveledDistanceMeters':
          _nonNegativeDoubleOrNull(
            body['traveledDistanceMeters'] ??
                body['traveled_distance_meters'] ??
                body['distanceMeters'] ??
                body['distance_meters'],
          ) ??
          0.0,
      'speedKmh': speedMetersPerSecond > 0 ? speedMetersPerSecond * 3.6 : 0,
      'observers': 0,
      'maxObservers': 0,
      'networkUsageBytes': _estimatedTripNetworkBytes(
        body,
        responseKind: _TripNetworkResponseKind.snapshot,
      ),
      'ratingAverage': 0,
      'ratingCount': 0,
      'likedByActorIds': <String>[],
      'note': note.isEmpty
          ? 'Trajet partagé en direct depuis le terrain.'
          : note,
      'liveLocation': liveLocation,
      'offRouteSince': null,
      'offRouteDistanceMeters': null,
      'path': const <JsonMap>[],
      'originLabel': split.$1.isEmpty ? 'Départ' : split.$1,
      'destinationLabel': split.$2.isEmpty ? 'Arrivée' : split.$2,
      'messages': <JsonMap>[
        _message(
          id: 'sys-$tripId',
          tripId: tripId,
          authorName: 'Système',
          role: 'administrateur',
          content:
              'Nouveau trajet live pour la ligne ${_displayCode(lineCode)}.',
          createdAt: now,
          isSystem: true,
        ),
      ],
    };
    final messages = List<JsonMap>.from(trip['messages'] as List);
    trip['messages'] = messages;
    trips.insert(0, trip);
    _state['trips'] = trips;
    session['selectedTripId'] = tripId;
    session['selectedLineCode'] = lineCode;
    session['currentLocation'] = <String, dynamic>{
      'lat': _double(liveLocation['lat']),
      'lng': _double(liveLocation['lng']),
      'accuracy': liveLocation['accuracy'],
      'timestamp': _text(liveLocation['timestamp']),
    };
    _putSession(sessionId, session);
    starTripIdsToRemember.add(tripId);
    var starHistoryChanged = false;
    for (final starTripId in starTripIdsToRemember) {
      starHistoryChanged =
          _rememberStarTripForUserId(_text(owner?['id']), starTripId) ||
          starHistoryChanged;
    }
    for (final notice in stoppedOwnedTripNotices) {
      addActivity(
        title: 'Trajet précédent arrêté',
        subtitle: _text(notice['reason']),
        iconKey: 'stop',
        colorValue: 0xFFD1495B,
        audienceSessionIds: _stringList(notice['audienceSessionIds']),
      );
    }
    addActivity(
      title: 'Trajet démarré',
      subtitle: 'La ligne ${_displayCode(lineCode)} est visible en direct.',
      iconKey: 'play',
      colorValue: _colorValue(line['colour'], lineCode),
      audienceSessionIds: <String>[sessionId],
    );
    final conversationChanged = ownerId.isNotEmpty;
    if (conversationChanged) {
      _ensureTripConversationForUser(ownerId, trip);
    }
    _notifySharedChange();
    await _persist(
      StateMutationBatch(
        users: starHistoryChanged,
        trips: true,
        sessions: true,
        activity: true,
        messageConversations: conversationChanged,
      ),
    );
    return _snapshotWithSystemTripCancellationNotices(
      sessionId,
      stoppedOwnedTripNotices,
    );
  }

  double _initialProgressForLineLive(int sameLineActiveCount) {
    final progress = (0.12 + sameLineActiveCount * 0.18) % 0.92;
    return progress < 0.08 ? progress + 0.08 : progress;
  }

  Future<JsonMap> updateTripLocation(
    String sessionId,
    String tripId,
    JsonMap body, {
    bool includeSnapshot = true,
  }) async {
    final session = _session(sessionId);
    final trips = _trips();
    final trip = trips.firstWhere(
      (candidate) => _text(candidate['id']) == tripId,
      orElse: () => throw StateError('Trajet introuvable.'),
    );
    if (!_canUpdateTripLocation(sessionId, session, trip)) {
      throw StateError('Accès refusé pour ce trajet.');
    }
    if (_text(trip['status']) != 'actif') {
      throw StateError("Ce trajet live n\'est plus actif.");
    }
    final location = body['location'];
    if (location is! Map) {
      throw StateError('La position GPS est invalide.');
    }

    final liveLocation = _parseLiveLocationOrThrow(location);
    final currentLiveLocation = trip['liveLocation'];
    if (_isStaleLiveLocationUpdate(currentLiveLocation, liveLocation)) {
      throw StateError(
        'Position GPS ignoree : point plus ancien que la position serveur.',
      );
    }
    if (_isImplausibleLiveLocationUpdate(currentLiveLocation, liveLocation)) {
      throw StateError(
        'Position GPS ignoree : deplacement incoherent avec le dernier GPS.',
      );
    }
    final receivedAt = _nowIso();
    final offRouteStopReason = _updateLiveRouteGuard(
      trip: trip,
      incomingLocation: liveLocation,
      currentLocation: currentLiveLocation,
      receivedAt: receivedAt,
    );
    final incomingProgress = body['progress'] == null
        ? null
        : _double(body['progress']).clamp(0.0, 1.0).toDouble();
    trip['traveledDistanceMeters'] = _nextTripTravelledDistanceMeters(
      trip,
      body: body,
      currentLocation: currentLiveLocation,
      incomingLocation: liveLocation,
      incomingProgress: incomingProgress,
    );
    trip['liveLocation'] = liveLocation;
    trip['lastUpdatedAt'] = receivedAt;
    session['currentLocation'] = <String, dynamic>{
      'lat': _double(liveLocation['lat']),
      'lng': _double(liveLocation['lng']),
      'accuracy': liveLocation['accuracy'],
      'timestamp': _text(liveLocation['timestamp']),
    };

    if (incomingProgress != null) {
      trip['progress'] = incomingProgress;
    }

    final speedMetersPerSecond = _double(liveLocation['speed']);
    if (speedMetersPerSecond > 0) {
      trip['speedKmh'] = speedMetersPerSecond * 3.6;
    }
    _addTripNetworkUsage(
      trip,
      body,
      responseKind: includeSnapshot
          ? _TripNetworkResponseKind.snapshot
          : _TripNetworkResponseKind.compact,
    );

    if (offRouteStopReason != null) {
      final notice = _systemTripCancellationNotice(
        trip,
        reason: offRouteStopReason,
        notificationType: 'trip_stopped_off_route',
        liveLocation: liveLocation,
      );
      final audienceSessionIds = _stringList(notice['audienceSessionIds']);
      _markTripStoppedBySystem(
        trip,
        tripId: tripId,
        reason: offRouteStopReason,
        stoppedAt: receivedAt,
      );
      if (_text(session['selectedTripId']) == tripId) {
        session['selectedTripId'] = null;
      }
      addActivity(
        title: 'Trajet live interrompu',
        subtitle: offRouteStopReason,
        iconKey: 'stop',
        colorValue: 0xFFD1495B,
        audienceSessionIds: audienceSessionIds,
      );
      _state['trips'] = trips;
      _putSession(sessionId, session);
      final starHistoryChanged =
          _rememberStarTripForOwner(trip) ||
          _rememberStarTripForSessionOwner(sessionId, session, trip);
      _notifySharedChange();
      await _persist(
        StateMutationBatch(
          users: starHistoryChanged,
          trips: true,
          sessions: true,
          activity: true,
        ),
      );
      throw SystemTripCancellationException(
        "Ce trajet live n\'est plus actif : position hors trace confirmee.",
        notice: notice,
      );
    }

    _state['trips'] = trips;
    _putSession(sessionId, session);
    _notifySharedChange();
    await _persist(const StateMutationBatch(trips: true, sessions: true));
    return includeSnapshot
        ? snapshot(sessionId)
        : <String, dynamic>{'sessionId': sessionId};
  }

  Future<JsonMap> heartbeatTrip(
    String sessionId,
    String tripId,
    JsonMap body, {
    bool includeSnapshot = true,
  }) async {
    final session = _session(sessionId);
    final trips = _trips();
    final trip = trips.firstWhere(
      (candidate) => _text(candidate['id']) == tripId,
      orElse: () => throw StateError('Trajet introuvable.'),
    );
    if (!_canUpdateTripLocation(sessionId, session, trip)) {
      throw StateError('AccÃ¨s refusÃ© pour ce trajet.');
    }
    if (_text(trip['status']) != 'actif') {
      throw StateError("Ce trajet live n\'est plus actif.");
    }

    final heartbeatAt = _nowIso();
    trip['lastUpdatedAt'] = heartbeatAt;
    var sessionLocationRefreshed = false;
    final liveLocation = trip['liveLocation'];
    if (liveLocation is Map) {
      final lat = _double(liveLocation['lat'] ?? liveLocation['latitude']);
      final lng = _double(liveLocation['lng'] ?? liveLocation['longitude']);
      if (_isValidLatLng(lat, lng)) {
        session['currentLocation'] = <String, dynamic>{
          'lat': lat,
          'lng': lng,
          'accuracy': liveLocation['accuracy'],
          'timestamp': heartbeatAt,
        };
        _putSession(sessionId, session);
        sessionLocationRefreshed = true;
      }
    }
    _addTripNetworkUsage(
      trip,
      body.isEmpty ? <String, dynamic>{'heartbeat': true} : body,
      responseKind: includeSnapshot
          ? _TripNetworkResponseKind.snapshot
          : _TripNetworkResponseKind.compact,
    );
    _state['trips'] = trips;
    _notifySharedChange();
    await _persist(
      StateMutationBatch(trips: true, sessions: sessionLocationRefreshed),
    );
    return includeSnapshot
        ? snapshot(sessionId)
        : <String, dynamic>{'sessionId': sessionId};
  }

  Future<List<JsonMap>> expireOffRouteActiveTrips() async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final trips = _trips();
    final sessions = _sessions();
    final notices = <JsonMap>[];
    var tripsChanged = false;
    var usersChanged = false;

    for (final trip in trips) {
      if (_text(trip['status']) != 'actif') continue;
      final liveLocation = trip['liveLocation'];
      if (liveLocation is! Map) continue;

      final beforeOffRouteSince = _text(trip['offRouteSince']);
      final beforeOffRouteDistance = _text(trip['offRouteDistanceMeters']);
      final location = Map<String, dynamic>.from(liveLocation);
      final offRouteStopReason = _updateLiveRouteGuard(
        trip: trip,
        incomingLocation: location,
        currentLocation: liveLocation,
        receivedAt: nowIso,
      );

      if (offRouteStopReason == null) {
        if (beforeOffRouteSince != _text(trip['offRouteSince']) ||
            beforeOffRouteDistance != _text(trip['offRouteDistanceMeters'])) {
          tripsChanged = true;
        }
        continue;
      }

      final tripId = _text(trip['id']);
      final notice = _systemTripCancellationNotice(
        trip,
        reason: offRouteStopReason,
        notificationType: 'trip_stopped_off_route',
        liveLocation: location,
      );
      final audienceSessionIds = _stringList(notice['audienceSessionIds']);
      _markTripStoppedBySystem(
        trip,
        tripId: tripId,
        reason: offRouteStopReason,
        stoppedAt: nowIso,
      );
      usersChanged = _rememberStarTripForOwner(trip) || usersChanged;
      for (final session in sessions.values) {
        if (_text(session['selectedTripId']) == tripId) {
          session['selectedTripId'] = null;
        }
      }
      addActivity(
        title: 'Trajet live interrompu',
        subtitle: offRouteStopReason,
        iconKey: 'stop',
        colorValue: 0xFFD1495B,
        audienceSessionIds: audienceSessionIds,
      );
      notices.add(notice);
      tripsChanged = true;
    }

    if (!tripsChanged) return const <JsonMap>[];
    _state['trips'] = trips;
    if (notices.isNotEmpty) {
      _state['sessions'] = sessions;
      _notifySharedChange();
    }
    await _persist(
      StateMutationBatch(
        users: usersChanged,
        trips: true,
        sessions: notices.isNotEmpty,
        activity: notices.isNotEmpty,
      ),
    );
    return notices;
  }

  Future<List<JsonMap>> expireStaleActiveTrips({
    Duration timeout = const Duration(seconds: 150),
  }) async {
    final now = DateTime.now().toUtc();
    final nowIso = now.toIso8601String();
    final trips = _trips();
    final expiredNotices = <JsonMap>[];
    var usersChanged = false;

    for (final trip in trips) {
      if (_text(trip['status']) != 'actif') continue;
      final lastUpdatedAt = DateTime.tryParse(_text(trip['lastUpdatedAt']));
      if (lastUpdatedAt == null) continue;
      if (now.difference(lastUpdatedAt.toUtc()) < timeout) continue;

      final tripId = _text(trip['id']);
      final lineCode = _text(trip['line_code']);
      final lineLabel = _displayCode(lineCode);
      final lineName = _routeTitle(lineByCode(lineCode));
      final busLabel = lineName.isEmpty
          ? 'ligne $lineLabel'
          : 'ligne $lineLabel - $lineName';
      final liveLocation = trip['liveLocation'];
      final lat = liveLocation is Map
          ? _double(liveLocation['lat'] ?? liveLocation['latitude'])
          : double.nan;
      final lng = liveLocation is Map
          ? _double(liveLocation['lng'] ?? liveLocation['longitude'])
          : double.nan;
      final hasLastLocation = _isValidLatLng(lat, lng);
      final locationSuffix = hasLastLocation
          ? ' Derniere position GPS: ${lat.toStringAsFixed(5)} / ${lng.toStringAsFixed(5)}.'
          : ' Derniere position GPS indisponible.';
      final timeoutLabel = _durationLabel(timeout);
      final reason =
          "Trajet live interrompu automatiquement : l\'Etoile du bus "
          '$busLabel ne communique plus avec le serveur depuis plus de $timeoutLabel.';
      final audience = notificationAudienceForTrip(tripId);

      trip['status'] = 'termine';
      trip['lastUpdatedAt'] = nowIso;
      final messages = List<JsonMap>.from(
        trip['messages'] as List? ?? const [],
      );
      messages.add(
        _message(
          id: _newEntityId('sys-timeout-$tripId'),
          tripId: tripId,
          authorName: 'Systeme',
          role: 'administrateur',
          content: '$reason$locationSuffix',
          createdAt: nowIso,
          isSystem: true,
        ),
      );
      trip['messages'] = messages;
      usersChanged = _rememberStarTripForOwner(trip) || usersChanged;
      addActivity(
        title: 'Trajet live interrompu',
        subtitle: 'Bus $busLabel. $reason$locationSuffix',
        iconKey: 'stop',
        colorValue: 0xFFD1495B,
        audienceSessionIds: audience.sessionIds,
      );
      expiredNotices.add(<String, dynamic>{
        'notificationType': 'trip_stopped_timeout',
        'tripId': tripId,
        'lineCode': lineCode,
        'lineLabel': busLabel,
        'reason': reason,
        'lastLocation': hasLastLocation
            ? <String, dynamic>{'lat': lat, 'lng': lng}
            : null,
        'tokens': audience.tokens,
        'audienceSessionIds': audience.sessionIds.toList(growable: false),
      });
    }

    if (expiredNotices.isEmpty) return const <JsonMap>[];
    _state['trips'] = trips;
    _notifySharedChange();
    await _persist(
      StateMutationBatch(users: usersChanged, trips: true, activity: true),
    );
    return expiredNotices;
  }

  Future<bool> pruneRetainedHistory() async {
    final now = DateTime.now().toUtc();
    var tripsChanged = false;
    var reportsChanged = false;
    var sessionsChanged = false;

    final trips = _trips();
    final retainedCompletedTripIds = _retainedCompletedTripIds(trips, now);
    final nextTrips = <JsonMap>[];
    for (final trip in trips) {
      final tripId = _text(trip['id']);
      final isActive = _text(trip['status']) == 'actif';
      if (!isActive && !retainedCompletedTripIds.contains(tripId)) {
        tripsChanged = true;
        continue;
      }

      final messages = _mapList(trip['messages']);
      final retainedMessages = _retainedTripMessages(messages, now);
      if (retainedMessages.length != messages.length) {
        tripsChanged = true;
        nextTrips.add(<String, dynamic>{...trip, 'messages': retainedMessages});
      } else {
        nextTrips.add(trip);
      }
    }
    if (tripsChanged) {
      _state['trips'] = nextTrips;
    }

    final validTripIds = nextTrips
        .map((trip) => _text(trip['id']))
        .where((id) => id.isNotEmpty)
        .toSet();
    final sessions = _sessions();
    for (final entry in sessions.entries.toList(growable: false)) {
      final selectedTripId = _text(entry.value['selectedTripId']);
      if (selectedTripId.isNotEmpty && !validTripIds.contains(selectedTripId)) {
        final nextSession = _normalizeSession(entry.value);
        nextSession['selectedTripId'] = null;
        sessions[entry.key] = nextSession;
        sessionsChanged = true;
      }
    }
    if (sessionsChanged) {
      _state['sessions'] = sessions;
    }

    final reports = _reports();
    final retainedReportIds = _retainedReportIds(reports, now);
    final nextReports = reports
        .where((report) => retainedReportIds.contains(_text(report['id'])))
        .toList(growable: false);
    if (nextReports.length != reports.length) {
      reportsChanged = true;
      _state['reports'] = nextReports;
    }

    if (!tripsChanged && !reportsChanged && !sessionsChanged) return false;
    _notifySharedChange();
    await _persist(
      StateMutationBatch(
        trips: tripsChanged,
        reports: reportsChanged,
        sessions: sessionsChanged,
      ),
    );
    return true;
  }

  Future<JsonMap> stopTrip(
    String sessionId,
    String tripId, {
    String? reason,
  }) async {
    final session = _session(sessionId);
    final stopReason = reason?.trim() ?? '';
    final trips = _trips();
    final activityAudience = notificationAudienceForTrip(tripId).sessionIds
      ..add(sessionId);
    var found = false;
    JsonMap? stoppedTrip;
    for (final trip in trips) {
      if (_text(trip['id']) == tripId) {
        found = true;
        if (!_canManageTrip(sessionId, session, trip)) {
          throw StateError('Accès refusé pour ce trajet.');
        }
        _addTripNetworkUsage(
          trip,
          stopReason.isEmpty
              ? <String, dynamic>{'tripId': tripId}
              : <String, dynamic>{'tripId': tripId, 'reason': stopReason},
          responseKind: _TripNetworkResponseKind.snapshot,
        );
        trip['status'] = 'termine';
        trip['lastUpdatedAt'] = _nowIso();
        stoppedTrip = trip;
        if (stopReason.isNotEmpty) {
          final messages = List<JsonMap>.from(trip['messages'] as List);
          messages.add(
            _message(
              id: _newEntityId('sys-stop-$tripId'),
              tripId: tripId,
              authorName: 'Système',
              role: 'administrateur',
              content: stopReason,
              createdAt: _nowIso(),
              isSystem: true,
            ),
          );
          trip['messages'] = messages;
        }
        break;
      }
    }
    if (!found) {
      throw StateError('Trajet introuvable.');
    }
    _state['trips'] = trips;
    if (_text(session['selectedTripId']) == tripId) {
      session['selectedTripId'] = null;
      _putSession(sessionId, session);
    }
    final starHistoryChanged =
        stoppedTrip != null &&
        (_rememberStarTripForOwner(stoppedTrip) ||
            _rememberStarTripForSessionOwner(sessionId, session, stoppedTrip));
    addActivity(
      title: stopReason.isEmpty ? 'Trajet arrêté' : 'Trajet retiré',
      subtitle: stopReason.isEmpty
          ? 'Le suivi live a été fermé pour ce trajet.'
          : stopReason,
      iconKey: 'stop',
      colorValue: 0xFFD1495B,
      audienceSessionIds: activityAudience,
    );
    _notifySharedChange();
    await _persist(
      StateMutationBatch(
        users: starHistoryChanged,
        trips: true,
        sessions: true,
        activity: true,
      ),
    );
    return snapshot(sessionId);
  }

  Future<JsonMap> sendMessage(
    String sessionId,
    String tripId,
    String content, {
    String? messageId,
    String? createdAt,
  }) async {
    final session = _session(sessionId);
    final text = _boundedText(content, _maxMessageLength, fieldName: 'Message');
    if (text.isEmpty) {
      throw StateError('Le message est vide.');
    }
    final trips = _trips();
    final trip = trips.firstWhere(
      (candidate) => _text(candidate['id']) == tripId,
      orElse: () => throw StateError('Trajet introuvable.'),
    );
    final messages = List<JsonMap>.from(trip['messages'] as List);
    final owner = _currentUser(session);
    final requestedMessageId = _clientIdOrEmpty(
      messageId,
      fieldName: 'Identifiant message',
    );
    final effectiveMessageId = requestedMessageId.isEmpty
        ? _newEntityId('msg')
        : requestedMessageId;
    final effectiveCreatedAt = _clientTimestampOrNow(
      createdAt,
      fieldName: 'Date du message',
    );
    messages.add(
      _message(
        id: effectiveMessageId,
        tripId: tripId,
        authorName:
            owner?['fullName'] ?? _roleLabel(_text(session['activeRole'])),
        role: _text(session['activeRole']),
        content: text,
        createdAt: effectiveCreatedAt,
        isSystem: false,
      ),
    );
    final activityAudience = notificationAudienceForTrip(tripId).sessionIds
      ..add(sessionId);
    trip['messages'] = messages;
    _addTripNetworkUsage(trip, <String, dynamic>{
      'content': text,
    }, responseKind: _TripNetworkResponseKind.snapshot);
    _state['trips'] = trips;
    addActivity(
      title: 'Message publié',
      subtitle: 'Chat du trajet mis à  jour.',
      iconKey: 'chat',
      colorValue: 0xFF0F8B8D,
      audienceSessionIds: activityAudience,
    );
    _notifySharedChange();
    await _persist(const StateMutationBatch(trips: true, activity: true));
    return snapshot(sessionId);
  }

  Future<JsonMap> rateTrip(String sessionId, String tripId, int score) async {
    if (score < 1 || score > 5) {
      throw StateError('La note doit être comprise entre 1 et 5.');
    }
    final actorId = _tripRatingActorId(sessionId);
    final trips = _trips();
    final trip = trips.firstWhere(
      (candidate) => _text(candidate['id']) == tripId,
      orElse: () => throw StateError('Trajet introuvable.'),
    );
    final ratedByActorIds = _stringList(
      trip['ratedByActorIds'] ?? trip['rated_by_actor_ids'],
    );
    if (ratedByActorIds.contains(actorId)) {
      throw StateError('Vous avez déjà noté ce trajet.');
    }
    final currentAverage = _double(trip['ratingAverage']);
    final currentCount = _int(trip['ratingCount']);
    final total = currentAverage * currentCount;
    final count = currentCount + 1;
    trip['ratingAverage'] = (total + score) / count;
    trip['ratingCount'] = count;
    trip['ratedByActorIds'] = <String>[...ratedByActorIds, actorId]..sort();
    trip['lastUpdatedAt'] = _nowIso();
    final activityAudience = notificationAudienceForTrip(tripId).sessionIds
      ..add(sessionId);
    _state['trips'] = trips;
    addActivity(
      title: 'Note enregistrée',
      subtitle: 'Le trajet a reçu une nouvelle évaluation.',
      iconKey: 'star',
      colorValue: 0xFFEE964B,
      audienceSessionIds: activityAudience,
    );
    _notifySharedChange();
    await _persist(const StateMutationBatch(trips: true, activity: true));
    return snapshot(sessionId);
  }

  Future<JsonMap> setTripLike(
    String sessionId,
    String tripId,
    bool liked,
  ) async {
    final actorId = _tripLikeActorId(sessionId);
    if (actorId.isEmpty) {
      throw StateError('Session invalide pour ce like.');
    }
    final trips = _trips();
    final trip = trips.firstWhere(
      (candidate) => _text(candidate['id']) == tripId,
      orElse: () => throw StateError('Trajet introuvable.'),
    );
    final likedBy = _tripLikeActorIds(trip).toSet();
    final sessionActorId = _tripSessionLikeActorId(sessionId);
    bool changed;
    if (liked) {
      changed = likedBy.remove(sessionActorId);
      changed = likedBy.add(actorId) || changed;
    } else {
      changed = likedBy.remove(actorId);
      changed = likedBy.remove(sessionActorId) || changed;
    }
    if (!changed) {
      return <String, dynamic>{
        ...snapshot(sessionId),
        'tripLikeChanged': false,
      };
    }

    trip['likedByActorIds'] = likedBy.toList(growable: false)..sort();
    _state['trips'] = trips;
    if (liked) {
      final activityAudience = notificationAudienceForTripOwner(tripId)
          .sessionIds
        ..remove(sessionId);
      addActivity(
        title: 'Nouveau j\'aime',
        subtitle: 'Votre trajet a reçu un nouveau j\'aime.',
        iconKey: 'heart',
        colorValue: 0xFFD1495B,
        audienceSessionIds: activityAudience,
      );
    }
    _notifySharedChange();
    await _persist(
      StateMutationBatch(trips: true, activity: liked),
    );
    return <String, dynamic>{
      ...snapshot(sessionId),
      'tripLikeChanged': liked,
    };
  }

  Future<JsonMap> createReport(String sessionId, JsonMap body) async {
    final session = _session(sessionId);
    final owner = _currentUser(session);
    final busNumber = _boundedText(
      body['busNumber'],
      _maxBusNumberLength,
      fieldName: 'Numero de bus',
    );
    final lineLabel = _boundedText(
      body['lineLabel'],
      _maxLineLabelLength,
      fieldName: 'Libelle de ligne',
    );
    final note = _boundedText(body['note'], _maxNoteLength, fieldName: 'Note');
    final location = body['location'];
    if (location is! Map) {
      throw StateError('La position du signalement est invalide.');
    }
    final parsedLocation = _parseLatLngOrThrow(location);
    session['currentLocation'] = <String, dynamic>{
      'lat': parsedLocation['lat'],
      'lng': parsedLocation['lng'],
      'accuracy': _double(location['accuracy']),
      'timestamp': _clientTimestampOrNow(
        location['timestamp'],
        fieldName: 'Date GPS signalement',
        maxPast: const Duration(minutes: 10),
        maxFuture: _liveLocationMaxFutureSkew,
      ),
    };
    _putSession(sessionId, session);
    final requestedReportId = _clientIdOrEmpty(
      body['reportId'],
      fieldName: 'Identifiant signalement',
    );
    final reportId = requestedReportId.isEmpty
        ? _newEntityId('r')
        : requestedReportId;
    final createdAt = _clientTimestampOrNow(
      body['createdAt'],
      fieldName: 'Date du signalement',
    );
    final report = <String, dynamic>{
      'id': reportId,
      'busNumber': busNumber.isEmpty
          ? _normalizeCode(_text(session['selectedLineCode']))
          : busNumber,
      'lineCode': _normalizeCode(
        _text(body['lineCode']).isEmpty
            ? _text(session['selectedLineCode'])
            : _boundedText(
                body['lineCode'],
                _maxLineCodeLength,
                fieldName: 'Ligne',
              ),
      ),
      'lineLabel': lineLabel.isEmpty ? 'Ligne inconnue' : lineLabel,
      'reporterId': _text(owner?['id']),
      'reporterName':
          owner?['fullName'] ?? _roleLabel(_text(session['activeRole'])),
      'location': {'lat': parsedLocation['lat'], 'lng': parsedLocation['lng']},
      'status': 'valide',
      'createdAt': createdAt,
      'note': note.isEmpty
          ? "Signalement terrain partage depuis l\'application."
          : note,
      'confidence': 0.78,
    };
    final reports = _reports();
    reports.insert(0, report);
    _state['reports'] = reports;
    addActivity(
      title: 'Signalement enregistré',
      subtitle: 'Bus ${report['busNumber']} publié immédiatement.',
      iconKey: 'report',
      colorValue: 0xFF0F8B8D,
      audienceSessionIds: <String>[sessionId],
    );
    _notifySharedChange();
    await _persist(
      const StateMutationBatch(reports: true, sessions: true, activity: true),
    );
    return snapshot(sessionId);
  }

  Future<JsonMap> updateReportStatus(
    String sessionId,
    String reportId,
    String status,
  ) async {
    _requireAdmin(sessionId);
    final reports = _reports();
    for (final report in reports) {
      if (_text(report['id']) == reportId) {
        report['status'] = _normalizeReportStatus(status);
        break;
      }
    }
    _state['reports'] = reports;
    addActivity(
      title: 'Signalement modéré',
      subtitle: 'Statut mis à  jour.',
      iconKey: 'moderation',
      colorValue: 0xFFD1495B,
      audienceSessionIds: _adminSessionIds(includeSessionId: sessionId),
    );
    _notifySharedChange();
    await _persist(const StateMutationBatch(reports: true, activity: true));
    return snapshot(sessionId);
  }

  Future<JsonMap> deleteReport(String sessionId, String reportId) async {
    _requireAdmin(sessionId);
    final reports = _reports();
    final previousLength = reports.length;
    reports.removeWhere((report) => _text(report['id']) == reportId);
    if (reports.length == previousLength) {
      throw StateError('Signalement introuvable.');
    }
    _state['reports'] = reports;
    addActivity(
      title: 'Signalement supprimé',
      subtitle: 'Une alerte publiée a été retirée.',
      iconKey: 'moderation',
      colorValue: 0xFFD1495B,
      audienceSessionIds: _adminSessionIds(includeSessionId: sessionId),
    );
    _notifySharedChange();
    await _persist(const StateMutationBatch(reports: true, activity: true));
    return snapshot(sessionId);
  }

  Future<JsonMap> toggleUserStatus(String sessionId, String userId) async {
    _requireAdmin(sessionId);
    final users = _users();
    for (final user in users) {
      if (_text(user['id']) == userId) {
        user['status'] = _text(user['status']) == 'actif'
            ? 'suspendu'
            : 'actif';
        user['lastSeenAt'] = _nowIso();
        break;
      }
    }
    _state['users'] = users;
    addActivity(
      title: 'Compte modulé',
      subtitle: 'Une action de gouvernance a été appliquée.',
      iconKey: 'admin',
      colorValue: 0xFFD1495B,
      audienceSessionIds: _adminSessionIds(includeSessionId: sessionId),
    );
    _notifySharedChange();
    await _persist(const StateMutationBatch(users: true, activity: true));
    return snapshot(sessionId);
  }

  JsonMap _seedState() {
    final now = DateTime.now();
    final users = <JsonMap>[];
    final bootstrapAdmin = _bootstrapAdminFromEnv(now);
    if (bootstrapAdmin != null) {
      users.add(bootstrapAdmin);
    }

    return <String, dynamic>{
      'sessions': <String, JsonMap>{},
      'users': users,
      'trips': <JsonMap>[],
      'reports': <JsonMap>[],
      'pushTokens': <JsonMap>[],
      'activity': <JsonMap>[],
    };
  }

  JsonMap? _bootstrapAdminFromEnv(DateTime now) {
    final email = (Platform.environment['PIWIBUS_ADMIN_EMAIL'] ?? '')
        .trim()
        .toLowerCase();
    final password = (Platform.environment['PIWIBUS_ADMIN_PASSWORD'] ?? '')
        .trim();
    if (email.isEmpty && password.isEmpty) {
      return null;
    }
    if (!_isValidEmail(email)) {
      throw StateError(
        'PIWIBUS_ADMIN_EMAIL invalide. '
        'Utilisez une adresse email valide.',
      );
    }
    if (password.length < 12) {
      throw StateError(
        'PIWIBUS_ADMIN_PASSWORD trop court. '
        'Utilisez au moins 12 caractères.',
      );
    }
    final fullName =
        (Platform.environment['PIWIBUS_ADMIN_NAME'] ?? '').trim().isEmpty
        ? 'Administrateur Piwibus'
        : (Platform.environment['PIWIBUS_ADMIN_NAME'] ?? '').trim();
    final phone = (Platform.environment['PIWIBUS_ADMIN_PHONE'] ?? '').trim();
    final nowIso = now.toIso8601String();
    return _user(
      id: _newEntityId('admin'),
      fullName: fullName,
      email: email,
      phone: phone,
      role: 'administrateur',
      status: 'actif',
      passwordHash: _hashPassword(email, password),
      createdAt: nowIso,
      lastSeenAt: nowIso,
    );
  }

  bool _ensureBootstrapAdminFromEnv() {
    final admin = _bootstrapAdminFromEnv(DateTime.now());
    if (admin == null) return false;

    final users = _users();
    final adminEmail = _text(admin['email']).toLowerCase();
    final index = users.indexWhere(
      (user) => _text(user['email']).toLowerCase() == adminEmail,
    );
    if (index < 0) {
      users.insert(0, admin);
      _state['users'] = users;
      return true;
    }

    final existing = users[index];
    final fullName = _text(admin['fullName']);
    final phone = _text(admin['phone']);
    existing['primaryRole'] = 'administrateur';
    existing['status'] = 'actif';
    existing['passwordHash'] = _text(admin['passwordHash']);
    if (fullName.isNotEmpty) existing['fullName'] = fullName;
    if (phone.isNotEmpty) existing['phone'] = phone;
    if (_text(existing['createdAt']).isEmpty) {
      existing['createdAt'] = _text(admin['createdAt']);
    }
    _state['users'] = users;
    return true;
  }

  void _enforceNoDefaultAdminPassword() {
    final users = _users();
    var changed = false;
    for (final user in users) {
      if (!_isKnownDefaultAdminPassword(user)) continue;
      final email = _text(user['email']).toLowerCase();
      final replacementPassword =
          (Platform.environment['PIWIBUS_ADMIN_PASSWORD'] ?? '').trim();
      if (replacementPassword.length < 12) {
        throw StateError(
          'Le compte administrateur "$email" utilise encore un mot de passe '
          'par défaut. Définissez PIWIBUS_ADMIN_PASSWORD (>= 12 caractères) '
          'puis redémarrez le backend.',
        );
      }
      user['passwordHash'] = _hashPassword(email, replacementPassword);
      user['lastSeenAt'] = _nowIso();
      changed = true;
    }
    if (changed) {
      _state['users'] = users;
    }
  }

  bool _isKnownDefaultAdminPassword(JsonMap user) {
    final email = _text(user['email']).toLowerCase();
    if (email != 'admin@piwibus.ci') return false;
    if (_normalizeRole(user['primaryRole']?.toString()) != 'administrateur') {
      return false;
    }
    final storedHash = _text(user['passwordHash']);
    if (storedHash.isEmpty) return false;
    return _verifyPassword(email, 'admin123', storedHash);
  }

  JsonMap _user({
    required String id,
    required String fullName,
    required String email,
    required String phone,
    String? profilePhotoDataUrl,
    String? nameChangedAt,
    required String role,
    required String status,
    required String passwordHash,
    required String createdAt,
    required String lastSeenAt,
    String? activityReadAt,
    Iterable<String> readAlertIds = const <String>[],
    Iterable<String> starTripIds = const <String>[],
    Iterable<String> followedTripIds = const <String>[],
  }) {
    return <String, dynamic>{
      'id': id,
      'fullName': fullName,
      'email': email,
      'phone': phone,
      'profilePhotoDataUrl': profilePhotoDataUrl,
      if (nameChangedAt != null) 'nameChangedAt': nameChangedAt,
      'primaryRole': role,
      'status': status,
      'createdAt': createdAt,
      'lastSeenAt': lastSeenAt,
      'passwordHash': passwordHash,
      if (activityReadAt != null) 'activityReadAt': activityReadAt,
      'readAlertIds': readAlertIds.toList(growable: false),
      'starTripIds': starTripIds.toList(growable: false),
      'followedTripIds': followedTripIds.toList(growable: false),
    };
  }

  JsonMap _publicUser(JsonMap user) {
    final public = publicUserFromState(
      user,
      _sessions(),
      sessionOnlineById: _sessionOnline,
    );
    return <String, dynamic>{
      ...public,
      'readAlertIds':
          (user['readAlertIds'] as List?)?.cast<String>().toList(
            growable: false,
          ) ??
          const <String>[],
      'starTripIds':
          (user['starTripIds'] as List?)?.cast<String>().toList(
            growable: false,
          ) ??
          const <String>[],
      'followedTripIds':
          (user['followedTripIds'] as List?)?.cast<String>().toList(
            growable: false,
          ) ??
          const <String>[],
    };
  }

  Map<String, JsonMap> _usersById() {
    return <String, JsonMap>{
      for (final user in _users())
        if (_text(user['id']).isNotEmpty) _text(user['id']): user,
    };
  }

  List<JsonMap> _messageConversationsForSession(JsonMap? currentUser) {
    final currentUserId = _text(currentUser?['id']);
    if (currentUserId.isEmpty) return const <JsonMap>[];
    final usersById = _usersById();
    final visible = _messageConversations()
        .where(
          (conversation) => _stringList(
            conversation['participantIds'],
          ).contains(currentUserId),
        )
        .map(
          (conversation) => _publicMessageConversation(
            conversation,
            currentUserId: currentUserId,
            usersById: usersById,
          ),
        )
        .toList(growable: false);
    visible.sort(
      (a, b) => _text(b['updatedAt']).compareTo(_text(a['updatedAt'])),
    );
    return visible;
  }

  JsonMap? _messageConversationForParticipant(
    String conversationId,
    String currentUserId,
  ) {
    final normalizedId = conversationId.trim();
    if (normalizedId.isEmpty || currentUserId.trim().isEmpty) return null;
    for (final conversation in _messageConversations()) {
      if (_text(conversation['id']) != normalizedId) continue;
      if (!_stringList(
        conversation['participantIds'],
      ).contains(currentUserId)) {
        throw StateError('Acces refuse pour cette conversation.');
      }
      return conversation;
    }
    return null;
  }

  JsonMap _publicMessageConversation(
    JsonMap conversation, {
    required String currentUserId,
    required Map<String, JsonMap> usersById,
  }) {
    final participantIds = _stringList(conversation['participantIds']);
    final peerUserId = participantIds.firstWhere(
      (id) => id != currentUserId,
      orElse: () => '',
    );
    final readSequences = _sequenceMap(conversation['readSequences']);
    final readThrough = readSequences[currentUserId] ?? 0;
    final unreadCount = math.max(
      0,
      _int(conversation['messageCursor']) - readThrough,
    );
    final peerUser = usersById[peerUserId];
    final kind = _text(conversation['kind']).isEmpty
        ? 'direct'
        : _text(conversation['kind']);
    final title = _text(conversation['title']).isNotEmpty
        ? _text(conversation['title'])
        : kind == 'direct' && peerUser != null
        ? _text(peerUser['fullName'])
        : 'Conversation trajet';
    return <String, dynamic>{
      'id': _text(conversation['id']),
      'kind': kind,
      'participantIds': participantIds,
      if (_text(conversation['tripId']).isNotEmpty)
        'tripId': _text(conversation['tripId']),
      'peerUser': peerUser == null ? null : _publicMessagingPeerUser(peerUser),
      'title': title,
      'subtitle': _text(conversation['subtitle']),
      'lastMessagePreview': _text(conversation['lastMessagePreview']),
      if (_text(conversation['lastMessageId']).isNotEmpty)
        'lastMessageId': _text(conversation['lastMessageId']),
      if (_text(conversation['lastSenderId']).isNotEmpty)
        'lastSenderId': _text(conversation['lastSenderId']),
      'unreadCount': unreadCount,
      'messageCursor': _int(conversation['messageCursor']),
      'createdAt': _text(conversation['createdAt']),
      'updatedAt': _text(conversation['updatedAt']),
    };
  }

  JsonMap _publicMessageItem(JsonMap message) {
    return <String, dynamic>{
      'id': _text(message['id']),
      'conversationId': _text(
        message['conversationId'] ?? message['conversation_id'],
      ),
      'senderId': _text(message['senderId'] ?? message['sender_id']),
      'senderName': _text(message['senderName'] ?? message['sender_name']),
      'body': _text(message['body']),
      'sequence': _int(message['sequence']),
      'createdAt': _text(message['createdAt'] ?? message['created_at']),
    };
  }

  JsonMap _publicMessagingPeerUser(
    JsonMap user, {
    bool includeProfilePhotoDataUrl = false,
  }) {
    final public = publicUserFromState(
      user,
      _sessions(),
      sessionOnlineById: _sessionOnline,
    );
    return <String, dynamic>{
      'id': _text(public['id']),
      'fullName': _text(public['fullName']),
      if (_text(public['status']).isNotEmpty) 'status': _text(public['status']),
      if (public['isOnline'] != null) 'isOnline': public['isOnline'],
      if (_text(public['lastSeenAt']).isNotEmpty)
        'lastSeenAt': _text(public['lastSeenAt']),
      if (includeProfilePhotoDataUrl &&
          _text(public['profilePhotoDataUrl']).isNotEmpty)
        'profilePhotoDataUrl': _text(public['profilePhotoDataUrl']),
    };
  }

  Map<String, int> _sequenceMap(Object? raw) {
    if (raw is! Map) return <String, int>{};
    return raw.map((key, value) => MapEntry(key.toString(), _int(value)));
  }

  String _messagePreview(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.length <= 180) return normalized;
    return '${normalized.substring(0, 179)}…';
  }

  JsonMap _storedUserOr(JsonMap fallback) {
    final id = _text(fallback['id']);
    if (id.isEmpty) return fallback;
    return _users().firstWhere(
      (user) => _text(user['id']) == id,
      orElse: () => fallback,
    );
  }

  JsonMap _publicTripForSession(
    JsonMap trip,
    String sessionId, {
    bool includeAdminTelemetry = false,
  }) {
    final public = <String, dynamic>{...trip};
    public['path'] = const <JsonMap>[];
    final likedByActorIds = _tripLikeActorIds(trip);
    final ratedByActorIds = _stringList(
      trip['ratedByActorIds'] ?? trip['rated_by_actor_ids'],
    );
    public['likeCount'] = likedByActorIds.toSet().length;
    public['likedByCurrentUser'] = _tripLikedBySession(
      likedByActorIds,
      sessionId,
    );
    public['ratedByCurrentUser'] = _tripRatedBySession(
      ratedByActorIds,
      sessionId,
    );
    public.remove('likedByActorIds');
    public.remove('liked_by_actor_ids');
    if (!includeAdminTelemetry) {
      public.remove('networkUsageBytes');
      public.remove('network_usage_bytes');
    }
    final currentOwnerSessionId = 'session-$sessionId';
    final ownerSessionId = _text(trip['owner_session_id']);
    if (ownerSessionId.isEmpty) {
      public.remove('owner_session_id');
    } else {
      public['owner_session_id'] = ownerSessionId == currentOwnerSessionId
          ? 'current-session'
          : 'other-session';
    }
    if (_text(public['owner_id']).startsWith('session-')) {
      public['owner_id'] = ownerSessionId == currentOwnerSessionId
          ? 'session-owner'
          : 'anonymous-owner';
    }
    return public;
  }

  JsonMap _publicNearbyTrip(JsonMap trip) {
    final public = <String, dynamic>{...trip};
    public['path'] = const <JsonMap>[];
    public['likeCount'] = _tripLikeCount(trip);
    public['likedByCurrentUser'] = false;
    public.remove('likedByActorIds');
    public.remove('liked_by_actor_ids');
    public.remove('owner_session_id');
    public.remove('networkUsageBytes');
    public.remove('network_usage_bytes');
    if (_text(public['owner_id']).startsWith('session-')) {
      public['owner_id'] = 'anonymous-owner';
    }
    return public;
  }

  List<JsonMap> _tripsWithObserverCounts(List<JsonMap> trips) {
    if (trips.isEmpty) return const <JsonMap>[];
    final ownerByTripId = <String, String>{};
    final activeTripIds = <String>{};
    for (final trip in trips) {
      final tripId = _text(trip['id']);
      if (tripId.isEmpty) continue;
      ownerByTripId[tripId] = _text(trip['owner_id']);
      if (_text(trip['status']) == 'actif') activeTripIds.add(tripId);
    }
    final observerCounts = <String, int>{};
    for (final entry in _sessions().entries) {
      final session = _normalizeSession(entry.value);
      if (!_sessionIsCurrentObserver(session)) continue;
      final selectedTripId = _text(session['selectedTripId']);
      if (!activeTripIds.contains(selectedTripId)) continue;
      final ownerId = ownerByTripId[selectedTripId] ?? '';
      if (_sessionOwnsOwnerId(entry.key, session, ownerId)) continue;
      observerCounts[selectedTripId] =
          (observerCounts[selectedTripId] ?? 0) + 1;
    }
    var maxObserverChanged = false;
    final result = trips
        .map((trip) {
          final tripId = _text(trip['id']);
          final observers = observerCounts[tripId] ?? 0;
          final maxObservers = math.max(_int(trip['maxObservers']), observers);
          if (maxObservers != _int(trip['maxObservers'])) {
            trip['maxObservers'] = maxObservers;
            maxObserverChanged = true;
          }
          return <String, dynamic>{
            ...trip,
            'observers': observers,
            'maxObservers': maxObservers,
          };
        })
        .toList(growable: false);
    if (maxObserverChanged) {
      _state['trips'] = trips;
      unawaited(_persist(const StateMutationBatch(trips: true)));
    }
    return result;
  }

  int _estimatedTripNetworkBytes(
    Object? payload, {
    required _TripNetworkResponseKind responseKind,
  }) {
    try {
      final payloadBytes = utf8.encode(jsonEncode(payload)).length;
      return payloadBytes +
          _estimatedTripRequestEnvelopeBytes +
          switch (responseKind) {
            _TripNetworkResponseKind.compact =>
              _estimatedTripCompactResponseBytes,
            _TripNetworkResponseKind.snapshot =>
              _estimatedTripSnapshotResponseBytes,
          };
    } catch (_) {
      final payloadBytes = _text(payload).length;
      return payloadBytes +
          _estimatedTripRequestEnvelopeBytes +
          switch (responseKind) {
            _TripNetworkResponseKind.compact =>
              _estimatedTripCompactResponseBytes,
            _TripNetworkResponseKind.snapshot =>
              _estimatedTripSnapshotResponseBytes,
          };
    }
  }

  void _addTripNetworkUsage(
    JsonMap trip,
    Object? payload, {
    required _TripNetworkResponseKind responseKind,
  }) {
    final estimate = _estimatedTripNetworkBytes(
      payload,
      responseKind: responseKind,
    );
    if (estimate <= 0) return;
    trip['networkUsageBytes'] = _int(trip['networkUsageBytes']) + estimate;
  }

  bool _sessionIsCurrentObserver(JsonMap session) {
    if (_normalizeRole(session['activeRole']?.toString()) != 'observateur') {
      return false;
    }
    final now = DateTime.now().toUtc();
    final location = session['currentLocation'];
    if (location is Map) {
      final locationTimestamp = DateTime.tryParse(
        _text(location['timestamp'] ?? location['updatedAt']),
      );
      if (locationTimestamp != null &&
          now.difference(locationTimestamp.toUtc()) <=
              _currentLocationFreshness) {
        return true;
      }
    }
    final lastSeenAt = DateTime.tryParse(_text(session['lastSeenAt']));
    return lastSeenAt != null &&
        now.difference(lastSeenAt.toUtc()) <= _observerSessionFreshness;
  }

  JsonMap _publicReport(JsonMap report) {
    return <String, dynamic>{
      'id': _text(report['id']),
      'busNumber': _text(report['busNumber']),
      'lineCode': _text(report['lineCode']),
      'lineLabel': _text(report['lineLabel']),
      'reporterName': _text(report['reporterName']),
      'location': report['location'],
      'status': _text(report['status']),
      'createdAt': _text(report['createdAt']),
      'note': _text(report['note']),
      'confidence': _double(report['confidence']),
    };
  }

  JsonMap _message({
    required String id,
    required String tripId,
    required String authorName,
    required String role,
    required String content,
    required String createdAt,
    required bool isSystem,
  }) {
    return <String, dynamic>{
      'id': id,
      'tripId': tripId,
      'authorName': authorName,
      'role': role,
      'content': content,
      'createdAt': createdAt,
      'isSystem': isSystem,
    };
  }

  JsonMap _adminTrip(JsonMap trip) {
    final lineCode = _normalizeCode(trip['line_code'] ?? trip['lineCode']);
    final liveLocation = trip['liveLocation'];
    final lastLocation = liveLocation is Map
        ? Map<String, dynamic>.from(liveLocation)
        : null;
    final routeDistanceKm = _tripRouteDistanceKm(trip);
    final travelledDistanceKm = _tripTravelledDistanceKm(trip);
    final messages = _mapList(trip['messages']);
    final recentMessages = messages
        .skip(math.max(0, messages.length - 20))
        .toList(growable: false);
    return <String, dynamic>{
      'id': _text(trip['id']),
      'lineCode': lineCode,
      'displayCode': _displayCode(lineCode),
      'lineTitle': _routeTitle(lineByCode(lineCode)),
      'colorValue': _colorValue(lineByCode(lineCode)?['colour'], lineCode),
      'ownerId': _text(trip['owner_id']),
      'ownerName': _text(trip['owner_name']),
      'ownerPhotoDataUrl': _nullableText(trip['owner_photo_data_url']),
      'ownerRole': _text(trip['owner_role']),
      'status': _text(trip['status']),
      'startedAt': _text(trip['startedAt']),
      'lastUpdatedAt': _text(trip['lastUpdatedAt']),
      'progress': _double(trip['progress']),
      'distanceKm': travelledDistanceKm,
      'routeDistanceKm': routeDistanceKm,
      'speedKmh': _double(trip['speedKmh']),
      'observers': _int(trip['observers']),
      'maxObservers': _int(trip['maxObservers']),
      'networkUsageBytes': _int(trip['networkUsageBytes']),
      'ratingAverage': _double(trip['ratingAverage']),
      'ratingCount': _int(trip['ratingCount']),
      'likeCount': _tripLikeCount(trip),
      'messageCount': messages.length,
      'note': _text(trip['note']),
      'liveLocation': lastLocation,
      'offRouteSince': _text(trip['offRouteSince']),
      'offRouteDistanceMeters': _double(trip['offRouteDistanceMeters']),
      'originLabel': _text(trip['originLabel']),
      'destinationLabel': _text(trip['destinationLabel']),
      'lastSystemMessage': _lastSystemMessage(trip),
      'messages': recentMessages,
    };
  }

  double _tripTravelledDistanceKm(JsonMap trip) {
    return _tripTravelledDistanceMeters(trip) / 1000;
  }

  double _tripTravelledDistanceMeters(JsonMap trip) {
    final explicitDistanceMeters = _tripExplicitTravelledDistanceMeters(trip);
    if (explicitDistanceMeters != null) return explicitDistanceMeters;
    final routeDistanceKm = _tripRouteDistanceKm(trip);
    if (!routeDistanceKm.isFinite || routeDistanceKm <= 0) return 0;
    final progress = _double(trip['progress']).clamp(0.0, 1.0).toDouble();
    return routeDistanceKm * 1000 * progress;
  }

  double? _tripExplicitTravelledDistanceMeters(JsonMap trip) {
    return _nonNegativeDoubleOrNull(
      trip['traveledDistanceMeters'] ??
          trip['traveled_distance_meters'] ??
          trip['distanceMeters'] ??
          trip['distance_meters'],
    );
  }

  double _nextTripTravelledDistanceMeters(
    JsonMap trip, {
    required JsonMap body,
    required Object? currentLocation,
    required JsonMap incomingLocation,
    required double? incomingProgress,
  }) {
    final currentExplicitDistance = _tripExplicitTravelledDistanceMeters(trip);
    final incomingExplicitDistance = _nonNegativeDoubleOrNull(
      body['traveledDistanceMeters'] ??
          body['traveled_distance_meters'] ??
          body['distanceMeters'] ??
          body['distance_meters'],
    );
    if (incomingExplicitDistance != null) {
      return currentExplicitDistance == null
          ? incomingExplicitDistance
          : math.max(currentExplicitDistance, incomingExplicitDistance);
    }

    var distanceMeters =
        currentExplicitDistance ?? _tripTravelledDistanceMeters(trip);
    final previousProgress = _double(
      trip['progress'],
    ).clamp(0.0, 1.0).toDouble();
    final routeDistanceMeters = _tripRouteDistanceKm(trip) * 1000;
    if (incomingProgress != null &&
        routeDistanceMeters.isFinite &&
        routeDistanceMeters > 0) {
      final progressDelta = incomingProgress - previousProgress;
      if (progressDelta.isFinite && progressDelta > 0) {
        return distanceMeters + (routeDistanceMeters * progressDelta);
      }
    }

    final directDistance = _liveLocationStepDistanceMeters(
      currentLocation,
      incomingLocation,
    );
    if (directDistance != null && directDistance > 3) {
      distanceMeters += directDistance;
    }
    return distanceMeters;
  }

  double? _liveLocationStepDistanceMeters(
    Object? currentLocation,
    JsonMap incomingLocation,
  ) {
    if (currentLocation is! Map) return null;
    final current = Map<String, dynamic>.from(currentLocation);
    final currentLat = _double(current['lat'] ?? current['latitude']);
    final currentLng = _double(current['lng'] ?? current['longitude']);
    final incomingLat = _double(
      incomingLocation['lat'] ?? incomingLocation['latitude'],
    );
    final incomingLng = _double(
      incomingLocation['lng'] ?? incomingLocation['longitude'],
    );
    if (!_isValidLatLng(currentLat, currentLng) ||
        !_isValidLatLng(incomingLat, incomingLng)) {
      return null;
    }
    final distanceMeters = _distanceMeters(
      currentLat,
      currentLng,
      incomingLat,
      incomingLng,
    );
    return distanceMeters.isFinite && distanceMeters >= 0
        ? distanceMeters
        : null;
  }

  double _tripRouteDistanceKm(JsonMap trip) {
    final pathDistanceKm = _pathDistanceKm(_tripPathPoints(trip));
    if (pathDistanceKm > 0) return pathDistanceKm;

    final lineCode = _normalizeCode(trip['line_code'] ?? trip['lineCode']);
    final line = lineByCode(lineCode);
    if (line == null) return 0;
    final segments = _lineSegments(line);
    if (segments.isEmpty) return 0;
    return segments
        .map(_pathDistanceKm)
        .fold<double>(0, (best, distance) => math.max(best, distance));
  }

  List<({double lat, double lng})> _tripPathPoints(JsonMap trip) {
    return _mapList(trip['path'])
        .map((point) {
          final lat = _double(point['lat'] ?? point['latitude']);
          final lng = _double(point['lng'] ?? point['longitude']);
          return (lat: lat, lng: lng);
        })
        .where((point) => _isValidLatLng(point.lat, point.lng))
        .toList(growable: false);
  }

  double _pathDistanceKm(List<({double lat, double lng})> points) {
    if (points.length < 2) return 0;
    var distanceMeters = 0.0;
    for (var index = 0; index < points.length - 1; index += 1) {
      distanceMeters += _distanceMeters(
        points[index].lat,
        points[index].lng,
        points[index + 1].lat,
        points[index + 1].lng,
      );
    }
    return distanceMeters / 1000;
  }

  JsonMap _adminReport(JsonMap report) {
    return <String, dynamic>{
      'id': _text(report['id']),
      'busNumber': _text(report['busNumber']),
      'lineCode': _normalizeCode(report['lineCode']),
      'lineLabel': _text(report['lineLabel']),
      'reporterId': _text(report['reporterId']),
      'reporterName': _text(report['reporterName']),
      'location': report['location'],
      'status': _text(report['status']),
      'createdAt': _text(report['createdAt']),
      'note': _text(report['note']),
      'confidence': _double(report['confidence']),
    };
  }

  List<JsonMap> _adminCatalogLines() {
    return _lines
        .map((line) {
          final code = _normalizeCode(line['route_short_name'] ?? line['code']);
          return <String, dynamic>{
            'lineCode': code,
            'displayCode': _displayCode(code),
            'title': _routeTitle(line),
            'colorValue': _colorValue(line['colour'], code),
          };
        })
        .where((line) => _text(line['lineCode']).isNotEmpty)
        .toList(growable: false);
  }

  List<JsonMap> _adminLineStats(List<JsonMap> trips, List<JsonMap> reports) {
    final statsByCode = <String, JsonMap>{};
    for (final line in _lines) {
      final code = _normalizeCode(line['route_short_name'] ?? line['code']);
      if (code.isEmpty) continue;
      statsByCode[code] = <String, dynamic>{
        'lineCode': code,
        'displayCode': _displayCode(code),
        'title': _routeTitle(line),
        'colorValue': _colorValue(line['colour'], code),
        'trips': 0,
        'activeTrips': 0,
        'observers': 0,
        'reports': 0,
        'distanceKm': 0.0,
      };
    }
    for (final trip in trips) {
      final code = _normalizeCode(trip['line_code'] ?? trip['lineCode']);
      final item = statsByCode[code] ??= <String, dynamic>{
        'lineCode': code,
        'displayCode': _displayCode(code),
        'title': '',
        'colorValue': _colorValue(null, code),
        'trips': 0,
        'activeTrips': 0,
        'observers': 0,
        'reports': 0,
        'distanceKm': 0.0,
      };
      item['trips'] = _int(item['trips']) + 1;
      item['observers'] = _int(item['observers']) + _int(trip['observers']);
      item['distanceKm'] =
          _double(item['distanceKm']) + _tripTravelledDistanceKm(trip);
      if (_text(trip['status']) == 'actif') {
        item['activeTrips'] = _int(item['activeTrips']) + 1;
      }
    }
    for (final report in reports) {
      final code = _normalizeCode(report['lineCode']);
      final item = statsByCode[code] ??= <String, dynamic>{
        'lineCode': code,
        'displayCode': _displayCode(code),
        'title': _text(report['lineLabel']),
        'colorValue': _colorValue(null, code),
        'trips': 0,
        'activeTrips': 0,
        'observers': 0,
        'reports': 0,
      };
      item['reports'] = _int(item['reports']) + 1;
    }
    return statsByCode.values.toList(growable: false)..sort((a, b) {
      final activeCompare = _int(
        b['activeTrips'],
      ).compareTo(_int(a['activeTrips']));
      if (activeCompare != 0) return activeCompare;
      return _int(b['trips']).compareTo(_int(a['trips']));
    });
  }

  JsonMap _activityEntry({
    required String id,
    required String title,
    required String subtitle,
    required String timestamp,
    required String iconKey,
    required int colorValue,
    Iterable<String> audienceSessionIds = const <String>[],
    Iterable<String> audienceUserIds = const <String>[],
  }) {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'timestamp': timestamp,
      'iconKey': iconKey,
      'colorValue': colorValue,
      'audienceSessionIds': audienceSessionIds.toList(growable: false),
      'audienceUserIds': audienceUserIds.toList(growable: false),
    };
  }

  JsonMap _normalizeState(JsonMap input, {bool pruneLegacyFixtures = false}) {
    final sessions = <String, JsonMap>{};
    final rawSessions = input['sessions'];
    if (rawSessions is Map) {
      for (final entry in rawSessions.entries) {
        final sessionId = entry.key?.toString().trim() ?? '';
        if (sessionId.isEmpty) continue;
        final value = entry.value;
        sessions[sessionId] = _normalizeSession(
          value is Map
              ? Map<String, dynamic>.from(value)
              : const <String, dynamic>{},
        );
      }
    }
    if (sessions.isEmpty && _hasLegacySessionFields(input)) {
      sessions['legacy-local'] = _normalizeSession(input);
    }

    final output = <String, dynamic>{
      'sessions': sessions,
      'users': _mapList(input['users']).map(_normalizeUser).toList(),
      'trips': _singleActiveTripPerOwner(
        _mapList(input['trips']).map(_normalizeTrip).toList(),
      ),
      'reports': _mapList(input['reports']).map(_normalizeReport).toList(),
      'pushTokens': _mapList(
        input['pushTokens'],
      ).map(_normalizePushToken).toList(),
      'activity': _mapList(input['activity']).map(_normalizeActivity).toList(),
      'messageConversations': _mapList(
        input['messageConversations'] ?? input['message_conversations'],
      ).map(_normalizeMessageConversation).toList(),
    };

    return pruneLegacyFixtures ? _pruneLegacyFixtures(output) : output;
  }

  JsonMap _pruneLegacyFixtures(JsonMap state) {
    const legacyUserIds = <String>{
      'u1',
      'u2',
      'u3',
      'u-etoile-001',
      'u-reporteur-001',
      'u-observateur-001',
    };
    const legacyUserEmails = <String>{
      'awa@piwibus.ci',
      'mamadou@piwibus.ci',
      'nadia@piwibus.ci',
      'observateur@piwibus.ci',
      'awa.kone@piwibus.ci',
      'mamadou.traore@piwibus.ci',
      'nadia.kouassi@piwibus.ci',
    };
    const legacyTripIds = <String>{'trip-84', 'trip-611', 'trip-206', 'trip-6'};
    const legacyReportIds = <String>{'r1', 'r2', 'r3'};
    const legacyReporterNames = <String>{
      'awa konate',
      'mamadou traore',
      'nadia kouassi',
      'awa koné',
      'mamadou traoré',
    };

    final users = _mapList(state['users']);
    final removedUserIds = <String>{};
    final cleanedUsers = <JsonMap>[];
    for (final user in users) {
      final userId = _text(user['id']);
      final email = _text(user['email']).toLowerCase();
      final isLegacy =
          legacyUserIds.contains(userId) || legacyUserEmails.contains(email);
      if (isLegacy) {
        removedUserIds.add(userId);
      } else {
        cleanedUsers.add(user);
      }
    }

    final cleanedTrips = _mapList(state['trips'])
        .where((trip) {
          final tripId = _text(trip['id']);
          final ownerId = _text(trip['owner_id']);
          final note = _text(trip['note']).toLowerCase();
          final liveLocation = trip['liveLocation'];
          final isMocked =
              liveLocation is Map &&
              (liveLocation['isMocked'] == true ||
                  liveLocation['is_mocked'] == true);
          return !legacyTripIds.contains(tripId) &&
              !removedUserIds.contains(ownerId) &&
              !note.contains('demonstration') &&
              !note.contains('démonstration') &&
              !isMocked;
        })
        .toList(growable: false);

    final cleanedReports = _mapList(state['reports'])
        .where((report) {
          final reportId = _text(report['id']);
          final reporterId = _text(report['reporterId']);
          final reporterName = _text(report['reporterName']).toLowerCase();
          return !legacyReportIds.contains(reportId) &&
              !removedUserIds.contains(reporterId) &&
              !legacyReporterNames.contains(reporterName);
        })
        .toList(growable: false);

    final validTripIds = cleanedTrips
        .map((trip) => _text(trip['id']))
        .where((id) => id.isNotEmpty)
        .toSet();
    final cleanedSessions = _sessionsFromRaw(state['sessions']).map((
      sessionId,
      session,
    ) {
      final normalized = _normalizeSession(session);
      final currentUser = normalized['currentUser'];
      if (currentUser is Map &&
          removedUserIds.contains(_text(currentUser['id']))) {
        normalized['currentUser'] = null;
        normalized['activeRole'] = 'etoile';
        normalized['section'] = 'accueil';
      }
      final selectedTripId = _text(normalized['selectedTripId']);
      if (selectedTripId.isNotEmpty && !validTripIds.contains(selectedTripId)) {
        normalized['selectedTripId'] = null;
      }
      return MapEntry(sessionId, normalized);
    });

    return <String, dynamic>{
      ...state,
      'sessions': cleanedSessions,
      'users': cleanedUsers,
      'trips': cleanedTrips,
      'reports': cleanedReports,
    };
  }

  Map<String, JsonMap> _sessionsFromRaw(Object? raw) {
    if (raw is! Map) return <String, JsonMap>{};
    return raw.map(
      (key, value) => MapEntry(
        key.toString(),
        value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{},
      ),
    );
  }

  bool _hasLegacySessionFields(JsonMap input) {
    return input.containsKey('currentUser') ||
        input.containsKey('activeRole') ||
        input.containsKey('section') ||
        input.containsKey('searchQuery') ||
        input.containsKey('selectedLineCode') ||
        input.containsKey('selectedTripId') ||
        input.containsKey('favoriteLineCodes');
  }

  JsonMap _normalizeSession(JsonMap input) {
    final currentUser = input['currentUser'] is Map
        ? _refreshPublicUser(Map<String, dynamic>.from(input['currentUser']))
        : null;
    final output = <String, dynamic>{
      'currentUser': currentUser,
      'activeRole': _normalizeRole(input['activeRole']?.toString()),
      'section': _normalizeSection(input['section']?.toString()),
      'isOnline': input['isOnline'] == true,
      'searchQuery': input['searchQuery']?.toString() ?? '',
      'selectedLineCode': input['selectedLineCode']?.toString(),
      'selectedTripId': input['selectedTripId']?.toString(),
      'favoriteLineCodes': _stringList(input['favoriteLineCodes']),
      'currentLocation': _normalizeCurrentLocation(input['currentLocation']),
      'createdAt': _dateValue(input['createdAt']),
      'lastSeenAt': _dateValue(input['lastSeenAt']),
    };

    if (output['activeRole'] == 'administrateur' &&
        !_userCanAdmin(output['currentUser'])) {
      output['activeRole'] = 'etoile';
      if (output['section'] == 'administration') {
        output['section'] = 'accueil';
      }
    }

    return output;
  }

  JsonMap _normalizeUser(JsonMap input) {
    return <String, dynamic>{
      'id': _text(input['id']),
      'fullName': _text(input['fullName']),
      'email': _text(input['email']),
      'phone': _text(input['phone']),
      'profilePhotoDataUrl': _nullableText(
        input['profilePhotoDataUrl'] ?? input['profile_photo_data_url'],
      ),
      'nameChangedAt': _dateValueOrNull(
        input['nameChangedAt'] ?? input['name_changed_at'],
      ),
      'primaryRole': _normalizeRole(input['primaryRole']?.toString()),
      'status': _normalizeUserStatus(input['status']?.toString()),
      'createdAt': _dateValue(input['createdAt']),
      'lastSeenAt': input['lastSeenAt'] == null
          ? null
          : _dateValue(input['lastSeenAt']),
      'passwordHash': _text(input['passwordHash']),
      'passwordResetHash': _text(input['passwordResetHash']),
      'passwordResetRequestedAt': _dateValueOrNull(
        input['passwordResetRequestedAt'],
      ),
      'passwordResetExpiresAt': _dateValueOrNull(
        input['passwordResetExpiresAt'],
      ),
      'passwordResetAttempts': _int(input['passwordResetAttempts']),
      'activityReadAt': _dateValueOrNull(input['activityReadAt']),
      'readAlertIds': _stringList(input['readAlertIds']),
      'starTripIds': _stringList(input['starTripIds']),
      'followedTripIds': _stringList(input['followedTripIds']),
    };
  }

  JsonMap _normalizeTrip(JsonMap input) {
    return <String, dynamic>{
      'id': _text(input['id']),
      'line_code': _normalizeCode(_text(input['line_code'])),
      'owner_id': _text(input['owner_id']),
      'owner_session_id': _text(
        input['owner_session_id'] ?? input['ownerSessionId'],
      ),
      'owner_name': _text(input['owner_name']),
      'owner_photo_data_url': _nullableText(
        input['owner_photo_data_url'] ?? input['ownerPhotoDataUrl'],
      ),
      'owner_role': _normalizeRole(input['owner_role']?.toString()),
      'status': _normalizeTripStatus(input['status']?.toString()),
      'startedAt': _dateValue(input['startedAt']),
      'lastUpdatedAt': _dateValue(input['lastUpdatedAt']),
      'progress': _double(input['progress']),
      'traveledDistanceMeters': _nonNegativeDoubleOrNull(
        input['traveledDistanceMeters'] ??
            input['traveled_distance_meters'] ??
            input['distanceMeters'] ??
            input['distance_meters'],
      ),
      'speedKmh': _double(input['speedKmh']),
      'observers': _int(input['observers']),
      'maxObservers': math.max(
        _int(input['maxObservers']),
        _int(input['observers']),
      ),
      'networkUsageBytes': _int(input['networkUsageBytes']),
      'ratingAverage': _double(input['ratingAverage']),
      'ratingCount': _int(input['ratingCount']),
      'likedByActorIds': _stringList(
        input['likedByActorIds'] ?? input['liked_by_actor_ids'],
      ),
      'note': _text(input['note']),
      'liveLocation': input['liveLocation'] == null
          ? null
          : _normalizeLiveLocation(input['liveLocation']),
      'offRouteSince': _dateValueOrNull(input['offRouteSince']),
      'offRouteDistanceMeters': input['offRouteDistanceMeters'] == null
          ? null
          : _double(input['offRouteDistanceMeters']),
      'path': _mapList(input['path']).map(_normalizeLatLng).toList(),
      'originLabel': _cleanTerminalLabel(_text(input['originLabel'])),
      'destinationLabel': _cleanTerminalLabel(_text(input['destinationLabel'])),
      'messages': _mapList(input['messages']).map(_normalizeMessage).toList(),
    };
  }

  List<JsonMap> _singleActiveTripPerOwner(List<JsonMap> trips) {
    final activeOwnerIds = <String>{};
    for (final trip in trips) {
      if (_text(trip['status']) != 'actif') continue;
      final ownerId = _text(trip['owner_id']);
      if (ownerId.isEmpty) continue;
      if (activeOwnerIds.add(ownerId)) continue;
      trip['status'] = 'termine';
      trip['lastUpdatedAt'] = _nowIso();
    }
    return trips;
  }

  JsonMap _normalizeMessage(JsonMap input) {
    return <String, dynamic>{
      'id': _text(input['id']),
      'tripId': _text(input['tripId']),
      'authorName': _text(input['authorName']),
      'role': _normalizeRole(input['role']?.toString()),
      'content': _text(input['content']),
      'createdAt': _dateValue(input['createdAt']),
      'isSystem': input['isSystem'] == true,
    };
  }

  JsonMap _normalizeMessageConversation(JsonMap input) {
    final participantIds = _stringList(
      input['participantIds'] ?? input['participant_ids'],
    ).toSet().toList(growable: false)..sort();
    final messages =
        _mapList(
            input['messages'],
          ).map(_normalizeMessageItem).toList(growable: false)
          ..sort((a, b) => _int(a['sequence']).compareTo(_int(b['sequence'])));
    final messageCursor = math.max(
      _int(input['messageCursor'] ?? input['message_cursor']),
      messages.fold<int>(
        0,
        (max, message) => math.max(max, _int(message['sequence'])),
      ),
    );
    return <String, dynamic>{
      'id': _text(input['id']),
      'kind': _text(input['kind']).isEmpty ? 'direct' : _text(input['kind']),
      'participantIds': participantIds,
      'tripId': _nullableText(input['tripId'] ?? input['trip_id']),
      'title': _text(input['title']),
      'subtitle': _text(input['subtitle']),
      'lastMessagePreview': _text(
        input['lastMessagePreview'] ?? input['last_message_preview'],
      ),
      'lastMessageId': _nullableText(
        input['lastMessageId'] ?? input['last_message_id'],
      ),
      'lastSenderId': _nullableText(
        input['lastSenderId'] ?? input['last_sender_id'],
      ),
      'messageCursor': messageCursor,
      'readSequences': _sequenceMap(
        input['readSequences'] ?? input['read_sequences'],
      ),
      'createdAt': _dateValue(input['createdAt'] ?? input['created_at']),
      'updatedAt': _dateValue(input['updatedAt'] ?? input['updated_at']),
      'messages': messages
          .map((message) {
            return <String, dynamic>{
              ...message,
              if (_text(message['conversationId']).isEmpty)
                'conversationId': _text(input['id']),
            };
          })
          .toList(growable: false),
    };
  }

  JsonMap _normalizeMessageItem(JsonMap input) {
    final body = _text(
      input['body'] ?? input['content'] ?? input['ciphertext'],
    );
    return <String, dynamic>{
      'id': _text(input['id'] ?? input['messageId'] ?? input['message_id']),
      'conversationId': _text(
        input['conversationId'] ?? input['conversation_id'],
      ),
      'senderId': _text(input['senderId'] ?? input['sender_id']),
      'senderName': _text(input['senderName'] ?? input['sender_name']),
      'body': body,
      'sequence': _int(input['sequence'] ?? input['message_order']),
      'createdAt': _dateValue(input['createdAt'] ?? input['created_at']),
    };
  }

  JsonMap _normalizeReport(JsonMap input) {
    final location = input['location'];
    final locationMap = location is Map<String, dynamic>
        ? location
        : const <String, dynamic>{};
    return <String, dynamic>{
      'id': _text(input['id']),
      'busNumber': _text(input['busNumber']),
      'lineCode': _normalizeCode(
        _text(input['lineCode']).isEmpty
            ? _text(input['busNumber'])
            : _text(input['lineCode']),
      ),
      'lineLabel': _text(input['lineLabel']),
      'reporterId': _text(input['reporterId'] ?? input['reporter_id']),
      'reporterName': _text(input['reporterName']),
      'location': <String, dynamic>{
        'lat': _double(locationMap['lat']),
        'lng': _double(locationMap['lng']),
      },
      'status': _normalizeReportStatus(input['status']?.toString()),
      'createdAt': _dateValue(input['createdAt']),
      'note': _text(input['note']),
      'confidence': _double(input['confidence']),
    };
  }

  JsonMap _normalizeActivity(JsonMap input) {
    final title = _text(input['title']);
    final subtitle = _text(input['subtitle']);
    final timestamp = _dateValue(input['timestamp']);
    final iconKey = _text(input['iconKey']);
    final colorValue = _int(input['colorValue']);
    final audienceSessionIds = _stringList(input['audienceSessionIds']);
    final audienceUserIds = _stringList(input['audienceUserIds']);
    final id = _text(input['id']);
    return <String, dynamic>{
      'id': id.isEmpty
          ? _legacyActivityId(
              title: title,
              subtitle: subtitle,
              timestamp: timestamp,
              iconKey: iconKey,
              colorValue: colorValue,
              audienceSessionIds: audienceSessionIds,
              audienceUserIds: audienceUserIds,
            )
          : id,
      'title': title,
      'subtitle': subtitle,
      'timestamp': timestamp,
      'iconKey': iconKey,
      'colorValue': colorValue,
      'audienceSessionIds': audienceSessionIds,
      'audienceUserIds': audienceUserIds,
    };
  }

  JsonMap _normalizePushToken(JsonMap input) {
    return <String, dynamic>{
      'id': _text(input['id']),
      'token': _text(input['token']),
      'platform': _text(input['platform']),
      'sessionId': _text(input['sessionId']),
      'userId': _text(input['userId']),
      'status': _text(input['status']) == 'disabled' ? 'disabled' : 'active',
      'appVersion': _text(input['appVersion']),
      'buildNumber': _text(input['buildNumber']),
      'androidAbi': _text(input['androidAbi']),
      'sdkInt': _int(input['sdkInt']),
      'is64BitProcess': input['is64BitProcess'] == true,
      'deviceModel': _text(input['deviceModel']),
      'createdAt': _dateValue(input['createdAt']),
      'lastSeenAt': _dateValue(input['lastSeenAt']),
    };
  }

  JsonMap _normalizeLatLng(JsonMap input) {
    return <String, dynamic>{
      'lat': _double(input['lat']),
      'lng': _double(input['lng']),
    };
  }

  JsonMap? _normalizeCurrentLocation(Object? value) {
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);
    final lat = _double(map['lat'] ?? map['latitude']);
    final lng = _double(map['lng'] ?? map['longitude']);
    if (!_isValidLatLng(lat, lng)) return null;
    return <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'accuracy': map['accuracy'] == null ? null : _double(map['accuracy']),
      'timestamp': _normalizedCurrentLocationTimestamp(
        map['timestamp'] ?? map['updatedAt'],
      ),
    };
  }

  String _normalizedCurrentLocationTimestamp(Object? value) {
    final timestamp = DateTime.tryParse(_text(value));
    final now = DateTime.now().toUtc();
    if (timestamp == null) return _nowIso();
    final timestampUtc = timestamp.toUtc();
    if (timestampUtc.isAfter(now.add(_liveLocationMaxFutureSkew))) {
      return _nowIso();
    }
    return timestampUtc.toIso8601String();
  }

  JsonMap _normalizeLiveLocation(Object? value) {
    final location = value is Map<String, dynamic>
        ? value
        : value is Map
        ? Map<String, dynamic>.from(value)
        : const <String, dynamic>{};
    return <String, dynamic>{
      'lat': _double(location['lat'] ?? location['latitude']),
      'lng': _double(location['lng'] ?? location['longitude']),
      'timestamp': _dateValue(location['timestamp'] ?? location['updatedAt']),
      'accuracy': location['accuracy'] == null
          ? null
          : _double(location['accuracy']),
      'heading': location['heading'] == null
          ? null
          : _double(location['heading']),
      'speed': location['speed'] == null ? null : _double(location['speed']),
      'isMocked': location['isMocked'] == true || location['is_mocked'] == true,
      'provider': _text(location['provider']).toLowerCase(),
    };
  }

  JsonMap _parseLiveLocationOrThrow(Object? value) {
    final normalized = _normalizeLiveLocation(value);
    final lat = _double(normalized['lat']);
    final lng = _double(normalized['lng']);
    if (!_isValidLatLng(lat, lng)) {
      throw StateError('Les coordonnées GPS sont invalides.');
    }
    _validateLiveLocationTimestampOrThrow(normalized);
    _validateLiveLocationQualityOrThrow(normalized);
    if (normalized['isMocked'] == true) {
      throw StateError(
        'Les positions GPS simulées ne sont pas acceptées pour un live.',
      );
    }
    return normalized;
  }

  void _validateLiveLocationOnRouteOrThrow(JsonMap line, JsonMap location) {
    final proximity = _routeProximityForLineLocation(line, location);
    if (proximity == null) return;
    if (proximity.distanceMeters <= proximity.toleranceMeters) return;
    throw StateError(
      'La position GPS initiale est hors du trace de la ligne '
      '${_displayCode(line['code'])} '
      '(${_metersLabel(proximity.distanceMeters)} du trace).',
    );
  }

  String? _updateLiveRouteGuard({
    required JsonMap trip,
    required JsonMap incomingLocation,
    required Object? currentLocation,
    required String receivedAt,
  }) {
    final line = lineByCode(_text(trip['line_code']));
    if (line == null) {
      trip.remove('offRouteSince');
      trip.remove('offRouteDistanceMeters');
      return null;
    }
    final proximity = _routeProximityForLineLocation(line, incomingLocation);
    if (proximity == null || !proximity.distanceMeters.isFinite) {
      trip.remove('offRouteSince');
      trip.remove('offRouteDistanceMeters');
      return null;
    }

    if (proximity.distanceMeters <= proximity.toleranceMeters) {
      trip.remove('offRouteSince');
      trip.remove('offRouteDistanceMeters');
      return null;
    }

    final checkedAt =
        DateTime.tryParse(receivedAt)?.toUtc() ?? DateTime.now().toUtc();
    final incomingSampleAt = _liveLocationTimestamp(incomingLocation);
    final previousServerAt = DateTime.tryParse(
      _text(trip['lastUpdatedAt']),
    )?.toUtc();
    final previousAt =
        _liveLocationTimestamp(currentLocation) ?? previousServerAt;
    final existingOffRouteSince = DateTime.tryParse(
      _text(trip['offRouteSince']),
    )?.toUtc();
    final resumedAfterLongGap =
        (previousAt != null &&
            incomingSampleAt != null &&
            incomingSampleAt.difference(previousAt) >=
                _liveOffRoutePersistenceDuration) ||
        (previousServerAt != null &&
            checkedAt.difference(previousServerAt) >=
                _liveOffRoutePersistenceDuration);
    final offRouteSince =
        existingOffRouteSince ??
        (resumedAfterLongGap
            ? checkedAt.subtract(_liveOffRoutePersistenceDuration)
            : checkedAt);

    trip['offRouteSince'] = offRouteSince.toIso8601String();
    trip['offRouteDistanceMeters'] = proximity.distanceMeters;

    if (checkedAt.difference(offRouteSince) <
        _liveOffRoutePersistenceDuration) {
      return null;
    }

    final lineLabel = _displayCode(_text(trip['line_code']));
    final distanceLabel = _metersLabel(proximity.distanceMeters);
    final durationLabel = _durationLabel(_liveOffRoutePersistenceDuration);
    final gapText = resumedAfterLongGap
        ? ' apres une reprise de connexion'
        : '';
    return 'Trajet live interrompu automatiquement : l\'Etoile de la ligne '
        '$lineLabel est hors du trace$gapText depuis au moins $durationLabel '
        '($distanceLabel du trace).';
  }

  DateTime? _liveLocationTimestamp(Object? value) {
    if (value is! Map) return null;
    return DateTime.tryParse(
      _text(value['timestamp'] ?? value['updatedAt']),
    )?.toUtc();
  }

  ({double distanceMeters, double toleranceMeters})?
  _routeProximityForLineLocation(JsonMap line, JsonMap location) {
    final lat = _double(location['lat'] ?? location['latitude']);
    final lng = _double(location['lng'] ?? location['longitude']);
    if (!_isValidLatLng(lat, lng)) return null;
    final segments = _lineSegments(line);
    if (segments.isEmpty) return null;
    final distanceMeters = _distanceMetersToSegments(lat, lng, segments);
    final toleranceMeters = math.max(
      _liveOffRouteBaseToleranceMeters,
      _locationAccuracyPaddingMeters(location['accuracy']) + 50,
    );
    return (distanceMeters: distanceMeters, toleranceMeters: toleranceMeters);
  }

  JsonMap _systemTripCancellationNotice(
    JsonMap trip, {
    required String reason,
    required String notificationType,
    Object? liveLocation,
  }) {
    final tripId = _text(trip['id']);
    final lineCode = _text(trip['line_code']);
    final lineLabel = _displayCode(lineCode);
    final lineName = _routeTitle(lineByCode(lineCode));
    final busLabel = lineName.isEmpty
        ? 'ligne $lineLabel'
        : 'ligne $lineLabel - $lineName';
    final audience = notificationAudienceForTrip(tripId);
    final location = liveLocation ?? trip['liveLocation'];
    final lat = location is Map
        ? _double(location['lat'] ?? location['latitude'])
        : double.nan;
    final lng = location is Map
        ? _double(location['lng'] ?? location['longitude'])
        : double.nan;
    final hasLastLocation = _isValidLatLng(lat, lng);
    return <String, dynamic>{
      'notificationType': notificationType,
      'tripId': tripId,
      'lineCode': lineCode,
      'lineLabel': busLabel,
      'reason': reason,
      'lastLocation': hasLastLocation
          ? <String, dynamic>{'lat': lat, 'lng': lng}
          : null,
      'tokens': audience.tokens,
      'audienceSessionIds': audience.sessionIds.toList(growable: false),
    };
  }

  void _markTripStoppedBySystem(
    JsonMap trip, {
    required String tripId,
    required String reason,
    required String stoppedAt,
  }) {
    trip['status'] = 'termine';
    trip['lastUpdatedAt'] = stoppedAt;
    trip.remove('offRouteSince');
    trip.remove('offRouteDistanceMeters');
    final messages = List<JsonMap>.from(trip['messages'] as List);
    messages.add(
      _message(
        id: _newEntityId('sys-stop-$tripId'),
        tripId: tripId,
        authorName: 'Systeme',
        role: 'administrateur',
        content: reason,
        createdAt: stoppedAt,
        isSystem: true,
      ),
    );
    trip['messages'] = messages;
  }

  String _metersLabel(double meters) {
    if (!meters.isFinite) return 'distance inconnue';
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.round()} m';
  }

  bool _isStaleLiveLocationUpdate(Object? current, JsonMap incoming) {
    if (current is! Map) return false;
    final currentTimestamp = DateTime.tryParse(
      _text(current['timestamp'] ?? current['updatedAt']),
    );
    final incomingTimestamp = DateTime.tryParse(
      _text(incoming['timestamp'] ?? incoming['updatedAt']),
    );
    if (currentTimestamp == null || incomingTimestamp == null) return false;
    final now = DateTime.now().toUtc();
    if (currentTimestamp.toUtc().isAfter(now.add(_liveLocationMaxFutureSkew))) {
      return false;
    }
    return !incomingTimestamp.toUtc().isAfter(currentTimestamp.toUtc());
  }

  bool _isImplausibleLiveLocationUpdate(Object? current, JsonMap incoming) {
    if (current is! Map) return false;
    final currentLat = _double(current['lat'] ?? current['latitude']);
    final currentLng = _double(current['lng'] ?? current['longitude']);
    final incomingLat = _double(incoming['lat'] ?? incoming['latitude']);
    final incomingLng = _double(incoming['lng'] ?? incoming['longitude']);
    if (!_isValidLatLng(currentLat, currentLng) ||
        !_isValidLatLng(incomingLat, incomingLng)) {
      return false;
    }
    final currentTimestamp = DateTime.tryParse(
      _text(current['timestamp'] ?? current['updatedAt']),
    );
    final incomingTimestamp = DateTime.tryParse(
      _text(incoming['timestamp'] ?? incoming['updatedAt']),
    );
    if (currentTimestamp == null || incomingTimestamp == null) return false;

    final elapsedSeconds =
        incomingTimestamp
            .toUtc()
            .difference(currentTimestamp.toUtc())
            .inMilliseconds /
        1000;
    if (elapsedSeconds <= 0) return false;

    final distanceMeters = _distanceMeters(
      currentLat,
      currentLng,
      incomingLat,
      incomingLng,
    );
    final allowedDistance = math.max(
      _liveLocationJumpGraceMeters,
      (_liveLocationMaxPlausibleSpeedMetersPerSecond * elapsedSeconds) +
          _locationAccuracyPaddingMeters(current['accuracy']) +
          _locationAccuracyPaddingMeters(incoming['accuracy']) +
          30,
    );
    return distanceMeters > allowedDistance;
  }

  void _validateLiveLocationTimestampOrThrow(JsonMap location) {
    final timestamp = DateTime.tryParse(_text(location['timestamp']));
    final now = DateTime.now().toUtc();
    if (timestamp == null) {
      location['timestamp'] = _nowIso();
      return;
    }
    final timestampUtc = timestamp.toUtc();
    if (timestampUtc.isAfter(now.add(_liveLocationMaxFutureSkew))) {
      location['timestamp'] = _nowIso();
      return;
    }
    if (now.difference(timestampUtc) > _liveLocationMaxSampleAge) {
      throw StateError('La position GPS est trop ancienne.');
    }
  }

  void _validateLiveLocationQualityOrThrow(JsonMap location) {
    final accuracy = location['accuracy'];
    if (accuracy == null) {
      throw StateError('La précision GPS est requise.');
    }
    final accuracyValue = _double(accuracy);
    if (!accuracyValue.isFinite ||
        accuracyValue <= 0 ||
        accuracyValue > _liveLocationMaxAccuracyMeters) {
      throw StateError('La précision GPS est insuffisante.');
    }
    location['accuracy'] = accuracyValue;
    if (_text(location['provider']) == 'network' && accuracyValue > 50) {
      throw StateError('La position réseau est trop approximative.');
    }

    final speed = location['speed'];
    if (speed != null) {
      final value = _double(speed);
      if (!value.isFinite ||
          value < 0 ||
          value > _liveLocationMaxPlausibleSpeedMetersPerSecond) {
        location['speed'] = null;
      }
    }

    final heading = location['heading'];
    if (heading != null) {
      final value = _double(heading);
      if (!value.isFinite) {
        location['heading'] = null;
      } else {
        location['heading'] = value % 360;
      }
    }
  }

  double _locationAccuracyPaddingMeters(Object? value) {
    if (value == null) return 0;
    final accuracy = _double(value);
    if (!accuracy.isFinite || accuracy <= 0) return 0;
    return accuracy;
  }

  String _durationLabel(Duration duration) {
    if (duration.inMinutes >= 1) {
      final minutes = duration.inMinutes;
      final remainderSeconds = duration.inSeconds - minutes * 60;
      if (remainderSeconds == 0) return '$minutes min';
      return '$minutes min $remainderSeconds s';
    }
    return '${duration.inSeconds} s';
  }

  JsonMap _parseLatLngOrThrow(Object? value) {
    final map = value is Map<String, dynamic>
        ? value
        : value is Map
        ? Map<String, dynamic>.from(value)
        : const <String, dynamic>{};
    final lat = _double(map['lat'] ?? map['latitude']);
    final lng = _double(map['lng'] ?? map['longitude']);
    if (!_isValidLatLng(lat, lng)) {
      throw StateError('Les coordonnées GPS sont invalides.');
    }
    return <String, dynamic>{'lat': lat, 'lng': lng};
  }

  bool _isValidLatLng(double lat, double lng) {
    if (lat.isNaN || lng.isNaN) return false;
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  bool _activityVisibleToSession(JsonMap activity, String sessionId) {
    final sessionAudience = _stringList(activity['audienceSessionIds']);
    if (sessionAudience.contains(sessionId)) return true;

    final session = _session(sessionId);
    final user = _currentUser(session);
    final userId = _text(user?['id']);
    final userAudience = _stringList(activity['audienceUserIds']);
    if (userId.isNotEmpty && userAudience.contains(userId)) return true;

    if (sessionAudience.isNotEmpty) {
      if (user != null) {
        for (final legacySessionId in _sessionIdsForUser(user)) {
          if (sessionAudience.contains(legacySessionId)) return true;
        }
      }
      return false;
    }
    if (userAudience.isNotEmpty) return false;
    if (!_activityLooksPrivate(activity)) return true;

    final email = _text(user?['email']).toLowerCase();
    if (email.isEmpty) return false;
    final text = '${_text(activity['title'])} ${_text(activity['subtitle'])}'
        .toLowerCase();
    return text.contains(email);
  }

  bool _activityLooksPrivate(JsonMap activity) {
    final iconKey = _text(activity['iconKey']).toLowerCase();
    if (const {'auth', 'admin', 'moderation'}.contains(iconKey)) return true;
    final text = '${_text(activity['title'])} ${_text(activity['subtitle'])}'
        .toLowerCase();
    const privateMarkers = <String>[
      'mot de passe',
      'reinitialisation',
      'réinitialisation',
      'connexion admin',
      'compte module',
      'compte modulé',
      'gouvernance',
      'signalement modere',
      'signalement modéré',
      'signalement supprime',
      'signalement supprimé',
      'notification admin',
    ];
    return privateMarkers.any(text.contains);
  }

  Set<String> _sessionsNearLine(JsonMap line, {required double radiusMeters}) {
    return _sessionsNearSegments(
      _lineSegments(line),
      radiusMeters: radiusMeters,
    );
  }

  Set<String> _sessionsNearSegments(
    List<List<({double lat, double lng})>> segments, {
    required double radiusMeters,
    Duration? freshness,
  }) {
    if (segments.isEmpty) return <String>{};
    final result = <String>{};
    final now = DateTime.now();
    final effectiveRadius = normalizePeerSearchRadiusMeters(radiusMeters);
    final effectiveFreshness = freshness ?? _currentLocationFreshness;
    for (final entry in _sessions().entries) {
      final session = entry.value;
      if (!isPeerPresenceFresh(
        lastSeenAt: session['lastSeenAt'],
        now: now,
        freshness: effectiveFreshness,
      )) {
        continue;
      }
      final locationCandidate = selectPeerSearchLocation(
        sessionLocation: session['currentLocation'],
        now: now,
        freshness: effectiveFreshness,
      );
      if (locationCandidate == null) continue;
      final distance = _distanceMetersToSegments(
        locationCandidate.lat,
        locationCandidate.lng,
        segments,
      );
      if (distance.isFinite && distance <= effectiveRadius) {
        result.add(entry.key);
      }
    }
    return result;
  }

  List<List<({double lat, double lng})>> _lineSegments(JsonMap line) {
    return routeSegmentsFromGeometry(
      geometry: _text(line['geometry']),
      shape: _text(line['shape']),
    );
  }

  double _distanceMetersToSegments(
    double lat,
    double lng,
    List<List<({double lat, double lng})>> segments,
  ) {
    return distanceMetersToRouteSegments(lat, lng, segments);
  }

  List<JsonMap> _mapList(Object? value) {
    if (value is! List) return <JsonMap>[];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return <String>[];
    return value
        .map((item) => item?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .toList();
  }

  List<JsonMap> _users() => _mapList(_state['users']);
  List<JsonMap> _trips() => _mapList(_state['trips']);
  List<JsonMap> _reports() => _mapList(_state['reports']);
  List<JsonMap> _activityItems() => _mapList(_state['activity']);
  List<JsonMap> _messageConversations() =>
      _mapList(_state['messageConversations']);
  Map<String, JsonMap> _sessions() {
    final raw = _state['sessions'];
    if (raw is! Map) return <String, JsonMap>{};
    return raw.map(
      (key, value) => MapEntry(
        key.toString(),
        value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{},
      ),
    );
  }

  JsonMap _session(String sessionId) {
    final sessions = _sessions();
    final existing = sessions[sessionId];
    if (existing == null) return _defaultSessionState();
    final normalized = _normalizeSession(existing);
    if (_sessionIsExpired(normalized)) return _defaultSessionState();
    return normalized;
  }

  void _putSession(String sessionId, JsonMap session) {
    final sessions = _sessions();
    sessions[sessionId] = _normalizeSession(session);
    _state['sessions'] = sessions;
  }

  JsonMap _defaultSessionState() {
    return <String, dynamic>{
      'currentUser': null,
      'activeRole': 'etoile',
      'section': 'carte',
      'searchQuery': '',
      'selectedLineCode': null,
      'selectedTripId': null,
      'favoriteLineCodes': <String>[],
      'currentLocation': null,
      'createdAt': _nowIso(),
      'lastSeenAt': _nowIso(),
      'isOnline': false,
    };
  }

  String _rotateSessionId(
    String previousSessionId,
    JsonMap sourceSession, {
    bool clearCurrentUser = false,
  }) {
    final sessions = _sessions();
    sessions.remove(previousSessionId);
    final nextSessionId = _newSessionId();
    final normalized = _normalizeSession(sourceSession);
    if (clearCurrentUser) {
      normalized['currentUser'] = null;
      normalized['activeRole'] = 'etoile';
      normalized['section'] = 'accueil';
    }
    normalized['createdAt'] = _nowIso();
    normalized['lastSeenAt'] = _nowIso();
    sessions[nextSessionId] = normalized;
    _state['sessions'] = sessions;
    return nextSessionId;
  }

  bool _adoptSessionStarTrips(String sessionId, JsonMap user) {
    final sessionOwnerId = 'session-$sessionId';
    final userId = _text(user['id']);
    if (userId.isEmpty) return false;
    final trips = _trips();
    var tripsChanged = false;
    for (final trip in trips) {
      if (!_isStarHistoryTrip(trip)) continue;
      final ownerSessionId = _text(trip['owner_session_id']);
      final ownerId = _text(trip['owner_id']);
      if (ownerId != sessionOwnerId &&
          !(ownerId.isEmpty && ownerSessionId == sessionOwnerId)) {
        continue;
      }
      final tripId = _text(trip['id']);
      trip['owner_id'] = userId;
      trip['owner_session_id'] = sessionOwnerId;
      trip['owner_name'] = _text(user['fullName']).isEmpty
          ? _text(trip['owner_name'])
          : _text(user['fullName']);
      trip['owner_photo_data_url'] = _nullableText(user['profilePhotoDataUrl']);
      if (_text(trip['status']) == 'actif') {
        trip['owner_role'] = _initialActiveRoleFor(user);
      }
      _rememberStarTripForUserId(userId, tripId);
      tripsChanged = true;
    }
    if (tripsChanged) {
      _state['trips'] = trips;
    }
    return tripsChanged;
  }

  bool _refreshUserOwnedTripProfiles(JsonMap user) {
    final userId = _text(user['id']);
    if (userId.isEmpty) return false;
    final trips = _trips();
    var changed = false;
    for (final trip in trips) {
      if (_text(trip['owner_id']) != userId) continue;
      trip['owner_name'] = _text(user['fullName']).isEmpty
          ? _text(trip['owner_name'])
          : _text(user['fullName']);
      trip['owner_photo_data_url'] = _nullableText(user['profilePhotoDataUrl']);
      changed = true;
    }
    if (changed) {
      _state['trips'] = trips;
    }
    return changed;
  }

  List<JsonMap> _stopActiveTripsOwnedBySession(
    String sessionId,
    JsonMap session, {
    required String reason,
    required String notificationType,
  }) {
    final ownerSessionId = 'session-$sessionId';
    final ownerIds = <String>{ownerSessionId};
    final currentUserId = _text(_currentUser(session)?['id']);
    if (currentUserId.isNotEmpty) {
      ownerIds.add(currentUserId);
    }
    final trips = _trips();
    final now = _nowIso();
    final notices = <JsonMap>[];
    for (final trip in trips) {
      if (_text(trip['status']) != 'actif') continue;
      final tripOwnerSessionId = _text(trip['owner_session_id']);
      if (tripOwnerSessionId.isNotEmpty) {
        if (tripOwnerSessionId != ownerSessionId) continue;
      } else if (!ownerIds.contains(_text(trip['owner_id']))) {
        continue;
      }
      final tripId = _text(trip['id']);
      final notice = _systemTripCancellationNotice(
        trip,
        reason: reason,
        notificationType: notificationType,
      );
      _markTripStoppedBySystem(
        trip,
        tripId: tripId,
        reason: reason,
        stoppedAt: now,
      );
      addActivity(
        title: 'Trajet live arrêté',
        subtitle: reason,
        iconKey: 'stop',
        colorValue: 0xFFD1495B,
        audienceSessionIds: _stringList(notice['audienceSessionIds']),
      );
      notices.add(notice);
    }
    if (notices.isNotEmpty) {
      _state['trips'] = trips;
    }
    return notices;
  }

  bool _sessionIsExpired(JsonMap session) {
    if (session['currentUser'] is Map) return false;
    final createdAt = DateTime.tryParse(_text(session['createdAt']));
    final lastSeenAt = DateTime.tryParse(_text(session['lastSeenAt']));
    final now = DateTime.now();
    if (createdAt == null || lastSeenAt == null) return true;
    if (now.difference(createdAt) > _anonymousSessionAbsoluteTimeout) {
      return true;
    }
    if (now.difference(lastSeenAt) > _anonymousSessionIdleTimeout) return true;
    return false;
  }

  Set<String> _retainedCompletedTripIds(List<JsonMap> trips, DateTime now) {
    final candidates =
        trips
            .where((trip) => _text(trip['status']) != 'actif')
            .where((trip) => _text(trip['id']).isNotEmpty)
            .where(
              (trip) => !_isOlderThan(
                trip['lastUpdatedAt'] ?? trip['startedAt'],
                now,
                _completedTripRetention,
              ),
            )
            .toList(growable: false)
          ..sort(
            (a, b) => _dateOrEpoch(
              b['lastUpdatedAt'] ?? b['startedAt'],
            ).compareTo(_dateOrEpoch(a['lastUpdatedAt'] ?? a['startedAt'])),
          );
    return candidates
        .take(_maxRetainedCompletedTrips)
        .map((trip) => _text(trip['id']))
        .toSet();
  }

  List<JsonMap> _retainedTripMessages(List<JsonMap> messages, DateTime now) {
    if (messages.isEmpty) return messages;
    final retained = messages
        .where(
          (message) =>
              !_isOlderThan(message['createdAt'], now, _tripMessageRetention),
        )
        .toList(growable: true);
    if (retained.isEmpty) {
      retained.add(messages.last);
    }
    if (retained.length <= _maxRetainedMessagesPerTrip) {
      return retained.toList(growable: false);
    }
    return retained
        .skip(retained.length - _maxRetainedMessagesPerTrip)
        .toList(growable: false);
  }

  Set<String> _retainedReportIds(List<JsonMap> reports, DateTime now) {
    final candidates =
        reports
            .where((report) => _text(report['id']).isNotEmpty)
            .where(
              (report) =>
                  !_isOlderThan(report['createdAt'], now, _reportRetention),
            )
            .toList(growable: false)
          ..sort(
            (a, b) => _dateOrEpoch(
              b['createdAt'],
            ).compareTo(_dateOrEpoch(a['createdAt'])),
          );
    return candidates
        .take(_maxRetainedReports)
        .map((report) => _text(report['id']))
        .toSet();
  }

  bool _isOlderThan(Object? value, DateTime now, Duration retention) {
    final date = DateTime.tryParse(_text(value));
    if (date == null) return false;
    return now.difference(date.toUtc()) > retention;
  }

  DateTime _dateOrEpoch(Object? value) {
    return DateTime.tryParse(_text(value))?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  bool _sessionNeedsRotation(String sessionId, JsonMap session) {
    if (session['currentUser'] is Map) return false;
    if (_hasActiveTripOwnedBySession(sessionId)) return false;
    final createdAt = DateTime.tryParse(_text(session['createdAt']));
    if (createdAt == null) return true;
    return DateTime.now().difference(createdAt) > _sessionRotationInterval;
  }

  bool _hasActiveTripOwnedBySession(String sessionId) {
    final ownerId = 'session-$sessionId';
    return _trips().any(
      (trip) =>
          _text(trip['status']) == 'actif' &&
          (_text(trip['owner_session_id']) == ownerId ||
              _text(trip['owner_id']) == ownerId),
    );
  }

  bool _sessionNeedsTouch(JsonMap session) {
    final lastSeenAt = DateTime.tryParse(_text(session['lastSeenAt']));
    if (lastSeenAt == null) return true;
    return DateTime.now().difference(lastSeenAt) > _sessionTouchInterval;
  }

  void setSessionLastSeenAtForTesting(String sessionId, String lastSeenAt) {
    final sessions = _sessions();
    final session = sessions[sessionId];
    if (session == null) return;
    session['lastSeenAt'] = lastSeenAt;
    _state['sessions'] = sessions;
  }

  void setUserLastSeenAtForTesting(String userId, String lastSeenAt) {
    final users = _users();
    for (var index = 0; index < users.length; index++) {
      if (_text(users[index]['id']) != userId) continue;
      users[index] = {...users[index], 'lastSeenAt': lastSeenAt};
    }
    _state['users'] = users;
  }

  bool _pruneExpiredSessions(Map<String, JsonMap> sessions) {
    final expiredIds = <String>[];
    for (final entry in sessions.entries) {
      if (_sessionIsExpired(_normalizeSession(entry.value))) {
        expiredIds.add(entry.key);
      }
    }
    if (expiredIds.isEmpty) return false;
    for (final id in expiredIds) {
      sessions.remove(id);
    }
    return true;
  }

  JsonMap? _refreshPublicUser(Object? user) {
    if (user is! Map) return null;
    final publicUser = Map<String, dynamic>.from(user);
    final id = _text(publicUser['id']);
    final email = _text(publicUser['email']).toLowerCase();
    for (final candidate in _users()) {
      if ((id.isNotEmpty && _text(candidate['id']) == id) ||
          (email.isNotEmpty &&
              _text(candidate['email']).toLowerCase() == email)) {
        return _publicUser(candidate);
      }
    }
    return publicUser;
  }

  void _refreshUserInSessions(JsonMap user) {
    final userId = _text(user['id']);
    final email = _text(user['email']).toLowerCase();
    if (userId.isEmpty && email.isEmpty) return;
    final publicUser = _publicUser(user);
    final sessions = _sessions();
    var changed = false;
    for (final entry in sessions.entries) {
      final currentUser = entry.value['currentUser'];
      if (currentUser is! Map) continue;
      final currentUserId = _text(currentUser['id']);
      final currentEmail = _text(currentUser['email']).toLowerCase();
      final sameUser =
          (userId.isNotEmpty && currentUserId == userId) ||
          (email.isNotEmpty && currentEmail == email);
      if (!sameUser) continue;
      entry.value['currentUser'] = publicUser;
      changed = true;
    }
    if (changed) {
      _state['sessions'] = sessions;
    }
  }

  List<String> _favoriteCodes(JsonMap session) =>
      _stringList(session['favoriteLineCodes']);

  String _tripLikeActorId(String sessionId) {
    final userId = _text(_currentUser(_session(sessionId))?['id']);
    return userId.isEmpty ? _tripSessionLikeActorId(sessionId) : 'user-$userId';
  }

  String _tripSessionLikeActorId(String sessionId) => 'session-$sessionId';

  String _tripRatingActorId(String sessionId) {
    final userId = _text(_currentUser(_session(sessionId))?['id']);
    return userId.isEmpty ? _tripSessionLikeActorId(sessionId) : 'user-$userId';
  }

  List<String> _tripLikeActorIds(JsonMap trip) {
    final ids = _stringList(
      trip['likedByActorIds'] ?? trip['liked_by_actor_ids'],
    ).toSet().toList(growable: false);
    ids.sort();
    return ids;
  }

  int _tripLikeCount(JsonMap trip) => _tripLikeActorIds(trip).length;

  bool _tripLikedBySession(List<String> likedByActorIds, String sessionId) {
    return likedByActorIds.contains(_tripLikeActorId(sessionId)) ||
        likedByActorIds.contains(_tripSessionLikeActorId(sessionId));
  }

  bool _tripRatedBySession(List<String> ratedByActorIds, String sessionId) {
    return ratedByActorIds.contains(_tripRatingActorId(sessionId)) ||
        ratedByActorIds.contains(_tripSessionLikeActorId(sessionId));
  }

  JsonMap? _currentUser(JsonMap session) {
    final user = session['currentUser'];
    return user is Map<String, dynamic>
        ? Map<String, dynamic>.from(user)
        : null;
  }

  String _authenticatedUserId(String sessionId) {
    final currentUserId = _text(_currentUser(_session(sessionId))?['id']);
    if (currentUserId.isEmpty) {
      throw StateError('Authentification requise.');
    }
    return currentUserId;
  }

  bool _sessionUserCanAdmin(JsonMap session) =>
      _userCanAdmin(_currentUser(session));

  Set<String> _sessionIdsForUser(JsonMap user) {
    final userId = _text(user['id']);
    final email = _text(user['email']).toLowerCase();
    if (userId.isEmpty && email.isEmpty) return <String>{};
    return _sessions().entries
        .where((entry) {
          final currentUser = entry.value['currentUser'];
          if (currentUser is! Map) return false;
          final currentUserId = _text(currentUser['id']);
          final currentEmail = _text(currentUser['email']).toLowerCase();
          return (userId.isNotEmpty && currentUserId == userId) ||
              (email.isNotEmpty && currentEmail == email);
        })
        .map((entry) => entry.key)
        .toSet();
  }

  Set<String> _userIdsForSessionAudience(Iterable<String> sessionIds) {
    final sessions = _sessions();
    final result = <String>{};
    for (final sessionId in sessionIds) {
      final currentUser = sessions[sessionId]?['currentUser'];
      if (currentUser is! Map) continue;
      final userId = _text(currentUser['id']);
      if (userId.isNotEmpty) result.add(userId);
    }
    return result;
  }

  Set<String> _adminSessionIds({String? includeSessionId}) {
    final ids = _sessions().entries
        .where((entry) => _sessionUserCanAdmin(entry.value))
        .map((entry) => entry.key)
        .toSet();
    final extra = _text(includeSessionId);
    if (extra.isNotEmpty) ids.add(extra);
    return ids;
  }

  bool _canManageTrip(String sessionId, JsonMap session, JsonMap trip) {
    if (_sessionUserCanAdmin(session)) return true;
    return _sessionOwnsOwnerId(sessionId, session, _text(trip['owner_id']));
  }

  bool _canUpdateTripLocation(String sessionId, JsonMap session, JsonMap trip) {
    if (_sessionUserCanAdmin(session)) return true;
    final ownerSessionId = _text(trip['owner_session_id']);
    if (ownerSessionId.isNotEmpty) {
      return ownerSessionId == 'session-$sessionId';
    }
    return _sessionOwnsOwnerId(sessionId, session, _text(trip['owner_id']));
  }

  bool _sessionOwnsOwnerId(String sessionId, JsonMap session, String ownerId) {
    final normalizedOwnerId = _text(ownerId);
    if (normalizedOwnerId.isEmpty) return false;
    final currentUserId = _text(_currentUser(session)?['id']);
    if (currentUserId.isNotEmpty && normalizedOwnerId == currentUserId) {
      return true;
    }
    return normalizedOwnerId == 'session-$sessionId';
  }

  void _requireAdmin(String sessionId) {
    final session = _session(sessionId);
    if (_text(session['activeRole']) != 'administrateur' ||
        !_sessionUserCanAdmin(session)) {
      throw StateError('Accès administrateur requis.');
    }
  }

  String _initialActiveRoleFor(JsonMap user) => 'etoile';

  static bool _userCanAdmin(Object? user) {
    if (user is! Map) return false;
    final map = Map<String, dynamic>.from(user);
    return _normalizeRole(map['primaryRole']?.toString()) == 'administrateur' &&
        _normalizeUserStatus(map['status']?.toString()) == 'actif';
  }

  void addActivity({
    required String title,
    required String subtitle,
    required String iconKey,
    required int colorValue,
    Iterable<String> audienceSessionIds = const <String>[],
    Iterable<String> audienceUserIds = const <String>[],
    bool isPublic = false,
  }) {
    final audience = audienceSessionIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final userAudience = <String>{
      ...audienceUserIds.map((id) => id.trim()).where((id) => id.isNotEmpty),
      ..._userIdsForSessionAudience(audience),
    }.toList(growable: false);
    final entryLooksPrivate = _activityLooksPrivate(<String, dynamic>{
      'title': title,
      'subtitle': subtitle,
      'iconKey': iconKey,
    });
    if (audience.isEmpty &&
        userAudience.isEmpty &&
        (!isPublic || entryLooksPrivate)) {
      return;
    }
    final activity = _activityItems();
    activity.insert(
      0,
      _activityEntry(
        id: _newEntityId('act'),
        title: title,
        subtitle: subtitle,
        timestamp: _nowIso(),
        iconKey: iconKey,
        colorValue: colorValue,
        audienceSessionIds: audience,
        audienceUserIds: userAudience,
      ),
    );
    _state['activity'] = activity;
  }

  Future<void> publishActivity({
    required String title,
    required String subtitle,
    required String iconKey,
    required int colorValue,
    Iterable<String> audienceSessionIds = const <String>[],
    Iterable<String> audienceUserIds = const <String>[],
    bool isPublic = false,
  }) async {
    addActivity(
      title: title,
      subtitle: subtitle,
      iconKey: iconKey,
      colorValue: colorValue,
      audienceSessionIds: audienceSessionIds,
      audienceUserIds: audienceUserIds,
      isPublic: isPublic,
    );
    _notifySharedChange();
    await _persist(const StateMutationBatch(activity: true));
  }

  /// Enregistre l'instant auquel l'utilisateur authentifié de [sessionId]
  /// a lu ses activités. Persiste en base — survit à la désinstallation.
  Future<String> setActivityReadAt(String sessionId) async {
    final session = _sessions()[sessionId];
    if (session == null) throw StateError('Session introuvable.');
    final currentUserId = _nullableText(session['currentUser']?['id']);
    if (currentUserId == null || currentUserId.isEmpty) {
      throw StateError('Authentification requise.');
    }
    final users = _users();
    final index = users.indexWhere((u) => _text(u['id']) == currentUserId);
    if (index < 0) throw StateError('Utilisateur introuvable.');
    final now = _nowIso();
    users[index] = {...users[index], 'activityReadAt': now};
    _state['users'] = users;
    _refreshUserInSessions(users[index]);
    _notifySharedChange();
    await _persist(const StateMutationBatch(users: true, sessions: true));
    return now;
  }

  /// Marque l'alerte [reportId] comme lue pour l'utilisateur de [sessionId].
  /// Persiste dans `read_alert_ids` (tableau Postgres) — survit à la réinstall.
  Future<void> markAlertRead(String sessionId, String reportId) async {
    final session = _sessions()[sessionId];
    if (session == null) throw StateError('Session introuvable.');
    final currentUserId = _nullableText(session['currentUser']?['id']);
    if (currentUserId == null || currentUserId.isEmpty) {
      throw StateError('Authentification requise.');
    }
    if (reportId.trim().isEmpty) throw StateError('reportId invalide.');
    final users = _users();
    final index = users.indexWhere((u) => _text(u['id']) == currentUserId);
    if (index < 0) throw StateError('Utilisateur introuvable.');
    final existing = List<String>.from(
      (users[index]['readAlertIds'] as List?) ?? const [],
    );
    if (!existing.contains(reportId)) {
      existing.add(reportId);
      users[index] = {...users[index], 'readAlertIds': existing};
      _state['users'] = users;
      _refreshUserInSessions(users[index]);
      _notifySharedChange();
      await _persist(const StateMutationBatch(users: true, sessions: true));
    }
  }

  Future<void> _saveState() async {
    await _persistence.saveState(_state);
  }

  Future<void> _persist(StateMutationBatch batch) async {
    await _persistence.applyMutations(state: _state, batch: batch);
  }

  Future<void> close() async {
    await _externalChangeSubscription?.cancel();
    await _sharedChanges.close();
    await _persistence.close();
  }

  void _notifySharedChange({bool publishExternal = true}) {
    _sharedRevision += 1;
    if (!_sharedChanges.isClosed) {
      _sharedChanges.add(_sharedRevision);
    }
    final publish = _publishSharedChange;
    if (publishExternal && publish != null) {
      unawaited(
        publish().catchError((_) {
          // Redis/pubsub publication is best-effort; persistence already won.
        }),
      );
    }
  }

  static String _normalizeHeader(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll('"', '');
  }

  static String _normalizeCode(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return text;
    return int.tryParse(text) != null ? int.parse(text).toString() : text;
  }

  static int _compareCodes(String a, String b) {
    final ai = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), ''));
    final bi = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), ''));
    if (ai != null && bi != null) return ai.compareTo(bi);
    return a.compareTo(b);
  }

  static String _normalizeRole(String? value) {
    final candidate = value?.trim().toLowerCase() ?? '';
    const allowed = {'observateur', 'etoile', 'reporteur', 'administrateur'};
    return allowed.contains(candidate) ? candidate : 'etoile';
  }

  static String _normalizeSection(String? value) {
    final candidate = value?.trim().toLowerCase() ?? '';
    const allowed = {
      'accueil',
      'carte',
      'trajets',
      'signalements',
      'messagerie',
      'administration',
    };
    return allowed.contains(candidate) ? candidate : 'carte';
  }

  static String _normalizeTripStatus(String? value) {
    final candidate = value?.trim().toLowerCase() ?? '';
    return candidate == 'termine' ? 'termine' : 'actif';
  }

  static String _normalizeReportStatus(String? value) {
    final candidate = value?.trim().toLowerCase() ?? '';
    return switch (candidate) {
      'valide' => 'valide',
      'refuse' => 'refuse',
      _ => 'enAttente',
    };
  }

  static String _normalizeUserStatus(String? value) {
    final candidate = value?.trim().toLowerCase() ?? '';
    return candidate == 'suspendu' ? 'suspendu' : 'actif';
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';
  static String? _nullableText(Object? value) =>
      value == null ? null : value.toString().trim();
  static String _boundedText(
    Object? value,
    int maxLength, {
    required String fieldName,
  }) {
    final text = _text(value);
    if (text.length > maxLength) {
      throw StateError('$fieldName trop long.');
    }
    return text;
  }

  static String _clientIdOrEmpty(Object? value, {required String fieldName}) {
    final text = _boundedText(value, _maxClientIdLength, fieldName: fieldName);
    if (text.isEmpty) return '';
    if (!RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(text)) {
      throw StateError('$fieldName invalide.');
    }
    return text;
  }

  static String _clientTimestampOrNow(
    Object? value, {
    required String fieldName,
    Duration maxPast = const Duration(days: 7),
    Duration maxFuture = const Duration(minutes: 10),
  }) {
    final text = _text(value);
    if (text.isEmpty) return _nowIso();
    final parsed = DateTime.tryParse(text);
    if (parsed == null) {
      throw StateError('$fieldName invalide.');
    }
    final now = DateTime.now().toUtc();
    final utc = parsed.toUtc();
    if (utc.isBefore(now.subtract(maxPast)) ||
        utc.isAfter(now.add(maxFuture))) {
      throw StateError('$fieldName hors fenetre autorisee.');
    }
    return utc.toIso8601String();
  }

  static double _double(Object? value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;
  static bool _isStaticValidLatLng(double lat, double lng) {
    if (!lat.isFinite || !lng.isFinite) return false;
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  static double? _nonNegativeDoubleOrNull(Object? value) {
    if (value == null) return null;
    final parsed = double.tryParse(value.toString());
    if (parsed == null || !parsed.isFinite || parsed < 0) return null;
    return parsed;
  }

  static int _int(Object? value) => int.tryParse(value?.toString() ?? '') ?? 0;

  static String _dateValue(Object? value) {
    if (value == null) return _nowIso();
    final text = value.toString();
    if (text.isEmpty) return _nowIso();
    return DateTime.tryParse(text)?.toIso8601String() ?? _nowIso();
  }

  static String? _dateValueOrNull(Object? value) {
    if (value == null) return null;
    final text = value.toString();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text)?.toIso8601String();
  }

  static String _nowIso() => DateTime.now().toIso8601String();

  static String _newSessionId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _newEntityId(String prefix) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = math.Random.secure();
    final randomSegment = StringBuffer();
    for (var index = 0; index < 8; index += 1) {
      randomSegment.write(alphabet[random.nextInt(alphabet.length)]);
    }
    return '$prefix-${randomSegment.toString()}';
  }

  static String _legacyActivityId({
    required String title,
    required String subtitle,
    required String timestamp,
    required String iconKey,
    required int colorValue,
    required List<String> audienceSessionIds,
    required List<String> audienceUserIds,
  }) {
    final payload = jsonEncode(<String, dynamic>{
      'title': title,
      'subtitle': subtitle,
      'timestamp': timestamp,
      'iconKey': iconKey,
      'colorValue': colorValue,
      'audienceSessionIds': audienceSessionIds,
      'audienceUserIds': audienceUserIds,
    });
    return 'act-legacy-${sha1.convert(utf8.encode(payload))}';
  }

  static String _newPasswordResetCode() {
    final random = math.Random.secure();
    return (100000 + random.nextInt(900000)).toString();
  }

  static void _clearPasswordReset(JsonMap user) {
    user.remove('passwordResetHash');
    user.remove('passwordResetRequestedAt');
    user.remove('passwordResetExpiresAt');
    user.remove('passwordResetAttempts');
  }

  static String _hashPassword(String email, String password) {
    final normalizedEmail = email.trim().toLowerCase();
    final secret = '$normalizedEmail::$password';
    final hash = BCrypt.hashpw(secret, BCrypt.gensalt(logRounds: 12));
    return 'bcrypt:$hash';
  }

  static bool _verifyPassword(
    String email,
    String password,
    String storedHash,
  ) {
    if (storedHash.isEmpty) return false;
    final normalizedEmail = email.trim().toLowerCase();
    final secret = '$normalizedEmail::$password';
    if (storedHash.startsWith('bcrypt:')) {
      final bcryptHash = storedHash.substring('bcrypt:'.length);
      if (bcryptHash.isEmpty) return false;
      return BCrypt.checkpw(secret, bcryptHash);
    }

    // Legacy fallback for old SHA-256 hashes. Will be replaced at next login.
    final legacy = sha256.convert(utf8.encode(secret)).toString();
    return storedHash == legacy;
  }

  static bool _isValidEmail(String email) {
    const pattern = r'^[^\s@]+@[^\s@]+\.[^\s@]+$';
    return RegExp(pattern).hasMatch(email.trim());
  }

  static String _normalizedUserName(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  static bool _userNameMatches(String a, String b) {
    return _normalizedUserName(a) == _normalizedUserName(b);
  }

  bool _userNameExists(
    List<JsonMap> users,
    String fullName, {
    String? exceptId,
  }) {
    final normalized = _normalizedUserName(fullName);
    if (normalized.isEmpty) return false;
    return users.any((user) {
      if (exceptId != null && _text(user['id']) == exceptId) return false;
      return _normalizedUserName(_text(user['fullName'])) == normalized;
    });
  }

  static DateTime? _nextAllowedProfileNameChangeAt(Object? value) {
    final text = _text(value);
    if (text.isEmpty) return null;
    final changedAt = DateTime.tryParse(text)?.toUtc();
    if (changedAt == null) return null;
    return _addCalendarMonths(changedAt, _profileNameChangeCooldownMonths);
  }

  static DateTime _addCalendarMonths(DateTime date, int months) {
    final monthIndex = date.month - 1 + months;
    final year = date.year + monthIndex ~/ 12;
    final month = monthIndex % 12 + 1;
    final lastDay = DateTime.utc(year, month + 1, 0).day;
    final day = math.min(date.day, lastDay);
    return DateTime.utc(
      year,
      month,
      day,
      date.hour,
      date.minute,
      date.second,
      date.millisecond,
      date.microsecond,
    );
  }

  static String _profileNameChangeDateLabel(DateTime date) {
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  String? _profilePhotoDataUrlFrom(Object? value) {
    final text = _boundedText(
      value,
      _maxProfilePhotoDataUrlLength,
      fieldName: 'Photo de profil',
    );
    if (text.isEmpty) return null;
    final match = RegExp(
      r'^data:image/(png|jpe?g|webp);base64,([A-Za-z0-9+/=\r\n]+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) {
      throw StateError('Photo de profil invalide.');
    }
    try {
      final bytes = base64Decode(
        match.group(2)!.replaceAll(RegExp(r'\s+'), ''),
      );
      if (bytes.length > _maxProfilePhotoBytes) {
        throw StateError('Photo de profil trop volumineuse.');
      }
    } on FormatException {
      throw StateError('Photo de profil invalide.');
    }
    return text;
  }

  static double _distanceMeters(
    double fromLat,
    double fromLng,
    double toLat,
    double toLng,
  ) {
    const earthRadiusMeters = 6371008.8;
    final lat1 = fromLat * math.pi / 180;
    final lat2 = toLat * math.pi / 180;
    final dLat = (toLat - fromLat) * math.pi / 180;
    final dLng = (toLng - fromLng) * math.pi / 180;
    final sinLat = math.sin(dLat / 2);
    final sinLng = math.sin(dLng / 2);
    final h =
        sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLng * sinLng;
    return earthRadiusMeters * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  static String _roleLabel(String role) {
    return switch (_normalizeRole(role)) {
      'observateur' => 'Observateur',
      'etoile' => 'Étoile',
      'reporteur' => 'Reporteur',
      'administrateur' => 'Administrateur',
      _ => 'Observateur',
    };
  }

  static String _displayCode(String code) {
    if (code.trim().length <= 2) {
      return code.trim().padLeft(2, '0');
    }
    return code.trim();
  }

  static String _routeTitle(JsonMap? line) {
    if (line == null) return '';
    return _text(line['name']).replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _lastSystemMessage(JsonMap trip) {
    for (final message in _mapList(trip['messages']).reversed) {
      if (message['isSystem'] == true) {
        return _text(message['content']);
      }
    }
    return '';
  }

  static (String, String) _routeSplit(String routeTitle) {
    final split = _cleanTerminalLabel(routeTitle).split(RegExp(r'[â†”â†’]'));
    final origin = split.isNotEmpty ? split.first.trim() : '';
    final destination = split.length > 1 ? split.last.trim() : '';
    return (origin, destination);
  }

  static String _cleanTerminalLabel(String label) {
    return label
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceFirst(
          RegExp(r'^(?:bateau[- ]?bus|bus)\s*\d+\s*:\s*', caseSensitive: false),
          '',
        )
        .trim();
  }

  static int _colorValue(Object? value, String code) {
    final text = value?.toString().trim() ?? '';
    if (text.startsWith('#')) {
      final hex = text.substring(1);
      final normalized = hex.length == 6 ? 'FF$hex' : hex;
      final parsed = int.tryParse(normalized, radix: 16);
      if (parsed != null) return parsed;
    }
    final digits =
        int.tryParse(code.replaceAll(RegExp(r'[^0-9]'), '')) ??
        code.hashCode.abs();
    final hue = (digits * 47) % 360;
    final saturation = 0.72;
    final lightness = 0.44;
    final c = (1 - (2 * lightness - 1).abs()) * saturation;
    final x = c * (1 - (((hue / 60) % 2) - 1).abs());
    final m = lightness - c / 2;
    double r = 0;
    double g = 0;
    double b = 0;
    if (hue < 60) {
      r = c;
      g = x;
      b = 0;
    } else if (hue < 120) {
      r = x;
      g = c;
      b = 0;
    } else if (hue < 180) {
      r = 0;
      g = c;
      b = x;
    } else if (hue < 240) {
      r = 0;
      g = x;
      b = c;
    } else if (hue < 300) {
      r = x;
      g = 0;
      b = c;
    } else {
      r = c;
      g = 0;
      b = x;
    }
    final red = ((r + m) * 255).round().clamp(0, 255);
    final green = ((g + m) * 255).round().clamp(0, 255);
    final blue = ((b + m) * 255).round().clamp(0, 255);
    return (0xFF << 24) | (red << 16) | (green << 8) | blue;
  }
}

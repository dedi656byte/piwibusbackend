import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';

class StateMutationBatch {
  const StateMutationBatch({
    this.users = false,
    this.sessions = false,
    this.trips = false,
    this.reports = false,
    this.pushTokens = false,
    this.activity = false,
    this.messageConversations = false,
  });

  final bool users;
  final bool sessions;
  final bool trips;
  final bool reports;
  final bool pushTokens;
  final bool activity;
  final bool messageConversations;

  bool get isEmpty =>
      !users &&
      !sessions &&
      !trips &&
      !reports &&
      !pushTokens &&
      !activity &&
      !messageConversations;
}

abstract class StatePersistence {
  String get name;
  bool get isDatabaseBacked => false;
  bool get supportsGeospatialQueries => false;

  Future<Map<String, dynamic>?> loadState();

  Future<void> saveState(Map<String, dynamic> state);

  Future<void> checkReady() async {}

  Future<void> applyMutations({
    required Map<String, dynamic> state,
    required StateMutationBatch batch,
  }) async {
    if (batch.isEmpty) return;
    await saveState(state);
  }

  Future<List<Map<String, dynamic>>> nearbyActiveTrips({
    required double lat,
    required double lng,
    required double radiusMeters,
    required int limit,
  }) async {
    return const <Map<String, dynamic>>[];
  }

  Future<void> close() async {}

  static Future<StatePersistence> open({
    required Directory backendDir,
    required File stateFile,
  }) async {
    final databaseUrl =
        (Platform.environment['PIWIBUS_DATABASE_URL'] ??
                Platform.environment['DATABASE_URL'] ??
                '')
            .trim();
    if (databaseUrl.isNotEmpty) {
      return PostgresStatePersistence.open(databaseUrl);
    }
    return JsonFileStatePersistence(stateFile);
  }
}

class JsonFileStatePersistence extends StatePersistence {
  JsonFileStatePersistence(this._stateFile);

  final File _stateFile;

  @override
  String get name => 'json-file:${p.normalize(_stateFile.path)}';

  @override
  Future<Map<String, dynamic>?> loadState() async {
    await _stateFile.parent.create(recursive: true);
    if (!await _stateFile.exists()) return null;
    final decoded = jsonDecode(await _stateFile.readAsString());
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }

  @override
  Future<void> saveState(Map<String, dynamic> state) async {
    await _stateFile.parent.create(recursive: true);
    await _stateFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state),
      flush: true,
    );
  }

  @override
  Future<void> checkReady() async {
    await _stateFile.parent.create(recursive: true);
  }
}

class PostgresStatePersistence extends StatePersistence {
  PostgresStatePersistence._({
    required String databaseUrl,
    required Connection connection,
    required bool postgisAvailable,
  }) : _databaseUrl = databaseUrl,
       _connection = connection,
       _postgisAvailable = postgisAvailable;

  final String _databaseUrl;
  Connection _connection;
  bool _postgisAvailable;
  Future<void>? _reconnectInFlight;
  bool _closed = false;

  final Map<String, String> _lastSessionFingerprints = <String, String>{};
  final Map<String, String> _lastUserFingerprints = <String, String>{};
  final Map<String, String> _lastTripFingerprints = <String, String>{};
  final Map<String, String> _lastMessageFingerprints = <String, String>{};
  final Map<String, String> _lastMessageConversationFingerprints =
      <String, String>{};
  final Map<String, String> _lastMessageItemFingerprints = <String, String>{};
  final Map<String, String> _lastReportFingerprints = <String, String>{};
  final Map<String, String> _lastPushTokenFingerprints = <String, String>{};
  String? _lastActivityFingerprint;
  String? _lastTripLocationsFingerprint;

  static const String _stateId = 'default';

  @override
  String get name =>
      _postgisAvailable ? 'postgres-normalized-postgis' : 'postgres-normalized';

  @override
  bool get isDatabaseBacked => true;

  @override
  bool get supportsGeospatialQueries => _postgisAvailable;

  @override
  Future<void> checkReady() async {
    await _withConnectionRetry((connection) async {
      final result = await connection.execute('SELECT pg_is_in_recovery()');
      final inRecovery = result.isNotEmpty && result.first[0] == true;
      if (inRecovery) {
        throw StateError('Postgres is still in recovery mode.');
      }
    });
  }

  static Future<PostgresStatePersistence> open(String databaseUrl) async {
    final normalizedDatabaseUrl = _withDefaultSslMode(databaseUrl);
    final connection = await Connection.openFromUrl(normalizedDatabaseUrl);
    final postgisAvailable = await _tryEnablePostgis(connection);
    await _ensureSchema(connection, postgisAvailable: postgisAvailable);
    final persistence = PostgresStatePersistence._(
      databaseUrl: normalizedDatabaseUrl,
      connection: connection,
      postgisAvailable: postgisAvailable,
    );
    await persistence._migrateLegacyStateIfNeeded();
    return persistence;
  }

  @override
  Future<Map<String, dynamic>?> loadState() {
    return _withConnectionRetry((connection) async {
      final hasState = await _hasNormalizedStateOn(connection);
      if (!hasState) return null;

      final userRows = await connection.execute('''
      SELECT
        id, sort_order, full_name, email, phone, profile_photo_data_url,
        name_changed_at, primary_role, status,
        created_at, last_seen_at, password_hash, password_reset_hash,
        password_reset_requested_at, password_reset_expires_at,
        password_reset_attempts, activity_read_at, read_alert_ids,
        star_trip_ids, followed_trip_ids
      FROM piwibus_users
      ORDER BY sort_order ASC, created_at DESC, id ASC
    ''');
      final users = userRows
          .map((row) => _userFromRow(row.toColumnMap()))
          .toList(growable: false);
      final publicUsersById = <String, Map<String, dynamic>>{
        for (final user in users) _text(user['id']): _publicUser(user),
      };

      final sessionRows = await connection.execute('''
      SELECT
        session_id, current_user_id, active_role, section, search_query,
        selected_line_code, selected_trip_id, favorite_line_codes,
        current_location, created_at, last_seen_at
      FROM piwibus_sessions
    ''');
      final sessions = <String, Map<String, dynamic>>{};
      for (final row in sessionRows) {
        final map = row.toColumnMap();
        final sessionId = _text(map['session_id']);
        if (sessionId.isEmpty) continue;
        final currentUserId = _text(map['current_user_id']);
        sessions[sessionId] = <String, dynamic>{
          'currentUser': publicUsersById[currentUserId],
          'activeRole': _text(map['active_role']),
          'section': _text(map['section']),
          'searchQuery': _text(map['search_query']),
          'selectedLineCode': _nullableText(map['selected_line_code']),
          'selectedTripId': _nullableText(map['selected_trip_id']),
          'favoriteLineCodes': _jsonStringList(map['favorite_line_codes']),
          'currentLocation': _jsonMapOrNull(map['current_location']),
          'createdAt': _iso(map['created_at']),
          'lastSeenAt': _iso(map['last_seen_at']),
        };
      }

      final messageItemRows = await connection.execute('''
      SELECT
        trip_id, message_id, message_order, author_name, role, content,
        created_at, is_system
      FROM piwibus_trip_messages
      ORDER BY trip_id ASC, message_order ASC, created_at ASC, message_id ASC
    ''');
      final messagesByTripId = <String, List<Map<String, dynamic>>>{};
      for (final row in messageItemRows) {
        final map = row.toColumnMap();
        final tripId = _text(map['trip_id']);
        if (tripId.isEmpty) continue;
        (messagesByTripId[tripId] ??= <Map<String, dynamic>>[])
            .add(<String, dynamic>{
              'id': _text(map['message_id']),
              'tripId': tripId,
              'authorName': _text(map['author_name']),
              'role': _text(map['role']),
              'content': _text(map['content']),
              'createdAt': _iso(map['created_at']),
              'isSystem': map['is_system'] == true,
            });
      }

      final tripRows = await connection.execute('''
      SELECT
        id, sort_order, line_code, owner_id, owner_session_id, owner_name,
        owner_photo_data_url, owner_role, status, started_at, last_updated_at,
        progress, speed_kmh,
        observers, max_observers, network_usage_bytes,
        rating_average, rating_count, liked_by_actor_ids, note, live_location,
        off_route_since, off_route_distance_meters, path,
        origin_label, destination_label
      FROM piwibus_trips
      ORDER BY sort_order ASC, started_at DESC, id ASC
    ''');
      final trips = tripRows
          .map((row) {
            final map = row.toColumnMap();
            final tripId = _text(map['id']);
            return <String, dynamic>{
              'id': tripId,
              'line_code': _text(map['line_code']),
              'owner_id': _text(map['owner_id']),
              'owner_session_id': _text(map['owner_session_id']),
              'owner_name': _text(map['owner_name']),
              'owner_photo_data_url': _text(map['owner_photo_data_url']),
              'owner_role': _text(map['owner_role']),
              'status': _text(map['status']),
              'startedAt': _iso(map['started_at']),
              'lastUpdatedAt': _iso(map['last_updated_at']),
              'progress': _double(map['progress']),
              'speedKmh': _double(map['speed_kmh']),
              'observers': _int(map['observers']),
              'maxObservers': _int(map['max_observers']),
              'networkUsageBytes': _int(map['network_usage_bytes']),
              'ratingAverage': _double(map['rating_average']),
              'ratingCount': _int(map['rating_count']),
              'likedByActorIds':
                  (map['liked_by_actor_ids'] as List?)?.cast<String>().toList(
                    growable: false,
                  ) ??
                  const <String>[],
              'note': _text(map['note']),
              'liveLocation': _jsonMapOrNull(map['live_location']),
              'offRouteSince': _iso(map['off_route_since']),
              'offRouteDistanceMeters': map['off_route_distance_meters'] == null
                  ? null
                  : _double(map['off_route_distance_meters']),
              'path': _jsonMapList(map['path']),
              'originLabel': _text(map['origin_label']),
              'destinationLabel': _text(map['destination_label']),
              'messages':
                  messagesByTripId[tripId] ?? const <Map<String, dynamic>>[],
            };
          })
          .toList(growable: false);

      final reportRows = await connection.execute('''
      SELECT
        id, sort_order, bus_number, line_code, line_label, reporter_id,
        reporter_name, lat, lng, status, created_at, note, confidence
      FROM piwibus_reports
      ORDER BY sort_order ASC, created_at DESC, id ASC
    ''');
      final reports = reportRows
          .map((row) {
            final map = row.toColumnMap();
            return <String, dynamic>{
              'id': _text(map['id']),
              'busNumber': _text(map['bus_number']),
              'lineCode': _text(map['line_code']),
              'lineLabel': _text(map['line_label']),
              'reporterId': _text(map['reporter_id']),
              'reporterName': _text(map['reporter_name']),
              'location': <String, dynamic>{
                'lat': _double(map['lat']),
                'lng': _double(map['lng']),
              },
              'status': _text(map['status']),
              'createdAt': _iso(map['created_at']),
              'note': _text(map['note']),
              'confidence': _double(map['confidence']),
            };
          })
          .toList(growable: false);

      final tokenRows = await connection.execute('''
      SELECT
        id, sort_order, token, platform, session_id, user_id, status,
        app_version, build_number, android_abi, sdk_int, is_64_bit_process,
        device_model, created_at, last_seen_at
      FROM piwibus_push_tokens
      ORDER BY sort_order ASC, created_at DESC, id ASC
    ''');
      final pushTokens = tokenRows
          .map((row) {
            final map = row.toColumnMap();
            return <String, dynamic>{
              'id': _text(map['id']),
              'token': _text(map['token']),
              'platform': _text(map['platform']),
              'sessionId': _text(map['session_id']),
              'userId': _text(map['user_id']),
              'status': _text(map['status']),
              'appVersion': _text(map['app_version']),
              'buildNumber': _text(map['build_number']),
              'androidAbi': _text(map['android_abi']),
              'sdkInt': _int(map['sdk_int']),
              'is64BitProcess': map['is_64_bit_process'] == true,
              'deviceModel': _text(map['device_model']),
              'createdAt': _iso(map['created_at']),
              'lastSeenAt': _iso(map['last_seen_at']),
            };
          })
          .toList(growable: false);

      final activityRows = await connection.execute('''
      SELECT
        position, title, subtitle, timestamp, icon_key, color_value,
        audience_session_ids, audience_user_ids
      FROM piwibus_activity
      ORDER BY position ASC
    ''');
      final activity = activityRows
          .map((row) {
            final map = row.toColumnMap();
            return <String, dynamic>{
              'title': _text(map['title']),
              'subtitle': _text(map['subtitle']),
              'timestamp': _iso(map['timestamp']),
              'iconKey': _text(map['icon_key']),
              'colorValue': _int(map['color_value']),
              'audienceSessionIds': _jsonStringList(
                map['audience_session_ids'],
              ),
              'audienceUserIds': _jsonStringList(map['audience_user_ids']),
            };
          })
          .toList(growable: false);

      final messageRows = await connection.execute('''
      SELECT
        conversation_id, message_id, message_order, sender_id, sender_name,
        body, sequence, created_at
      FROM piwibus_message_items
      ORDER BY conversation_id ASC, sequence ASC, created_at ASC, message_id ASC
    ''');
      final messagesByConversationId = <String, List<Map<String, dynamic>>>{};
      for (final row in messageRows) {
        final map = row.toColumnMap();
        final conversationId = _text(map['conversation_id']);
        if (conversationId.isEmpty) continue;
        (messagesByConversationId[conversationId] ??= <Map<String, dynamic>>[])
            .add(<String, dynamic>{
              'id': _text(map['message_id']),
              'conversationId': conversationId,
              'senderId': _text(map['sender_id']),
              'senderName': _text(map['sender_name']),
              'body': _text(map['body']),
              'sequence': _int(map['sequence']),
              'createdAt': _iso(map['created_at']),
            });
      }

      final messageConversationRows = await connection.execute('''
      SELECT
        id, sort_order, kind, participant_ids, trip_id, title, subtitle,
        last_message_preview, last_message_id, last_sender_id, message_cursor,
        read_sequences, created_at, updated_at
      FROM piwibus_message_conversations
      ORDER BY sort_order ASC, updated_at DESC, id ASC
    ''');
      final messageConversations = messageConversationRows
          .map((row) {
            final map = row.toColumnMap();
            final conversationId = _text(map['id']);
            return <String, dynamic>{
              'id': conversationId,
              'kind': _text(map['kind']),
              'participantIds': _sqlStringList(map['participant_ids']),
              'tripId': _text(map['trip_id']),
              'title': _text(map['title']),
              'subtitle': _text(map['subtitle']),
              'lastMessagePreview': _text(map['last_message_preview']),
              'lastMessageId': _text(map['last_message_id']),
              'lastSenderId': _text(map['last_sender_id']),
              'messageCursor': _int(map['message_cursor']),
              'readSequences':
                  _jsonMapOrNull(map['read_sequences']) ??
                  const <String, dynamic>{},
              'createdAt': _iso(map['created_at']),
              'updatedAt': _iso(map['updated_at']),
              'messages':
                  messagesByConversationId[conversationId] ??
                  const <Map<String, dynamic>>[],
            };
          })
          .toList(growable: false);

      final state = <String, dynamic>{
        'sessions': sessions,
        'users': users,
        'trips': trips,
        'reports': reports,
        'pushTokens': pushTokens,
        'activity': activity,
        'messageConversations': messageConversations,
      };
      _refreshFingerprintsFromState(state);
      return state;
    });
  }

  @override
  Future<void> saveState(Map<String, dynamic> state) async {
    await _withTransactionRetry((session) async {
      await _syncUsers(session, _mapList(state['users']));
      await _syncSessions(session, _sessionMap(state['sessions']));
      await _syncTrips(session, _mapList(state['trips']));
      await _syncReports(session, _mapList(state['reports']));
      await _syncPushTokens(session, _mapList(state['pushTokens']));
      await _syncActivity(session, _mapList(state['activity']));
      await _syncMessageConversations(
        session,
        _mapList(state['messageConversations']),
      );
      await _syncTripLocations(session, state);
      await _bumpRevisionAndNotify(session);
    });
    _refreshFingerprintsFromState(state);
  }

  @override
  Future<void> applyMutations({
    required Map<String, dynamic> state,
    required StateMutationBatch batch,
  }) async {
    if (batch.isEmpty) return;
    await _withTransactionRetry((session) async {
      if (batch.users) {
        await _syncUsers(session, _mapList(state['users']));
      }
      if (batch.sessions) {
        await _syncSessions(session, _sessionMap(state['sessions']));
      }
      if (batch.trips) {
        await _syncTrips(session, _mapList(state['trips']));
        await _syncTripLocations(session, state);
      }
      if (batch.reports) {
        await _syncReports(session, _mapList(state['reports']));
      }
      if (batch.pushTokens) {
        await _syncPushTokens(session, _mapList(state['pushTokens']));
      }
      if (batch.activity) {
        await _syncActivity(session, _mapList(state['activity']));
      }
      if (batch.messageConversations) {
        await _syncMessageConversations(
          session,
          _mapList(state['messageConversations']),
        );
      }
      await _bumpRevisionAndNotify(session);
    });
    _refreshFingerprintsFromState(state, batch: batch);
  }

  @override
  Future<List<Map<String, dynamic>>> nearbyActiveTrips({
    required double lat,
    required double lng,
    required double radiusMeters,
    required int limit,
  }) async {
    return _withConnectionRetry((connection) async {
      final boundedLimit = limit.clamp(1, 100).toInt();
      final boundedRadius = radiusMeters.clamp(1, 50000).toDouble();
      if (_postgisAvailable) {
        final result = await connection.execute(
          Sql.named('''
          WITH origin AS (
            SELECT ST_SetSRID(ST_MakePoint(@lng, @lat), 4326)::geography AS point
          )
          SELECT
            trip_id,
            line_code,
            owner_id,
            lat,
            lng,
            updated_at,
            ST_Distance(location, origin.point) AS distance_meters
          FROM piwibus_trip_locations, origin
          WHERE status = 'actif'
            AND location IS NOT NULL
            AND ST_DWithin(location, origin.point, @radius)
          ORDER BY location <-> origin.point
          LIMIT @limit
        '''),
          parameters: <String, Object?>{
            'lat': lat,
            'lng': lng,
            'radius': boundedRadius,
            'limit': boundedLimit,
          },
        );
        return result.map((row) => row.toColumnMap()).toList(growable: false);
      }

      final result = await connection.execute(
        Sql.named('''
        SELECT
          trip_id,
          line_code,
          owner_id,
          lat,
          lng,
          updated_at,
          (
            6371008.8 * 2 * asin(
              sqrt(
                pow(sin(radians((lat - @lat) / 2)), 2) +
                cos(radians(@lat)) * cos(radians(lat)) *
                pow(sin(radians((lng - @lng) / 2)), 2)
              )
            )
          ) AS distance_meters
        FROM piwibus_trip_locations
        WHERE status = 'actif'
        ORDER BY distance_meters ASC
        LIMIT @limit
      '''),
        parameters: <String, Object?>{
          'lat': lat,
          'lng': lng,
          'limit': boundedLimit,
        },
      );
      return result
          .map((row) => row.toColumnMap())
          .where((row) => _double(row['distance_meters']) <= boundedRadius)
          .toList(growable: false);
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
    final reconnecting = _reconnectInFlight;
    if (reconnecting != null) {
      try {
        await reconnecting;
      } catch (_) {
        // Closing should remain best-effort even if a reconnect just failed.
      }
    }
    try {
      await _connection.close(force: true);
    } catch (_) {
      // The connection can already be closed by PostgreSQL or the network.
    }
  }

  Future<void> _migrateLegacyStateIfNeeded() async {
    if (await _hasNormalizedState()) return;
    final legacy = await _loadLegacyState();
    if (legacy == null) return;
    await saveState(legacy);
  }

  Future<bool> _hasNormalizedState() {
    return _withConnectionRetry(_hasNormalizedStateOn);
  }

  Future<bool> _hasNormalizedStateOn(Connection connection) async {
    final result = await connection.execute('''
      SELECT
        EXISTS (SELECT 1 FROM piwibus_meta WHERE id = 'default') OR
        EXISTS (SELECT 1 FROM piwibus_users) OR
        EXISTS (SELECT 1 FROM piwibus_sessions) OR
        EXISTS (SELECT 1 FROM piwibus_trips) OR
        EXISTS (SELECT 1 FROM piwibus_reports) OR
        EXISTS (SELECT 1 FROM piwibus_push_tokens) OR
        EXISTS (SELECT 1 FROM piwibus_activity)
    ''');
    return result.isNotEmpty && result.first[0] == true;
  }

  Future<Map<String, dynamic>?> _loadLegacyState() {
    return _withConnectionRetry(_loadLegacyStateOn);
  }

  Future<Map<String, dynamic>?> _loadLegacyStateOn(
    Connection connection,
  ) async {
    final result = await connection.execute(
      Sql.named('SELECT payload FROM piwibus_state WHERE id = @id'),
      parameters: const <String, Object?>{'id': _stateId},
    );
    if (result.isEmpty) return null;
    return _jsonMapOrNull(result.first[0]);
  }

  Future<T> _withConnectionRetry<T>(
    Future<T> Function(Connection connection) action,
  ) async {
    try {
      return await action(await _connectionOrReconnect());
    } catch (error) {
      if (!_isClosedConnectionError(error)) rethrow;
      await _reconnect();
      return action(await _connectionOrReconnect());
    }
  }

  Future<T> _withTransactionRetry<T>(
    Future<T> Function(TxSession session) action,
  ) {
    return _withConnectionRetry((connection) => connection.runTx(action));
  }

  Future<Connection> _connectionOrReconnect() async {
    if (_closed) {
      throw StateError('Postgres persistence is closed.');
    }
    if (_connection.isOpen) return _connection;
    await _reconnect();
    return _connection;
  }

  Future<void> _reconnect() {
    if (_closed) {
      throw StateError('Postgres persistence is closed.');
    }
    final reconnecting = _reconnectInFlight;
    if (reconnecting != null) return reconnecting;

    final previous = _connection;
    late final Future<void> nextReconnect;
    nextReconnect = () async {
      Connection? next;
      try {
        next = await Connection.openFromUrl(_databaseUrl);
        final postgisAvailable = await _tryEnablePostgis(next);
        await _ensureSchema(next, postgisAvailable: postgisAvailable);
        if (_closed) {
          await next.close(force: true);
          throw StateError('Postgres persistence is closed.');
        }
        _postgisAvailable = postgisAvailable;
        _connection = next;
        try {
          await previous.close(force: true);
        } catch (_) {
          // The previous connection may already have been closed by the server.
        }
      } catch (_) {
        if (next != null && next.isOpen) {
          try {
            await next.close(force: true);
          } catch (_) {}
        }
        rethrow;
      } finally {
        if (identical(_reconnectInFlight, nextReconnect)) {
          _reconnectInFlight = null;
        }
      }
    }();

    _reconnectInFlight = nextReconnect;
    return nextReconnect;
  }

  static bool _isClosedConnectionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('connection is not open') ||
        text.contains('connection is closed') ||
        text.contains('connection closed') ||
        text.contains('connection terminated') ||
        text.contains('closed unexpectedly') ||
        text.contains('server closed the connection') ||
        text.contains('connection reset') ||
        text.contains('broken pipe') ||
        text.contains('socketexception');
  }

  Future<void> _syncUsers(TxSession session, List<Map<String, dynamic>> users) {
    final next = <String, Map<String, dynamic>>{};
    for (var index = 0; index < users.length; index += 1) {
      final user = users[index];
      final id = _text(user['id']);
      if (id.isEmpty) continue;
      next[id] = <String, dynamic>{...user, 'sortOrder': index};
    }
    return _syncKeyedCollection(
      session: session,
      next: next,
      previous: _lastUserFingerprints,
      deleteSql: 'DELETE FROM piwibus_users WHERE id = @id',
      upsert: (row) async {
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_users (
              id, sort_order, full_name, email, phone, profile_photo_data_url,
              name_changed_at, primary_role, status,
              created_at, last_seen_at, password_hash, password_reset_hash,
              password_reset_requested_at, password_reset_expires_at,
              password_reset_attempts,
              activity_read_at, read_alert_ids,
              star_trip_ids, followed_trip_ids
            )
            VALUES (
              @id, @sort_order, @full_name, @email, @phone,
              @profile_photo_data_url, @name_changed_at, @primary_role,
              @status, @created_at,
              @last_seen_at, @password_hash, @password_reset_hash,
              @password_reset_requested_at, @password_reset_expires_at,
              @password_reset_attempts, @activity_read_at, @read_alert_ids,
              @star_trip_ids,
              @followed_trip_ids
            )
            ON CONFLICT (id) DO UPDATE SET
              sort_order = EXCLUDED.sort_order,
              full_name = EXCLUDED.full_name,
              email = EXCLUDED.email,
              phone = EXCLUDED.phone,
              profile_photo_data_url = EXCLUDED.profile_photo_data_url,
              name_changed_at = EXCLUDED.name_changed_at,
              primary_role = EXCLUDED.primary_role,
              status = EXCLUDED.status,
              created_at = EXCLUDED.created_at,
              last_seen_at = EXCLUDED.last_seen_at,
              password_hash = EXCLUDED.password_hash,
              password_reset_hash = EXCLUDED.password_reset_hash,
              password_reset_requested_at = EXCLUDED.password_reset_requested_at,
              password_reset_expires_at = EXCLUDED.password_reset_expires_at,
              password_reset_attempts = EXCLUDED.password_reset_attempts,
              activity_read_at = EXCLUDED.activity_read_at,
              read_alert_ids = EXCLUDED.read_alert_ids,
              star_trip_ids = EXCLUDED.star_trip_ids,
              followed_trip_ids = EXCLUDED.followed_trip_ids
          '''),
          parameters: <String, Object?>{
            'id': _text(row['id']),
            'sort_order': _int(row['sortOrder']),
            'full_name': _text(row['fullName']),
            'email': _text(row['email']),
            'phone': _text(row['phone']),
            'profile_photo_data_url': _nullableText(row['profilePhotoDataUrl']),
            'name_changed_at': _nullableDateTime(row['nameChangedAt']),
            'primary_role': _text(row['primaryRole']),
            'status': _text(row['status']),
            'created_at': _dateTime(row['createdAt']),
            'last_seen_at': _nullableDateTime(row['lastSeenAt']),
            'password_hash': _text(row['passwordHash']),
            'password_reset_hash': _nullableText(row['passwordResetHash']),
            'password_reset_requested_at': _nullableDateTime(
              row['passwordResetRequestedAt'],
            ),
            'password_reset_expires_at': _nullableDateTime(
              row['passwordResetExpiresAt'],
            ),
            'password_reset_attempts': _int(row['passwordResetAttempts']),
            'activity_read_at': _nullableDateTime(row['activityReadAt']),
            'read_alert_ids':
                (row['readAlertIds'] as List?)?.cast<String>().toList(
                  growable: false,
                ) ??
                const <String>[],
            'star_trip_ids':
                (row['starTripIds'] as List?)?.cast<String>().toList(
                  growable: false,
                ) ??
                const <String>[],
            'followed_trip_ids':
                (row['followedTripIds'] as List?)?.cast<String>().toList(
                  growable: false,
                ) ??
                const <String>[],
          },
          ignoreRows: true,
        );
      },
    );
  }

  Future<void> _syncSessions(
    TxSession session,
    Map<String, Map<String, dynamic>> sessions,
  ) {
    return _syncKeyedCollection(
      session: session,
      next: sessions,
      previous: _lastSessionFingerprints,
      deleteSql: 'DELETE FROM piwibus_sessions WHERE session_id = @id',
      upsert: (row) async {
        final currentUser = row['currentUser'];
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_sessions (
              session_id, current_user_id, active_role, section, search_query,
              selected_line_code, selected_trip_id, favorite_line_codes,
              current_location, created_at, last_seen_at
            )
            VALUES (
              @session_id, @current_user_id, @active_role, @section,
              @search_query, @selected_line_code, @selected_trip_id,
              CAST(@favorite_line_codes AS jsonb), CAST(@current_location AS jsonb),
              @created_at, @last_seen_at
            )
            ON CONFLICT (session_id) DO UPDATE SET
              current_user_id = EXCLUDED.current_user_id,
              active_role = EXCLUDED.active_role,
              section = EXCLUDED.section,
              search_query = EXCLUDED.search_query,
              selected_line_code = EXCLUDED.selected_line_code,
              selected_trip_id = EXCLUDED.selected_trip_id,
              favorite_line_codes = EXCLUDED.favorite_line_codes,
              current_location = EXCLUDED.current_location,
              created_at = EXCLUDED.created_at,
              last_seen_at = EXCLUDED.last_seen_at
          '''),
          parameters: <String, Object?>{
            'session_id': _text(row['sessionId']),
            'current_user_id': currentUser is Map
                ? _nullableText(currentUser['id'])
                : null,
            'active_role': _text(row['activeRole']),
            'section': _text(row['section']),
            'search_query': _text(row['searchQuery']),
            'selected_line_code': _nullableText(row['selectedLineCode']),
            'selected_trip_id': _nullableText(row['selectedTripId']),
            'favorite_line_codes': jsonEncode(
              _stringList(row['favoriteLineCodes']),
            ),
            'current_location': _jsonOrNull(row['currentLocation']),
            'created_at': _dateTime(row['createdAt']),
            'last_seen_at': _dateTime(row['lastSeenAt']),
          },
          ignoreRows: true,
        );
      },
    );
  }

  Future<void> _syncTrips(
    TxSession session,
    List<Map<String, dynamic>> trips,
  ) async {
    final nextTrips = <String, Map<String, dynamic>>{};
    final nextMessages = <String, Map<String, dynamic>>{};
    for (var tripIndex = 0; tripIndex < trips.length; tripIndex += 1) {
      final trip = trips[tripIndex];
      final tripId = _text(trip['id']);
      if (tripId.isEmpty) continue;
      nextTrips[tripId] = <String, dynamic>{...trip, 'sortOrder': tripIndex};
      final messages = _mapList(trip['messages']);
      for (
        var messageIndex = 0;
        messageIndex < messages.length;
        messageIndex += 1
      ) {
        final message = messages[messageIndex];
        final messageId = _text(message['id']);
        if (messageId.isEmpty) continue;
        nextMessages['$tripId::$messageId'] = <String, dynamic>{
          ...message,
          'tripId': tripId,
          'messageOrder': messageIndex,
        };
      }
    }

    await _syncKeyedCollection(
      session: session,
      next: nextTrips,
      previous: _lastTripFingerprints,
      deleteSql: 'DELETE FROM piwibus_trips WHERE id = @id',
      upsert: (row) async {
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_trips (
              id, sort_order, line_code, owner_id, owner_session_id, owner_name,
              owner_photo_data_url, owner_role, status, started_at,
              last_updated_at, progress, speed_kmh, observers, max_observers,
              network_usage_bytes, rating_average, rating_count,
              liked_by_actor_ids, note, live_location,
              off_route_since, off_route_distance_meters, path, origin_label,
              destination_label
            )
            VALUES (
              @id, @sort_order, @line_code, @owner_id, @owner_session_id,
              @owner_name, @owner_photo_data_url, @owner_role, @status,
              @started_at, @last_updated_at, @progress, @speed_kmh,
              @observers, @max_observers,
              @network_usage_bytes, @rating_average, @rating_count,
              @liked_by_actor_ids, @note, CAST(@live_location AS jsonb),
              @off_route_since,
              @off_route_distance_meters, CAST(@path AS jsonb),
              @origin_label, @destination_label
            )
            ON CONFLICT (id) DO UPDATE SET
              sort_order = EXCLUDED.sort_order,
              line_code = EXCLUDED.line_code,
              owner_id = EXCLUDED.owner_id,
              owner_session_id = EXCLUDED.owner_session_id,
              owner_name = EXCLUDED.owner_name,
              owner_photo_data_url = EXCLUDED.owner_photo_data_url,
              owner_role = EXCLUDED.owner_role,
              status = EXCLUDED.status,
              started_at = EXCLUDED.started_at,
              last_updated_at = EXCLUDED.last_updated_at,
              progress = EXCLUDED.progress,
              speed_kmh = EXCLUDED.speed_kmh,
              observers = EXCLUDED.observers,
              max_observers = EXCLUDED.max_observers,
              network_usage_bytes = EXCLUDED.network_usage_bytes,
              rating_average = EXCLUDED.rating_average,
              rating_count = EXCLUDED.rating_count,
              liked_by_actor_ids = EXCLUDED.liked_by_actor_ids,
              note = EXCLUDED.note,
              live_location = EXCLUDED.live_location,
              off_route_since = EXCLUDED.off_route_since,
              off_route_distance_meters = EXCLUDED.off_route_distance_meters,
              path = EXCLUDED.path,
              origin_label = EXCLUDED.origin_label,
              destination_label = EXCLUDED.destination_label
          '''),
          parameters: <String, Object?>{
            'id': _text(row['id']),
            'sort_order': _int(row['sortOrder']),
            'line_code': _text(row['line_code']),
            'owner_id': _nullableText(row['owner_id']),
            'owner_session_id': _nullableText(row['owner_session_id']),
            'owner_name': _text(row['owner_name']),
            'owner_photo_data_url': _nullableText(row['owner_photo_data_url']),
            'owner_role': _text(row['owner_role']),
            'status': _text(row['status']),
            'started_at': _dateTime(row['startedAt']),
            'last_updated_at': _dateTime(row['lastUpdatedAt']),
            'progress': _finiteDouble(row['progress']),
            'speed_kmh': _finiteDouble(row['speedKmh']),
            'observers': _int(row['observers']),
            'max_observers': _int(row['maxObservers']),
            'network_usage_bytes': _int(row['networkUsageBytes']),
            'rating_average': _finiteDouble(row['ratingAverage']),
            'rating_count': _int(row['ratingCount']),
            'liked_by_actor_ids': _stringList(row['likedByActorIds']),
            'note': _text(row['note']),
            'live_location': _jsonOrNull(row['liveLocation']),
            'off_route_since': _nullableDateTime(row['offRouteSince']),
            'off_route_distance_meters': row['offRouteDistanceMeters'] == null
                ? null
                : _finiteDouble(row['offRouteDistanceMeters']),
            'path': jsonEncode(_mapList(row['path'])),
            'origin_label': _text(row['originLabel']),
            'destination_label': _text(row['destinationLabel']),
          },
          ignoreRows: true,
        );
      },
    );

    await _syncKeyedCollection(
      session: session,
      next: nextMessages,
      previous: _lastMessageFingerprints,
      deleteSql:
          'DELETE FROM piwibus_trip_messages WHERE trip_id || \'::\' || message_id = @id',
      upsert: (row) async {
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_trip_messages (
              trip_id, message_id, message_order, author_name, role, content,
              created_at, is_system
            )
            VALUES (
              @trip_id, @message_id, @message_order, @author_name, @role,
              @content, @created_at, @is_system
            )
            ON CONFLICT (trip_id, message_id) DO UPDATE SET
              message_order = EXCLUDED.message_order,
              author_name = EXCLUDED.author_name,
              role = EXCLUDED.role,
              content = EXCLUDED.content,
              created_at = EXCLUDED.created_at,
              is_system = EXCLUDED.is_system
          '''),
          parameters: <String, Object?>{
            'trip_id': _text(row['tripId']),
            'message_id': _text(row['id']),
            'message_order': _int(row['messageOrder']),
            'author_name': _text(row['authorName']),
            'role': _text(row['role']),
            'content': _text(row['content']),
            'created_at': _dateTime(row['createdAt']),
            'is_system': row['isSystem'] == true,
          },
          ignoreRows: true,
        );
      },
    );
  }

  Future<void> _syncMessageConversations(
    TxSession session,
    List<Map<String, dynamic>> conversations,
  ) async {
    final nextConversations = <String, Map<String, dynamic>>{};
    final nextMessages = <String, Map<String, dynamic>>{};
    for (
      var conversationIndex = 0;
      conversationIndex < conversations.length;
      conversationIndex += 1
    ) {
      final conversation = conversations[conversationIndex];
      final conversationId = _text(conversation['id']);
      if (conversationId.isEmpty) continue;
      nextConversations[conversationId] = <String, dynamic>{
        ...conversation,
        'sortOrder': conversationIndex,
      };
      final messages = _mapList(conversation['messages']);
      for (
        var messageIndex = 0;
        messageIndex < messages.length;
        messageIndex += 1
      ) {
        final message = messages[messageIndex];
        final messageId = _text(message['id']);
        if (messageId.isEmpty) continue;
        nextMessages['$conversationId::$messageId'] = <String, dynamic>{
          ...message,
          'conversationId': conversationId,
          'messageOrder': messageIndex,
        };
      }
    }

    await _syncKeyedCollection(
      session: session,
      next: nextConversations,
      previous: _lastMessageConversationFingerprints,
      deleteSql: 'DELETE FROM piwibus_message_conversations WHERE id = @id',
      upsert: (row) async {
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_message_conversations (
              id, sort_order, kind, participant_ids, trip_id, title, subtitle,
              last_message_preview, last_message_id, last_sender_id,
              message_cursor, read_sequences, created_at, updated_at
            )
            VALUES (
              @id, @sort_order, @kind, @participant_ids, @trip_id, @title,
              @subtitle, @last_message_preview, @last_message_id,
              @last_sender_id, @message_cursor, @read_sequences::jsonb,
              @created_at, @updated_at
            )
            ON CONFLICT (id) DO UPDATE SET
              sort_order = EXCLUDED.sort_order,
              kind = EXCLUDED.kind,
              participant_ids = EXCLUDED.participant_ids,
              trip_id = EXCLUDED.trip_id,
              title = EXCLUDED.title,
              subtitle = EXCLUDED.subtitle,
              last_message_preview = EXCLUDED.last_message_preview,
              last_message_id = EXCLUDED.last_message_id,
              last_sender_id = EXCLUDED.last_sender_id,
              message_cursor = EXCLUDED.message_cursor,
              read_sequences = EXCLUDED.read_sequences,
              created_at = EXCLUDED.created_at,
              updated_at = EXCLUDED.updated_at
          '''),
          parameters: <String, Object?>{
            'id': _text(row['id']),
            'sort_order': _int(row['sortOrder']),
            'kind': _text(row['kind']).isEmpty ? 'direct' : _text(row['kind']),
            'participant_ids': _stringList(row['participantIds']),
            'trip_id': _nullableText(row['tripId']),
            'title': _text(row['title']),
            'subtitle': _text(row['subtitle']),
            'last_message_preview': _text(row['lastMessagePreview']),
            'last_message_id': _nullableText(row['lastMessageId']),
            'last_sender_id': _nullableText(row['lastSenderId']),
            'message_cursor': _int(row['messageCursor']),
            'read_sequences': jsonEncode(row['readSequences'] ?? const {}),
            'created_at': _dateTime(row['createdAt']),
            'updated_at': _dateTime(row['updatedAt']),
          },
          ignoreRows: true,
        );
      },
    );

    await _syncKeyedCollection(
      session: session,
      next: nextMessages,
      previous: _lastMessageItemFingerprints,
      deleteSql:
          'DELETE FROM piwibus_message_items WHERE conversation_id || \'::\' || message_id = @id',
      upsert: (row) async {
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_message_items (
              conversation_id, message_id, message_order, sender_id,
              sender_name, body, sequence, created_at
            )
            VALUES (
              @conversation_id, @message_id, @message_order, @sender_id,
              @sender_name, @body, @sequence, @created_at
            )
            ON CONFLICT (conversation_id, message_id) DO UPDATE SET
              message_order = EXCLUDED.message_order,
              sender_id = EXCLUDED.sender_id,
              sender_name = EXCLUDED.sender_name,
              body = EXCLUDED.body,
              sequence = EXCLUDED.sequence,
              created_at = EXCLUDED.created_at
          '''),
          parameters: <String, Object?>{
            'conversation_id': _text(row['conversationId']),
            'message_id': _text(row['id']),
            'message_order': _int(row['messageOrder']),
            'sender_id': _text(row['senderId']),
            'sender_name': _text(row['senderName']),
            'body': _text(row['body']),
            'sequence': _int(row['sequence']),
            'created_at': _dateTime(row['createdAt']),
          },
          ignoreRows: true,
        );
      },
    );
  }

  Future<void> _syncReports(
    TxSession session,
    List<Map<String, dynamic>> reports,
  ) {
    final next = <String, Map<String, dynamic>>{};
    for (var index = 0; index < reports.length; index += 1) {
      final report = reports[index];
      final id = _text(report['id']);
      if (id.isEmpty) continue;
      next[id] = <String, dynamic>{...report, 'sortOrder': index};
    }
    return _syncKeyedCollection(
      session: session,
      next: next,
      previous: _lastReportFingerprints,
      deleteSql: 'DELETE FROM piwibus_reports WHERE id = @id',
      upsert: (row) async {
        final location = row['location'] is Map
            ? Map<String, dynamic>.from(row['location'] as Map)
            : const <String, dynamic>{};
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_reports (
              id, sort_order, bus_number, line_code, line_label, reporter_id,
              reporter_name, lat, lng, status, created_at, note, confidence
            )
            VALUES (
              @id, @sort_order, @bus_number, @line_code, @line_label,
              @reporter_id, @reporter_name, @lat, @lng, @status, @created_at,
              @note, @confidence
            )
            ON CONFLICT (id) DO UPDATE SET
              sort_order = EXCLUDED.sort_order,
              bus_number = EXCLUDED.bus_number,
              line_code = EXCLUDED.line_code,
              line_label = EXCLUDED.line_label,
              reporter_id = EXCLUDED.reporter_id,
              reporter_name = EXCLUDED.reporter_name,
              lat = EXCLUDED.lat,
              lng = EXCLUDED.lng,
              status = EXCLUDED.status,
              created_at = EXCLUDED.created_at,
              note = EXCLUDED.note,
              confidence = EXCLUDED.confidence
          '''),
          parameters: <String, Object?>{
            'id': _text(row['id']),
            'sort_order': _int(row['sortOrder']),
            'bus_number': _text(row['busNumber']),
            'line_code': _text(row['lineCode']),
            'line_label': _text(row['lineLabel']),
            'reporter_id': _nullableText(row['reporterId']),
            'reporter_name': _text(row['reporterName']),
            'lat': _finiteDouble(location['lat']),
            'lng': _finiteDouble(location['lng']),
            'status': _text(row['status']),
            'created_at': _dateTime(row['createdAt']),
            'note': _text(row['note']),
            'confidence': _finiteDouble(row['confidence']),
          },
          ignoreRows: true,
        );
      },
    );
  }

  Future<void> _syncPushTokens(
    TxSession session,
    List<Map<String, dynamic>> tokens,
  ) {
    final next = <String, Map<String, dynamic>>{};
    for (var index = 0; index < tokens.length; index += 1) {
      final token = tokens[index];
      final id = _text(token['id']);
      if (id.isEmpty) continue;
      next[id] = <String, dynamic>{...token, 'sortOrder': index};
    }
    return _syncKeyedCollection(
      session: session,
      next: next,
      previous: _lastPushTokenFingerprints,
      deleteSql: 'DELETE FROM piwibus_push_tokens WHERE id = @id',
      upsert: (row) async {
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_push_tokens (
              id, sort_order, token, platform, session_id, user_id, status,
              app_version, build_number, android_abi, sdk_int,
              is_64_bit_process, device_model, created_at, last_seen_at
            )
            VALUES (
              @id, @sort_order, @token, @platform, @session_id, @user_id,
              @status, @app_version, @build_number, @android_abi, @sdk_int,
              @is_64_bit_process, @device_model, @created_at, @last_seen_at
            )
            ON CONFLICT (id) DO UPDATE SET
              sort_order = EXCLUDED.sort_order,
              token = EXCLUDED.token,
              platform = EXCLUDED.platform,
              session_id = EXCLUDED.session_id,
              user_id = EXCLUDED.user_id,
              status = EXCLUDED.status,
              app_version = EXCLUDED.app_version,
              build_number = EXCLUDED.build_number,
              android_abi = EXCLUDED.android_abi,
              sdk_int = EXCLUDED.sdk_int,
              is_64_bit_process = EXCLUDED.is_64_bit_process,
              device_model = EXCLUDED.device_model,
              created_at = EXCLUDED.created_at,
              last_seen_at = EXCLUDED.last_seen_at
          '''),
          parameters: <String, Object?>{
            'id': _text(row['id']),
            'sort_order': _int(row['sortOrder']),
            'token': _text(row['token']),
            'platform': _text(row['platform']),
            'session_id': _nullableText(row['sessionId']),
            'user_id': _nullableText(row['userId']),
            'status': _text(row['status']),
            'app_version': _nullableText(row['appVersion']),
            'build_number': _nullableText(row['buildNumber']),
            'android_abi': _nullableText(row['androidAbi']),
            'sdk_int': _int(row['sdkInt']),
            'is_64_bit_process': row['is64BitProcess'] == true,
            'device_model': _nullableText(row['deviceModel']),
            'created_at': _dateTime(row['createdAt']),
            'last_seen_at': _dateTime(row['lastSeenAt']),
          },
          ignoreRows: true,
        );
      },
    );
  }

  Future<void> _syncActivity(
    TxSession session,
    List<Map<String, dynamic>> activity,
  ) async {
    final nextFingerprint = jsonEncode(activity);
    if (nextFingerprint == _lastActivityFingerprint) return;

    await session.execute('DELETE FROM piwibus_activity', ignoreRows: true);
    for (var index = 0; index < activity.length; index += 1) {
      final item = activity[index];
      await session.execute(
        Sql.named('''
          INSERT INTO piwibus_activity (
            position, title, subtitle, timestamp, icon_key, color_value,
            audience_session_ids, audience_user_ids
          )
          VALUES (
            @position, @title, @subtitle, @timestamp, @icon_key, @color_value,
            CAST(@audience_session_ids AS jsonb),
            CAST(@audience_user_ids AS jsonb)
          )
        '''),
        parameters: <String, Object?>{
          'position': index,
          'title': _text(item['title']),
          'subtitle': _text(item['subtitle']),
          'timestamp': _dateTime(item['timestamp']),
          'icon_key': _text(item['iconKey']),
          'color_value': _int(item['colorValue']),
          'audience_session_ids': jsonEncode(
            _stringList(item['audienceSessionIds']),
          ),
          'audience_user_ids': jsonEncode(_stringList(item['audienceUserIds'])),
        },
        ignoreRows: true,
      );
    }
  }

  Future<void> _bumpRevisionAndNotify(TxSession session) async {
    await session.execute(
      Sql.named('''
        INSERT INTO piwibus_meta (id, revision, updated_at)
        VALUES (@id, 1, now())
        ON CONFLICT (id) DO UPDATE SET
          revision = piwibus_meta.revision + 1,
          updated_at = now()
      '''),
      parameters: const <String, Object?>{'id': _stateId},
      ignoreRows: true,
    );
    await session.execute(
      Sql.named("SELECT pg_notify('piwibus_state_changed', @payload)"),
      parameters: <String, Object?>{
        'payload': DateTime.now().toIso8601String(),
      },
      ignoreRows: true,
    );
  }

  Future<void> _syncKeyedCollection({
    required TxSession session,
    required Map<String, Map<String, dynamic>> next,
    required Map<String, String> previous,
    required String deleteSql,
    required Future<void> Function(Map<String, dynamic> row) upsert,
  }) async {
    final nextFingerprints = <String, String>{
      for (final entry in next.entries) entry.key: jsonEncode(entry.value),
    };
    final removedIds = previous.keys
        .where((id) => !nextFingerprints.containsKey(id))
        .toList(growable: false);
    for (final id in removedIds) {
      await session.execute(
        Sql.named(deleteSql),
        parameters: <String, Object?>{'id': id},
        ignoreRows: true,
      );
    }
    for (final entry in next.entries) {
      if (previous[entry.key] == nextFingerprints[entry.key]) continue;
      await upsert(entry.value);
    }
  }

  Future<void> _syncTripLocations(
    TxSession session,
    Map<String, dynamic> state,
  ) async {
    final trips = _mapList(state['trips']);
    final activeRows = <Map<String, Object?>>[];
    for (final trip in trips) {
      if (_text(trip['status']) != 'actif') continue;
      final liveLocation = trip['liveLocation'];
      if (liveLocation is! Map) continue;
      final lat = _double(liveLocation['lat'] ?? liveLocation['latitude']);
      final lng = _double(liveLocation['lng'] ?? liveLocation['longitude']);
      if (!_isValidLatLng(lat, lng)) continue;
      final timestamp = _text(
        liveLocation['timestamp'] ?? liveLocation['updatedAt'],
      );
      final updatedAt = DateTime.tryParse(timestamp) ?? DateTime.now();
      activeRows.add(<String, Object?>{
        'trip_id': _text(trip['id']),
        'line_code': _text(trip['line_code']),
        'owner_id': _text(trip['owner_id']),
        'status': _text(trip['status']),
        'lat': lat,
        'lng': lng,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      });
    }
    activeRows.sort(
      (a, b) => _text(a['trip_id']).compareTo(_text(b['trip_id'])),
    );
    final nextFingerprint = jsonEncode(activeRows);
    if (nextFingerprint == _lastTripLocationsFingerprint) return;

    await session.execute(
      'DELETE FROM piwibus_trip_locations',
      ignoreRows: true,
    );
    for (final row in activeRows) {
      final updatedAt =
          DateTime.tryParse(_text(row['updated_at'])) ?? DateTime.now();
      if (_postgisAvailable) {
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_trip_locations (
              trip_id, line_code, owner_id, status, lat, lng, updated_at, location
            )
            VALUES (
              @trip_id, @line_code, @owner_id, @status, @lat, @lng,
              @updated_at,
              ST_SetSRID(ST_MakePoint(@lng, @lat), 4326)::geography
            )
          '''),
          parameters: <String, Object?>{
            'trip_id': row['trip_id'],
            'line_code': row['line_code'],
            'owner_id': row['owner_id'],
            'status': row['status'],
            'lat': row['lat'],
            'lng': row['lng'],
            'updated_at': updatedAt,
          },
          ignoreRows: true,
        );
      } else {
        await session.execute(
          Sql.named('''
            INSERT INTO piwibus_trip_locations (
              trip_id, line_code, owner_id, status, lat, lng, updated_at
            )
            VALUES (
              @trip_id, @line_code, @owner_id, @status, @lat, @lng, @updated_at
            )
          '''),
          parameters: <String, Object?>{
            'trip_id': row['trip_id'],
            'line_code': row['line_code'],
            'owner_id': row['owner_id'],
            'status': row['status'],
            'lat': row['lat'],
            'lng': row['lng'],
            'updated_at': updatedAt,
          },
          ignoreRows: true,
        );
      }
    }
  }

  void _refreshFingerprintsFromState(
    Map<String, dynamic> state, {
    StateMutationBatch? batch,
  }) {
    final refreshAll = batch == null;
    if (refreshAll || batch.users) {
      final users = _mapList(state['users']);
      _replaceFingerprints(
        _lastUserFingerprints,
        <String, Map<String, dynamic>>{
          for (var index = 0; index < users.length; index += 1)
            _text(users[index]['id']): <String, dynamic>{
              ...users[index],
              'sortOrder': index,
            },
        },
      );
    }
    if (refreshAll || batch.sessions) {
      _replaceFingerprints(
        _lastSessionFingerprints,
        _sessionMap(state['sessions']),
      );
    }

    if (refreshAll || batch.trips) {
      final trips = _mapList(state['trips']);
      final tripRows = <String, Map<String, dynamic>>{};
      final messageRows = <String, Map<String, dynamic>>{};
      for (var tripIndex = 0; tripIndex < trips.length; tripIndex += 1) {
        final trip = trips[tripIndex];
        final tripId = _text(trip['id']);
        if (tripId.isEmpty) continue;
        tripRows[tripId] = <String, dynamic>{...trip, 'sortOrder': tripIndex};
        final messages = _mapList(trip['messages']);
        for (
          var messageIndex = 0;
          messageIndex < messages.length;
          messageIndex += 1
        ) {
          final message = messages[messageIndex];
          final messageId = _text(message['id']);
          if (messageId.isEmpty) continue;
          messageRows['$tripId::$messageId'] = <String, dynamic>{
            ...message,
            'tripId': tripId,
            'messageOrder': messageIndex,
          };
        }
      }
      _replaceFingerprints(_lastTripFingerprints, tripRows);
      _replaceFingerprints(_lastMessageFingerprints, messageRows);
      _lastTripLocationsFingerprint = _tripLocationFingerprint(state);
    }

    if (refreshAll || batch.reports) {
      final reports = _mapList(state['reports']);
      _replaceFingerprints(
        _lastReportFingerprints,
        <String, Map<String, dynamic>>{
          for (var index = 0; index < reports.length; index += 1)
            _text(reports[index]['id']): <String, dynamic>{
              ...reports[index],
              'sortOrder': index,
            },
        },
      );
    }

    if (refreshAll || batch.pushTokens) {
      final pushTokens = _mapList(state['pushTokens']);
      _replaceFingerprints(
        _lastPushTokenFingerprints,
        <String, Map<String, dynamic>>{
          for (var index = 0; index < pushTokens.length; index += 1)
            _text(pushTokens[index]['id']): <String, dynamic>{
              ...pushTokens[index],
              'sortOrder': index,
            },
        },
      );
    }
    if (refreshAll || batch.activity) {
      _lastActivityFingerprint = jsonEncode(_mapList(state['activity']));
    }
    if (refreshAll || batch.messageConversations) {
      final conversations = _mapList(state['messageConversations']);
      final conversationRows = <String, Map<String, dynamic>>{};
      final messageRows = <String, Map<String, dynamic>>{};
      for (
        var conversationIndex = 0;
        conversationIndex < conversations.length;
        conversationIndex += 1
      ) {
        final conversation = conversations[conversationIndex];
        final conversationId = _text(conversation['id']);
        if (conversationId.isEmpty) continue;
        conversationRows[conversationId] = <String, dynamic>{
          ...conversation,
          'sortOrder': conversationIndex,
        };
        final messages = _mapList(conversation['messages']);
        for (
          var messageIndex = 0;
          messageIndex < messages.length;
          messageIndex += 1
        ) {
          final message = messages[messageIndex];
          final messageId = _text(message['id']);
          if (messageId.isEmpty) continue;
          messageRows['$conversationId::$messageId'] = <String, dynamic>{
            ...message,
            'conversationId': conversationId,
            'messageOrder': messageIndex,
          };
        }
      }
      _replaceFingerprints(
        _lastMessageConversationFingerprints,
        conversationRows,
      );
      _replaceFingerprints(_lastMessageItemFingerprints, messageRows);
    }
  }

  void _replaceFingerprints(
    Map<String, String> target,
    Map<String, Map<String, dynamic>> rows,
  ) {
    target
      ..clear()
      ..addAll(<String, String>{
        for (final entry in rows.entries)
          if (entry.key.isNotEmpty) entry.key: jsonEncode(entry.value),
      });
  }

  static String _withDefaultSslMode(String databaseUrl) {
    final uri = Uri.parse(databaseUrl);
    final hasSslMode = uri.queryParameters.keys.any(
      (key) => key.toLowerCase() == 'sslmode',
    );
    if (hasSslMode) return databaseUrl;
    return uri
        .replace(
          queryParameters: <String, String>{
            ...uri.queryParameters,
            'sslmode': 'disable',
          },
        )
        .toString();
  }

  static Future<bool> _tryEnablePostgis(Connection connection) async {
    try {
      await connection.execute(
        'CREATE EXTENSION IF NOT EXISTS postgis',
        ignoreRows: true,
      );
      await connection.execute('SELECT postgis_version()');
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _ensureSchema(
    Connection connection, {
    required bool postgisAvailable,
  }) async {
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS piwibus_schema_migrations (
        version integer PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )
      ''', ignoreRows: true);
    await _applyMigration(
      connection,
      version: 1,
      statements: <String>[
        '''
        CREATE TABLE IF NOT EXISTS piwibus_state (
          id text PRIMARY KEY,
          payload jsonb NOT NULL,
          revision bigint NOT NULL DEFAULT 0,
          updated_at timestamptz NOT NULL DEFAULT now()
        )
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_trip_locations (
          trip_id text PRIMARY KEY,
          line_code text NOT NULL,
          owner_id text,
          status text NOT NULL,
          lat double precision NOT NULL,
          lng double precision NOT NULL,
          updated_at timestamptz NOT NULL DEFAULT now()
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_trip_locations_status_idx
        ON piwibus_trip_locations (status, updated_at DESC)
        ''',
      ],
    );
    if (postgisAvailable) {
      await _applyMigration(
        connection,
        version: 2,
        statements: <String>[
          '''
          ALTER TABLE piwibus_trip_locations
          ADD COLUMN IF NOT EXISTS location geography(Point, 4326)
          ''',
          '''
          CREATE INDEX IF NOT EXISTS piwibus_trip_locations_location_gix
          ON piwibus_trip_locations USING GIST (location)
          ''',
        ],
      );
    }
    await _applyMigration(
      connection,
      version: 3,
      statements: <String>[
        '''
        CREATE TABLE IF NOT EXISTS piwibus_meta (
          id text PRIMARY KEY,
          revision bigint NOT NULL DEFAULT 0,
          updated_at timestamptz NOT NULL DEFAULT now()
        )
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_users (
          id text PRIMARY KEY,
          sort_order integer NOT NULL,
          full_name text NOT NULL,
          email text NOT NULL UNIQUE,
          phone text NOT NULL DEFAULT '',
          profile_photo_data_url text,
          name_changed_at timestamptz,
          primary_role text NOT NULL,
          status text NOT NULL,
          created_at timestamptz NOT NULL,
          last_seen_at timestamptz,
          password_hash text NOT NULL,
          password_reset_hash text,
          password_reset_requested_at timestamptz,
          password_reset_expires_at timestamptz,
          password_reset_attempts integer NOT NULL DEFAULT 0,
          activity_read_at timestamptz,
          read_alert_ids text[] NOT NULL DEFAULT '{}',
          star_trip_ids text[] NOT NULL DEFAULT '{}',
          followed_trip_ids text[] NOT NULL DEFAULT '{}'
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_users_status_idx
        ON piwibus_users (status, created_at DESC)
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_sessions (
          session_id text PRIMARY KEY,
          current_user_id text,
          active_role text NOT NULL,
          section text NOT NULL,
          search_query text NOT NULL DEFAULT '',
          selected_line_code text,
          selected_trip_id text,
          favorite_line_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
          current_location jsonb,
          created_at timestamptz NOT NULL,
          last_seen_at timestamptz NOT NULL
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_sessions_last_seen_idx
        ON piwibus_sessions (last_seen_at DESC)
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_trips (
          id text PRIMARY KEY,
          sort_order integer NOT NULL,
          line_code text NOT NULL,
          owner_id text,
          owner_session_id text,
          owner_name text NOT NULL,
          owner_photo_data_url text,
          owner_role text NOT NULL,
          status text NOT NULL,
          started_at timestamptz NOT NULL,
          last_updated_at timestamptz NOT NULL,
          progress double precision NOT NULL,
          speed_kmh double precision NOT NULL,
          observers integer NOT NULL,
          max_observers integer NOT NULL DEFAULT 0,
          network_usage_bytes bigint NOT NULL DEFAULT 0,
          rating_average double precision NOT NULL,
          rating_count integer NOT NULL,
          liked_by_actor_ids text[] NOT NULL DEFAULT '{}',
          note text NOT NULL,
          live_location jsonb,
          off_route_since timestamptz,
          off_route_distance_meters double precision,
          path jsonb NOT NULL DEFAULT '[]'::jsonb,
          origin_label text NOT NULL,
          destination_label text NOT NULL
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_trips_status_updated_idx
        ON piwibus_trips (status, last_updated_at DESC)
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS liked_by_actor_ids text[] NOT NULL DEFAULT '{}'
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS owner_session_id text
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS off_route_since timestamptz
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS off_route_distance_meters double precision
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS max_observers integer NOT NULL DEFAULT 0
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS network_usage_bytes bigint NOT NULL DEFAULT 0
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_trip_messages (
          trip_id text NOT NULL REFERENCES piwibus_trips(id) ON DELETE CASCADE,
          message_id text NOT NULL,
          message_order integer NOT NULL,
          author_name text NOT NULL,
          role text NOT NULL,
          content text NOT NULL,
          created_at timestamptz NOT NULL,
          is_system boolean NOT NULL DEFAULT false,
          PRIMARY KEY (trip_id, message_id)
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_trip_messages_trip_idx
        ON piwibus_trip_messages (trip_id, message_order, created_at)
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_reports (
          id text PRIMARY KEY,
          sort_order integer NOT NULL,
          bus_number text NOT NULL,
          line_code text NOT NULL,
          line_label text NOT NULL,
          reporter_id text,
          reporter_name text NOT NULL,
          lat double precision NOT NULL,
          lng double precision NOT NULL,
          status text NOT NULL,
          created_at timestamptz NOT NULL,
          note text NOT NULL,
          confidence double precision NOT NULL
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_reports_status_created_idx
        ON piwibus_reports (status, created_at DESC)
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_push_tokens (
          id text PRIMARY KEY,
          sort_order integer NOT NULL,
          token text NOT NULL UNIQUE,
          platform text NOT NULL,
          session_id text,
          user_id text,
          status text NOT NULL,
          app_version text,
          build_number text,
          android_abi text,
          sdk_int integer NOT NULL DEFAULT 0,
          is_64_bit_process boolean NOT NULL DEFAULT false,
          device_model text,
          created_at timestamptz NOT NULL,
          last_seen_at timestamptz NOT NULL
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_push_tokens_status_idx
        ON piwibus_push_tokens (status, last_seen_at DESC)
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_activity (
          position integer PRIMARY KEY,
          title text NOT NULL,
          subtitle text NOT NULL,
          timestamp timestamptz NOT NULL,
          icon_key text NOT NULL,
          color_value bigint NOT NULL,
          audience_session_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
          audience_user_ids jsonb NOT NULL DEFAULT '[]'::jsonb
        )
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 4,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_activity
        ALTER COLUMN color_value TYPE bigint
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 5,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS app_version text
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS build_number text
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS android_abi text
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS sdk_int integer NOT NULL DEFAULT 0
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS is_64_bit_process boolean NOT NULL DEFAULT false
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS device_model text
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 6,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS password_reset_hash text
        ''',
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS password_reset_requested_at timestamptz
        ''',
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS password_reset_expires_at timestamptz
        ''',
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS password_reset_attempts integer NOT NULL DEFAULT 0
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 7,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS owner_session_id text
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS off_route_since timestamptz
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS off_route_distance_meters double precision
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS path jsonb
        ''',
        '''
        UPDATE piwibus_trips
        SET path = '[]'::jsonb
        WHERE path IS NULL
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN path SET DEFAULT '[]'::jsonb
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN path SET NOT NULL
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS origin_label text
        ''',
        '''
        UPDATE piwibus_trips
        SET origin_label = ''
        WHERE origin_label IS NULL
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN origin_label SET DEFAULT ''
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN origin_label SET NOT NULL
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS destination_label text
        ''',
        '''
        UPDATE piwibus_trips
        SET destination_label = ''
        WHERE destination_label IS NULL
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN destination_label SET DEFAULT ''
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN destination_label SET NOT NULL
        ''',
        '''
        ALTER TABLE piwibus_trip_messages
        ADD COLUMN IF NOT EXISTS is_system boolean
        ''',
        '''
        UPDATE piwibus_trip_messages
        SET is_system = false
        WHERE is_system IS NULL
        ''',
        '''
        ALTER TABLE piwibus_trip_messages
        ALTER COLUMN is_system SET DEFAULT false
        ''',
        '''
        ALTER TABLE piwibus_trip_messages
        ALTER COLUMN is_system SET NOT NULL
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS app_version text
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS build_number text
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS android_abi text
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS sdk_int integer
        ''',
        '''
        UPDATE piwibus_push_tokens
        SET sdk_int = 0
        WHERE sdk_int IS NULL
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ALTER COLUMN sdk_int SET DEFAULT 0
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ALTER COLUMN sdk_int SET NOT NULL
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS is_64_bit_process boolean
        ''',
        '''
        UPDATE piwibus_push_tokens
        SET is_64_bit_process = false
        WHERE is_64_bit_process IS NULL
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ALTER COLUMN is_64_bit_process SET DEFAULT false
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ALTER COLUMN is_64_bit_process SET NOT NULL
        ''',
        '''
        ALTER TABLE piwibus_push_tokens
        ADD COLUMN IF NOT EXISTS device_model text
        ''',
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS password_reset_hash text
        ''',
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS password_reset_requested_at timestamptz
        ''',
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS password_reset_expires_at timestamptz
        ''',
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS password_reset_attempts integer
        ''',
        '''
        UPDATE piwibus_users
        SET password_reset_attempts = 0
        WHERE password_reset_attempts IS NULL
        ''',
        '''
        ALTER TABLE piwibus_users
        ALTER COLUMN password_reset_attempts SET DEFAULT 0
        ''',
        '''
        ALTER TABLE piwibus_users
        ALTER COLUMN password_reset_attempts SET NOT NULL
        ''',
        '''
        ALTER TABLE piwibus_activity
        ADD COLUMN IF NOT EXISTS audience_session_ids jsonb
        ''',
        '''
        UPDATE piwibus_activity
        SET audience_session_ids = '[]'::jsonb
        WHERE audience_session_ids IS NULL
        ''',
        '''
        ALTER TABLE piwibus_activity
        ALTER COLUMN audience_session_ids SET DEFAULT '[]'::jsonb
        ''',
        '''
        ALTER TABLE piwibus_activity
        ALTER COLUMN audience_session_ids SET NOT NULL
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 8,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS max_observers integer
        ''',
        '''
        UPDATE piwibus_trips
        SET max_observers = observers
        WHERE max_observers IS NULL
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN max_observers SET DEFAULT 0
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN max_observers SET NOT NULL
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS network_usage_bytes bigint
        ''',
        '''
        UPDATE piwibus_trips
        SET network_usage_bytes = 0
        WHERE network_usage_bytes IS NULL
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN network_usage_bytes SET DEFAULT 0
        ''',
        '''
        ALTER TABLE piwibus_trips
        ALTER COLUMN network_usage_bytes SET NOT NULL
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 9,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS activity_read_at timestamptz
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 10,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS read_alert_ids text[] NOT NULL DEFAULT '{}'
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 11,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS followed_trip_ids text[] NOT NULL DEFAULT '{}'
        ''',
        '''
        ALTER TABLE piwibus_activity
        ADD COLUMN IF NOT EXISTS audience_user_ids jsonb
        ''',
        '''
        UPDATE piwibus_activity
        SET audience_user_ids = '[]'::jsonb
        WHERE audience_user_ids IS NULL
        ''',
        '''
        ALTER TABLE piwibus_activity
        ALTER COLUMN audience_user_ids SET DEFAULT '[]'::jsonb
        ''',
        '''
        ALTER TABLE piwibus_activity
        ALTER COLUMN audience_user_ids SET NOT NULL
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 12,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS liked_by_actor_ids text[] NOT NULL DEFAULT '{}'
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 13,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS star_trip_ids text[] NOT NULL DEFAULT '{}'
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 14,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS profile_photo_data_url text
        ''',
        '''
        ALTER TABLE piwibus_trips
        ADD COLUMN IF NOT EXISTS owner_photo_data_url text
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 15,
      statements: const <String>[
        '''
        ALTER TABLE piwibus_users
        ADD COLUMN IF NOT EXISTS name_changed_at timestamptz
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 16,
      statements: const <String>[
        '''
        CREATE TABLE IF NOT EXISTS piwibus_message_conversations (
          id text PRIMARY KEY,
          sort_order integer NOT NULL,
          kind text NOT NULL DEFAULT 'direct',
          participant_ids text[] NOT NULL DEFAULT '{}',
          trip_id text,
          title text NOT NULL DEFAULT '',
          subtitle text NOT NULL DEFAULT '',
          last_message_preview text NOT NULL DEFAULT '',
          last_message_id text,
          last_sender_id text,
          message_cursor integer NOT NULL DEFAULT 0,
          read_sequences jsonb NOT NULL DEFAULT '{}'::jsonb,
          created_at timestamptz NOT NULL,
          updated_at timestamptz NOT NULL
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_message_conversations_updated_idx
        ON piwibus_message_conversations (updated_at DESC)
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_message_conversations_participants_gin
        ON piwibus_message_conversations USING GIN (participant_ids)
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_message_items (
          conversation_id text NOT NULL REFERENCES piwibus_message_conversations(id) ON DELETE CASCADE,
          message_id text NOT NULL,
          message_order integer NOT NULL,
          sender_id text NOT NULL,
          sender_name text NOT NULL,
          body text NOT NULL,
          sequence integer NOT NULL,
          created_at timestamptz NOT NULL,
          PRIMARY KEY (conversation_id, message_id)
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_message_items_conversation_idx
        ON piwibus_message_items (conversation_id, sequence, created_at)
        ''',
      ],
    );
    await _applyMigration(
      connection,
      version: 17,
      statements: const <String>[
        '''
        CREATE TABLE IF NOT EXISTS piwibus_message_conversations (
          id text PRIMARY KEY,
          sort_order integer NOT NULL,
          kind text NOT NULL DEFAULT 'direct',
          participant_ids text[] NOT NULL DEFAULT '{}',
          trip_id text,
          title text NOT NULL DEFAULT '',
          subtitle text NOT NULL DEFAULT '',
          last_message_preview text NOT NULL DEFAULT '',
          last_message_id text,
          last_sender_id text,
          message_cursor integer NOT NULL DEFAULT 0,
          read_sequences jsonb NOT NULL DEFAULT '{}'::jsonb,
          created_at timestamptz NOT NULL,
          updated_at timestamptz NOT NULL
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_message_conversations_updated_idx
        ON piwibus_message_conversations (updated_at DESC)
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_message_conversations_participants_gin
        ON piwibus_message_conversations USING GIN (participant_ids)
        ''',
        '''
        CREATE TABLE IF NOT EXISTS piwibus_message_items (
          conversation_id text NOT NULL REFERENCES piwibus_message_conversations(id) ON DELETE CASCADE,
          message_id text NOT NULL,
          message_order integer NOT NULL,
          sender_id text NOT NULL,
          sender_name text NOT NULL,
          body text NOT NULL,
          sequence integer NOT NULL,
          created_at timestamptz NOT NULL,
          PRIMARY KEY (conversation_id, message_id)
        )
        ''',
        '''
        CREATE INDEX IF NOT EXISTS piwibus_message_items_conversation_idx
        ON piwibus_message_items (conversation_id, sequence, created_at)
        ''',
        '''
        DROP TABLE IF EXISTS piwibus_direct_messages
        ''',
        '''
        DROP TABLE IF EXISTS piwibus_direct_conversations
        ''',
        '''
        ALTER TABLE piwibus_users
        DROP COLUMN IF EXISTS messaging_public_key
        ''',
      ],
    );
  }

  static Future<void> _applyMigration(
    Connection connection, {
    required int version,
    required List<String> statements,
  }) async {
    final applied = await connection.execute(
      Sql.named(
        'SELECT 1 FROM piwibus_schema_migrations WHERE version = @version',
      ),
      parameters: <String, Object?>{'version': version},
    );
    if (applied.isNotEmpty) return;
    await connection.runTx((session) async {
      for (final statement in statements) {
        await session.execute(statement, ignoreRows: true);
      }
      await session.execute(
        Sql.named(
          'INSERT INTO piwibus_schema_migrations (version) VALUES (@version)',
        ),
        parameters: <String, Object?>{'version': version},
        ignoreRows: true,
      );
    });
  }

  static Map<String, Map<String, dynamic>> _sessionMap(Object? raw) {
    if (raw is! Map) return <String, Map<String, dynamic>>{};
    return raw.map((key, value) {
      final map = value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
      return MapEntry(key.toString(), <String, dynamic>{
        ...map,
        'sessionId': key.toString(),
      });
    });
  }

  static List<Map<String, dynamic>> _mapList(Object? value) {
    if (value is! List) return <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static List<Map<String, dynamic>> _jsonMapList(Object? value) {
    final decoded = _decodeJson(value);
    if (decoded is! List) return <Map<String, dynamic>>[];
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static Map<String, dynamic>? _jsonMapOrNull(Object? value) {
    final decoded = _decodeJson(value);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }

  static List<String> _jsonStringList(Object? value) {
    final decoded = _decodeJson(value);
    if (decoded is! List) return const <String>[];
    return decoded
        .map((item) => item?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _sqlStringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((item) => item?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static Object? _decodeJson(Object? value) {
    if (value is String) {
      try {
        return jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    return value;
  }

  static Map<String, dynamic> _userFromRow(Map<String, dynamic> row) {
    return <String, dynamic>{
      'id': _text(row['id']),
      'fullName': _text(row['full_name']),
      'email': _text(row['email']),
      'phone': _text(row['phone']),
      'profilePhotoDataUrl': _text(row['profile_photo_data_url']),
      'nameChangedAt': row['name_changed_at'] == null
          ? null
          : _iso(row['name_changed_at']),
      'primaryRole': _text(row['primary_role']),
      'status': _text(row['status']),
      'createdAt': _iso(row['created_at']),
      'lastSeenAt': row['last_seen_at'] == null
          ? null
          : _iso(row['last_seen_at']),
      'passwordHash': _text(row['password_hash']),
      'passwordResetHash': _text(row['password_reset_hash']),
      'passwordResetRequestedAt': row['password_reset_requested_at'] == null
          ? null
          : _iso(row['password_reset_requested_at']),
      'passwordResetExpiresAt': row['password_reset_expires_at'] == null
          ? null
          : _iso(row['password_reset_expires_at']),
      'passwordResetAttempts': _int(row['password_reset_attempts']),
      'activityReadAt': row['activity_read_at'] == null
          ? null
          : _iso(row['activity_read_at']),
      'readAlertIds':
          (row['read_alert_ids'] as List?)?.cast<String>().toList(
            growable: false,
          ) ??
          const <String>[],
      'starTripIds':
          (row['star_trip_ids'] as List?)?.cast<String>().toList(
            growable: false,
          ) ??
          const <String>[],
      'followedTripIds':
          (row['followed_trip_ids'] as List?)?.cast<String>().toList(
            growable: false,
          ) ??
          const <String>[],
    };
  }

  static Map<String, dynamic> _publicUser(Map<String, dynamic> user) {
    return <String, dynamic>{
      'id': _text(user['id']),
      'fullName': _text(user['fullName']),
      'email': _text(user['email']),
      'phone': _text(user['phone']),
      'profilePhotoDataUrl': _nullableText(user['profilePhotoDataUrl']),
      'nameChangedAt': user['nameChangedAt'] == null
          ? null
          : _text(user['nameChangedAt']),
      'primaryRole': _text(user['primaryRole']),
      'status': _text(user['status']),
      'createdAt': _text(user['createdAt']),
      'lastSeenAt': user['lastSeenAt'] == null
          ? null
          : _text(user['lastSeenAt']),
      'activityReadAt': user['activityReadAt'] == null
          ? null
          : _text(user['activityReadAt']),
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

  static String? _jsonOrNull(Object? value) {
    if (value == null) return null;
    return jsonEncode(value);
  }

  static DateTime _dateTime(Object? value) {
    if (value is DateTime) return value;
    return DateTime.tryParse(_text(value)) ?? DateTime.now();
  }

  static DateTime? _nullableDateTime(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(_text(value));
  }

  static String _iso(Object? value) {
    if (value is DateTime) return value.toIso8601String();
    return _text(value);
  }

  static bool _isValidLatLng(double lat, double lng) {
    if (lat.isNaN || lng.isNaN) return false;
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  static String? _nullableText(Object? value) {
    final text = _text(value);
    return text.isEmpty ? null : text;
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';

  static int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double _double(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? double.nan;
  }

  static double _finiteDouble(Object? value) {
    final parsed = _double(value);
    return parsed.isFinite ? parsed : 0.0;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((item) => item?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  String _tripLocationFingerprint(Map<String, dynamic> state) {
    final trips = _mapList(state['trips']);
    final rows = <Map<String, Object?>>[];
    for (final trip in trips) {
      if (_text(trip['status']) != 'actif') continue;
      final liveLocation = trip['liveLocation'];
      if (liveLocation is! Map) continue;
      final lat = _double(liveLocation['lat'] ?? liveLocation['latitude']);
      final lng = _double(liveLocation['lng'] ?? liveLocation['longitude']);
      if (!_isValidLatLng(lat, lng)) continue;
      final timestamp = _text(
        liveLocation['timestamp'] ?? liveLocation['updatedAt'],
      );
      final updatedAt = DateTime.tryParse(timestamp) ?? DateTime.now();
      rows.add(<String, Object?>{
        'trip_id': _text(trip['id']),
        'line_code': _text(trip['line_code']),
        'owner_id': _text(trip['owner_id']),
        'status': _text(trip['status']),
        'lat': lat,
        'lng': lng,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      });
    }
    rows.sort((a, b) => _text(a['trip_id']).compareTo(_text(b['trip_id'])));
    return jsonEncode(rows);
  }
}

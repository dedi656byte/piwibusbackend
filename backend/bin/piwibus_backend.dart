import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../lib/src/ops_logger.dart';
import '../lib/src/password_reset_email_service.dart';
import '../lib/src/production_config.dart';
import '../lib/src/push_notifications.dart';
import '../lib/src/rate_limiter.dart';
import '../lib/src/redis_realtime.dart';
import '../lib/src/store.dart';

const String _backendBuildLabel = '2026-06-25-live-timeout-v1';
const Duration _realtimeSnapshotDebounce = Duration(milliseconds: 100);
const Duration _realtimeKeepAliveInterval = Duration(seconds: 30);
const double _realtimeRelevanceRadiusMeters = 2500;
const Duration _adminJwtTtl = Duration(hours: 8);
const int _adminSessionMaxAgeSeconds = 8 * 60 * 60;
const int _maxJsonBodyBytes = 64 * 1024;
const String _adminSessionCookieName = 'piwibus_admin_token';
const String _webSocketProtocolName = 'piwibus.realtime';
const String _webSocketAuthProtocolPrefix = 'piwibus.auth.';
const String _adminAssetVersion = '20260913-v2';
const String _openStreetMapTileHost = 'https://tile.openstreetmap.org';
const String _contentSecurityPolicy =
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data: https://tile.openstreetmap.org; "
    "connect-src 'self' ws: wss:; frame-ancestors 'none'; object-src 'none'; "
    "base-uri 'none'";

Future<void> main(List<String> args) async {
  final host =
      _argValue(args, '--host') ??
      Platform.environment['PIWIBUS_BACKEND_HOST'] ??
      '127.0.0.1';
  final port =
      int.tryParse(
        _argValue(args, '--port') ??
            Platform.environment['PIWIBUS_BACKEND_PORT'] ??
            '8080',
      ) ??
      8080;
  final corsOrigin = Platform.environment['PIWIBUS_CORS_ORIGIN'] ?? '*';
  const logger = OpsLogger();
  final productionConfig = ProductionConfig.fromEnvironment();
  productionConfig.validateOrThrow();
  final passwordResetEmail = PasswordResetEmailService.fromEnvironment(
    logger: logger,
  );
  if (productionConfig.isProduction &&
      !productionConfig.allowDevDefaults &&
      !passwordResetEmail.enabled) {
    throw StateError(
      'Configuration SMTP requise en production pour le mot de passe oublie '
      '(PIWIBUS_SMTP_HOST, PIWIBUS_SMTP_USERNAME, PIWIBUS_SMTP_PASSWORD, '
      'PIWIBUS_MAIL_FROM).',
    );
  }
  final redis = await RedisRealtime.openFromEnvironment(logger: logger);

  final store = await PiwibusStore.load();
  if (redis != null) {
    store.attachChangePublisher(redis.publishChange);
    store.listenToExternalChanges(redis.remoteChanges);
  }
  final jwtCodec = _JwtCodec.fromEnvironment();
  final metrics = _MetricsRegistry();
  final snapshotPollCursors = _BoundedSnapshotCursorCache();
  final pushNotifications = PushNotificationService.fromEnvironment(
    logger: logger,
  );
  final mapTileClient = http.Client();
  final rateLimiter = RateLimiter(
    limitPerMinute:
        int.tryParse(
          Platform.environment['PIWIBUS_RATE_LIMIT_PER_MINUTE'] ?? '',
        ) ??
        180,
    redis: redis,
    trustProxyHeaders: _envFlag('PIWIBUS_TRUST_PROXY_HEADERS'),
  );
  const defaultStaleTripTimeout = Duration(seconds: 150);
  final staleTripTimeout = _durationFromEnvSeconds(
    'PIWIBUS_STALE_TRIP_TIMEOUT_SECONDS',
    defaultStaleTripTimeout,
  );
  final staleTripSweepInterval = _durationFromEnvSeconds(
    'PIWIBUS_STALE_TRIP_SWEEP_SECONDS',
    const Duration(seconds: 30),
  );
  void sendTripCancellationNotice(JsonMap notice) {
    final tokens = _stringList(notice['tokens']);
    final tripId = _string(notice['tripId']);
    final lineLabel = _string(notice['lineLabel']);
    final reason = _string(notice['reason']);
    final notificationType = _string(notice['notificationType']).isEmpty
        ? 'trip_stopped_system'
        : _string(notice['notificationType']);
    final lastLocation = notice['lastLocation'];
    final latText = lastLocation is Map ? _string(lastLocation['lat']) : '';
    final lngText = lastLocation is Map ? _string(lastLocation['lng']) : '';
    final tripPayload = latText.isNotEmpty && lngText.isNotEmpty
        ? 'trip-ended:$tripId:$latText:$lngText'
        : 'trip-ended:$tripId';
    final locationText = lastLocation is Map
        ? ' Derniere position: $latText / $lngText.'
        : '';
    unawaited(
      pushNotifications.sendToTokens(
        tokens: tokens,
        title: 'Trajet $lineLabel interrompu',
        body: '$reason$locationText',
        data: <String, String>{
          'type': notificationType,
          'tripId': tripId,
          'lineCode': _string(notice['lineCode']),
          'lineLabel': lineLabel,
          'reason': reason,
          'payload': tripPayload,
          if (latText.isNotEmpty) 'lat': latText,
          if (lngText.isNotEmpty) 'lng': lngText,
        },
      ),
    );
  }

  void sendTripCancellationNoticesFromSnapshot(JsonMap payload) {
    final rawNotices = payload.remove('_systemTripCancellationNotices');
    if (rawNotices is! Iterable) return;
    for (final notice in rawNotices) {
      if (notice is Map<String, dynamic>) {
        sendTripCancellationNotice(notice);
      } else if (notice is Map) {
        sendTripCancellationNotice(Map<String, dynamic>.from(notice));
      }
    }
  }

  var staleTripExpiryInFlight = false;
  Future<void> expireStaleTrips() async {
    if (staleTripExpiryInFlight) return;
    staleTripExpiryInFlight = true;
    try {
      final notices = await store.expireStaleActiveTrips(
        timeout: staleTripTimeout,
      );
      for (final notice in notices) {
        sendTripCancellationNotice(notice);
      }
      final offRouteNotices = await store.expireOffRouteActiveTrips();
      for (final notice in offRouteNotices) {
        sendTripCancellationNotice(notice);
      }
      await store.pruneRetainedHistory();
    } catch (error, stackTrace) {
      logger.error('Live trip sweep failed', const {}, error, stackTrace);
    } finally {
      staleTripExpiryInFlight = false;
    }
  }

  final staleTripExpiryTimer = Timer.periodic(
    staleTripSweepInterval,
    (_) => unawaited(expireStaleTrips()),
  );
  unawaited(expireStaleTrips());
  final router = Router();
  final adminWebDir = Directory(
    p.join(File.fromUri(Platform.script).parent.parent.path, 'admin_web'),
  );
  Future<String> sessionIdFor(Request request) =>
      store.ensureSession(_sessionIdFromRequest(request, jwtCodec));
  Future<String> adminSessionIdFor(Request request) async {
    final rawSessionId = _sessionIdFromRequest(request, jwtCodec);
    if (rawSessionId == null || rawSessionId.trim().isEmpty) {
      throw StateError('Session administrateur requise.');
    }
    final sessionId = await store.ensureSession(rawSessionId);
    if (!store.sessionCanAdmin(sessionId)) {
      throw StateError('Acces administrateur requis.');
    }
    return sessionId;
  }

  JsonMap adminDashboardFor(String sessionId) {
    return <String, dynamic>{
      ...store.adminDashboard(sessionId, metrics: metrics.snapshot()),
      'csrfToken': jwtCodec.csrfToken(sessionId),
    };
  }

  router.get('/health', (Request request) => _text('ok'));
  router.get('/ready', (Request request) async {
    try {
      await store.checkReady();
      return _json(
        _readinessPayload(
          store: store,
          redis: redis,
          productionConfig: productionConfig,
          pushNotifications: pushNotifications,
          passwordResetEmail: passwordResetEmail,
        ),
      );
    } catch (error) {
      return _json(
        _readinessPayload(
          store: store,
          redis: redis,
          productionConfig: productionConfig,
          pushNotifications: pushNotifications,
          passwordResetEmail: passwordResetEmail,
          status: 'degraded',
          error: error.toString(),
        ),
        statusCode: 503,
      );
    }
  });
  router.get('/metrics', (Request request) {
    return Response.ok(
      metrics.render(),
      headers: const {
        HttpHeaders.contentTypeHeader: 'text/plain; version=0.0.4',
      },
    );
  });
  router.post('/admin/auth/login', (Request request) async {
    try {
      final sessionId = await sessionIdFor(request);
      final body = await _readJson(request);
      await store.adminSignIn(sessionId, body);
      final token = jwtCodec.issue(sessionId, ttl: _adminJwtTtl);
      return _json(<String, dynamic>{
        'csrfToken': jwtCodec.csrfToken(sessionId),
        'dashboard': adminDashboardFor(sessionId),
      }, headers: _adminSessionCookieHeaders(request, token));
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });
  router.post('/admin/auth/logout', (Request request) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      _requireAdminCsrf(request, sessionId, jwtCodec);
      await store.logout(sessionId);
      return _json(<String, dynamic>{
        'ok': true,
      }, headers: _clearAdminSessionCookieHeaders(request));
    } catch (error) {
      return _error(
        error is StateError ? error.message : error.toString(),
        statusCode: 401,
      );
    }
  });
  router.get('/admin/dashboard', (Request request) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      return _json(
        adminDashboardFor(sessionId),
        headers: _adminSessionCookieHeaders(
          request,
          jwtCodec.issue(sessionId, ttl: _adminJwtTtl),
        ),
      );
    } catch (error) {
      return _error(
        error is StateError ? error.message : error.toString(),
        statusCode: 401,
      );
    }
  });
  router.get('/admin/map-data', (Request request) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      return _json(store.adminMapData(sessionId));
    } catch (error) {
      return _error(
        error is StateError ? error.message : error.toString(),
        statusCode: 401,
      );
    }
  });
  router.get('/admin/map-tiles/<z|[0-9]+>/<x|[0-9]+>/<y|[0-9]+>.png', (
    Request request,
    String z,
    String x,
    String y,
  ) async {
    try {
      await adminSessionIdFor(request);
      return await _proxyOpenStreetMapTile(mapTileClient, z: z, x: x, y: y);
    } catch (error) {
      return _text(
        error is StateError ? error.message : error.toString(),
        statusCode: error is StateError ? 400 : 502,
      );
    }
  });
  router.get('/admin/events', (Request request) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      metrics.sseOpened();
      return Response.ok(
        _adminEventStream(request, store, sessionId, metrics),
        headers: _eventStreamHeaders(),
      );
    } catch (error) {
      return _error(
        error is StateError ? error.message : error.toString(),
        statusCode: 401,
      );
    }
  });
  router.get('/admin/ws', (Request request) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      final handler = webSocketHandler(
        (WebSocketChannel channel, String? protocol) =>
            _handleAdminWebSocket(request, channel, store, sessionId, metrics),
        protocols: const <String>[_webSocketProtocolName],
        allowedOrigins: _webSocketAllowedOrigins(corsOrigin),
      );
      return handler(request);
    } on HijackException {
      rethrow;
    } catch (error) {
      return _error(
        error is StateError ? error.message : error.toString(),
        statusCode: 401,
      );
    }
  });
  router.post('/admin/trips/<id>/stop', (Request request, String id) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      _requireAdminCsrf(request, sessionId, jwtCodec);
      final body = await _readJson(request);
      final bodyReason = _boundedString(
        body['reason'],
        500,
        fieldName: 'Motif',
      );
      final reason = bodyReason.isEmpty
          ? 'Trajet arrete par un administrateur Piwibus.'
          : bodyReason;
      final audience = store.notificationAudienceForTrip(id);
      await store.stopTrip(sessionId, id, reason: reason);
      if (audience.tokens.isNotEmpty) {
        unawaited(
          pushNotifications.sendToTokens(
            tokens: audience.tokens,
            title: 'Trajet live arrete',
            body: reason,
            data: <String, String>{
              'type': 'trip_stopped_admin',
              'tripId': id,
              'reason': reason,
            },
          ),
        );
      }
      return _json(adminDashboardFor(sessionId));
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });
  router.patch('/admin/users/<id>/status', (Request request, String id) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      _requireAdminCsrf(request, sessionId, jwtCodec);
      await store.toggleUserStatus(sessionId, id);
      return _json(adminDashboardFor(sessionId));
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });
  router.patch('/admin/reports/<id>/status', (
    Request request,
    String id,
  ) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      _requireAdminCsrf(request, sessionId, jwtCodec);
      final body = await _readJson(request);
      await store.updateReportStatus(
        sessionId,
        id,
        _boundedString(body['status'], 32, fieldName: 'Statut'),
      );
      return _json(adminDashboardFor(sessionId));
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });
  router.delete('/admin/reports/<id>', (Request request, String id) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      _requireAdminCsrf(request, sessionId, jwtCodec);
      await store.deleteReport(sessionId, id);
      return _json(adminDashboardFor(sessionId));
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });
  router.post('/admin/notifications', (Request request) async {
    try {
      final sessionId = await adminSessionIdFor(request);
      _requireAdminCsrf(request, sessionId, jwtCodec);
      final body = await _readJson(request);
      final titleInput = _boundedString(body['title'], 120, fieldName: 'Titre');
      final title = titleInput.isEmpty ? 'Message Piwibus' : titleInput;
      final message = _boundedString(body['body'], 1000, fieldName: 'Message');
      if (message.isEmpty) {
        throw StateError('Le contenu de la notification est requis.');
      }
      final targetTypeInput = _boundedString(
        body['targetType'],
        32,
        fieldName: 'Audience',
      );
      final targetType = targetTypeInput.isEmpty ? 'all' : targetTypeInput;
      final targetId = _boundedString(
        body['targetId'],
        120,
        fieldName: 'Cible',
      );
      final audience = store.adminNotificationAudience(
        targetType: targetType,
        targetId: targetId,
        lineCode: _boundedString(body['lineCode'], 32, fieldName: 'Ligne'),
        radiusMeters: double.tryParse(_string(body['radiusMeters'])) ?? 2000,
      );
      await store.recordAdminNotification(
        sessionId: sessionId,
        title: title,
        body: message,
        targetLabel: '$targetType ${targetId.isEmpty ? "global" : targetId}',
        audienceSessionIds: audience.sessionIds,
      );
      if (audience.tokens.isNotEmpty) {
        await pushNotifications.sendToTokens(
          tokens: audience.tokens,
          title: title,
          body: message,
          data: <String, String>{
            'type': 'admin_broadcast',
            'targetType': targetType,
            if (targetId.isNotEmpty) 'targetId': targetId,
          },
        );
      }
      return _json(<String, dynamic>{
        ...adminDashboardFor(sessionId),
        'notificationResult': <String, dynamic>{
          'targetType': targetType,
          'targetId': targetId,
          'tokens': audience.tokens.length,
          'sessions': audience.sessionIds.length,
        },
      });
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });
  router.get('/snapshot', (Request request) async {
    final sessionId = await sessionIdFor(request);
    final revision = store.sharedRevision;
    final snapshot = store.snapshot(sessionId);
    final clientSnapshotRevision = _clientSnapshotRevision(request);
    final includeLines = _includeLines(request, snapshot);

    if (clientSnapshotRevision == revision && !includeLines) {
      return _json(_emptyRealtimeDeltaEnvelope(revision));
    }

    // Comme pour le WebSocket/SSE, on essaie de renvoyer un delta plutot que
    // le snapshot complet aux clients qui utilisent ce polling REST de
    // secours (fallback quand le temps reel n'est pas disponible). On ne le
    // fait que lorsque les lignes ne sont pas demandees : elles ne font pas
    // partie du curseur de delta et changent rarement.
    if (!includeLines) {
      final scope = store.realtimeScope(sessionId);
      final snapshotForDelta = _snapshotForRequest(
        request,
        store.snapshot(sessionId, includeLines: false),
        jwtCodec,
      );
      final currentCursor = _RealtimeSnapshotCursor.fromSnapshot(
        snapshotForDelta,
        scope,
      );
      final previousCursor = snapshotPollCursors[sessionId];
      snapshotPollCursors[sessionId] = currentCursor;
      if (previousCursor != null) {
        final envelope = _realtimeDeltaEnvelope(
          previous: previousCursor,
          current: currentCursor,
          currentActivity: snapshotForDelta['activity'],
          revision: revision,
        );
        return _json(envelope ?? _emptyRealtimeDeltaEnvelope(revision));
      }
    }

    return _json(_snapshotForRequest(request, snapshot, jwtCodec));
  });
  router.get('/events', (Request request) async {
    final sessionId = await sessionIdFor(request);
    metrics.sseOpened();
    return Response.ok(
      _snapshotEventStream(request, store, sessionId, jwtCodec, metrics),
      headers: _eventStreamHeaders(),
    );
  });
  router.get('/ws', (Request request) async {
    final sessionId = await sessionIdFor(request);
    final handler = webSocketHandler(
      (channel, _) => _handleSnapshotWebSocket(
        request,
        channel,
        store,
        sessionId,
        jwtCodec,
        metrics,
      ),
      protocols: const <String>[_webSocketProtocolName],
      allowedOrigins: _webSocketAllowedOrigins(corsOrigin),
      pingInterval: const Duration(seconds: 25),
    );
    return handler(request);
  });
  router.get('/lines', (Request request) {
    final query = request.url.queryParameters['q'];
    return _json(<String, dynamic>{
      ...store.lineMetadata(),
      'items': store.lines(query),
    });
  });
  router.get('/lines/metadata', (Request request) {
    return _json(store.lineMetadata());
  });
  router.get('/lines/<code>', (Request request, String code) {
    final line = store.lineByCode(code);
    if (line == null) {
      return _error('Ligne introuvable.', statusCode: 404);
    }
    return _json(<String, dynamic>{'item': line});
  });
  router.get('/trips/nearby', (Request request) async {
    try {
      final lat = double.tryParse(request.url.queryParameters['lat'] ?? '');
      final lng = double.tryParse(request.url.queryParameters['lng'] ?? '');
      if (lat == null || lng == null) {
        return _error('Parametres lat et lng requis.');
      }
      final radiusMeters =
          double.tryParse(
            request.url.queryParameters['radiusMeters'] ??
                request.url.queryParameters['radius'] ??
                '',
          ) ??
          1000;
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 20;
      if (_queryFlag(request, 'countsByLine') ||
          _queryFlag(request, 'lineCounts')) {
        return _json(<String, dynamic>{
          'items': await store.nearbyTripLineCounts(
            lat: lat,
            lng: lng,
            radiusMeters: radiusMeters,
            limit: limit,
          ),
        });
      }
      return _json(<String, dynamic>{
        'items': await store.nearbyTrips(
          lat: lat,
          lng: lng,
          radiusMeters: radiusMeters,
          limit: limit,
        ),
      });
    } catch (error) {
      return _error(error.toString());
    }
  });
  router.get('/trips/<id>/status', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    final item = store.tripStatusForSession(sessionId, id);
    if (item == null) {
      return _error('Trajet introuvable.', statusCode: 404);
    }
    return _json(
      _snapshotForRequest(request, <String, dynamic>{
        'sessionId': sessionId,
        'item': item,
      }, jwtCodec),
    );
  });

  router.post('/auth/sign-in', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.signIn(sessionId, body),
    );
  });
  router.post('/auth/register', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.register(sessionId, body),
    );
  });
  Future<Response> handlePasswordResetRequest(Request request) async {
    try {
      final body = await _readJson(request);
      return _json(
        await store.requestPasswordReset(
          body,
          includeResetCode: _includePasswordResetCode(),
          sendCode: passwordResetEmail.enabled
              ? passwordResetEmail.sendPasswordResetCode
              : null,
        ),
      );
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  }

  router.post('/auth/password-reset/request', handlePasswordResetRequest);
  router.post('/auth/password-reset/request/', handlePasswordResetRequest);
  router.post('/auth/reset-password/request', handlePasswordResetRequest);
  router.post('/auth/forgot-password', handlePasswordResetRequest);

  Future<Response> handlePasswordResetConfirm(Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.confirmPasswordReset(sessionId, body),
    );
  }

  router.post('/auth/password-reset/confirm', handlePasswordResetConfirm);
  router.post('/auth/password-reset/confirm/', handlePasswordResetConfirm);
  router.post('/auth/reset-password/confirm', handlePasswordResetConfirm);
  router.post('/auth/logout', (Request request) async {
    final sessionId = await sessionIdFor(request);
    final snapshot = await store.logout(sessionId);
    sendTripCancellationNoticesFromSnapshot(snapshot);
    return _json(_snapshotForRequest(request, snapshot, jwtCodec));
  });
  // Marque toutes les activités comme lues pour l'utilisateur connecté.
  // Persiste en base de données — survit à la désinstallation de l'app.
  Future<Response> handleProfileUpdate(Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.updateProfile(sessionId, body),
    );
  }

  router.post('/me/profile', handleProfileUpdate);
  router.patch('/me/profile', handleProfileUpdate);
  router.patch('/me/activity-read-at', (Request request) async {
    try {
      final sessionId = await sessionIdFor(request);
      final activityReadAt = await store.setActivityReadAt(sessionId);
      return _json(<String, dynamic>{
        'ok': true,
        'activityReadAt': activityReadAt,
      });
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });
  // Marque une alerte spécifique comme lue pour l'utilisateur connecté.
  // Persiste dans read_alert_ids — survit à la désinstallation.
  router.patch('/me/read-alerts/<reportId>', (
    Request request,
    String reportId,
  ) async {
    try {
      final sessionId = await sessionIdFor(request);
      await store.markAlertRead(sessionId, reportId);
      return _json(<String, dynamic>{'ok': true});
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });
  router.post('/session/role', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.switchRole(sessionId, _string(body['role'])),
    );
  });
  router.post('/session/section', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.setSection(sessionId, _string(body['section'])),
    );
  });
  router.post('/session/search', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.setSearchQuery(sessionId, _rawString(body['query'])),
    );
  });
  router.post('/session/selected-line', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.selectLine(sessionId, _string(body['lineCode'])),
    );
  });
  router.post('/session/selected-trip', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.selectTrip(sessionId, _string(body['tripId'])),
    );
  });
  router.post('/session/location', (Request request) async {
    final sessionId = await sessionIdFor(request);
    final compact = _compactResponseRequested(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.updateSessionLocation(
        sessionId,
        body,
        includeSnapshot: !compact,
      ),
    );
  });
  router.post('/favorites/toggle', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.toggleFavorite(sessionId, _string(body['lineCode'])),
    );
  });
  router.post('/devices/push-token', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.registerPushToken(sessionId, body),
    );
  });

  // Sert la photo de profil d'un utilisateur en tant que ressource binaire
  // cacheable (ETag + Cache-Control longue duree), plutot que de la
  // reembarquer en base64 dans chaque snapshot/JSON qui reference cet
  // utilisateur (voir _servedPhotoUrlFor / _withServedPhotoUrls).
  router.get('/users/<id>/photo', (Request request, String id) async {
    try {
      final dataUrl = store.rawProfilePhotoDataUrlForUser(id);
      if (dataUrl == null || dataUrl.isEmpty) {
        return _text('Photo introuvable.', statusCode: 404);
      }
      final comma = dataUrl.indexOf(',');
      if (comma <= 0 || comma >= dataUrl.length - 1) {
        return _text('Photo invalide.', statusCode: 404);
      }
      final header = dataUrl.substring(0, comma);
      final contentType = _contentTypeFromDataUrlHeader(header);
      final etag = '"${_shortHash(dataUrl)}"';
      final ifNoneMatch = request.headers[HttpHeaders.ifNoneMatchHeader];
      final cacheHeaders = <String, String>{
        HttpHeaders.cacheControlHeader: 'public, max-age=604800, immutable',
        HttpHeaders.etagHeader: etag,
      };
      if (ifNoneMatch != null && ifNoneMatch.trim() == etag) {
        return Response(304, headers: cacheHeaders);
      }
      final bytes = base64Decode(dataUrl.substring(comma + 1));
      return Response.ok(
        bytes,
        headers: <String, String>{
          HttpHeaders.contentTypeHeader: contentType,
          ...cacheHeaders,
        },
      );
    } catch (_) {
      return _text('Photo indisponible.', statusCode: 404);
    }
  });

  router.get('/messages/peers/nearby-line', (Request request) async {
    try {
      final sessionId = await sessionIdFor(request);
      final lineCode =
          request.url.queryParameters['lineCode'] ??
          request.url.queryParameters['line_code'] ??
          '';
      // Only allow nearby searches scoped to a specific selected line.
      // If no lineCode is provided or it's empty, return an empty list
      // instead of performing a global or ambiguous search.
      if (lineCode.trim().isEmpty) {
        return _json(<String, dynamic>{'items': <Object>[]});
      }
      final radiusMeters =
          double.tryParse(
            request.url.queryParameters['radiusMeters'] ??
                request.url.queryParameters['radius_meters'] ??
                request.url.queryParameters['radius'] ??
                '',
          ) ??
          1000;
      final freshnessMinutes = int.tryParse(
        request.url.queryParameters['freshnessMinutes'] ??
            request.url.queryParameters['freshness_minutes'] ??
            '',
      );
      final limit = int.tryParse(request.url.queryParameters['limit'] ?? '');
      final includeProfilePhotoDataUrl =
          _queryFlag(request, 'includeProfilePhotoDataUrl') ||
          _queryFlag(request, 'include_profile_photo_data_url') ||
          _queryFlag(request, 'includeAvatarData') ||
          _queryFlag(request, 'include_avatar_data');
      // If the provided lineCode doesn't match a known line, return empty
      // result rather than an error to avoid surprising the client UI.
      try {
        final items = store.messagePeerCandidatesForLine(
          sessionId,
          lineCode: lineCode,
          radiusMeters: radiusMeters,
          freshness: freshnessMinutes == null
              ? null
              : Duration(minutes: freshnessMinutes),
          limit: limit ?? 20,
          includeProfilePhotoDataUrl: includeProfilePhotoDataUrl,
        );
        // Si une photo est demandee (opt-in, desactive par defaut), on la
        // sert via l'URL cacheable plutot que le base64 brut.
        final servedItems = items.map((item) {
          final user = item['user'];
          if (user is! Map) return item;
          return <String, dynamic>{
            ...item,
            'user': _withServedUserPhoto(request, user),
          };
        }).toList(growable: false);
        return _json(<String, dynamic>{'items': servedItems});
      } on StateError {
        return _json(<String, dynamic>{'items': <Object>[]});
      }
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });

  router.get('/messages/conversations', (Request request) async {
    try {
      final sessionId = await sessionIdFor(request);
      return _json(<String, dynamic>{
        'items': store.messageConversationsForSession(sessionId),
      });
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });

  router.post('/messages/conversations', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.startMessageConversation(sessionId, body),
    );
  });

  router.get('/messages/conversations/<id>/messages', (
    Request request,
    String id,
  ) async {
    try {
      final sessionId = await sessionIdFor(request);
      final query = request.url.queryParameters;
      final afterSequence =
          int.tryParse(
            query['afterSequence'] ?? query['after_sequence'] ?? '',
          ) ??
          0;
      final beforeSequence =
          int.tryParse(
            query['beforeSequence'] ?? query['before_sequence'] ?? '',
          ) ??
          0;
      final limit = int.tryParse(query['limit'] ?? '') ?? 40;
      return _json(<String, dynamic>{
        'items': store.conversationMessages(
          sessionId,
          id,
          afterSequence: afterSequence,
          beforeSequence: beforeSequence,
          limit: limit,
        ),
      });
    } catch (error) {
      return _error(error is StateError ? error.message : error.toString());
    }
  });

  router.post('/messages/conversations/<id>/messages', (
    Request request,
    String id,
  ) async {
    final sessionId = await sessionIdFor(request);
    final compact = _compactResponseRequested(request);
    try {
      final body = await _readJson(request);
      final result = await store.sendMessageItem(sessionId, id, body);
      final message = result['message'] is Map
          ? Map<String, dynamic>.from(result['message'] as Map)
          : store.lastMessageForConversation(id);
      try {
        final recipientIds = _stringList(result['recipientUserIds']);
        for (final recipientId in recipientIds) {
          if (recipientId.isEmpty) continue;
          final audience = store.notificationAudienceForUser(recipientId);
          if (audience.tokens.isNotEmpty) {
            final data = <String, String>{
              'type': 'message_created',
              'conversationId': id,
              'messageId': _string(message?['id']),
              'senderId': _string(
                message?['senderId'] ?? message?['sender_id'],
              ),
              'createdAt': _string(
                message?['createdAt'] ?? message?['created_at'],
              ),
            };
            unawaited(
              pushNotifications.sendToTokens(
                tokens: audience.tokens,
                title: 'Nouveau message',
                body: 'Vous avez reçu un nouveau message',
                data: data,
              ),
            );
          }
        }
      } catch (_) {
        // Push failures are non-fatal for message delivery.
      }
      if (compact) {
        return _json(<String, dynamic>{
          'ok': true,
          if (message != null) 'message': message,
        });
      }
      return _json(_snapshotForRequest(request, result, jwtCodec));
    } catch (error) {
      if (error is StateError) {
        return _error(error.message);
      }
      if (error is FormatException) {
        return _error(error.message);
      }
      return _error(error.toString());
    }
  });

  router.patch('/messages/conversations/<id>/read', (
    Request request,
    String id,
  ) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.markMessageConversationRead(sessionId, id, body),
    );
  });

  router.post('/trips', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(request, jwtCodec, (body) async {
      final snapshot = await store.startTrip(sessionId, body);
      sendTripCancellationNoticesFromSnapshot(snapshot);
      final lineCode = _string(body['lineCode']);
      final audience = store.notificationAudienceNearLine(lineCode);
      if (audience.sessionIds.isNotEmpty) {
        await store.publishActivity(
          title: 'Nouveau bus sur la ligne',
          subtitle: 'Un nouveau bus vient d’apparaître sur la ligne $lineCode.',
          iconKey: 'bus',
          colorValue: 0xFF0F8B8D,
          audienceSessionIds: audience.sessionIds,
        );
      }
      unawaited(
        pushNotifications.sendToTokens(
          tokens: audience.tokens,
          title: 'Nouveau bus sur la ligne',
          body: 'Un nouveau bus vient d’apparaître sur la ligne $lineCode.',
          data: <String, String>{'type': 'trip_started', 'lineCode': lineCode},
        ),
      );
      return snapshot;
    });
  });
  router.patch('/trips/<id>/location', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    final compact = _compactResponseRequested(request);
    return _handleJson(request, jwtCodec, (body) async {
      try {
        return await store.updateTripLocation(
          sessionId,
          id,
          body,
          includeSnapshot: !compact,
        );
      } on SystemTripCancellationException catch (error) {
        sendTripCancellationNotice(error.notice);
        throw StateError(error.message);
      }
    });
  });
  router.post('/trips/<id>/heartbeat', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    final compact = _compactResponseRequested(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) =>
          store.heartbeatTrip(sessionId, id, body, includeSnapshot: !compact),
    );
  });
  router.post('/trips/<id>/stop', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(request, jwtCodec, (body) async {
      final snapshot = await store.stopTrip(
        sessionId,
        id,
        reason: _string(body['reason']),
      );
      return snapshot;
    });
  });
  router.post('/trips/<id>/messages', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.sendMessage(
        sessionId,
        id,
        _string(body['content']),
        messageId: _string(body['messageId']),
        createdAt: _string(body['createdAt']),
      ),
    );
  });
  router.post('/trips/<id>/ratings', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(request, jwtCodec, (body) {
      final score = int.tryParse(_string(body['score']));
      if (score == null || score < 1 || score > 5) {
        throw const FormatException(
          'La note doit être un entier entre 1 et 5.',
        );
      }
      return store.rateTrip(sessionId, id, score);
    });
  });
  router.post('/trips/<id>/likes', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(request, jwtCodec, (body) async {
      final liked = body['liked'];
      if (liked is! bool) {
        throw const FormatException('Etat du like requis.');
      }
      final result = await store.setTripLike(sessionId, id, liked);
      if (result['tripLikeChanged'] == true && liked) {
        final audience = store.notificationAudienceForTripOwner(id);
        unawaited(
          pushNotifications.sendToTokens(
            tokens: audience.tokens,
            title: 'Nouveau j\'aime',
            body: 'Votre trajet a reçu un nouveau j\'aime.',
            data: <String, String>{'type': 'trip_liked', 'tripId': id},
          ),
        );
      }
      result.remove('tripLikeChanged');
      return result;
    });
  });

  router.post('/reports', (Request request) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(request, jwtCodec, (body) async {
      final snapshot = await store.createReport(sessionId, body);
      final lineCode = _string(body['lineCode']).isEmpty
          ? _string(snapshot['selectedLineCode'])
          : _string(body['lineCode']);
      final audience = store.notificationAudienceNearLine(lineCode);
      if (audience.sessionIds.isNotEmpty) {
        await store.publishActivity(
          title: 'Nouvelle alerte proche',
          subtitle:
              'Une alerte sur la ligne $lineCode a été publiée à moins de 200 m.',
          iconKey: 'report',
          colorValue: 0xFFEE964B,
          audienceSessionIds: audience.sessionIds,
        );
      }
      unawaited(
        pushNotifications.sendToTokens(
          tokens: audience.tokens,
          title: 'Nouveau signalement',
          body:
              'Une alerte vient d’être publiée sur la ligne $lineCode près de vous.',
          data: <String, String>{
            'type': 'report_created',
            'lineCode': lineCode,
          },
        ),
      );
      return snapshot;
    });
  });
  router.patch('/reports/<id>/status', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) =>
          store.updateReportStatus(sessionId, id, _string(body['status'])),
    );
  });
  router.delete('/reports/<id>', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (_) => store.deleteReport(sessionId, id),
    );
  });
  router.patch('/users/<id>/status', (Request request, String id) async {
    final sessionId = await sessionIdFor(request);
    return _handleJson(
      request,
      jwtCodec,
      (body) => store.toggleUserStatus(sessionId, id),
    );
  });
  router.get('/admin', (Request request) {
    return _serveAdminWebFile(adminWebDir, 'index.html');
  });
  router.get('/admin/', (Request request) {
    return _serveAdminWebFile(adminWebDir, 'index.html');
  });
  router.get('/admin/<path|.*>', (Request request, String path) {
    final targetPath = path.trim().isEmpty ? 'index.html' : path.trim();
    return _serveAdminWebFile(adminWebDir, targetPath);
  });

  final handler = Pipeline()
      .addMiddleware(_corsMiddleware(corsOrigin))
      .addMiddleware(metrics.middleware())
      .addMiddleware(_requestLogMiddleware(logger))
      .addMiddleware(_storageReadinessMiddleware(store))
      .addMiddleware(rateLimiter.middleware())
      .addHandler(router.call);

  final server = await shelf_io.serve(handler, host, port);
  logger.info('Piwibus backend running', <String, Object?>{
    'url': 'http://${server.address.host}:${server.port}',
    'storage': store.storageBackend,
    'redisRealtime': redis != null,
    'pushNotifications': pushNotifications.enabled,
    'staleTripTimeoutSeconds': staleTripTimeout.inSeconds,
    'staleTripSweepSeconds': staleTripSweepInterval.inSeconds,
  });

  var shutdownStarted = false;
  Future<void> shutdown(String reason) async {
    if (shutdownStarted) return;
    shutdownStarted = true;
    logger.info('Piwibus backend stopping', <String, Object?>{
      'reason': reason,
    });
    staleTripExpiryTimer.cancel();
    await server.close(force: false);
    pushNotifications.close();
    mapTileClient.close();
    await redis?.close();
    await store.close();
    logger.info('Piwibus backend stopped');
  }

  ProcessSignal.sigint.watch().listen((_) {
    unawaited(shutdown('sigint'));
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) {
      unawaited(shutdown('sigterm'));
    });
  }
}

Future<Response> _handleJson(
  Request request,
  _JwtCodec jwtCodec,
  FutureOr<JsonMap> Function(JsonMap body) action,
) async {
  try {
    final body = await _readJson(request);
    return _json(_snapshotForRequest(request, await action(body), jwtCodec));
  } catch (error) {
    if (error is StateError) {
      return _error(error.message);
    }
    if (error is FormatException) {
      return _error(error.message);
    }
    return _error(error.toString());
  }
}

Future<JsonMap> _readJson(Request request) async {
  final declaredLength = int.tryParse(
    request.headers[HttpHeaders.contentLengthHeader] ?? '',
  );
  if (declaredLength != null && declaredLength > _maxJsonBodyBytes) {
    throw const FormatException('Le corps JSON est trop volumineux.');
  }

  final bytes = BytesBuilder(copy: false);
  var totalBytes = 0;
  await for (final chunk in request.read()) {
    totalBytes += chunk.length;
    if (totalBytes > _maxJsonBodyBytes) {
      throw const FormatException('Le corps JSON est trop volumineux.');
    }
    bytes.add(chunk);
  }
  final raw = utf8.decode(bytes.takeBytes());
  if (raw.trim().isEmpty) {
    return <String, dynamic>{};
  }
  final decoded = jsonDecode(raw);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  throw const FormatException('Le corps JSON doit être un objet.');
}

JsonMap _readinessPayload({
  required PiwibusStore store,
  required RedisRealtime? redis,
  required ProductionConfig productionConfig,
  required PushNotificationService pushNotifications,
  required PasswordResetEmailService passwordResetEmail,
  String status = 'ok',
  String? error,
}) {
  return <String, dynamic>{
    'status': status,
    'storage': store.storageBackend,
    'databaseBacked': store.isDatabaseBacked,
    'geospatialQueries': store.supportsGeospatialQueries,
    'environment': productionConfig.environment,
    'redisRealtime': redis != null,
    'pushNotifications': pushNotifications.enabled,
    'build': _backendBuildLabel,
    'adminAssetVersion': _adminAssetVersion,
    if (error != null && error.isNotEmpty) 'error': error,
    'features': <String, dynamic>{
      'passwordReset': true,
      'passwordResetEmail': passwordResetEmail.enabled,
      'adminWeb': true,
    },
  };
}

Middleware _storageReadinessMiddleware(PiwibusStore store) {
  return (Handler innerHandler) {
    return (Request request) async {
      if (_skipsStorageReadiness(request)) {
        return innerHandler(request);
      }
      try {
        await store.checkReady();
      } catch (error) {
        return _json(
          <String, dynamic>{
            'error': 'Service temporairement indisponible.',
            'status': 'degraded',
            'detail': error.toString(),
          },
          statusCode: 503,
          headers: const <String, String>{'Retry-After': '10'},
        );
      }
      return innerHandler(request);
    };
  };
}

bool _skipsStorageReadiness(Request request) {
  final path = request.url.path;
  if (path == 'health' || path == 'ready' || path == 'metrics') {
    return true;
  }
  if (path == 'admin' || path == 'admin/') return true;
  if (path.startsWith('admin/map-tiles/')) return true;
  if (path.startsWith('admin/')) {
    final assetPath = path.substring('admin/'.length);
    return _looksLikeAdminStaticAsset(assetPath);
  }
  return false;
}

bool _looksLikeAdminStaticAsset(String path) {
  if (path.isEmpty) return true;
  final extension = p.extension(path).toLowerCase();
  return switch (extension) {
    '.html' ||
    '.css' ||
    '.js' ||
    '.json' ||
    '.svg' ||
    '.png' ||
    '.jpg' ||
    '.jpeg' ||
    '.ico' ||
    '.map' => true,
    _ => false,
  };
}

Response _json(
  Object body, {
  int statusCode = 200,
  Map<String, String>? headers,
}) {
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      if (headers != null) ...headers,
    },
  );
}

Response _text(String body, {int statusCode = 200}) {
  return Response(
    statusCode,
    body: body,
    headers: const {HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8'},
  );
}

Response _error(String message, {int statusCode = 400}) {
  return _json(<String, dynamic>{'error': message}, statusCode: statusCode);
}

Future<Response> _proxyOpenStreetMapTile(
  http.Client client, {
  required String z,
  required String x,
  required String y,
}) async {
  final zoom = int.tryParse(z);
  final tileX = int.tryParse(x);
  final tileY = int.tryParse(y);
  if (zoom == null || tileX == null || tileY == null) {
    throw StateError('Tuile OpenStreetMap invalide.');
  }
  if (zoom < 0 || zoom > 19) {
    throw StateError('Zoom OpenStreetMap invalide.');
  }
  final tileCount = 1 << zoom;
  if (tileX < 0 || tileX >= tileCount || tileY < 0 || tileY >= tileCount) {
    throw StateError('Coordonnees de tuile OpenStreetMap invalides.');
  }

  final uri = Uri.parse('$_openStreetMapTileHost/$zoom/$tileX/$tileY.png');
  final upstream = await client
      .get(
        uri,
        headers: const <String, String>{
          HttpHeaders.userAgentHeader: 'PiwibusAdminMap/1.0',
          HttpHeaders.acceptHeader: 'image/png,image/*;q=0.8,*/*;q=0.5',
        },
      )
      .timeout(const Duration(seconds: 8));
  if (upstream.statusCode != 200) {
    return _text(
      'Tuile OpenStreetMap indisponible (${upstream.statusCode}).',
      statusCode: 502,
    );
  }
  return Response.ok(
    Stream<List<int>>.value(upstream.bodyBytes),
    headers: const <String, String>{
      HttpHeaders.contentTypeHeader: 'image/png',
      HttpHeaders.cacheControlHeader:
          'public, max-age=86400, stale-while-revalidate=604800',
      'X-Content-Type-Options': 'nosniff',
    },
  );
}

Response _serveAdminWebFile(Directory adminWebDir, String requestedPath) {
  final normalizedPath = p.normalize(requestedPath).replaceAll('\\', '/');
  if (normalizedPath.startsWith('../') ||
      normalizedPath == '..' ||
      p.isAbsolute(normalizedPath)) {
    return _text('Fichier admin invalide.', statusCode: 400);
  }
  final effectivePath = _adminWebEffectivePath(normalizedPath);
  final file = File(p.join(adminWebDir.path, effectivePath));
  final absoluteRoot = p.normalize(adminWebDir.absolute.path);
  final absoluteFile = p.normalize(file.absolute.path);
  if (!p.isWithin(absoluteRoot, absoluteFile) && absoluteRoot != absoluteFile) {
    return _text('Fichier admin invalide.', statusCode: 400);
  }
  if (!file.existsSync()) {
    return _text('Fichier admin introuvable.', statusCode: 404);
  }
  return Response.ok(
    file.openRead(),
    headers: <String, String>{
      HttpHeaders.contentTypeHeader: _contentTypeForPath(file.path),
      HttpHeaders.cacheControlHeader: 'no-store, max-age=0, must-revalidate',
      HttpHeaders.pragmaHeader: 'no-cache',
      HttpHeaders.expiresHeader: '0',
      'Content-Security-Policy': _contentSecurityPolicy,
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
    },
  );
}

String _adminWebEffectivePath(String normalizedPath) {
  if (normalizedPath == 'app.$_adminAssetVersion.js') {
    return 'app.js';
  }
  if (normalizedPath == 'styles.$_adminAssetVersion.css') {
    return 'styles.css';
  }
  if (normalizedPath == 'chart.umd.min.$_adminAssetVersion.js') {
    return 'chart.umd.min.js';
  }
  return normalizedPath;
}

String _contentTypeForPath(String path) {
  final extension = p.extension(path).toLowerCase();
  return switch (extension) {
    '.html' => 'text/html; charset=utf-8',
    '.css' => 'text/css; charset=utf-8',
    '.js' => 'application/javascript; charset=utf-8',
    '.json' => 'application/json; charset=utf-8',
    '.svg' => 'image/svg+xml',
    '.png' => 'image/png',
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.ico' => 'image/x-icon',
    _ => 'application/octet-stream',
  };
}

JsonMap _emptyRealtimeDeltaEnvelope(int revision) {
  return <String, dynamic>{
    'type': 'snapshotDelta',
    'revision': revision,
    'data': const <String, dynamic>{},
  };
}

int? _clientSnapshotRevision(Request request) {
  final raw =
      request.url.queryParameters['snapshotRevision'] ??
      request.url.queryParameters['snapshot_revision'] ??
      request.url.queryParameters['revision'];
  if (raw == null) return null;
  final revision = int.tryParse(raw.trim());
  return revision != null && revision >= 0 ? revision : null;
}

class _RealtimeSnapshotCursor {
  _RealtimeSnapshotCursor({
    required this.values,
    required this.activityFingerprint,
    required this.trips,
    required this.reports,
    required this.users,
    required this.messageConversations,
  });

  final JsonMap values;
  final String activityFingerprint;
  final List<JsonMap> trips;
  final List<JsonMap> reports;
  final List<JsonMap> users;
  final List<JsonMap> messageConversations;

  factory _RealtimeSnapshotCursor.fromSnapshot(
    JsonMap snapshot,
    JsonMap scope,
  ) {
    const collectionKeys = <String>{
      'trips',
      'reports',
      'users',
      'messageConversations',
    };
    const ignoredKeys = <String>{'sessionId', 'lines', 'activity'};
    final values = <String, dynamic>{};
    for (final entry in snapshot.entries) {
      if (collectionKeys.contains(entry.key) ||
          ignoredKeys.contains(entry.key)) {
        continue;
      }
      values[entry.key] = entry.value;
    }

    return _RealtimeSnapshotCursor(
      values: values,
      activityFingerprint: jsonEncode(
        snapshot['activity'] ?? const <JsonMap>[],
      ),
      trips: _mapList(snapshot['trips'])
          .where((item) => _tripRelevantToRealtimeScope(item, scope))
          .toList(growable: false),
      reports: _mapList(snapshot['reports'])
          .where((item) => _reportRelevantToRealtimeScope(item, scope))
          .toList(growable: false),
      users: _mapList(snapshot['users'])
          .where((item) => _userRelevantToRealtimeScope(item, snapshot, scope))
          .toList(growable: false),
      messageConversations: _mapList(
        snapshot['messageConversations'],
      ).toList(growable: false),
    );
  }

  JsonMap collectionSnapshot() {
    return <String, dynamic>{
      'trips': trips,
      'reports': reports,
      'users': users,
      'messageConversations': messageConversations,
    };
  }
}

// Cache bornee (LRU) des curseurs de snapshot utilises par le polling REST
// de secours (voir GET /snapshot). Sans borne, une session_id arbitraire
// (ou un client qui en genere beaucoup) ferait grossir cette map
// indefiniment ; on garde donc seulement les `maxEntries` sessions les plus
// recemment actives et on evince les plus anciennes.
class _BoundedSnapshotCursorCache {
  // Valeur fixe : aucun appelant n'a jamais eu besoin de la personnaliser,
  // d'ou la suppression du parametre de constructeur correspondant
  // (lint `unused_element_parameter`).
  final int maxEntries = 2000;

  // Map (LinkedHashMap par defaut en Dart) : l'ordre d'insertion est
  // preserve, ce qui nous sert a implementer un ordre "least recently used".
  final Map<String, _RealtimeSnapshotCursor> _entries =
      <String, _RealtimeSnapshotCursor>{};

  _RealtimeSnapshotCursor? operator [](String sessionId) {
    final cursor = _entries.remove(sessionId);
    if (cursor == null) return null;
    // Reinsertion en fin de map pour marquer cette entree comme la plus
    // recemment utilisee.
    _entries[sessionId] = cursor;
    return cursor;
  }

  void operator []=(String sessionId, _RealtimeSnapshotCursor cursor) {
    _entries.remove(sessionId);
    _entries[sessionId] = cursor;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

JsonMap _fullRealtimeSnapshotEnvelope({
  required JsonMap current,
  required int revision,
}) {
  return <String, dynamic>{
    'type': 'snapshot',
    'revision': revision,
    'data': current,
  };
}

JsonMap? _realtimeDeltaEnvelope({
  required _RealtimeSnapshotCursor previous,
  required _RealtimeSnapshotCursor current,
  required Object? currentActivity,
  required int revision,
}) {
  final set = <String, dynamic>{};
  final keys = <String>{...previous.values.keys, ...current.values.keys};
  for (final key in keys) {
    if (!_jsonEquivalent(previous.values[key], current.values[key])) {
      set[key] = current.values[key];
    }
  }
  if (previous.activityFingerprint != current.activityFingerprint) {
    set['activity'] = currentActivity ?? const <JsonMap>[];
  }

  final collections = <String, dynamic>{};
  final previousCollections = previous.collectionSnapshot();
  final currentCollections = current.collectionSnapshot();
  final tripDelta = _entityCollectionDelta(
    'trips',
    previousCollections,
    currentCollections,
    (_) => true,
    changedItem: _realtimeTripPatch,
  );
  if (tripDelta != null) collections['trips'] = tripDelta;

  final reportDelta = _entityCollectionDelta(
    'reports',
    previousCollections,
    currentCollections,
    (_) => true,
  );
  if (reportDelta != null) collections['reports'] = reportDelta;

  final userDelta = _entityCollectionDelta(
    'users',
    previousCollections,
    currentCollections,
    (_) => true,
  );
  if (userDelta != null) collections['users'] = userDelta;

  final messageConversationDelta = _entityCollectionDelta(
    'messageConversations',
    previousCollections,
    currentCollections,
    (_) => true,
    changedItem: _realtimeMessageConversationPatch,
  );
  if (messageConversationDelta != null) {
    collections['messageConversations'] = messageConversationDelta;
  }

  if (set.isEmpty && collections.isEmpty) return null;
  return <String, dynamic>{
    'revision': revision,
    if (set.isNotEmpty) 'set': set,
    if (collections.isNotEmpty) 'collections': collections,
  };
}

JsonMap? _entityCollectionDelta(
  String key,
  JsonMap previous,
  JsonMap current,
  bool Function(JsonMap item) relevant, {
  JsonMap Function(JsonMap previousItem, JsonMap currentItem)? changedItem,
}) {
  final previousItems = _mapList(previous[key]);
  final currentItems = _mapList(current[key]);
  final previousById = <String, JsonMap>{
    for (final item in previousItems)
      if (_string(item['id']).isNotEmpty) _string(item['id']): item,
  };
  final currentById = <String, JsonMap>{
    for (final item in currentItems)
      if (_string(item['id']).isNotEmpty) _string(item['id']): item,
  };
  final upsert = <JsonMap>[];
  final remove = <String>[];
  final ids = <String>{...previousById.keys, ...currentById.keys};
  for (final id in ids) {
    final previousItem = previousById[id];
    final currentItem = currentById[id];
    final wasRelevant = previousItem != null && relevant(previousItem);
    final isRelevant = currentItem != null && relevant(currentItem);
    if (currentItem == null || !isRelevant) {
      if (wasRelevant) remove.add(id);
      continue;
    }
    if (!wasRelevant) {
      upsert.add(currentItem);
    } else if (!_jsonEquivalent(previousItem, currentItem)) {
      upsert.add(changedItem?.call(previousItem, currentItem) ?? currentItem);
    }
  }

  final previousOrder = previousItems
      .where(relevant)
      .map((item) => _string(item['id']))
      .where((id) => id.isNotEmpty)
      .toList(growable: false);
  final currentOrder = currentItems
      .where(relevant)
      .map((item) => _string(item['id']))
      .where((id) => id.isNotEmpty)
      .toList(growable: false);
  final orderChanged = !_jsonEquivalent(previousOrder, currentOrder);
  if (upsert.isEmpty && remove.isEmpty && !orderChanged) return null;

  return <String, dynamic>{
    if (changedItem != null && upsert.isNotEmpty) 'patch': true,
    if (upsert.isNotEmpty) 'upsert': upsert,
    if (remove.isNotEmpty) 'remove': remove,
    if (orderChanged || upsert.isNotEmpty || remove.isNotEmpty)
      'order': currentOrder,
  };
}

JsonMap _realtimeTripPatch(JsonMap previousItem, JsonMap currentItem) {
  final patch = <String, dynamic>{'id': _string(currentItem['id'])};
  for (final key in currentItem.keys) {
    if (key == 'id') continue;
    if (!_jsonEquivalent(previousItem[key], currentItem[key])) {
      patch[key] = currentItem[key];
    }
  }
  for (final key in previousItem.keys) {
    if (key == 'id' || currentItem.containsKey(key)) continue;
    patch[key] = null;
  }
  return patch;
}

JsonMap _realtimeMessageConversationPatch(
  JsonMap previousItem,
  JsonMap currentItem,
) {
  final patch = <String, dynamic>{'id': _string(currentItem['id'])};
  for (final key in currentItem.keys) {
    if (key == 'id') continue;
    if (!_jsonEquivalent(previousItem[key], currentItem[key])) {
      patch[key] = currentItem[key];
    }
  }
  for (final key in previousItem.keys) {
    if (key == 'id' || currentItem.containsKey(key)) continue;
    patch[key] = null;
  }
  return patch;
}

bool _tripRelevantToRealtimeScope(JsonMap trip, JsonMap scope) {
  if (scope['canViewAll'] == true) return true;
  final selectedTripId = _string(scope['selectedTripId']);
  if (selectedTripId.isNotEmpty && _string(trip['id']) == selectedTripId) {
    return true;
  }
  final selectedLineCode = _normalizeSnapshotCode(scope['selectedLineCode']);
  final lineCode = _normalizeSnapshotCode(
    trip['line_code'] ?? trip['lineCode'],
  );
  if (selectedLineCode.isNotEmpty && selectedLineCode == lineCode) return true;

  final scopeLocation = _freshScopeLocation(scope['currentLocation']);
  final liveLocation = trip['liveLocation'] ?? trip['live_location'];
  final tripLatLng = _latLngFromMap(liveLocation);
  if (scopeLocation == null || tripLatLng == null) return false;
  return _distanceMeters(
        scopeLocation.lat,
        scopeLocation.lng,
        tripLatLng.lat,
        tripLatLng.lng,
      ) <=
      _realtimeRelevanceRadiusMeters;
}

bool _reportRelevantToRealtimeScope(JsonMap report, JsonMap scope) {
  if (scope['canViewAll'] == true) return true;
  final selectedLineCode = _normalizeSnapshotCode(scope['selectedLineCode']);
  final lineCode = _normalizeSnapshotCode(
    report['lineCode'] ?? report['line_code'],
  );
  if (selectedLineCode.isNotEmpty && selectedLineCode == lineCode) return true;

  final scopeLocation = _freshScopeLocation(scope['currentLocation']);
  final reportLatLng = _latLngFromMap(report['location']);
  if (scopeLocation == null || reportLatLng == null) return false;
  return _distanceMeters(
        scopeLocation.lat,
        scopeLocation.lng,
        reportLatLng.lat,
        reportLatLng.lng,
      ) <=
      _realtimeRelevanceRadiusMeters;
}

bool _userRelevantToRealtimeScope(
  JsonMap user,
  JsonMap current,
  JsonMap scope,
) {
  if (scope['canViewAll'] == true) return true;
  // If the client has a selected line, the snapshot will include only the
  // users near that line; in that case consider all snapshot users relevant
  // so they are included in realtime updates.
  final selectedLineCode = _normalizeSnapshotCode(scope['selectedLineCode']);
  if (selectedLineCode.isNotEmpty) return true;

  final currentUser = current['currentUser'];
  final currentUserId = currentUser is Map ? _string(currentUser['id']) : '';
  return currentUserId.isNotEmpty && _string(user['id']) == currentUserId;
}

({double lat, double lng})? _freshScopeLocation(Object? value) {
  final location = _latLngFromMap(value);
  if (location == null) return null;
  if (value is Map) {
    final timestamp = DateTime.tryParse(
      _string(value['timestamp'] ?? value['updatedAt'] ?? value['updated_at']),
    );
    if (timestamp != null &&
        DateTime.now().toUtc().difference(timestamp.toUtc()) >
            const Duration(minutes: 5)) {
      return null;
    }
  }
  return location;
}

({double lat, double lng})? _latLngFromMap(Object? value) {
  if (value is! Map) return null;
  final lat = double.tryParse(_string(value['lat'] ?? value['latitude']));
  final lng = double.tryParse(_string(value['lng'] ?? value['longitude']));
  if (lat == null || lng == null) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  return (lat: lat, lng: lng);
}

String _normalizeSnapshotCode(Object? value) {
  final text = _string(value);
  if (text.isEmpty) return text;
  final digits = int.tryParse(text.replaceAll(RegExp(r'[^0-9]'), ''));
  return digits?.toString() ?? text;
}

bool _jsonEquivalent(Object? left, Object? right) =>
    jsonEncode(left) == jsonEncode(right);

double _distanceMeters(
  double fromLat,
  double fromLng,
  double toLat,
  double toLng,
) {
  const earthRadiusMeters = 6371008.8;
  final lat1 = fromLat * 3.141592653589793 / 180;
  final lat2 = toLat * 3.141592653589793 / 180;
  final dLat = (toLat - fromLat) * 3.141592653589793 / 180;
  final dLng = (toLng - fromLng) * 3.141592653589793 / 180;
  final sinLat = math.sin(dLat / 2);
  final sinLng = math.sin(dLng / 2);
  final h = sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLng * sinLng;
  return earthRadiusMeters * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}

Stream<List<int>> _snapshotEventStream(
  Request request,
  PiwibusStore store,
  String sessionId,
  _JwtCodec jwtCodec,
  _MetricsRegistry metrics,
) {
  late final StreamController<List<int>> controller;
  StreamSubscription<int>? subscription;
  Timer? keepAliveTimer;
  Timer? snapshotDebounceTimer;
  _RealtimeSnapshotCursor? lastSnapshot;
  final clientSnapshotRevision = _clientSnapshotRevision(request);

  void addText(String text) {
    if (!controller.isClosed) {
      controller.add(utf8.encode(text));
    }
  }

  void sendSnapshot() {
    final revision = store.sharedRevision;
    final scope = store.realtimeScope(sessionId);
    final currentSnapshot = _snapshotForRequest(
      request,
      store.snapshot(sessionId, includeLines: false),
      jwtCodec,
    );
    final currentCursor = _RealtimeSnapshotCursor.fromSnapshot(
      currentSnapshot,
      scope,
    );
    if (lastSnapshot == null && clientSnapshotRevision == revision) {
      lastSnapshot = currentCursor;
      final envelope = _emptyRealtimeDeltaEnvelope(revision);
      addText('event: ${envelope['type']}\n');
      addText('data: ${jsonEncode(envelope)}\n\n');
      return;
    }
    final previousCursor = lastSnapshot;
    final envelope = previousCursor == null
        ? _fullRealtimeSnapshotEnvelope(
            current: currentSnapshot,
            revision: revision,
          )
        : _realtimeDeltaEnvelope(
            previous: previousCursor,
            current: currentCursor,
            currentActivity: currentSnapshot['activity'],
            revision: revision,
          );
    lastSnapshot = currentCursor;
    if (envelope == null) return;
    addText('event: ${envelope['type']}\n');
    addText('data: ${jsonEncode(envelope)}\n\n');
  }

  void scheduleSnapshot() {
    if (snapshotDebounceTimer?.isActive ?? false) return;
    snapshotDebounceTimer = Timer(_realtimeSnapshotDebounce, sendSnapshot);
  }

  controller = StreamController<List<int>>(
    onListen: () {
      store.setSessionOnline(sessionId);
      addText('retry: 3000\n\n');
      sendSnapshot();
      subscription = store.sharedChanges.listen((_) => scheduleSnapshot());
      keepAliveTimer = Timer.periodic(
        _realtimeKeepAliveInterval,
        (_) => addText(': ping ${DateTime.now().toIso8601String()}\n\n'),
      );
    },
    onCancel: () async {
      store.setSessionOffline(sessionId);
      keepAliveTimer?.cancel();
      snapshotDebounceTimer?.cancel();
      metrics.sseClosed();
      await subscription?.cancel();
    },
  );

  return controller.stream;
}

Stream<List<int>> _adminEventStream(
  Request request,
  PiwibusStore store,
  String sessionId,
  _MetricsRegistry metrics,
) {
  late final StreamController<List<int>> controller;
  StreamSubscription<int>? subscription;
  Timer? keepAliveTimer;
  Timer? snapshotDebounceTimer;

  void addText(String text) {
    if (!controller.isClosed) {
      controller.add(utf8.encode(text));
    }
  }

  void sendDashboard() {
    final payload = store.adminDashboard(
      sessionId,
      metrics: metrics.snapshot(),
    );
    addText('event: dashboard\n');
    addText('data: ${jsonEncode(payload)}\n\n');
  }

  void scheduleDashboard() {
    if (snapshotDebounceTimer?.isActive ?? false) return;
    snapshotDebounceTimer = Timer(
      const Duration(milliseconds: 750),
      sendDashboard,
    );
  }

  controller = StreamController<List<int>>(
    onListen: () {
      addText('retry: 3000\n\n');
      sendDashboard();
      subscription = store.sharedChanges.listen((_) => scheduleDashboard());
      keepAliveTimer = Timer.periodic(
        const Duration(seconds: 25),
        (_) => addText(': ping ${DateTime.now().toIso8601String()}\n\n'),
      );
    },
    onCancel: () async {
      keepAliveTimer?.cancel();
      snapshotDebounceTimer?.cancel();
      metrics.sseClosed();
      await subscription?.cancel();
    },
  );

  return controller.stream;
}

void _handleSnapshotWebSocket(
  Request request,
  WebSocketChannel channel,
  PiwibusStore store,
  String sessionId,
  _JwtCodec jwtCodec,
  _MetricsRegistry metrics,
) {
  StreamSubscription<int>? subscription;
  Timer? keepAliveTimer;
  Timer? snapshotDebounceTimer;
  _RealtimeSnapshotCursor? lastSnapshot;
  final clientSnapshotRevision = _clientSnapshotRevision(request);
  var closed = false;
  metrics.webSocketOpened();
  store.setSessionOnline(sessionId);

  void send(Object payload) {
    if (closed) return;
    channel.sink.add(jsonEncode(payload));
  }

  void sendSnapshot() {
    final revision = store.sharedRevision;
    final scope = store.realtimeScope(sessionId);
    final currentSnapshot = _snapshotForRequest(
      request,
      store.snapshot(sessionId, includeLines: false),
      jwtCodec,
    );
    final currentCursor = _RealtimeSnapshotCursor.fromSnapshot(
      currentSnapshot,
      scope,
    );
    if (lastSnapshot == null && clientSnapshotRevision == revision) {
      lastSnapshot = currentCursor;
      send(_emptyRealtimeDeltaEnvelope(revision));
      return;
    }
    final previousCursor = lastSnapshot;
    final envelope = previousCursor == null
        ? _fullRealtimeSnapshotEnvelope(
            current: currentSnapshot,
            revision: revision,
          )
        : _realtimeDeltaEnvelope(
            previous: previousCursor,
            current: currentCursor,
            currentActivity: currentSnapshot['activity'],
            revision: revision,
          );
    lastSnapshot = currentCursor;
    if (envelope == null) return;
    send(envelope);
  }

  void scheduleSnapshot() {
    if (snapshotDebounceTimer?.isActive ?? false) return;
    snapshotDebounceTimer = Timer(_realtimeSnapshotDebounce, sendSnapshot);
  }

  sendSnapshot();
  subscription = store.sharedChanges.listen((_) => scheduleSnapshot());
  keepAliveTimer = Timer.periodic(
    _realtimeKeepAliveInterval,
    (_) => send(<String, dynamic>{
      'type': 'ping',
      'timestamp': DateTime.now().toIso8601String(),
    }),
  );
  channel.stream.listen(
    (_) {},
    onDone: () async {
      closed = true;
      store.setSessionOffline(sessionId);
      keepAliveTimer?.cancel();
      snapshotDebounceTimer?.cancel();
      metrics.webSocketClosed();
      await subscription?.cancel();
    },
    onError: (_) async {
      closed = true;
      store.setSessionOffline(sessionId);
      keepAliveTimer?.cancel();
      snapshotDebounceTimer?.cancel();
      metrics.webSocketClosed();
      await subscription?.cancel();
    },
    cancelOnError: true,
  );
}

void _handleAdminWebSocket(
  Request request,
  WebSocketChannel channel,
  PiwibusStore store,
  String sessionId,
  _MetricsRegistry metrics,
) {
  StreamSubscription<int>? subscription;
  Timer? keepAliveTimer;
  Timer? snapshotDebounceTimer;
  var closed = false;
  metrics.webSocketOpened();

  void send(Object payload) {
    if (closed) return;
    channel.sink.add(jsonEncode(payload));
  }

  void sendDashboard() {
    send(<String, dynamic>{
      'type': 'dashboard',
      'data': store.adminDashboard(sessionId, metrics: metrics.snapshot()),
    });
  }

  void scheduleDashboard() {
    if (snapshotDebounceTimer?.isActive ?? false) return;
    snapshotDebounceTimer = Timer(
      const Duration(milliseconds: 750),
      sendDashboard,
    );
  }

  sendDashboard();
  subscription = store.sharedChanges.listen((_) => scheduleDashboard());
  keepAliveTimer = Timer.periodic(
    const Duration(seconds: 25),
    (_) => send(<String, dynamic>{
      'type': 'ping',
      'timestamp': DateTime.now().toIso8601String(),
    }),
  );
  channel.stream.listen(
    (_) {},
    onDone: () async {
      closed = true;
      keepAliveTimer?.cancel();
      snapshotDebounceTimer?.cancel();
      metrics.webSocketClosed();
      await subscription?.cancel();
    },
    onError: (_) async {
      closed = true;
      keepAliveTimer?.cancel();
      snapshotDebounceTimer?.cancel();
      metrics.webSocketClosed();
      await subscription?.cancel();
    },
    cancelOnError: true,
  );
}

Map<String, String> _eventStreamHeaders() {
  return const <String, String>{
    HttpHeaders.contentTypeHeader: 'text/event-stream; charset=utf-8',
    HttpHeaders.cacheControlHeader: 'no-cache, no-transform',
    'X-Accel-Buffering': 'no',
  };
}

JsonMap _snapshotForRequest(
  Request request,
  JsonMap snapshot,
  _JwtCodec jwtCodec,
) {
  final rawSessionId = snapshot['sessionId']?.toString() ?? '';
  final securedSnapshot = rawSessionId.isEmpty
      ? snapshot
      : <String, dynamic>{
          ...snapshot,
          'sessionId': jwtCodec.issue(rawSessionId),
        };
  final withPhotoUrls = _withServedPhotoUrls(request, securedSnapshot);
  if (_includeLines(request, withPhotoUrls)) return withPhotoUrls;
  return <String, dynamic>{...withPhotoUrls, 'lines': const <JsonMap>[]};
}

// --- Photos de profil servies via un endpoint dedie et cacheable ---------
//
// Plutot que d'embarquer `profilePhotoDataUrl` (base64) dans chaque
// snapshot/JSON qui reference un utilisateur (ce qui est renvoye a chaque
// poll/realtime et ne beneficie d'aucun cache HTTP), on remplace ce champ
// par une URL de service `/users/<id>/photo?v=<hash>` que le client peut
// telecharger une seule fois et mettre en cache via les entetes HTTP
// standard (voir la route GET /users/<id>/photo).

String _shortHash(String value) {
  return sha256.convert(utf8.encode(value)).toString().substring(0, 16);
}

String _contentTypeFromDataUrlHeader(String header) {
  final match = RegExp(r'^data:([^;]+)').firstMatch(header);
  return match?.group(1) ?? 'image/jpeg';
}

String? _servedPhotoUrlFor(
  Request request,
  String? userId,
  Object? photoDataUrl,
) {
  final id = _string(userId);
  final dataUrl = _string(photoDataUrl);
  if (id.isEmpty || dataUrl.isEmpty) return null;
  final scheme = _requestIsSecure(request) ? 'https' : request.requestedUri.scheme;
  // shelf_io reconstruit `requestedUri` depuis l'en-tete Host mais en retirant
  // le port (ex: `192.168.5.1:8080` devient `192.168.5.1`), ce qui rend l'URL
  // servie inatteignable derriere un proxy sur un port non standard. On lit
  // donc l'en-tete Host brut, qui preserve le port (nginx le transmet via
  // `$http_host`, voir deploy/nginx/piwibus.conf).
  final authority =
      request.headers[HttpHeaders.hostHeader]?.trim() ??
      request.requestedUri.authority;
  final hash = _shortHash(dataUrl);
  return '$scheme://$authority/users/$id/photo?v=$hash';
}

JsonMap _withServedUserPhoto(Request request, Object? value) {
  if (value is! Map) return <String, dynamic>{};
  final user = Map<String, dynamic>.from(value);
  final servedUrl = _servedPhotoUrlFor(
    request,
    _string(user['id']),
    user['profilePhotoDataUrl'],
  );
  if (servedUrl != null) {
    user['profilePhotoDataUrl'] = servedUrl;
  }
  return user;
}

JsonMap _withServedTripOwnerPhoto(Request request, JsonMap trip) {
  final servedUrl = _servedPhotoUrlFor(
    request,
    _string(trip['owner_id'] ?? trip['ownerId']),
    trip['owner_photo_data_url'] ?? trip['ownerPhotoDataUrl'],
  );
  if (servedUrl != null) {
    trip['owner_photo_data_url'] = servedUrl;
  }
  return trip;
}

JsonMap _withServedPhotoUrls(Request request, JsonMap snapshot) {
  final result = Map<String, dynamic>.from(snapshot);

  final currentUser = result['currentUser'];
  if (currentUser is Map) {
    result['currentUser'] = _withServedUserPhoto(request, currentUser);
  }

  final users = result['users'];
  if (users is List) {
    result['users'] = users
        .map((item) => _withServedUserPhoto(request, item))
        .toList(growable: false);
  }

  final trips = result['trips'];
  if (trips is List) {
    result['trips'] = trips
        .map(
          (item) => item is Map
              ? _withServedTripOwnerPhoto(request, Map<String, dynamic>.from(item))
              : item,
        )
        .toList(growable: false);
  }

  final messageConversations = result['messageConversations'];
  if (messageConversations is List) {
    result['messageConversations'] = messageConversations.map((item) {
      if (item is! Map) return item;
      final conversation = Map<String, dynamic>.from(item);
      final peerUser = conversation['peerUser'];
      if (peerUser is Map) {
        conversation['peerUser'] = _withServedUserPhoto(request, peerUser);
      }
      return conversation;
    }).toList(growable: false);
  }

  return result;
}

bool _includeLines(Request request, JsonMap snapshot) {
  if (request.url.queryParameters['includeLines'] == 'false') return false;

  final clientLineDataVersion =
      request.url.queryParameters['lineDataVersion']?.trim() ?? '';
  final serverLineDataVersion =
      snapshot['lineDataVersion']?.toString().trim() ?? '';
  if (clientLineDataVersion.isNotEmpty &&
      serverLineDataVersion.isNotEmpty &&
      clientLineDataVersion == serverLineDataVersion) {
    return false;
  }
  return true;
}

bool _compactResponseRequested(Request request) {
  final rawCompact = request.url.queryParameters['compact']?.toLowerCase();
  return rawCompact == 'true' || rawCompact == '1' || rawCompact == 'yes';
}

bool _queryFlag(Request request, String name) {
  final raw = request.url.queryParameters[name]?.toLowerCase();
  return raw == 'true' || raw == '1' || raw == 'yes';
}

Middleware _corsMiddleware(String allowOrigin) {
  final allowAll = allowOrigin.trim() == '*';
  final allowedOrigins = allowOrigin
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet();

  return (Handler innerHandler) {
    return (Request request) async {
      final requestOrigin = request.headers['origin']?.trim();
      final headers = <String, String>{
        HttpHeaders.accessControlAllowHeadersHeader:
            'Content-Type, Authorization, X-Requested-With, '
            'X-Piwibus-Session-Id, X-CSRF-Token, Accept, Cache-Control',
        HttpHeaders.accessControlAllowMethodsHeader:
            'GET, POST, PATCH, PUT, DELETE, OPTIONS',
      };
      if (allowAll) {
        headers[HttpHeaders.accessControlAllowOriginHeader] = '*';
      } else if (requestOrigin != null && requestOrigin.isNotEmpty) {
        if (!allowedOrigins.contains(requestOrigin)) {
          return Response.forbidden(
            'Origin non autorisee.',
            headers: const <String, String>{
              HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
            },
          );
        }
        headers[HttpHeaders.accessControlAllowOriginHeader] = requestOrigin;
        headers[HttpHeaders.accessControlAllowCredentialsHeader] = 'true';
        headers[HttpHeaders.varyHeader] = 'origin';
      }
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }
      final response = await innerHandler(request);
      return response.change(
        headers: <String, String>{...response.headers, ...headers},
      );
    };
  };
}

String _string(Object? value) => value?.toString().trim() ?? '';
String _rawString(Object? value) => value?.toString() ?? '';

String _boundedString(
  Object? value,
  int maxLength, {
  required String fieldName,
}) {
  final text = _string(value);
  if (text.length > maxLength) {
    throw StateError('$fieldName trop long.');
  }
  return text;
}

bool _envFlag(String name) {
  final value = (Platform.environment[name] ?? '').trim().toLowerCase();
  return value == 'true' || value == '1' || value == 'yes';
}

void _requireAdminCsrf(Request request, String sessionId, _JwtCodec jwtCodec) {
  final provided = request.headers['x-csrf-token']?.trim() ?? '';
  if (!jwtCodec.verifyCsrfToken(sessionId, provided)) {
    throw StateError('Jeton CSRF admin invalide.');
  }
}

Duration _durationFromEnvSeconds(String name, Duration fallback) {
  final raw = Platform.environment[name]?.trim();
  final seconds = raw == null ? null : int.tryParse(raw);
  if (seconds == null || seconds <= 0) return fallback;
  return Duration(seconds: seconds);
}

List<String> _stringList(Object? value) {
  if (value is! Iterable) return const <String>[];
  return value
      .map((item) => _string(item))
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

List<JsonMap> _mapList(Object? value) {
  if (value is! Iterable) return const <JsonMap>[];
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

Map<String, String> _adminSessionCookieHeaders(Request request, String token) {
  return <String, String>{
    HttpHeaders.setCookieHeader: _adminSessionCookie(request, value: token),
  };
}

Map<String, String> _clearAdminSessionCookieHeaders(Request request) {
  return <String, String>{
    HttpHeaders.setCookieHeader: _adminSessionCookie(
      request,
      value: '',
      clear: true,
    ),
  };
}

String _adminSessionCookie(
  Request request, {
  required String value,
  bool clear = false,
}) {
  final parts = <String>[
    '$_adminSessionCookieName=${Uri.encodeComponent(value)}',
    'Path=/admin',
    'HttpOnly',
    'SameSite=Strict',
    clear ? 'Max-Age=0' : 'Max-Age=$_adminSessionMaxAgeSeconds',
  ];
  if (_requestIsSecure(request)) {
    parts.add('Secure');
  }
  return parts.join('; ');
}

bool _requestIsSecure(Request request) {
  final forwardedProto = request.headers['x-forwarded-proto']
      ?.split(',')
      .first
      .trim()
      .toLowerCase();
  return forwardedProto == 'https' || request.requestedUri.scheme == 'https';
}

String? _sessionIdFromRequest(Request request, _JwtCodec jwtCodec) {
  final direct = request.headers['x-piwibus-session-id']?.trim();
  if (direct != null && direct.isNotEmpty) {
    return _sessionIdFromTokenOrRaw(direct, jwtCodec);
  }

  final authorization =
      request.headers[HttpHeaders.authorizationHeader]?.trim() ?? '';
  const bearerPrefix = 'Bearer ';
  if (authorization.toLowerCase().startsWith(bearerPrefix.toLowerCase())) {
    final token = authorization.substring(bearerPrefix.length).trim();
    if (token.isNotEmpty) return _sessionIdFromTokenOrRaw(token, jwtCodec);
  }

  return _sessionIdFromCookie(request, jwtCodec) ??
      _sessionIdFromWebSocketProtocol(request, jwtCodec);
}

String? _sessionIdFromTokenOrRaw(String value, _JwtCodec jwtCodec) {
  final token = value.trim();
  if (token.isEmpty) return null;
  if (token.split('.').length == 3) {
    return jwtCodec.sessionIdFromToken(token);
  }
  return token;
}

String? _sessionIdFromCookie(Request request, _JwtCodec jwtCodec) {
  final cookieHeader = request.headers[HttpHeaders.cookieHeader] ?? '';
  if (cookieHeader.isEmpty) return null;
  for (final cookie in cookieHeader.split(';')) {
    final separatorIndex = cookie.indexOf('=');
    if (separatorIndex <= 0) continue;
    final name = cookie.substring(0, separatorIndex).trim();
    if (name != _adminSessionCookieName) continue;
    final encodedValue = cookie.substring(separatorIndex + 1).trim();
    if (encodedValue.isEmpty) return null;
    try {
      final token = Uri.decodeComponent(encodedValue);
      if (token.isNotEmpty) return _sessionIdFromTokenOrRaw(token, jwtCodec);
    } catch (_) {
      return null;
    }
  }
  return null;
}

String? _sessionIdFromWebSocketProtocol(Request request, _JwtCodec jwtCodec) {
  final protocolHeader = request.headers['sec-websocket-protocol'];
  if (protocolHeader == null || protocolHeader.isEmpty) return null;
  for (final protocol in protocolHeader.split(',')) {
    final value = protocol.trim();
    if (!value.startsWith(_webSocketAuthProtocolPrefix)) continue;
    final token = value.substring(_webSocketAuthProtocolPrefix.length).trim();
    if (token.isNotEmpty) return _sessionIdFromTokenOrRaw(token, jwtCodec);
  }
  return null;
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index == args.length - 1) {
    return null;
  }
  return args[index + 1];
}

bool _includePasswordResetCode() {
  final explicit =
      (Platform.environment['PIWIBUS_PASSWORD_RESET_SHOW_CODE'] ?? '')
          .trim()
          .toLowerCase();
  if (explicit == 'true' || explicit == '1' || explicit == 'yes') return true;
  if (explicit == 'false' || explicit == '0' || explicit == 'no') return false;
  return false;
}

Iterable<String>? _webSocketAllowedOrigins(String allowOrigin) {
  if (allowOrigin.trim() == '*') return null;
  final origins = allowOrigin
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  return origins.isEmpty ? null : origins;
}

Middleware _requestLogMiddleware(OpsLogger logger) {
  return (Handler innerHandler) {
    return (Request request) async {
      final stopwatch = Stopwatch()..start();
      try {
        final response = await innerHandler(request);
        logger.info('http_request', <String, Object?>{
          'method': request.method,
          'path': '/${request.url.path}',
          'statusCode': response.statusCode,
          'durationMs': stopwatch.elapsedMicroseconds / 1000,
          'client': _requestClientKey(request),
        });
        return response;
      } on HijackException {
        logger.info('http_request', <String, Object?>{
          'method': request.method,
          'path': '/${request.url.path}',
          'statusCode': 101,
          'durationMs': stopwatch.elapsedMicroseconds / 1000,
          'client': _requestClientKey(request),
        });
        rethrow;
      } catch (error, stackTrace) {
        logger.error(
          'http_request_failed',
          <String, Object?>{
            'method': request.method,
            'path': '/${request.url.path}',
            'durationMs': stopwatch.elapsedMicroseconds / 1000,
            'client': _requestClientKey(request),
          },
          error,
          stackTrace,
        );
        rethrow;
      }
    };
  };
}

String _requestClientKey(Request request) {
  final forwardedFor = request.headers['x-forwarded-for']?.split(',').first;
  final explicit =
      forwardedFor?.trim() ?? request.headers['x-real-ip']?.trim() ?? '';
  if (explicit.isNotEmpty) return explicit;
  final connectionInfo = request.context['shelf.io.connection_info'];
  if (connectionInfo is HttpConnectionInfo) {
    return connectionInfo.remoteAddress.address;
  }
  return 'unknown';
}

class _MetricsRegistry {
  int _requestsTotal = 0;
  int _responsesTotal = 0;
  int _responses4xx = 0;
  int _responses5xx = 0;
  int _webSocketConnections = 0;
  int _sseConnections = 0;
  double _latencyTotalMs = 0;
  double _latencyMaxMs = 0;

  Middleware middleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        final stopwatch = Stopwatch()..start();
        _requestsTotal += 1;
        try {
          final response = await innerHandler(request);
          _recordResponse(response.statusCode, stopwatch.elapsed);
          return response;
        } on HijackException {
          _recordResponse(101, stopwatch.elapsed);
          rethrow;
        } catch (_) {
          _recordResponse(500, stopwatch.elapsed);
          rethrow;
        }
      };
    };
  }

  void webSocketOpened() {
    _webSocketConnections += 1;
  }

  void webSocketClosed() {
    if (_webSocketConnections > 0) _webSocketConnections -= 1;
  }

  void sseOpened() {
    _sseConnections += 1;
  }

  void sseClosed() {
    if (_sseConnections > 0) _sseConnections -= 1;
  }

  JsonMap snapshot() {
    final average = _responsesTotal == 0
        ? 0
        : _latencyTotalMs / _responsesTotal;
    return <String, dynamic>{
      'requestsTotal': _requestsTotal,
      'responsesTotal': _responsesTotal,
      'responses4xx': _responses4xx,
      'responses5xx': _responses5xx,
      'latencyAverageMs': average,
      'latencyMaxMs': _latencyMaxMs,
      'webSocketConnections': _webSocketConnections,
      'sseConnections': _sseConnections,
    };
  }

  String render() {
    final current = snapshot();
    return '''
# HELP piwibus_http_requests_total Total HTTP requests.
# TYPE piwibus_http_requests_total counter
piwibus_http_requests_total ${current['requestsTotal']}
# HELP piwibus_http_responses_total Total HTTP responses.
# TYPE piwibus_http_responses_total counter
piwibus_http_responses_total ${current['responsesTotal']}
# HELP piwibus_http_responses_4xx_total Total 4xx HTTP responses.
# TYPE piwibus_http_responses_4xx_total counter
piwibus_http_responses_4xx_total ${current['responses4xx']}
# HELP piwibus_http_responses_5xx_total Total 5xx HTTP responses.
# TYPE piwibus_http_responses_5xx_total counter
piwibus_http_responses_5xx_total ${current['responses5xx']}
# HELP piwibus_http_request_latency_ms_avg Average HTTP latency in milliseconds.
# TYPE piwibus_http_request_latency_ms_avg gauge
piwibus_http_request_latency_ms_avg ${(current['latencyAverageMs'] as double).toStringAsFixed(3)}
# HELP piwibus_http_request_latency_ms_max Max HTTP latency in milliseconds.
# TYPE piwibus_http_request_latency_ms_max gauge
piwibus_http_request_latency_ms_max ${(current['latencyMaxMs'] as double).toStringAsFixed(3)}
# HELP piwibus_websocket_connections Current WebSocket connections.
# TYPE piwibus_websocket_connections gauge
piwibus_websocket_connections ${current['webSocketConnections']}
# HELP piwibus_sse_connections Current SSE connections.
# TYPE piwibus_sse_connections gauge
piwibus_sse_connections ${current['sseConnections']}
''';
  }

  void _recordResponse(int statusCode, Duration elapsed) {
    _responsesTotal += 1;
    if (statusCode >= 400 && statusCode < 500) _responses4xx += 1;
    if (statusCode >= 500) _responses5xx += 1;
    final latency = elapsed.inMicroseconds / 1000;
    _latencyTotalMs += latency;
    if (latency > _latencyMaxMs) _latencyMaxMs = latency;
  }
}

class _JwtCodec {
  _JwtCodec(this._secret);

  final String _secret;

  factory _JwtCodec.fromEnvironment() {
    final configured =
        (Platform.environment['PIWIBUS_JWT_SECRET'] ??
                Platform.environment['JWT_SECRET'] ??
                '')
            .trim();
    final secret = configured.isEmpty
        ? 'piwibus-development-secret-change-me'
        : configured;
    return _JwtCodec(secret);
  }

  String issue(String sessionId, {Duration? ttl}) {
    final existingSessionId = sessionIdFromToken(sessionId);
    if (ttl == null && existingSessionId != null) {
      return sessionId;
    }
    final effectiveSessionId = existingSessionId ?? sessionId;
    final now = DateTime.now().toUtc();
    final payload = <String, dynamic>{
      'sid': effectiveSessionId,
      'iat': now.millisecondsSinceEpoch ~/ 1000,
      if (ttl != null) 'exp': now.add(ttl).millisecondsSinceEpoch ~/ 1000,
    };
    final header = <String, dynamic>{'alg': 'HS256', 'typ': 'JWT'};
    final headerPart = _base64UrlJson(header);
    final payloadPart = _base64UrlJson(payload);
    final signaturePart = _sign('$headerPart.$payloadPart');
    return '$headerPart.$payloadPart.$signaturePart';
  }

  String? sessionIdFromToken(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final signed = '${parts[0]}.${parts[1]}';
    final expectedSignature = _sign(signed);
    if (!_constantTimeEquals(expectedSignature, parts[2])) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map) return null;
      final expiresAt = payload['exp'];
      if (expiresAt is int) {
        final nowSeconds =
            DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
        if (expiresAt <= nowSeconds) return null;
      } else if (expiresAt is String) {
        final parsedExpiresAt = int.tryParse(expiresAt);
        final nowSeconds =
            DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
        if (parsedExpiresAt == null || parsedExpiresAt <= nowSeconds) {
          return null;
        }
      } else if (expiresAt != null) {
        return null;
      }
      final sessionId = payload['sid']?.toString().trim() ?? '';
      return sessionId.isEmpty ? null : sessionId;
    } catch (_) {
      return null;
    }
  }

  String csrfToken(String sessionId) {
    return _sign('csrf:$sessionId');
  }

  bool verifyCsrfToken(String sessionId, String token) {
    final normalized = token.trim();
    return normalized.isNotEmpty &&
        _constantTimeEquals(csrfToken(sessionId), normalized);
  }

  String _base64UrlJson(Map<String, dynamic> value) {
    return base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  }

  String _sign(String value) {
    final hmac = Hmac(sha256, utf8.encode(_secret));
    return base64Url
        .encode(hmac.convert(utf8.encode(value)).bytes)
        .replaceAll('=', '');
  }

  bool _constantTimeEquals(String a, String b) {
    final left = utf8.encode(a);
    final right = utf8.encode(b);
    if (left.length != right.length) return false;
    var diff = 0;
    for (var i = 0; i < left.length; i += 1) {
      diff |= left[i] ^ right[i];
    }
    return diff == 0;
  }
}

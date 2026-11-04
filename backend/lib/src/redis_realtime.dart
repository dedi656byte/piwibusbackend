import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:redis/redis.dart';

import 'ops_logger.dart';

class RedisRealtime {
  RedisRealtime._({
    required this.config,
    required this.logger,
    required this.instanceId,
    required Command command,
    required RedisConnection commandConnection,
  }) : _command = command,
       _commandConnection = commandConnection;

  final RedisConfig config;
  final OpsLogger logger;
  final String instanceId;
  Command? _command;
  RedisConnection? _commandConnection;
  final StreamController<void> _remoteChanges =
      StreamController<void>.broadcast();
  final StreamController<void> _remotePresenceChanges =
      StreamController<void>.broadcast();
  RedisConnection? _subscriptionConnection;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _commandReconnectTimer;
  Future<void>? _commandReconnectFuture;
  RedisConnection? _commandReconnectConnection;
  int _commandReconnectAttempt = 0;
  DateTime? _lastRateLimitErrorLogAt;
  bool _closed = false;
  bool _subscriptionReady = false;

  Stream<void> get remoteChanges => _remoteChanges.stream;
  Stream<void> get remotePresenceChanges => _remotePresenceChanges.stream;
  bool get isSubscriptionReady => _subscriptionReady && !_closed;

  Future<void> checkReady() async {
    if (_closed) throw StateError('Redis realtime is closed.');
    final response = await _sendCommand(const ['PING']);
    if (response?.toString().toUpperCase() != 'PONG') {
      throw StateError('Redis command connection did not return PONG.');
    }
    if (!_subscriptionReady) {
      throw StateError('Redis realtime subscription is not active.');
    }
  }

  static Future<RedisRealtime?> openFromEnvironment({
    required OpsLogger logger,
  }) async {
    final config = RedisConfig.fromEnvironment();
    if (config == null) return null;

    return connect(config: config, logger: logger);
  }

  static Future<RedisRealtime> connect({
    required RedisConfig config,
    required OpsLogger logger,
  }) async {
    final commandConnection = RedisConnection();
    final command = await _connectCommandWithRetry(
      config: config,
      connection: commandConnection,
      logger: logger,
    );
    final instanceId = _newInstanceId();
    final realtime = RedisRealtime._(
      config: config,
      logger: logger,
      instanceId: instanceId,
      command: command,
      commandConnection: commandConnection,
    );
    await realtime._connectSubscription();
    logger.info('Redis enabled', <String, Object?>{
      'host': config.host,
      'port': config.port,
      'database': config.database,
      'channel': config.channel,
      'instanceId': instanceId,
    });
    return realtime;
  }

  static Future<Command> _connectCommandWithRetry({
    required RedisConfig config,
    required RedisConnection connection,
    required OpsLogger logger,
  }) async {
    const maxAttempts = 10;
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        return await config.connect(connection);
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt == maxAttempts) break;
        final delaySeconds = math.min(5, attempt);
        logger.warning('Redis startup connection failed; retrying', {
          'host': config.host,
          'port': config.port,
          'attempt': attempt,
          'maxAttempts': maxAttempts,
          'retryInSeconds': delaySeconds,
        });
        await Future<void>.delayed(Duration(seconds: delaySeconds));
      }
    }

    Error.throwWithStackTrace(
      lastError ?? StateError('Redis connection failed.'),
      lastStackTrace ?? StackTrace.current,
    );
  }

  Future<void> publishChange() async {
    if (_closed) return;
    final payload = jsonEncode(<String, Object?>{
      'instanceId': instanceId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    try {
      await _sendCommand(['PUBLISH', config.channel, payload]);
    } catch (error, stackTrace) {
      logger.error('Redis publish failed', const {}, error, stackTrace);
    }
  }

  Future<void> publishOutboxEvent({
    required String eventId,
    required String eventType,
    required Map<String, dynamic> payload,
  }) async {
    if (_closed) throw StateError('Redis realtime is closed.');
    const publishOnceScript = '''
      local existing = redis.call('GET', KEYS[1])
      if existing then return existing end
      local streamId = redis.call(
        'XADD', KEYS[2], 'MAXLEN', '~', ARGV[4], '*',
        'eventId', ARGV[1], 'eventType', ARGV[2], 'payload', ARGV[3]
      )
      redis.call('SET', KEYS[1], streamId, 'EX', ARGV[5])
      return streamId
    ''';
    final payloadText = jsonEncode(payload);
    try {
      await _sendCommand([
        'EVAL',
        publishOnceScript,
        '2',
        '${config.stream}:dedup:$eventId',
        config.stream,
        eventId,
        eventType,
        payloadText,
        10000,
        604800,
      ]);
      final notice = jsonEncode(<String, Object?>{
        'instanceId': instanceId,
        'eventId': eventId,
        'eventType': eventType,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });
      await _sendCommand(['PUBLISH', config.channel, notice]);
    } catch (error, stackTrace) {
      logger.error(
        'Redis outbox event publication failed',
        {'eventId': eventId, 'eventType': eventType},
        error,
        stackTrace,
      );
      rethrow;
    }
  }

  Future<int?> incrementRateLimit({
    required String key,
    required Duration window,
  }) async {
    if (_closed) return null;
    try {
      const incrementScript = '''
        local count = redis.call('INCR', KEYS[1])
        if count == 1 then
          redis.call('EXPIRE', KEYS[1], ARGV[1])
        end
        return count
      ''';
      final count = await _sendCommand([
        'EVAL',
        incrementScript,
        '1',
        key,
        window.inSeconds,
      ]);
      return count is int ? count : int.tryParse(count.toString());
    } catch (error, stackTrace) {
      if (_shouldLogRateLimitError()) {
        logger.error(
          'Redis rate limit failed; using in-memory fallback',
          {'key': key},
          error,
          stackTrace,
        );
      }
      return null;
    }
  }

  Future<String> registerPresence({
    required String sessionId,
    Duration lease = const Duration(seconds: 75),
  }) async {
    final connectionId = '$instanceId:${_newInstanceId()}';
    await _updatePresence(
      sessionId: sessionId,
      connectionId: connectionId,
      lease: lease,
      remove: false,
    );
    return connectionId;
  }

  Future<void> renewPresence({
    required String sessionId,
    required String connectionId,
    Duration lease = const Duration(seconds: 75),
  }) {
    return _updatePresence(
      sessionId: sessionId,
      connectionId: connectionId,
      lease: lease,
      remove: false,
    );
  }

  Future<void> unregisterPresence({
    required String sessionId,
    required String connectionId,
  }) {
    return _updatePresence(
      sessionId: sessionId,
      connectionId: connectionId,
      lease: Duration.zero,
      remove: true,
    );
  }

  Future<Set<String>> activePresenceSessionIds() async {
    if (_closed) throw StateError('Redis realtime is closed.');
    const activeSessionsScript = '''
      local now = tonumber(ARGV[1])
      redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
      return redis.call('ZRANGEBYSCORE', KEYS[1], now + 1, '+inf')
    ''';
    final result = await _sendCommand([
      'EVAL',
      activeSessionsScript,
      '1',
      '${config.presencePrefix}:sessions',
      DateTime.now().toUtc().millisecondsSinceEpoch,
    ]);
    if (result is! List) {
      throw StateError('Redis presence query returned an invalid response.');
    }
    return result.map((sessionId) => sessionId.toString()).toSet();
  }

  Future<void> _updatePresence({
    required String sessionId,
    required String connectionId,
    required Duration lease,
    required bool remove,
  }) async {
    if (_closed) throw StateError('Redis realtime is closed.');
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty || connectionId.isEmpty) {
      throw ArgumentError('Presence requires a session and connection id.');
    }
    const updatePresenceScript = '''
      local now = tonumber(ARGV[1])
      local previous = redis.call('ZCARD', KEYS[1])
      redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
      previous = redis.call('ZCARD', KEYS[1])
      if ARGV[4] == '1' then
        redis.call('ZREM', KEYS[1], ARGV[2])
      else
        redis.call('ZADD', KEYS[1], tonumber(ARGV[3]), ARGV[2])
        redis.call('EXPIRE', KEYS[1], tonumber(ARGV[5]))
      end
      local remaining = redis.call('ZCARD', KEYS[1])
      local maxScore = redis.call('ZREVRANGE', KEYS[1], 0, 0, 'WITHSCORES')
      if remaining == 0 then
        redis.call('DEL', KEYS[1])
        redis.call('ZREM', KEYS[2], ARGV[6])
      else
        redis.call('ZADD', KEYS[2], maxScore[2], ARGV[6])
      end
      if previous == 0 and remaining > 0 then return 1 end
      if previous > 0 and remaining == 0 then return -1 end
      return 0
    ''';
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final leaseMilliseconds = lease.inMilliseconds;
    final expiresAt = now + leaseMilliseconds;
    final leaseTtlSeconds = math.max(1, (lease.inSeconds * 2));
    try {
      final transition = await _sendCommand([
        'EVAL',
        updatePresenceScript,
        '2',
        '${config.presencePrefix}:session:$normalizedSessionId',
        '${config.presencePrefix}:sessions',
        now,
        connectionId,
        expiresAt,
        remove ? '1' : '0',
        leaseTtlSeconds,
        normalizedSessionId,
      ]);
      final transitionCode = transition is int
          ? transition
          : int.tryParse(transition.toString()) ?? 0;
      if (transitionCode != 0) {
        await _sendCommand([
          'PUBLISH',
          config.channel,
          jsonEncode(<String, Object?>{
            'type': 'presence_changed',
            'sessionId': normalizedSessionId,
            'online': transitionCode > 0,
            'timestamp': DateTime.now().toUtc().toIso8601String(),
          }),
        ]);
      }
    } catch (error, stackTrace) {
      logger.error(
        'Redis presence update failed',
        {'sessionId': normalizedSessionId},
        error,
        stackTrace,
      );
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _commandReconnectTimer?.cancel();
    await _subscription?.cancel();
    await _remoteChanges.close();
    await _remotePresenceChanges.close();
    await _subscriptionConnection?.close();
    final reconnectConnection = _commandReconnectConnection;
    if (reconnectConnection != null) {
      await _closeFailedCommandConnection(reconnectConnection);
    }
    final reconnectFuture = _commandReconnectFuture;
    if (reconnectFuture != null) {
      try {
        await reconnectFuture.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        logger.warning('Redis command reconnection did not stop during close');
      }
    }
    await _commandConnection?.close();
    _command = null;
    _commandConnection = null;
  }

  Future<Object?> _sendCommand(List<Object?> arguments) async {
    final command = _command;
    final connection = _commandConnection;
    if (command == null || connection == null) {
      _scheduleCommandReconnect();
      throw StateError('Redis command connection is not active.');
    }

    try {
      return await command.send_object(arguments);
    } catch (_) {
      if (identical(_commandConnection, connection)) {
        _command = null;
        _commandConnection = null;
        unawaited(_closeFailedCommandConnection(connection));
        _scheduleCommandReconnect();
      }
      rethrow;
    }
  }

  Future<void> _closeFailedCommandConnection(RedisConnection connection) async {
    try {
      await connection.close();
    } catch (error, stackTrace) {
      logger.warning('Redis command connection close failed', {
        'error': error.toString(),
        'stackTrace': stackTrace.toString(),
      });
    }
  }

  void _scheduleCommandReconnect() {
    if (_closed ||
        _command != null ||
        _commandReconnectTimer != null ||
        _commandReconnectFuture != null) {
      return;
    }

    final delaySeconds = math.min(
      30,
      1 << math.min(_commandReconnectAttempt, 5),
    );
    _commandReconnectAttempt += 1;
    _commandReconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _commandReconnectTimer = null;
      unawaited(_reconnectCommand());
    });
  }

  Future<void> _reconnectCommand() async {
    if (_closed || _command != null || _commandReconnectFuture != null) return;

    final connection = RedisConnection();
    final completer = Completer<void>();
    _commandReconnectFuture = completer.future;
    _commandReconnectConnection = connection;
    try {
      final command = await config
          .connect(connection)
          .timeout(const Duration(seconds: 10));
      if (_closed) {
        await connection.close();
        return;
      }
      _commandConnection = connection;
      _command = command;
      _commandReconnectAttempt = 0;
      logger.info('Redis command connection restored', {
        'host': config.host,
        'port': config.port,
      });
    } catch (error, stackTrace) {
      await _closeFailedCommandConnection(connection);
      logger.warning('Redis command reconnection failed', {
        'host': config.host,
        'port': config.port,
        'error': error.toString(),
        'stackTrace': stackTrace.toString(),
      });
    } finally {
      _commandReconnectFuture = null;
      _commandReconnectConnection = null;
      if (!_closed && _command == null) _scheduleCommandReconnect();
      completer.complete();
    }
    await completer.future;
  }

  Future<void> _connectSubscription() async {
    if (_closed) return;
    _subscriptionReady = false;
    final connection = RedisConnection();
    _subscriptionConnection = connection;
    try {
      final command = await config.connect(connection);
      if (_closed) {
        await connection.close();
        if (identical(_subscriptionConnection, connection)) {
          _subscriptionConnection = null;
        }
        return;
      }
      final pubSub = PubSub(command);
      _subscription = pubSub.getStream().listen(
        (dynamic event) => _handleMessage(event),
        onError: (Object error, StackTrace stackTrace) {
          logger.error(
            'Redis subscription failed',
            const {},
            error,
            stackTrace,
          );
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
      );
      pubSub.subscribe([config.channel]);
    } catch (error, stackTrace) {
      logger.error(
        'Redis subscription open failed',
        const {},
        error,
        stackTrace,
      );
      try {
        await connection.close();
      } catch (_) {}
      if (identical(_subscriptionConnection, connection)) {
        _subscriptionConnection = null;
      }
      _scheduleReconnect();
    }
  }

  void _handleMessage(Object event) {
    if (event is! List || event.length < 3) return;
    final kind = event[0]?.toString();
    final channel = event[1]?.toString();
    if (kind == 'subscribe' && channel == config.channel) {
      _subscriptionReady = true;
      return;
    }
    final payloadText = event[2]?.toString() ?? '';
    if (kind != 'message' || channel != config.channel) return;
    try {
      final payload = jsonDecode(payloadText);
      if (payload is Map && payload['type'] == 'presence_changed') {
        _remotePresenceChanges.add(null);
        return;
      }
      if (payload is Map &&
          payload['eventId'] == null &&
          payload['instanceId'] == instanceId) {
        return;
      }
      _remoteChanges.add(null);
    } catch (_) {
      logger.warning('Invalid Redis realtime message ignored');
    }
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _subscriptionReady = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      if (_closed) return;
      await _subscription?.cancel();
      if (_closed) return;
      try {
        await _subscriptionConnection?.close();
      } catch (_) {}
      _subscriptionConnection = null;
      if (_closed) return;
      await _connectSubscription();
    });
  }

  static String _newInstanceId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  bool _shouldLogRateLimitError() {
    final now = DateTime.now().toUtc();
    final last = _lastRateLimitErrorLogAt;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return false;
    }
    _lastRateLimitErrorLogAt = now;
    return true;
  }
}

class RedisConfig {
  RedisConfig({
    required this.host,
    required this.port,
    required this.secure,
    required this.username,
    required this.password,
    required this.database,
    required this.channel,
    this.stream = 'piwibus:outbox:events',
    this.presencePrefix = 'piwibus:presence',
  });

  final String host;
  final int port;
  final bool secure;
  final String? username;
  final String? password;
  final int database;
  final String channel;
  final String stream;
  final String presencePrefix;

  static RedisConfig? fromEnvironment() {
    final raw =
        (Platform.environment['PIWIBUS_REDIS_URL'] ??
                Platform.environment['REDIS_URL'] ??
                '')
            .trim();
    if (raw.isEmpty) return null;
    final uri = Uri.parse(raw);
    final secure = uri.scheme == 'rediss';
    final credentials = uri.userInfo.isEmpty ? null : uri.userInfo.split(':');
    final username = credentials == null || credentials.length < 2
        ? null
        : Uri.decodeComponent(credentials.first);
    final password = credentials == null
        ? null
        : Uri.decodeComponent(
            credentials.length == 1
                ? credentials.first
                : credentials.sublist(1).join(':'),
          );
    final dbText = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    return RedisConfig(
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 6379,
      secure: secure,
      username: username == null || username.isEmpty ? null : username,
      password: password == null || password.isEmpty ? null : password,
      database: int.tryParse(dbText) ?? 0,
      channel:
          (Platform.environment['PIWIBUS_REDIS_CHANNEL'] ?? 'piwibus:changes')
              .trim(),
      stream:
          (Platform.environment['PIWIBUS_REDIS_STREAM'] ??
                  'piwibus:outbox:events')
              .trim(),
      presencePrefix:
          (Platform.environment['PIWIBUS_REDIS_PRESENCE_PREFIX'] ??
                  'piwibus:presence')
              .trim(),
    );
  }

  Future<Command> connect(RedisConnection connection) async {
    final command = secure
        ? await connection.connectSecure(host, port)
        : await connection.connect(host, port);
    if (password != null && username != null) {
      await command.send_object(['AUTH', username, password]);
    } else if (password != null) {
      await command.send_object(['AUTH', password]);
    }
    if (database > 0) {
      await command.send_object(['SELECT', database]);
    }
    return command;
  }
}

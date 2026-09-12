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
  final Command _command;
  final RedisConnection _commandConnection;
  final StreamController<void> _remoteChanges =
      StreamController<void>.broadcast();
  RedisConnection? _subscriptionConnection;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  DateTime? _lastRateLimitErrorLogAt;
  bool _closed = false;

  Stream<void> get remoteChanges => _remoteChanges.stream;

  static Future<RedisRealtime?> openFromEnvironment({
    required OpsLogger logger,
  }) async {
    final config = RedisConfig.fromEnvironment();
    if (config == null) return null;

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
      await _command.send_object(['PUBLISH', config.channel, payload]);
    } catch (error, stackTrace) {
      logger.error('Redis publish failed', const {}, error, stackTrace);
    }
  }

  Future<int?> incrementRateLimit({
    required String key,
    required Duration window,
  }) async {
    if (_closed) return null;
    try {
      final count = await _command.send_object(['INCR', key]);
      if (count == 1) {
        await _command.send_object(['EXPIRE', key, window.inSeconds]);
      }
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

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _remoteChanges.close();
    await _subscriptionConnection?.close();
    await _commandConnection.close();
  }

  Future<void> _connectSubscription() async {
    if (_closed) return;
    final connection = RedisConnection();
    try {
      final command = await config.connect(connection);
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
      _subscriptionConnection = connection;
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
      _scheduleReconnect();
    }
  }

  void _handleMessage(Object event) {
    if (event is! List || event.length < 3) return;
    final kind = event[0]?.toString();
    final channel = event[1]?.toString();
    final payloadText = event[2]?.toString() ?? '';
    if (kind != 'message' || channel != config.channel) return;
    try {
      final payload = jsonDecode(payloadText);
      if (payload is Map && payload['instanceId'] == instanceId) return;
      _remoteChanges.add(null);
    } catch (_) {
      _remoteChanges.add(null);
    }
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      await _subscription?.cancel();
      try {
        await _subscriptionConnection?.close();
      } catch (_) {}
      _subscriptionConnection = null;
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
  });

  final String host;
  final int port;
  final bool secure;
  final String? username;
  final String? password;
  final int database;
  final String channel;

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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:piwibus_backend/src/ops_logger.dart';
import 'package:piwibus_backend/src/redis_realtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'outbox publication records a stream event before publishing a wakeup',
    () async {
      final server = await _FakeRedisServer.start();
      final realtime = await RedisRealtime.connect(
        config: RedisConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          secure: false,
          username: null,
          password: null,
          database: 0,
          channel: 'test:changes',
          stream: 'test:events',
        ),
        logger: const OpsLogger(),
      );

      try {
        await realtime.publishOutboxEvent(
          eventId: 'state:42',
          eventType: 'state_changed',
          payload: const <String, dynamic>{'revision': 42},
        );

        final commands = server.commands
            .map((command) => command.first.toUpperCase())
            .toList();
        expect(commands.indexOf('EVAL'), lessThan(commands.indexOf('PUBLISH')));
        expect(commands.where((command) => command == 'EVAL'), hasLength(1));
      } finally {
        await realtime.close();
        await server.close();
      }
    },
  );

  test('reconnects the Redis command connection after it is closed', () async {
    final server = await _FakeRedisServer.start();
    final realtime = await RedisRealtime.connect(
      config: RedisConfig(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        secure: false,
        username: null,
        password: null,
        database: 0,
        channel: 'test:changes',
      ),
      logger: const OpsLogger(),
    );

    try {
      await _waitUntil(
        () => realtime.isSubscriptionReady,
        reason: 'Redis subscription should become ready',
      );
      await realtime.checkReady();

      server.closeCommandConnection();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        await realtime.checkReady().timeout(const Duration(seconds: 2));
      } on Object {
        // The first readiness probe detects the closed socket and starts recovery.
      }

      await _waitUntil(
        () => realtime.checkReady().then((_) => true).catchError((_) => false),
        reason: 'Redis command connection should recover',
      );
    } finally {
      await realtime.close();
      await server.close();
    }
  });
}

Future<void> _waitUntil(
  FutureOr<bool> Function() condition, {
  required String reason,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail(reason);
}

class _FakeRedisServer {
  _FakeRedisServer._(this._server);

  final ServerSocket _server;
  final List<Socket> _connections = <Socket>[];
  final Map<Socket, List<String>> _arguments = <Socket, List<String>>{};
  final Map<Socket, int?> _expectedArguments = <Socket, int?>{};
  final List<List<String>> commands = <List<String>>[];

  int get port => _server.port;

  static Future<_FakeRedisServer> start() async {
    final server = _FakeRedisServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(server._accept);
    return server;
  }

  void closeCommandConnection() {
    _connections.first.destroy();
  }

  Future<void> close() async {
    await _server.close();
    for (final connection in _connections) {
      connection.destroy();
    }
  }

  void _accept(Socket socket) {
    _connections.add(socket);
    _arguments[socket] = <String>[];
    _expectedArguments[socket] = null;
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _handleLine(socket, line), onError: (Object _) {});
  }

  void _handleLine(Socket socket, String line) {
    if (line.startsWith('*')) {
      _expectedArguments[socket] = int.parse(line.substring(1));
      _arguments[socket]!.clear();
      return;
    }
    if (line.startsWith(r'$')) return;

    final args = _arguments[socket]!;
    args.add(line);
    final expected = _expectedArguments[socket];
    if (expected == null || args.length < expected) return;

    final command = List<String>.of(args);
    args.clear();
    _respond(socket, command);
  }

  void _respond(Socket socket, List<String> command) {
    commands.add(command);
    switch (command.first.toUpperCase()) {
      case 'PING':
        socket.add(utf8.encode('+PONG\r\n'));
      case 'SUBSCRIBE':
        final channel = command[1];
        socket.add(
          utf8.encode(
            '*3\r\n\$9\r\nsubscribe\r\n'
            '\$${channel.length}\r\n$channel\r\n:1\r\n',
          ),
        );
      case 'PUBLISH':
      case 'EXPIRE':
        socket.add(utf8.encode(':1\r\n'));
      case 'INCR':
        socket.add(utf8.encode(':1\r\n'));
      default:
        socket.add(utf8.encode('+OK\r\n'));
    }
  }
}

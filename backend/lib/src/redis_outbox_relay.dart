import 'dart:async';

import 'ops_logger.dart';
import 'redis_realtime.dart';
import 'store.dart';

class RedisOutboxRelay {
  RedisOutboxRelay({
    required this.store,
    required this.redis,
    required this.logger,
    this.onPublished,
    this.onFailure,
  });

  static const Duration _pollInterval = Duration(seconds: 1);
  static const Duration _leaseDuration = Duration(seconds: 30);
  static const int _batchSize = 50;

  final PiwibusStore store;
  final RedisRealtime redis;
  final OpsLogger logger;
  final void Function()? onPublished;
  final void Function()? onFailure;

  Timer? _timer;
  Future<void>? _drainInFlight;
  bool _closed = false;
  DateTime? _lastPruneAt;

  void start() {
    if (_closed) throw StateError('Redis outbox relay is closed.');
    if (_timer != null) return;
    _timer = Timer.periodic(_pollInterval, (_) => _startDrain());
    _startDrain();
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await _drainInFlight;
  }

  void _startDrain() {
    if (_closed || _drainInFlight != null) return;
    final drain = _drain();
    _drainInFlight = drain;
    unawaited(
      drain.whenComplete(() {
        if (identical(_drainInFlight, drain)) _drainInFlight = null;
      }),
    );
  }

  Future<void> _drain() async {
    try {
      for (var batch = 0; batch < 4 && !_closed; batch += 1) {
        final events = await store.claimOutboxEvents(
          workerId: redis.instanceId,
          type: 'state_changed',
          limit: _batchSize,
          lease: _leaseDuration,
        );
        if (events.isEmpty) break;

        for (final event in events) {
          if (_closed) break;
          try {
            await redis.publishOutboxEvent(
              eventId: event.id,
              eventType: event.type,
              payload: event.payload,
            );
            await store.markOutboxEventPublished(
              workerId: redis.instanceId,
              eventId: event.id,
            );
            onPublished?.call();
          } catch (error, stackTrace) {
            onFailure?.call();
            logger.error(
              'Redis outbox event will be retried',
              {'eventId': event.id},
              error,
              stackTrace,
            );
            try {
              await store.retryOutboxEvent(
                workerId: redis.instanceId,
                eventId: event.id,
                error: error.toString(),
              );
            } catch (retryError, retryStackTrace) {
              logger.error(
                'Redis outbox retry could not be scheduled; lease will expire',
                {'eventId': event.id},
                retryError,
                retryStackTrace,
              );
            }
          }
        }
      }

      final now = DateTime.now().toUtc();
      if (_lastPruneAt == null ||
          now.difference(_lastPruneAt!) >= const Duration(hours: 24)) {
        await store.prunePublishedOutboxEvents();
        _lastPruneAt = now;
      }
    } catch (error, stackTrace) {
      onFailure?.call();
      logger.error('Redis outbox relay failed', const {}, error, stackTrace);
    }
  }
}

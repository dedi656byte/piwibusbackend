import 'dart:async';

import 'ops_logger.dart';
import 'push_notifications.dart';
import 'state_persistence.dart';
import 'store.dart';

class PushOutboxWorker {
  PushOutboxWorker({
    required this.store,
    required this.pushNotifications,
    required this.logger,
    required this.workerId,
    this.onDelivered,
    this.onFailure,
  });

  static const Duration _pollInterval = Duration(seconds: 2);
  static const Duration _leaseDuration = Duration(minutes: 2);
  static const int _batchSize = 20;

  final PiwibusStore store;
  final PushNotificationService pushNotifications;
  final OpsLogger logger;
  final String workerId;
  final void Function()? onDelivered;
  final void Function()? onFailure;

  Timer? _timer;
  Future<void>? _drainInFlight;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('Push outbox worker is closed.');
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
      for (var batch = 0; batch < 2 && !_closed; batch += 1) {
        final events = await store.claimOutboxEvents(
          workerId: workerId,
          type: 'push_notification',
          limit: _batchSize,
          lease: _leaseDuration,
        );
        if (events.isEmpty) break;
        for (final event in events) {
          if (_closed) break;
          await _deliver(event);
        }
      }
    } catch (error, stackTrace) {
      onFailure?.call();
      logger.error('Push outbox worker failed', const {}, error, stackTrace);
    }
  }

  Future<void> _deliver(StateOutboxEvent event) async {
    try {
      final payload = event.payload;
      final rawData = payload['data'];
      final data = rawData is Map
          ? rawData.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : <String, String>{};
      final delivered = await pushNotifications.sendToTokensWithResult(
        tokens: store.pushTokensForOutboxEvent(payload),
        title: payload['title']?.toString() ?? '',
        body: payload['body']?.toString() ?? '',
        data: data,
      );
      if (!delivered) {
        throw StateError('One or more FCM deliveries failed.');
      }
      await store.markOutboxEventPublished(
        workerId: workerId,
        eventId: event.id,
      );
      onDelivered?.call();
    } catch (error, stackTrace) {
      onFailure?.call();
      logger.error(
        'Push outbox event will be retried',
        {'eventId': event.id, 'attempts': event.attempts},
        error,
        stackTrace,
      );
      final delaySeconds = (1 << (event.attempts.clamp(1, 10) - 1))
          .clamp(5, 3600)
          .toInt();
      try {
        await store.retryOutboxEvent(
          workerId: workerId,
          eventId: event.id,
          error: error.toString(),
          delay: Duration(seconds: delaySeconds),
          maxAttempts: 8,
        );
      } catch (retryError, retryStackTrace) {
        logger.error(
          'Push outbox retry could not be scheduled; lease will expire',
          {'eventId': event.id},
          retryError,
          retryStackTrace,
        );
      }
    }
  }
}

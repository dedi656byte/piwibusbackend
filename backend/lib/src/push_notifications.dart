import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import 'ops_logger.dart';

class PushNotificationDeliveryResult {
  const PushNotificationDeliveryResult({
    this.invalidTokens = const <String>{},
    this.hasRetryableFailures = false,
  });

  final Set<String> invalidTokens;
  final bool hasRetryableFailures;
}

class PushNotificationService {
  PushNotificationService._({
    required this.projectId,
    required this.logger,
    http.Client? client,
    http.Client? authorizedClient,
  }) : _client = client ?? http.Client(),
       _authorizedClient = authorizedClient;

  static const _firebaseMessagingScope =
      'https://www.googleapis.com/auth/firebase.messaging';

  final String projectId;
  final OpsLogger logger;
  final http.Client _client;
  http.Client? _authorizedClient;

  bool get enabled => projectId.isNotEmpty;

  factory PushNotificationService.forTesting({
    required String projectId,
    required OpsLogger logger,
    required http.Client authorizedClient,
  }) {
    return PushNotificationService._(
      projectId: projectId,
      logger: logger,
      authorizedClient: authorizedClient,
    );
  }

  static PushNotificationService fromEnvironment({required OpsLogger logger}) {
    return PushNotificationService._(
      projectId:
          (Platform.environment['PIWIBUS_FIREBASE_PROJECT_ID'] ??
                  Platform.environment['GOOGLE_CLOUD_PROJECT'] ??
                  Platform.environment['GCLOUD_PROJECT'] ??
                  '')
              .trim(),
      logger: logger,
    );
  }

  Future<void> sendToTokens({
    required Iterable<String> tokens,
    required String title,
    required String body,
    Map<String, String> data = const <String, String>{},
  }) async {
    await sendToTokensWithResult(
      tokens: tokens,
      title: title,
      body: body,
      data: data,
    );
  }

  Future<PushNotificationDeliveryResult> sendToTokensWithResult({
    required Iterable<String> tokens,
    required String title,
    required String body,
    Map<String, String> data = const <String, String>{},
  }) async {
    final uniqueTokens = tokens
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toSet();
    if (!enabled || uniqueTokens.isEmpty) {
      return const PushNotificationDeliveryResult();
    }

    final authorizedClient = await _authorizedHttpClient();
    if (authorizedClient == null) {
      return const PushNotificationDeliveryResult(hasRetryableFailures: true);
    }

    final eventId = data['eventId']?.trim() ?? '';
    final invalidTokens = <String>{};
    var hasRetryableFailures = false;
    for (final token in uniqueTokens) {
      try {
        final response = await authorizedClient.post(
          Uri.parse(
            'https://fcm.googleapis.com/v1/projects/$projectId/messages:send',
          ),
          headers: <String, String>{
            HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, Object?>{
            'message': <String, Object?>{
              'token': token,
              'notification': <String, String>{'title': title, 'body': body},
              'data': data,
              'android': <String, Object?>{
                'priority': 'HIGH',
                'notification': <String, String>{
                  'channel_id': 'piwibus_custom',
                  if (eventId.isNotEmpty) 'tag': eventId,
                },
              },
              if (eventId.isNotEmpty)
                'apns': <String, Object?>{
                  'headers': <String, String>{'apns-collapse-id': eventId},
                },
            },
          }),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final fcmError = _parseFcmError(response.body);
          if (response.statusCode == 404 &&
              fcmError.errorCode == 'UNREGISTERED') {
            invalidTokens.add(token);
            logger.warning('FCM token is unregistered', <String, Object?>{
              'statusCode': response.statusCode,
              'fcmStatus': fcmError.status,
              'fcmErrorCode': fcmError.errorCode,
            });
            continue;
          }
          hasRetryableFailures = true;
          logger.warning('FCM push failed', <String, Object?>{
            'statusCode': response.statusCode,
            'fcmStatus': fcmError.status,
            'fcmErrorCode': fcmError.errorCode,
          });
        }
      } catch (error, stackTrace) {
        hasRetryableFailures = true;
        logger.error('FCM push exception', const {}, error, stackTrace);
      }
    }
    return PushNotificationDeliveryResult(
      invalidTokens: invalidTokens,
      hasRetryableFailures: hasRetryableFailures,
    );
  }

  ({String? status, String? errorCode}) _parseFcmError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return (status: null, errorCode: null);
      final error = decoded['error'];
      if (error is! Map) return (status: null, errorCode: null);
      final details = error['details'];
      final errorCode = details is Iterable
          ? details
                .whereType<Map>()
                .map((detail) => detail['errorCode']?.toString())
                .firstWhere(
                  (code) => code != null && code.isNotEmpty,
                  orElse: () => null,
                )
          : null;
      return (status: error['status']?.toString(), errorCode: errorCode);
    } on FormatException {
      return (status: null, errorCode: null);
    }
  }

  Future<http.Client?> _authorizedHttpClient() async {
    final existing = _authorizedClient;
    if (existing != null) return existing;
    try {
      final client = await clientViaApplicationDefaultCredentials(
        scopes: const <String>[_firebaseMessagingScope],
        baseClient: _client,
      );
      _authorizedClient = client;
      return client;
    } catch (error, stackTrace) {
      logger.error(
        'FCM authorization unavailable',
        <String, Object?>{'projectIdConfigured': projectId.isNotEmpty},
        error,
        stackTrace,
      );
      return null;
    }
  }

  void close() {
    _authorizedClient?.close();
    _client.close();
  }
}

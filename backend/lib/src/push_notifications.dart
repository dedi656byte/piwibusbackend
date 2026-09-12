import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import 'ops_logger.dart';

class PushNotificationService {
  PushNotificationService._({
    required this.projectId,
    required this.logger,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const _firebaseMessagingScope =
      'https://www.googleapis.com/auth/firebase.messaging';

  final String projectId;
  final OpsLogger logger;
  final http.Client _client;
  http.Client? _authorizedClient;

  bool get enabled => projectId.isNotEmpty;

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
    final uniqueTokens = tokens
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toSet();
    if (!enabled || uniqueTokens.isEmpty) return;

    final authorizedClient = await _authorizedHttpClient();
    if (authorizedClient == null) return;

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
                },
              },
            },
          }),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          logger.warning('FCM push failed', <String, Object?>{
            'statusCode': response.statusCode,
            'body': response.body,
          });
        }
      } catch (error, stackTrace) {
        logger.error('FCM push exception', const {}, error, stackTrace);
      }
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

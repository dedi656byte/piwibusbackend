import 'dart:convert';

import 'package:piwibus_backend/src/public_health.dart';
import 'package:test/test.dart';

void main() {
  test('readiness responses expose only public status', () async {
    final ready = publicReadinessResponse(ready: true);
    final degraded = publicReadinessResponse(ready: false);

    expect(ready.statusCode, 200);
    expect(jsonDecode(await ready.readAsString()), <String, String>{
      'status': 'ok',
    });
    expect(degraded.statusCode, 503);
    expect(jsonDecode(await degraded.readAsString()), <String, String>{
      'status': 'degraded',
    });
  });

  test('storage readiness failure omits internal diagnostic details', () async {
    final response = publicStorageUnavailableResponse();
    final body = jsonDecode(await response.readAsString()) as Map;

    expect(response.statusCode, 503);
    expect(body, <String, String>{
      'error': 'Service temporairement indisponible.',
      'status': 'degraded',
    });
    expect(body.containsKey('detail'), isFalse);
    expect(response.headers['retry-after'], '10');
  });
}

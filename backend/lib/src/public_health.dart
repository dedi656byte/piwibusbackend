import 'dart:convert';

import 'package:shelf/shelf.dart';

Response publicReadinessResponse({required bool ready}) {
  return Response(
    ready ? 200 : 503,
    body: jsonEncode(<String, String>{'status': ready ? 'ok' : 'degraded'}),
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

Response publicStorageUnavailableResponse() {
  return Response(
    503,
    body: jsonEncode(<String, String>{
      'error': 'Service temporairement indisponible.',
      'status': 'degraded',
    }),
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
      'retry-after': '10',
    },
  );
}

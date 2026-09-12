import 'dart:io';

Future<void> main() async {
  final port =
      int.tryParse(Platform.environment['PIWIBUS_BACKEND_PORT'] ?? '') ?? 8080;
  final uri = Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: '/ready',
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 3));
    final response = await request.close().timeout(const Duration(seconds: 3));
    await response.drain<void>();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      exit(0);
    }
  } catch (_) {
    // Docker only needs the exit code for healthcheck decisions.
  } finally {
    client.close(force: true);
  }
  exit(1);
}

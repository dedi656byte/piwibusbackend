import 'dart:convert';
import 'dart:io';

class OpsLogger {
  const OpsLogger();

  void info(String message, [Map<String, Object?> fields = const {}]) {
    _write(stdout, 'info', message, fields);
  }

  void warning(String message, [Map<String, Object?> fields = const {}]) {
    _write(stdout, 'warning', message, fields);
  }

  void error(
    String message, [
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  ]) {
    _write(stderr, 'error', message, <String, Object?>{
      ...fields,
      if (error != null) 'error': error.toString(),
      if (stackTrace != null) 'stackTrace': stackTrace.toString(),
    });
  }

  void _write(
    IOSink sink,
    String level,
    String message,
    Map<String, Object?> fields,
  ) {
    sink.writeln(
      jsonEncode(<String, Object?>{
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'level': level,
        'message': message,
        ...fields,
      }),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'ops_logger.dart';

class PasswordResetEmailService {
  PasswordResetEmailService._({
    required this.logger,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.fromEmail,
    required this.fromName,
    required this.subject,
    required this.ssl,
    required this.allowInsecure,
    required this.enabled,
  });

  final OpsLogger logger;
  final String host;
  final int port;
  final String username;
  final String password;
  final String fromEmail;
  final String fromName;
  final String subject;
  final bool ssl;
  final bool allowInsecure;
  final bool enabled;

  static PasswordResetEmailService fromEnvironment({
    required OpsLogger logger,
  }) {
    final host = _env('PIWIBUS_SMTP_HOST');
    final username = _env('PIWIBUS_SMTP_USERNAME');
    final password = _env('PIWIBUS_SMTP_PASSWORD');
    final fromEmail = _env('PIWIBUS_MAIL_FROM');
    final fromName = _env('PIWIBUS_MAIL_FROM_NAME', fallback: 'Piwibus');
    final subject = _env(
      'PIWIBUS_PASSWORD_RESET_SUBJECT',
      fallback: 'Code de reinitialisation Piwibus',
    );
    final port = int.tryParse(_env('PIWIBUS_SMTP_PORT')) ?? 587;
    final ssl = _flag('PIWIBUS_SMTP_SSL');
    final allowInsecure = _flag('PIWIBUS_SMTP_ALLOW_INSECURE');
    final enabled =
        host.isNotEmpty &&
        username.isNotEmpty &&
        password.isNotEmpty &&
        fromEmail.isNotEmpty;

    if (!enabled) {
      logger.warning('Password reset email disabled', <String, Object?>{
        'reason':
            'Configure PIWIBUS_SMTP_HOST, PIWIBUS_SMTP_USERNAME, '
            'PIWIBUS_SMTP_PASSWORD and PIWIBUS_MAIL_FROM.',
      });
    }

    return PasswordResetEmailService._(
      logger: logger,
      host: host,
      port: port,
      username: username,
      password: password,
      fromEmail: fromEmail,
      fromName: fromName,
      subject: subject,
      ssl: ssl,
      allowInsecure: allowInsecure,
      enabled: enabled,
    );
  }

  Future<void> sendPasswordResetCode({
    required String email,
    required String code,
    required DateTime expiresAt,
  }) async {
    if (!enabled) {
      throw StateError('Service email de reinitialisation non configure.');
    }

    try {
      final client = await _SmtpClient.connect(
        host: host,
        port: port,
        username: username,
        password: password,
        ssl: ssl,
        allowInsecure: allowInsecure,
      );
      try {
        await client.sendMail(
          fromEmail: fromEmail,
          fromName: fromName,
          toEmail: email,
          subject: subject,
          text: _textBody(code: code, expiresAt: expiresAt),
          html: _htmlBody(code: code, expiresAt: expiresAt),
        );
      } finally {
        await client.close();
      }
      logger.info('Password reset email sent', <String, Object?>{
        'recipient': email,
      });
    } catch (error, stackTrace) {
      logger.error(
        'Password reset email failed',
        <String, Object?>{'recipient': email},
        error,
        stackTrace,
      );
      throw StateError(
        'Email de reinitialisation non envoye. Verifiez la configuration SMTP.',
      );
    }
  }

  static String _textBody({required String code, required DateTime expiresAt}) {
    final expiresLabel = _timeLabel(expiresAt);
    return '''
Bonjour,

Votre code de reinitialisation Piwibus est : $code

Il expire a $expiresLabel et reste valable 15 minutes. Si vous n'avez pas demande ce code, ignorez simplement cet email.

Piwibus
''';
  }

  static String _htmlBody({required String code, required DateTime expiresAt}) {
    final expiresLabel = htmlEscape.convert(_timeLabel(expiresAt));
    final safeCode = htmlEscape.convert(code);
    return '''
<!doctype html>
<html>
  <body style="font-family: Arial, sans-serif; color: #222; line-height: 1.45;">
    <h2 style="color: #D62828;">Piwibus</h2>
    <p>Votre code de reinitialisation est :</p>
    <p style="font-size: 28px; font-weight: 800; letter-spacing: 4px;">$safeCode</p>
    <p>Il expire a <strong>$expiresLabel</strong> et reste valable 15 minutes.</p>
    <p>Si vous n'avez pas demande ce code, ignorez simplement cet email.</p>
  </body>
</html>
''';
  }

  static String _timeLabel(DateTime dateTime) {
    final local = dateTime.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  static String _env(String name, {String fallback = ''}) {
    final value =
        Platform.environment[name]?.trim() ?? _dotenv()[name]?.trim() ?? '';
    return value.isEmpty ? fallback : value;
  }

  static bool _flag(String name) {
    final value = _env(name).toLowerCase();
    return value == 'true' || value == '1' || value == 'yes';
  }

  static Map<String, String> _dotenv() => _dotenvCache ??= _loadDotenv();

  static Map<String, String>? _dotenvCache;

  static Map<String, String> _loadDotenv() {
    final scriptDir = File.fromUri(Platform.script).parent;
    final candidates = <File>[
      File('${Directory.current.path}/.env'),
      File('${Directory.current.parent.path}/.env'),
      File('${scriptDir.path}/.env'),
      File('${scriptDir.parent.path}/.env'),
      File('${scriptDir.parent.parent.path}/.env'),
    ];
    for (final file in candidates) {
      if (!file.existsSync()) continue;
      final values = <String, String>{};
      for (final line in file.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final separator = trimmed.indexOf('=');
        if (separator <= 0) continue;
        final key = trimmed.substring(0, separator).trim();
        var value = trimmed.substring(separator + 1).trim();
        if ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'"))) {
          value = value.substring(1, value.length - 1);
        }
        values[key] = value;
      }
      return values;
    }
    return const <String, String>{};
  }
}

class _SmtpClient {
  _SmtpClient._({
    required this.socket,
    required this.reader,
    required this.host,
  });

  Socket socket;
  StreamIterator<String> reader;
  final String host;

  static Future<_SmtpClient> connect({
    required String host,
    required int port,
    required String username,
    required String password,
    required bool ssl,
    required bool allowInsecure,
  }) async {
    final socket = ssl
        ? await SecureSocket.connect(host, port, timeout: _timeout)
        : await Socket.connect(host, port, timeout: _timeout);
    final client = _SmtpClient._(
      socket: socket,
      reader: _lineReader(socket),
      host: host,
    );
    await client._expect(<int>[220]);
    var capabilities = await client._ehlo();
    final supportsStartTls = capabilities.any(
      (line) => line.toUpperCase().startsWith('STARTTLS'),
    );
    if (!ssl && supportsStartTls) {
      await client._sendCommand('STARTTLS', expectedCodes: <int>[220]);
      await client._upgradeToTls();
      capabilities = await client._ehlo();
    } else if (!ssl && !allowInsecure) {
      throw StateError('Le serveur SMTP ne propose pas STARTTLS.');
    }

    final authMethods = capabilities
        .where((line) => line.toUpperCase().startsWith('AUTH'))
        .join(' ')
        .toUpperCase();
    if (authMethods.contains('PLAIN')) {
      final token = base64.encode(
        utf8.encode('\u0000$username\u0000$password'),
      );
      await client._sendCommand('AUTH PLAIN $token', expectedCodes: <int>[235]);
    } else {
      await client._sendCommand('AUTH LOGIN', expectedCodes: <int>[334]);
      await client._sendRaw(base64.encode(utf8.encode(username)));
      await client._expect(<int>[334]);
      await client._sendRaw(base64.encode(utf8.encode(password)));
      await client._expect(<int>[235]);
    }
    return client;
  }

  Future<void> sendMail({
    required String fromEmail,
    required String fromName,
    required String toEmail,
    required String subject,
    required String text,
    required String html,
  }) async {
    final cleanFrom = _validateEmail(fromEmail, 'expediteur');
    final cleanTo = _validateEmail(toEmail, 'destinataire');
    await _sendCommand('MAIL FROM:<$cleanFrom>', expectedCodes: <int>[250]);
    await _sendCommand('RCPT TO:<$cleanTo>', expectedCodes: <int>[250, 251]);
    await _sendCommand('DATA', expectedCodes: <int>[354]);
    await _sendData(
      _message(
        fromEmail: cleanFrom,
        fromName: fromName,
        toEmail: cleanTo,
        subject: subject,
        text: text,
        html: html,
      ),
    );
    await _expect(<int>[250]);
  }

  Future<void> close() async {
    try {
      await _sendCommand('QUIT', expectedCodes: <int>[221]);
    } catch (_) {
      // Ignore close errors: the message has already been accepted or failed.
    }
    await reader.cancel();
    await socket.close();
  }

  Future<List<String>> _ehlo() async {
    await _sendRaw('EHLO piwibus.local');
    final response = await _readResponse();
    if (response.code == 250) return response.capabilities;
    await _sendRaw('HELO piwibus.local');
    final helo = await _readResponse();
    if (helo.code != 250) {
      throw StateError('SMTP HELO refuse: ${helo.message}');
    }
    return const <String>[];
  }

  Future<void> _upgradeToTls() async {
    final upgraded = await SecureSocket.secure(
      socket,
      host: host,
      onBadCertificate: (_) => false,
    );
    socket = upgraded;
    reader = _lineReader(upgraded);
  }

  Future<void> _sendCommand(
    String command, {
    required List<int> expectedCodes,
  }) async {
    await _sendRaw(command);
    await _expect(expectedCodes);
  }

  Future<void> _sendRaw(String command) async {
    socket.write('$command\r\n');
    await socket.flush();
  }

  Future<void> _sendData(String data) async {
    for (final rawLine in const LineSplitter().convert(data)) {
      final line = rawLine.startsWith('.') ? '.$rawLine' : rawLine;
      socket.write('$line\r\n');
    }
    socket.write('.\r\n');
    await socket.flush();
  }

  Future<void> _expect(List<int> expectedCodes) async {
    final response = await _readResponse();
    if (!expectedCodes.contains(response.code)) {
      throw StateError(
        'Reponse SMTP inattendue ${response.code}: ${response.message}',
      );
    }
  }

  Future<_SmtpResponse> _readResponse() async {
    final lines = <String>[];
    while (await reader.moveNext().timeout(_timeout)) {
      final line = reader.current;
      lines.add(line);
      if (line.length >= 4 && line[3] == ' ') {
        final code = int.tryParse(line.substring(0, 3));
        if (code != null) {
          return _SmtpResponse(code, lines);
        }
      } else if (line.length >= 3 && lines.length == 1) {
        final code = int.tryParse(line.substring(0, 3));
        if (code != null && (line.length == 3 || line[3] != '-')) {
          return _SmtpResponse(code, lines);
        }
      }
    }
    throw StateError('Connexion SMTP fermee.');
  }

  static StreamIterator<String> _lineReader(Socket socket) {
    return StreamIterator<String>(
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
  }

  static String _message({
    required String fromEmail,
    required String fromName,
    required String toEmail,
    required String subject,
    required String text,
    required String html,
  }) {
    final random = math.Random.secure();
    final boundary =
        'piwibus-${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 32)}';
    final safeFromName = _formatDisplayName(fromName);
    return [
      'From: $safeFromName <$fromEmail>',
      'To: <$toEmail>',
      'Subject: ${_headerText(subject)}',
      'Date: ${_rfcDate(DateTime.now().toUtc())}',
      'MIME-Version: 1.0',
      'Content-Type: multipart/alternative; boundary="$boundary"',
      '',
      '--$boundary',
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
      '',
      _base64Lines(text),
      '--$boundary',
      'Content-Type: text/html; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
      '',
      _base64Lines(html),
      '--$boundary--',
      '',
    ].join('\r\n');
  }

  static String _validateEmail(String value, String label) {
    final email = value.trim();
    if (email.contains('\r') || email.contains('\n')) {
      throw StateError('Adresse email $label invalide.');
    }
    final pattern = RegExp(r'^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$');
    if (!pattern.hasMatch(email)) {
      throw StateError('Adresse email $label invalide.');
    }
    return email;
  }

  static String _formatDisplayName(String value) {
    final clean = value
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) return 'Piwibus';
    final ascii = RegExp(r'^[\x20-\x7E]+$').hasMatch(clean);
    if (!ascii) return _headerText(clean);
    final escaped = clean.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  static String _headerText(String value) {
    final clean = value
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    final ascii = RegExp(r'^[\x20-\x7E]+$').hasMatch(clean);
    if (ascii) return clean;
    return '=?UTF-8?B?${base64.encode(utf8.encode(clean))}?=';
  }

  static String _base64Lines(String value) {
    final encoded = base64.encode(utf8.encode(value));
    final chunks = <String>[];
    for (var index = 0; index < encoded.length; index += 76) {
      chunks.add(
        encoded.substring(index, math.min(index + 76, encoded.length)),
      );
    }
    return chunks.join('\r\n');
  }

  static String _rfcDate(DateTime utc) {
    const weekdays = <int, String>{
      DateTime.monday: 'Mon',
      DateTime.tuesday: 'Tue',
      DateTime.wednesday: 'Wed',
      DateTime.thursday: 'Thu',
      DateTime.friday: 'Fri',
      DateTime.saturday: 'Sat',
      DateTime.sunday: 'Sun',
    };
    const months = <int, String>{
      DateTime.january: 'Jan',
      DateTime.february: 'Feb',
      DateTime.march: 'Mar',
      DateTime.april: 'Apr',
      DateTime.may: 'May',
      DateTime.june: 'Jun',
      DateTime.july: 'Jul',
      DateTime.august: 'Aug',
      DateTime.september: 'Sep',
      DateTime.october: 'Oct',
      DateTime.november: 'Nov',
      DateTime.december: 'Dec',
    };
    String two(int value) => value.toString().padLeft(2, '0');
    return '${weekdays[utc.weekday]}, ${two(utc.day)} ${months[utc.month]} '
        '${utc.year} ${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} +0000';
  }

  static const _timeout = Duration(seconds: 12);
}

class _SmtpResponse {
  const _SmtpResponse(this.code, this.lines);

  final int code;
  final List<String> lines;

  String get message => lines.join(' | ');

  List<String> get capabilities {
    return lines
        .map((line) {
          if (line.length >= 4 &&
              int.tryParse(line.substring(0, 3)) == code &&
              (line[3] == '-' || line[3] == ' ')) {
            return line.substring(4).trim();
          }
          return line.trim();
        })
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }
}

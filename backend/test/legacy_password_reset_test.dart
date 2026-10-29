import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test('legacy SHA-256 passwords require an email password reset', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'piwibus-legacy-password-reset',
    );
    final stateFile = File(p.join(tempDir.path, 'state.json'));
    var store = await PiwibusStore.openWithPersistence(
      JsonFileStatePersistence(stateFile),
    );
    addTearDown(() async {
      await store.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    const email = 'legacy-user@example.com';
    const oldPassword = 'legacy-password-123';
    const sessionId = 'legacy-user-session';
    await store.register(sessionId, <String, dynamic>{
      'fullName': 'Legacy User',
      'email': email,
      'password': oldPassword,
    });
    await store.close();

    final state =
        jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
    final users = (state['users'] as List).cast<Map<String, dynamic>>();
    users.single['passwordHash'] = sha256
        .convert(utf8.encode('$email::$oldPassword'))
        .toString();
    await stateFile.writeAsString(jsonEncode(state));

    store = await PiwibusStore.openWithPersistence(
      JsonFileStatePersistence(stateFile),
    );
    await expectLater(
      store.signIn(sessionId, <String, dynamic>{
        'email': email,
        'password': oldPassword,
      }),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Email ou mot de passe incorrect.',
        ),
      ),
    );

    String? resetCode;
    await store.requestPasswordReset(
      <String, dynamic>{'email': email},
      sendCode: ({required email, required code, required expiresAt}) async {
        resetCode = code;
      },
    );
    expect(resetCode, isNotNull);
    await store.confirmPasswordReset(sessionId, <String, dynamic>{
      'email': email,
      'code': resetCode,
      'password': 'replacement-password-123',
    });

    await expectLater(
      store.signIn(sessionId, <String, dynamic>{
        'email': email,
        'password': oldPassword,
      }),
      throwsA(isA<StateError>()),
    );
    await store.signIn(sessionId, <String, dynamic>{
      'email': email,
      'password': 'replacement-password-123',
    });
  });
}

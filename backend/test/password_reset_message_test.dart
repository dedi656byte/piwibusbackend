import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'password reset message is the same for existing and unknown emails',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'piwibus-password-reset-message',
      );
      final persistence = JsonFileStatePersistence(
        File(p.join(tempDir.path, 'state.json')),
      );
      final store = await PiwibusStore.openWithPersistence(persistence);
      addTearDown(() async {
        await store.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      await store.register('password-reset-message-session', <String, dynamic>{
        'fullName': 'Reset User',
        'email': 'reset-message@example.com',
        'password': 'password123',
      });

      var sentCodes = 0;
      Future<void> sendCode({
        required String email,
        required String code,
        required DateTime expiresAt,
      }) async {
        sentCodes += 1;
      }

      final existingAccountResponse = await store.requestPasswordReset(
        <String, dynamic>{'email': 'reset-message@example.com'},
        sendCode: sendCode,
      );
      final repeatedAccountResponse = await store.requestPasswordReset(
        <String, dynamic>{'email': 'reset-message@example.com'},
        sendCode: sendCode,
      );
      final unknownAccountResponse = await store.requestPasswordReset(
        <String, dynamic>{'email': 'unknown-reset-message@example.com'},
        sendCode: sendCode,
      );

      const expectedMessage =
          'Si cette adresse est associée à un compte Piwibus, vous recevrez un code de réinitialisation.';
      expect(existingAccountResponse['message'], expectedMessage);
      expect(repeatedAccountResponse['message'], expectedMessage);
      expect(unknownAccountResponse['message'], expectedMessage);
      expect(sentCodes, 1);
      expect(existingAccountResponse.keys.toSet(), <String>{
        'email',
        'message',
      });
      expect(
        unknownAccountResponse.keys.toSet(),
        existingAccountResponse.keys.toSet(),
      );
      expect(existingAccountResponse.containsKey('resetCode'), isFalse);
      expect(existingAccountResponse.containsKey('expiresAt'), isFalse);
    },
  );
}

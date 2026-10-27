import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'login and registration failures do not disclose account existence',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'piwibus-account-enumeration',
      );
      final store = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(File(p.join(tempDir.path, 'state.json'))),
      );
      addTearDown(() async {
        await store.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      await store.register('existing-user-session', <String, dynamic>{
        'fullName': 'Existing User',
        'email': 'existing-user@example.com',
        'password': 'password123',
      });

      final unknownEmailMessage = await _stateErrorMessage(
        () => store.signIn('unknown-user-session', <String, dynamic>{
          'email': 'unknown-user@example.com',
          'password': 'password123',
        }),
      );
      final wrongPasswordMessage = await _stateErrorMessage(
        () => store.signIn('existing-user-session', <String, dynamic>{
          'email': 'existing-user@example.com',
          'password': 'wrong-password',
        }),
      );
      final duplicateEmailMessage = await _stateErrorMessage(
        () => store.register('duplicate-email-session', <String, dynamic>{
          'fullName': 'Another User',
          'email': 'existing-user@example.com',
          'password': 'password123',
        }),
      );
      final duplicateNameMessage = await _stateErrorMessage(
        () => store.register('duplicate-name-session', <String, dynamic>{
          'fullName': 'Existing User',
          'email': 'new-user@example.com',
          'password': 'password123',
        }),
      );

      expect(unknownEmailMessage, 'Email ou mot de passe incorrect.');
      expect(wrongPasswordMessage, unknownEmailMessage);
      expect(
        duplicateEmailMessage,
        'Impossible de créer le compte avec ces informations.',
      );
      expect(duplicateNameMessage, duplicateEmailMessage);
    },
  );
}

Future<String> _stateErrorMessage(Future<Object?> Function() operation) async {
  try {
    await operation();
  } on StateError catch (error) {
    return error.message.toString();
  }
  throw StateError('Expected operation to fail.');
}

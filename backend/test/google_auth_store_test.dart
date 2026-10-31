import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/google_id_token_verifier.dart';
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  group('Google account sign-in', () {
    late Directory tempDir;
    late File stateFile;
    late PiwibusStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('piwibus-google-auth');
      stateFile = File(p.join(tempDir.path, 'state.json'));
      store = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(stateFile),
      );
    });

    tearDown(() async {
      await store.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('links a verified Google identity to the matching account', () async {
      final registered = await store
          .register('email-session', <String, dynamic>{
            'fullName': 'Existing User',
            'email': 'existing@example.com',
            'password': 'password123',
          });
      final existingUserId =
          (registered['currentUser'] as Map<String, dynamic>)['id'];

      final result = await store.signInWithGoogle(
        'google-session',
        const VerifiedGoogleIdentity(
          subject: 'google-subject-1',
          email: 'EXISTING@example.com',
          fullName: 'Google Profile Name',
        ),
      );

      final user = result['currentUser'] as Map<String, dynamic>;
      expect(user['id'], existingUserId);
      expect(result['sessionId'], 'google-session');
      expect(user, isNot(contains('googleSubject')));
      expect(jsonEncode(result), isNot(contains('google-subject-1')));

      final savedState =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      final savedUsers = (savedState['users'] as List)
          .cast<Map<String, dynamic>>();
      expect(savedUsers.single['googleSubject'], 'google-subject-1');
      expect(savedUsers.single['passwordHash'], isNotEmpty);
    });

    test(
      'creates a passwordless account and reuses it by Google subject',
      () async {
        final identity = const VerifiedGoogleIdentity(
          subject: 'google-subject-2',
          email: 'new-user@example.com',
          fullName: 'New User',
        );
        final created = await store.signInWithGoogle('first-session', identity);
        final userId = (created['currentUser'] as Map<String, dynamic>)['id'];
        final signedIn = await store.signInWithGoogle(
          'second-session',
          identity,
        );

        expect((signedIn['currentUser'] as Map<String, dynamic>)['id'], userId);
        await expectLater(
          store.signIn('password-session', <String, dynamic>{
            'email': 'new-user@example.com',
            'password': 'any-password',
          }),
          throwsA(isA<StateError>()),
        );

        final savedState =
            jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
        final savedUsers = (savedState['users'] as List)
            .cast<Map<String, dynamic>>();
        expect(savedUsers.single['phone'], isEmpty);
        expect(savedUsers.single['passwordHash'], isEmpty);
      },
    );

    test('reuses a linked subject when its Google email changes', () async {
      final firstSignIn = await store.signInWithGoogle(
        'first-session',
        const VerifiedGoogleIdentity(
          subject: 'google-subject-3',
          email: 'first@example.com',
          fullName: 'First User',
        ),
      );

      final secondSignIn = await store.signInWithGoogle(
        'second-session',
        const VerifiedGoogleIdentity(
          subject: 'google-subject-3',
          email: 'second@example.com',
          fullName: 'Second User',
        ),
      );

      expect(
        (secondSignIn['currentUser'] as Map<String, dynamic>)['id'],
        (firstSignIn['currentUser'] as Map<String, dynamic>)['id'],
      );
      final savedState =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      final savedUsers = (savedState['users'] as List);
      expect(savedUsers, hasLength(1));
    });

    test(
      'rejects a different subject from replacing an existing link',
      () async {
        const email = 'linked@example.com';
        await store.signInWithGoogle(
          'first-session',
          const VerifiedGoogleIdentity(
            subject: 'original-subject',
            email: email,
            fullName: 'Linked User',
          ),
        );

        await expectLater(
          store.signInWithGoogle(
            'second-session',
            const VerifiedGoogleIdentity(
              subject: 'replacement-subject',
              email: email,
              fullName: 'Linked User',
            ),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}

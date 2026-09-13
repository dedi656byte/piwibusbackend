import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  group('admin super user security', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp
          .createTemp('piwibus-admin-security-test');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'bootstrap administrator is marked as super admin and cannot be '
        'suspended or self-suspended', () async {
      final stateFile = File(p.join(tempDir.path, 'state.json'));
      final store = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(stateFile),
      );

      // The bootstrap admin is seeded automatically from env vars on store
      // creation. Always sign in with those credentials — never register.
      final adminEmail =
          (Platform.environment['PIWIBUS_ADMIN_EMAIL'] ?? 'dedivoss247@gmail.com')
              .toLowerCase();
      final adminPassword =
          Platform.environment['PIWIBUS_ADMIN_PASSWORD'] ?? 'Dedi@76201234567';

      // Sign in as the bootstrap admin (already seeded by the store).
      await store.signIn('admin-session', <String, dynamic>{
        'email': adminEmail,
        'password': adminPassword,
      });

      // Switch to administrator role — switchRole is async, must be awaited.
      await store.switchRole('admin-session', 'administrateur');

      // Retrieve admin ID from the session snapshot's currentUser.
      final adminSnapshot = store.snapshot('admin-session');
      final currentUser =
          adminSnapshot['currentUser'] as Map<String, dynamic>;
      final adminId = currentUser['id'] as String;

      // The admin must appear in the users list with isSuperAdmin == true.
      final publicUsers =
          (adminSnapshot['users'] as List).cast<Map<String, dynamic>>();
      final adminPublic = publicUsers.firstWhere(
        (u) => u['id'] == adminId,
        orElse: () => currentUser,
      );
      expect(
        adminPublic['isSuperAdmin'],
        isTrue,
        reason: 'Le bootstrap admin doit être marqué isSuperAdmin.',
      );

      // ---------------------------------------------------------------
      // Register a normal user (different session, different email).
      // ---------------------------------------------------------------
      await store.register('user-session', <String, dynamic>{
        'fullName': 'Normal User',
        'email': 'normal.user@example.com',
        'password': 'password123456',
      });

      final snapshotAfterRegister = store.snapshot('admin-session');
      final allUsers = (snapshotAfterRegister['users'] as List)
          .cast<Map<String, dynamic>>();
      final normalUser = allUsers.firstWhere(
        (u) => u['email'] == 'normal.user@example.com',
      );
      final normalUserId = normalUser['id'] as String;

      // Normal user must NOT be a super admin.
      expect(
        normalUser['isSuperAdmin'],
        isFalse,
        reason: 'Un utilisateur ordinaire ne doit pas être super admin.',
      );

      // ---------------------------------------------------------------
      // 1. Self-suspension by the admin → must throw StateError.
      // ---------------------------------------------------------------
      expect(
        () => store.toggleUserStatus('admin-session', adminId),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            anyOf(
              contains('Auto-suspension interdite'),
              contains('ne peut pas être suspendu'),
            ),
          ),
        ),
      );

      // ---------------------------------------------------------------
      // 2. Normal user can be suspended by the admin.
      // ---------------------------------------------------------------
      final res1 =
          await store.toggleUserStatus('admin-session', normalUserId);
      final list1 =
          (res1['users'] as List).cast<Map<String, dynamic>>();
      final suspendedUser =
          list1.firstWhere((u) => u['id'] == normalUserId);
      expect(
        suspendedUser['status'],
        equals('suspendu'),
        reason: 'Un utilisateur ordinaire doit pouvoir être suspendu.',
      );

      // ---------------------------------------------------------------
      // 3. Suspended normal user can be reactivated.
      // ---------------------------------------------------------------
      final res2 =
          await store.toggleUserStatus('admin-session', normalUserId);
      final list2 =
          (res2['users'] as List).cast<Map<String, dynamic>>();
      final activeUser =
          list2.firstWhere((u) => u['id'] == normalUserId);
      expect(
        activeUser['status'],
        equals('actif'),
        reason: 'Un utilisateur suspendu doit pouvoir être réactivé.',
      );
    });
  });
}


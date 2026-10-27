import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test('logout snapshot selects Carte', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'piwibus-logout-section',
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

    await store.register('logout-section-session', <String, dynamic>{
      'fullName': 'Logout User',
      'email': 'logout-section@example.com',
      'password': 'password123',
    });

    final snapshot = await store.logout('logout-section-session');

    expect(snapshot['currentUser'], isNull);
    expect(snapshot['section'], 'carte');
  });
}

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:piwibus_backend/src/state_persistence.dart';
import 'package:piwibus_backend/src/store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'report reactions are unique, reversible, and exclude the author',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'piwibus-report-reactions',
      );
      final stores = <PiwibusStore>[];
      addTearDown(() async {
        for (final store in stores) {
          await store.close();
        }
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });

      final stateFile = File(p.join(tempDir.path, 'state.json'));
      var store = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(stateFile),
      );
      stores.add(store);

      await store.register('report-author', <String, dynamic>{
        'fullName': 'Report Author',
        'email': 'report-author@example.com',
        'password': 'password123',
      });
      await store.register('first-voter', <String, dynamic>{
        'fullName': 'First Voter',
        'email': 'first-voter@example.com',
        'password': 'password123',
      });
      await store.register('second-voter', <String, dynamic>{
        'fullName': 'Second Voter',
        'email': 'second-voter@example.com',
        'password': 'password123',
      });
      await store.createReport('report-author', <String, dynamic>{
        'reportId': 'reaction-report',
        'busNumber': '05',
        'lineCode': '12',
        'location': <String, double>{'lat': 5.34, 'lng': -4.01},
        'note': 'Bus immobilisé',
      });
      await store.createReport('anonymous-author-session', <String, dynamic>{
        'reportId': 'anonymous-reaction-report',
        'busNumber': '18',
        'lineCode': '12',
        'location': <String, double>{'lat': 5.34, 'lng': -4.01},
        'note': 'Alerte anonyme',
      });

      var report = _report(store, 'report-author');
      expect(report['confidence'], 0.5);
      expect(report['isReportAuthor'], isTrue);
      await expectLater(
        store.setReportReaction('report-author', 'reaction-report', 'like'),
        throwsStateError,
      );
      expect(
        _report(
          store,
          'anonymous-author-session',
          reportId: 'anonymous-reaction-report',
        )['isReportAuthor'],
        isTrue,
      );
      await expectLater(
        store.setReportReaction(
          'anonymous-author-session',
          'anonymous-reaction-report',
          'dislike',
        ),
        throwsStateError,
      );

      await store.setReportReaction('first-voter', 'reaction-report', 'like');
      await store.setReportReaction('first-voter', 'reaction-report', 'like');
      await store.signIn('first-voter-second-session', {
        'email': 'first-voter@example.com',
        'password': 'password123',
      });
      await store.setReportReaction(
        'first-voter-second-session',
        'reaction-report',
        'like',
      );
      report = _report(store, 'second-voter');
      expect(report['likeCount'], 1);
      expect(report['confidence'], 0.55);

      await store.setReportReaction(
        'first-voter-second-session',
        'reaction-report',
        'dislike',
      );
      await store.setReportReaction(
        'second-voter',
        'reaction-report',
        'dislike',
      );
      report = _report(store, 'second-voter');
      expect(report['likeCount'], 0);
      expect(report['dislikeCount'], 2);
      expect(report['confidence'], 0.4);

      await store.setReportReaction('first-voter', 'reaction-report', null);
      report = _report(store, 'first-voter');
      expect(report['dislikeCount'], 1);
      expect(report['confidence'], 0.45);
      expect(report['currentReaction'], isNull);

      await store.close();
      stores.remove(store);
      store = await PiwibusStore.openWithPersistence(
        JsonFileStatePersistence(stateFile),
      );
      stores.add(store);
      report = _report(store, 'second-voter');
      expect(report['dislikeCount'], 1);
      expect(report['confidence'], 0.45);
    },
  );
}

Map<String, dynamic> _report(
  PiwibusStore store,
  String sessionId, {
  String reportId = 'reaction-report',
}) {
  final reports = store.snapshot(sessionId)['reports'] as List;
  return Map<String, dynamic>.from(
    reports.whereType<Map>().firstWhere((report) => report['id'] == reportId),
  );
}

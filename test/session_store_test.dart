import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/schema/session_document.dart';
import 'package:fujistudio_mobile/core/session/session_store.dart';

void _expectDeepEquals(Object? actual, Object? expected, String path) {
  expect(actual.runtimeType, equals(expected.runtimeType), reason: path);
  if (expected is Map && actual is Map) {
    expect(actual.keys.toSet(), equals(expected.keys.toSet()), reason: path);
    for (final k in expected.keys) {
      _expectDeepEquals(actual[k], expected[k], '$path.$k');
    }
    return;
  }
  if (expected is List && actual is List) {
    expect(actual.length, equals(expected.length), reason: path);
    for (var i = 0; i < expected.length; i++) {
      _expectDeepEquals(actual[i], expected[i], '$path[$i]');
    }
    return;
  }
  expect(actual, equals(expected), reason: path);
}

void main() {
  group('SessionStore', () {
    late Directory tempDir;
    late SessionStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_store_test_');
      store = SessionStore(
        explicitSessionRoot: tempDir.path,
        debounceDuration: const Duration(milliseconds: 40),
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('round-trips desktop_v2_4_2_sample.json with deep equality', () async {
      final rawText = File(
        'schemas/fixtures/desktop_v2_4_2_sample.json',
      ).readAsStringSync();
      final rawJson = jsonDecode(rawText) as Map<String, Object?>;
      final doc = SessionDocument.fromJson(rawJson);

      final albumKey = SessionStore.albumKeyFor('album_desktop_sample');
      await store.saveNow(albumKey, doc);

      final loaded = await store.loadSession(albumKey);
      expect(loaded, isNotNull);

      final wireLoaded =
          jsonDecode(jsonEncode(loaded!.toJson())) as Map<String, Object?>;
      final wireOriginal = jsonDecode(rawText) as Map<String, Object?>;
      _expectDeepEquals(wireLoaded, wireOriginal, 'root');
    });

    test(
      'quarantines truncated/corrupt primary file to .corrupt.* and recovers from .bak',
      () async {
        final rawJson = jsonDecode(
          File('schemas/fixtures/desktop_v2_4_2_sample.json').readAsStringSync(),
        ) as Map<String, Object?>;
        final docV1 = SessionDocument.fromJson(rawJson);
        final docV2 = docV1.copyWith(updatedAt: '2026-11-21T10:00:00Z');

        final albumKey = SessionStore.albumKeyFor('album_recover');
        await store.saveNow(albumKey, docV1);
        await store.saveNow(albumKey, docV2);

        final albumDir = await store.albumDirectory(albumKey);
        final primary = File(
          '${albumDir.path}${Platform.pathSeparator}${SessionStore.sessionFileName}',
        );
        // Truncate primary to simulate crash corruption while .bak holds docV1.
        await primary.writeAsString('{"schema_version": "2.4.2", "items": [');

        final recovered = await store.loadSession(albumKey);
        expect(recovered, isNotNull);
        expect(recovered!.updatedAt, equals(docV1.updatedAt));

        final entries = albumDir.listSync().map((e) => e.path).toList();
        expect(
          entries.any((p) => p.contains('.corrupt.')),
          isTrue,
          reason: 'Corrupt primary must be quarantined as .corrupt.<timestamp>',
        );
        expect(primary.existsSync(), isTrue);
      },
    );

    test(
      'serializes 25 overlapping Future.wait writes cleanly with final state and zero .tmp.* leftovers',
      () async {
        final rawJson = jsonDecode(
          File('schemas/fixtures/desktop_v2_4_2_sample.json').readAsStringSync(),
        ) as Map<String, Object?>;
        final baseDoc = SessionDocument.fromJson(rawJson);
        final albumKey = SessionStore.albumKeyFor('album_concurrent_25');

        final futures = <Future<void>>[];
        for (var i = 1; i <= 25; i++) {
          final mutated = baseDoc.copyWith(updatedAt: 'rev_$i');
          futures.add(
            store.saveNow(
              albumKey,
              mutated,
              recentEntry: RecentSessionEntry(
                albumId: 'album_concurrent_25',
                albumKey: albumKey,
                albumName: 'Concurrent Album',
                keepCount: i,
                totalCount: 25,
                updatedAtIso: 'rev_$i',
              ),
            ),
          );
        }
        await Future.wait(futures);

        final loaded = await store.loadSession(albumKey);
        expect(loaded, isNotNull);
        expect(loaded!.updatedAt, equals('rev_25'));

        final albumDir = await store.albumDirectory(albumKey);
        final leftovers = albumDir
            .listSync()
            .where((e) => e.path.contains('.tmp.'))
            .toList();
        expect(leftovers, isEmpty);

        final recent = await store.loadRecentSessions();
        expect(recent, hasLength(1));
        expect(recent.first.keepCount, equals(25));
      },
    );

    test(
      'writeChain recovers cleanly after a transient I/O write failure and persists subsequent writes',
      () async {
        final rawJson = jsonDecode(
          File('schemas/fixtures/desktop_v2_4_2_sample.json').readAsStringSync(),
        ) as Map<String, Object?>;
        final baseDoc = SessionDocument.fromJson(rawJson);
        final albumKey = SessionStore.albumKeyFor('album_writechain_recover');

        // Place a regular file where the album directory should be created so the
        // first saveNow fails with an I/O error and propagates to the caller.
        final blockingFile = File(
          '${tempDir.path}${Platform.pathSeparator}$albumKey',
        );
        await blockingFile.writeAsString('transient_obstacle');

        await expectLater(
          store.saveNow(albumKey, baseDoc.copyWith(updatedAt: 'failed_rev')),
          throwsA(isA<FileSystemException>()),
        );

        // Clear the transient obstacle and verify the next write succeeds on the same chain.
        await blockingFile.delete();
        await store.saveNow(
          albumKey,
          baseDoc.copyWith(updatedAt: 'recovered_rev_2'),
        );

        final loaded = await store.loadSession(albumKey);
        expect(loaded, isNotNull);
        expect(loaded!.updatedAt, equals('recovered_rev_2'));
      },
    );
  });
}

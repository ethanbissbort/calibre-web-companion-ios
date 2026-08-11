import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calibre_web_companion/core/services/api_service.dart';
import 'package:calibre_web_companion/core/services/download_manager.dart';
import 'package:calibre_web_companion/core/services/tag_service.dart';
import 'package:calibre_web_companion/features/book_details/data/datasources/book_details_remote_datasource.dart';
import 'package:calibre_web_companion/features/book_details/data/models/book_details_model.dart';
import 'package:calibre_web_companion/features/offline/data/models/offline_book_model.dart';
import 'package:calibre_web_companion/features/offline/data/repositories/offline_library_repository.dart';
import 'package:calibre_web_companion/features/settings/data/models/download_schema.dart';

/// On-device counterpart to the unit tests around downloaded-file bookkeeping.
///
/// Every one of those unit tests has to fake the two things this code is
/// actually about: where the platform puts the app sandbox, and whether a file
/// is really there. A fake `path_provider` always hands back the same directory,
/// so it can never reproduce the failure this suite exists for — on iOS/macOS
/// the app-container UUID changes on *every* app update, which invalidates every
/// absolute path the app wrote down, and downloaded books stop opening.
///
/// These tests therefore use the real sandbox, real file I/O and the real
/// preferences store, and only simulate the one thing that cannot be triggered
/// on demand: the container prefix having changed since the path was recorded.
///
/// Nothing here needs a Calibre-Web server, credentials or a network.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The key `DownloadManager` persists its uuid -> path registry under.
  const registryKey = 'downloaded_books_map';

  /// The key `OfflineLibraryRepository` persists its metadata map under.
  const offlineLibraryKey = 'offline_library';

  /// A container UUID that no installation of this app will ever have, so a
  /// path built from it is guaranteed not to resolve.
  const bogusContainer = 'DEADBEEF-0000-0000-0000-000000000000';

  late String stamp;
  late SharedPreferences prefs;
  late Directory documents;

  /// A private directory inside the real Documents directory. Everything this
  /// suite writes below the sandbox goes here so a single recursive delete
  /// cleans up, and the name is unique per run so a crashed run cannot poison
  /// the next one.
  late Directory workDir;

  /// Real files and directories to remove in `tearDown`, newest first.
  final junk = <FileSystemEntity>[];

  /// The preference values found before the suite ran, restored afterwards.
  /// These tests run on real devices, which may well be a developer's phone
  /// with a real library on it — the registry must come back untouched.
  String? previousRegistry;
  String? previousOfflineLibrary;

  DownloadManager newManager() =>
      DownloadManager(prefs: prefs, logger: Logger(level: Level.off));

  OfflineLibraryRepository newOfflineRepository() =>
      OfflineLibraryRepository(prefs: prefs, logger: Logger(level: Level.off));

  /// A datasource wired to the app's real (deliberately *uninitialised*)
  /// `ApiService`, so any accidental network call fails instead of silently
  /// reaching a server. Only the file-facing helpers are exercised below.
  BookDetailsRemoteDatasource newDatasource() {
    final logger = Logger(level: Level.off);
    final apiService = ApiService();
    return BookDetailsRemoteDatasource(
      apiService: apiService,
      logger: logger,
      tagService: TagService(apiService: apiService, logger: logger),
    );
  }

  /// Rewrites [realPath] into the path the same file had *before* an app
  /// update: the identical `/Documents/<relative>` tail, hanging off a
  /// container that no longer exists.
  ///
  /// This is exactly the shape of a stale path found in a real user's registry
  /// after an update, and the only input the healing code has to work from.
  String staleContainerPath(String realPath) {
    const marker = '/Documents/';
    final index = realPath.indexOf(marker);
    expect(
      index,
      isNonNegative,
      reason:
          'the Documents directory of this platform ($realPath) has no '
          '"/Documents/" segment, so container healing cannot be simulated',
    );
    final tail = realPath.substring(index + marker.length);
    return '/var/mobile/Containers/Data/Application/$bogusContainer'
        '/Documents/$tail';
  }

  /// Creates a real file below [workDir], registers it for cleanup and returns
  /// it. [name] may contain sub-directories.
  File writeRealFile(String name, {String contents = 'not a real book'}) {
    final file = File(p.join(workDir.path, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents, flush: true);
    return file;
  }

  setUp(() async {
    stamp = DateTime.now().microsecondsSinceEpoch.toString();

    prefs = await SharedPreferences.getInstance();
    // Read what the platform actually holds, not a stale in-process cache.
    await prefs.reload();
    previousRegistry = prefs.getString(registryKey);
    previousOfflineLibrary = prefs.getString(offlineLibraryKey);
    await prefs.remove(registryKey);
    await prefs.remove(offlineLibraryKey);

    documents = await getApplicationDocumentsDirectory();
    workDir = Directory(p.join(documents.path, 'itest_storage_paths_$stamp'));
    workDir.createSync(recursive: true);
    junk.add(workDir);
  });

  tearDown(() async {
    for (final entity in junk.reversed) {
      try {
        if (entity.existsSync()) entity.deleteSync(recursive: true);
      } catch (_) {
        // Best effort: a leftover file must never fail an otherwise green run.
      }
    }
    junk.clear();

    if (previousRegistry != null) {
      await prefs.setString(registryKey, previousRegistry!);
    } else {
      await prefs.remove(registryKey);
    }
    if (previousOfflineLibrary != null) {
      await prefs.setString(offlineLibraryKey, previousOfflineLibrary!);
    } else {
      await prefs.remove(offlineLibraryKey);
    }
  });

  group('download registry, real preferences and real files', () {
    testWidgets('a registration round-trips through the platform store', (
      tester,
    ) async {
      final uuid = 'itest-roundtrip-$stamp';
      final book = writeRealFile('roundtrip.epub');

      final manager = newManager();
      await manager.initialize();
      await manager.registerDownload(uuid, book.path);

      expect(manager.isBookDownloaded(uuid), isTrue);
      expect(manager.getBookPath(uuid), book.path);
      expect(manager.allDownloads[uuid], book.path);
      expect(
        () => manager.allDownloads[uuid] = 'tampered',
        throwsUnsupportedError,
        reason: 'callers must not be able to mutate the registry behind it',
      );

      // Re-reading from the platform proves the write reached the on-disk
      // plist/XML rather than only the in-memory cache, and a second manager
      // is what a cold launch would build.
      await prefs.reload();
      final relaunched = newManager();
      await relaunched.initialize();

      expect(relaunched.getBookPath(uuid), book.path);
      expect(await relaunched.checkFileExistence(uuid), isTrue);

      await relaunched.unregisterDownload(uuid);
      await prefs.reload();
      final afterRemoval = newManager();
      await afterRemoval.initialize();

      expect(afterRemoval.isBookDownloaded(uuid), isFalse);
      expect(afterRemoval.getBookPath(uuid), isNull);
      expect(
        book.existsSync(),
        isTrue,
        reason: 'unregistering forgets the book, it does not delete the file',
      );
    });

    testWidgets(
      'startup heals a path left over from a previous app container',
      (tester) async {
        final uuid = 'itest-healed-$stamp';
        final book = writeRealFile('healed.epub');
        final stale = staleContainerPath(book.path);

        expect(File(stale).existsSync(), isFalse);
        expect(stale, isNot(book.path));

        // Seed the registry the way an update leaves it: right relative path,
        // dead container prefix.
        await prefs.setString(registryKey, json.encode({uuid: stale}));

        final manager = newManager();
        await manager.initialize();

        expect(
          manager.getBookPath(uuid),
          book.path,
          reason: 'the entry must be re-anchored to the current container',
        );

        // Healing has to be written back, otherwise every launch pays for it
        // again and any consumer reading the raw preferences still breaks.
        await prefs.reload();
        final persisted =
            json.decode(prefs.getString(registryKey)!) as Map<String, dynamic>;
        expect(persisted[uuid], book.path);
      },
      // Android paths are SAF document URIs and app-private paths are stable,
      // so `_relocateFile` deliberately does nothing there.
      skip: Platform.isAndroid,
    );

    testWidgets(
      'a runtime existence check heals a path that went stale after startup',
      (tester) async {
        final uuid = 'itest-runtime-healed-$stamp';
        final book = writeRealFile('runtime_healed.epub');
        final stale = staleContainerPath(book.path);

        final manager = newManager();
        await manager.initialize();
        await manager.registerDownload(uuid, stale);

        expect(
          await manager.checkFileExistence(uuid),
          isTrue,
          reason: 'the book is on disk, only the recorded prefix is wrong',
        );
        expect(manager.getBookPath(uuid), book.path);

        await prefs.reload();
        final persisted =
            json.decode(prefs.getString(registryKey)!) as Map<String, dynamic>;
        expect(persisted[uuid], book.path);
      },
      skip: Platform.isAndroid,
    );

    testWidgets(
      'an entry that cannot be confirmed missing is kept, not dropped',
      (tester) async {
        // No `/Documents/` segment, so there is nothing to re-anchor against:
        // the file may be gone, or it may be somewhere this code does not know
        // how to look. Dropping the entry would lose the book from the offline
        // library for good, which is strictly worse than keeping a dud path.
        final uuid = 'itest-inconclusive-$stamp';
        final unresolvable =
            '/var/mobile/Containers/Data/Application/$bogusContainer'
            '/Library/Caches/itest_gone_$stamp.epub';
        expect(File(unresolvable).existsSync(), isFalse);

        await prefs.setString(registryKey, json.encode({uuid: unresolvable}));

        final manager = newManager();
        await manager.initialize();

        expect(manager.isBookDownloaded(uuid), isTrue);
        expect(manager.getBookPath(uuid), unresolvable);

        // The runtime check reports the file as unavailable...
        expect(await manager.checkFileExistence(uuid), isFalse);
        // ...but still must not silently unregister it.
        expect(manager.isBookDownloaded(uuid), isTrue);
      },
      skip: Platform.isAndroid,
    );

    testWidgets(
      'an entry that is confirmed missing is dropped',
      (tester) async {
        // The counterpart to the test above: this path *can* be re-anchored,
        // and the file is not at the new location either, so it really is gone
        // and keeping the entry would only produce a dead library row.
        final uuid = 'itest-confirmed-gone-$stamp';
        final stale = staleContainerPath(
          p.join(workDir.path, 'never_written.epub'),
        );

        await prefs.setString(registryKey, json.encode({uuid: stale}));

        final manager = newManager();
        await manager.initialize();

        expect(manager.isBookDownloaded(uuid), isFalse);

        await prefs.reload();
        final persisted =
            json.decode(prefs.getString(registryKey)!) as Map<String, dynamic>;
        expect(persisted.containsKey(uuid), isFalse);
      },
      skip: Platform.isAndroid,
    );

    testWidgets('the sweep removes only partial files', (tester) async {
      final keptBook = writeRealFile('kept.epub');
      final stalePart = writeRealFile('interrupted.epub$downloadPartSuffix');
      final nestedPart = writeRealFile(
        'nested/deeper/interrupted.pdf$downloadPartSuffix',
      );

      // The staging directory downloads are streamed through on the SAF path.
      // It belongs to the app, so only the files created here are cleaned up —
      // the directory itself may legitimately pre-exist.
      final temp = await getTemporaryDirectory();
      final stagingDir = Directory(
        p.join(temp.path, downloadStagingDirectoryName),
      );
      stagingDir.createSync(recursive: true);
      final stagedPart = File(
        p.join(stagingDir.path, 'staged_$stamp.epub$downloadPartSuffix'),
      )..writeAsStringSync('half a book', flush: true);
      final stagedKeeper = File(p.join(stagingDir.path, 'keep_$stamp.bin'))
        ..writeAsStringSync('not a partial download', flush: true);
      junk.addAll([stagedPart, stagedKeeper]);

      final removed = await newManager().sweepStalePartFiles(olderThan: Duration.zero);

      expect(stalePart.existsSync(), isFalse);
      expect(nestedPart.existsSync(), isFalse);
      expect(stagedPart.existsSync(), isFalse);
      expect(keptBook.existsSync(), isTrue);
      expect(stagedKeeper.existsSync(), isTrue);
      // Greater-or-equal, not exactly three: a real device may carry its own
      // leftovers from an interrupted download, and sweeping those is the
      // whole point.
      expect(removed, greaterThanOrEqualTo(3));
    });
  });

  group('offline library path reconciliation', () {
    OfflineBookModel bookAt(String uuid, String filePath, {String? coverPath}) =>
        OfflineBookModel(
          uuid: uuid,
          id: 42,
          title: 'ITest Offline Book',
          authors: 'ITest Author',
          series: '',
          seriesIndex: 0,
          filePath: filePath,
          format: 'epub',
          coverPath: coverPath,
          savedAt: DateTime.now().millisecondsSinceEpoch,
        );

    testWidgets('stored metadata adopts the healed download path', (
      tester,
    ) async {
      final uuid = 'itest-offline-$stamp';
      final book = writeRealFile('offline/book.epub');
      // What the metadata still says, long after the container moved.
      final stale =
          Platform.isAndroid
              ? '/data/user/0/gone.app/app_flutter/book_$stamp.epub'
              : staleContainerPath(book.path);

      final repository = newOfflineRepository();
      await repository.saveBook(bookAt(uuid, stale));

      // The download registry is healed on startup, so its path wins.
      final reconciled = await repository.reconcilePaths({uuid: book.path});

      expect(reconciled[uuid]!.filePath, book.path);

      // Persisted, so the next launch has nothing to do...
      await prefs.reload();
      expect(newOfflineRepository().getBook(uuid)!.filePath, book.path);

      // ...which an empty registry proves: with no help available the second
      // call still yields the healed path, i.e. it was written back.
      final second = await newOfflineRepository().reconcilePaths(const {});
      expect(second[uuid]!.filePath, book.path);
    });

    testWidgets(
      'a stale cover path is re-anchored, an unresolvable one is left alone',
      (tester) async {
        final healable = 'itest-offline-cover-$stamp';
        final unresolvable = 'itest-offline-nocover-$stamp';

        final cover = writeRealFile('offline/cover.img', contents: 'jpegish');
        final staleCover = staleContainerPath(cover.path);
        final book = writeRealFile('offline/covered.epub');
        final missingCover =
            '/var/mobile/Containers/Data/Application/$bogusContainer'
            '/Library/Caches/itest_cover_$stamp.img';

        final repository = newOfflineRepository();
        await repository.saveBook(
          bookAt(healable, book.path, coverPath: staleCover),
        );
        await repository.saveBook(
          bookAt(unresolvable, book.path, coverPath: missingCover),
        );

        final reconciled = await repository.reconcilePaths(const {});

        expect(reconciled[healable]!.coverPath, cover.path);
        expect(
          reconciled[unresolvable]!.coverPath,
          missingCover,
          reason:
              'a path that cannot be re-resolved is kept, never cleared — a '
              'missing cover must not cost the offline entry',
        );

        await prefs.reload();
        expect(newOfflineRepository().getBook(healable)!.coverPath, cover.path);

        final second = await newOfflineRepository().reconcilePaths(const {});
        expect(second[healable]!.coverPath, cover.path);
      },
      // `reconcilePaths` deliberately skips cover healing on Android, where
      // app-private paths do not move.
      skip: Platform.isAndroid,
    );

    testWidgets('an empty library reconciles to nothing', (tester) async {
      expect(await newOfflineRepository().reconcilePaths(const {}), isEmpty);
    });
  });

  group('partial download files on the real filesystem', () {
    // The first four bytes of every zip, and therefore of every EPUB.
    const zipMagic = 'PK';

    testWidgets('a .part file is never mistaken for a readable book', (
      tester,
    ) async {
      final datasource = newDatasource();

      final finished = writeRealFile('reader/book.epub', contents: zipMagic);
      final partial = writeRealFile(
        'reader/book.epub$downloadPartSuffix',
        contents: zipMagic,
      );
      final notAnEpub = writeRealFile(
        'reader/notes.epub',
        contents: 'plain text, not a container',
      );

      expect(await datasource.readLocalEpubBytes(finished.path), isNotEmpty);
      expect(
        await datasource.readLocalEpubBytes(partial.path),
        isNull,
        reason:
            'the staging suffix must disqualify a file even when its bytes '
            'look like a zip',
      );
      expect(
        await datasource.readLocalEpubBytes(notAnEpub.path),
        isNull,
        reason: 'the name alone is not evidence of a container',
      );
      expect(
        await datasource.readLocalEpubBytes(
          p.join(workDir.path, 'reader/absent.epub'),
        ),
        isNull,
      );
    });

    testWidgets('publishing a .part by rename yields a sweep-proof book', (
      tester,
    ) async {
      // The exact publish step `downloadBookToDevice` performs, against the
      // real sandbox filesystem: stream into a sibling `.part`, then rename.
      final target = File(p.join(workDir.path, 'published.epub'));
      final part = File('${target.path}$downloadPartSuffix');
      part.writeAsStringSync('$zipMagic complete payload', flush: true);

      await part.rename(target.path);

      expect(part.existsSync(), isFalse);
      expect(target.existsSync(), isTrue);
      expect(target.readAsStringSync(), '$zipMagic complete payload');

      // And the startup sweep must not undo the publish.
      await newManager().sweepStalePartFiles(olderThan: Duration.zero);

      expect(
        target.existsSync(),
        isTrue,
        reason: 'a published book carries no suffix and must survive the sweep',
      );
    });

    testWidgets('an existing sandbox copy is returned without a request', (
      tester,
    ) async {
      // Only the path arithmetic is under test here. Nothing is mocked: if the
      // reuse branch failed to short-circuit, the call would fall through to
      // `getDownloadStream` on an uninitialised ApiService and fail the test
      // rather than quietly hitting a server.
      final title = 'ITest Book $stamp';
      final author = 'ITest Author $stamp';
      final series = 'ITest Series $stamp';
      final book = BookDetailsModel(
        id: 1,
        uuid: 'itest-sandbox-$stamp',
        title: title,
        authors: author,
        series: series,
      );

      // author/series/book/book.epub, as the schema prescribes.
      final expected = File(
        p.join(documents.path, author, series, title, '$title.epub'),
      );
      junk.add(Directory(p.join(documents.path, author)));
      expected.parent.createSync(recursive: true);
      expected.writeAsStringSync(zipMagic, flush: true);

      final path = await newDatasource().downloadBookToDevice(
        book,
        format: 'epub',
        schema: DownloadSchema.authorSeriesBook,
      );

      expect(path, expected.path);
      expect(File(path).existsSync(), isTrue);
    });
  });
}

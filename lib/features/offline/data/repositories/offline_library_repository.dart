import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calibre_web_companion/features/offline/data/models/offline_book_model.dart';

class OfflineLibraryRepository {
  final SharedPreferences _prefs;
  final Logger _logger;

  static const String _storageKey = 'offline_library';
  static const String _coverDirName = 'offline_covers';
  static const String _documentsMarker = '/Documents/';

  OfflineLibraryRepository({
    required SharedPreferences prefs,
    required Logger logger,
  }) : _prefs = prefs,
       _logger = logger;

  Map<String, dynamic> _readMap() {
    final raw = _prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = json.decode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (e) {
      _logger.w('Could not decode offline library: $e');
      return {};
    }
  }

  Future<void> _writeMap(Map<String, dynamic> map) async {
    await _prefs.setString(_storageKey, json.encode(map));
  }

  List<OfflineBookModel> getAll() {
    final map = _readMap();
    final books =
        map.values
            .whereType<Map>()
            .map((e) => OfflineBookModel.fromJson(Map<String, dynamic>.from(e)))
            .toList();
    books.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return books;
  }

  OfflineBookModel? getBook(String uuid) {
    final map = _readMap();
    final entry = map[uuid];
    if (entry is Map) {
      return OfflineBookModel.fromJson(Map<String, dynamic>.from(entry));
    }
    return null;
  }

  Future<void> saveBook(OfflineBookModel book, {Uint8List? coverBytes}) async {
    var toStore = book;
    if (coverBytes != null && coverBytes.isNotEmpty) {
      final coverPath = await _writeCover(book.uuid, coverBytes);
      if (coverPath != null) toStore = book.copyWith(coverPath: coverPath);
    }
    final map = _readMap();
    map[book.uuid] = toStore.toJson();
    await _writeMap(map);
    _logger.i('Saved offline metadata for "${book.title}"');
  }

  Future<void> remove(String uuid) async {
    final map = _readMap();
    final existing = map[uuid];
    if (existing is Map) {
      final coverPath = existing['coverPath']?.toString();
      if (coverPath != null && coverPath.isNotEmpty) {
        try {
          final f = File(coverPath);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
    map.remove(uuid);
    await _writeMap(map);
  }

  bool isSaved(String uuid) => _readMap().containsKey(uuid);

  /// Re-points stored metadata at the paths where the files actually live now.
  ///
  /// On iOS/macOS the app-container UUID changes on every app update, so the
  /// absolute paths written at download time go stale. [downloadPaths] holds
  /// the paths DownloadManager keeps, which it already heals on startup, so
  /// they win over whatever is stored here. Cover paths are healed the same
  /// way by re-resolving them against the current Documents directory.
  ///
  /// Healed values are written back so the work only has to happen once, and
  /// nothing is ever dropped: a path that cannot be resolved is left as-is.
  ///
  /// On Android this is a no-op — the stored path and the download registry
  /// path are always the same string there, and app-private paths are stable.
  Future<Map<String, OfflineBookModel>> reconcilePaths(
    Map<String, String> downloadPaths,
  ) async {
    final map = _readMap();
    if (map.isEmpty) return const {};

    String? documentsPath;
    if (!Platform.isAndroid) {
      try {
        documentsPath = (await getApplicationDocumentsDirectory()).path;
      } catch (e) {
        _logger.w('Could not resolve documents directory: $e');
      }
    }

    final books = <String, OfflineBookModel>{};
    var changed = false;

    for (final entry in map.entries) {
      final stored = entry.value;
      if (stored is! Map) continue;

      final original = OfflineBookModel.fromJson(
        Map<String, dynamic>.from(stored),
      );
      var book = original;

      final downloadPath = downloadPaths[entry.key];
      if (downloadPath != null &&
          downloadPath.isNotEmpty &&
          downloadPath != book.filePath) {
        _logger.i(
          'Offline metadata for ${entry.key} pointed at a stale path. '
          'Using $downloadPath.',
        );
        book = book.copyWith(filePath: downloadPath);
      }

      if (documentsPath != null) {
        final healedCover = _relocateInDocuments(book.coverPath, documentsPath);
        if (healedCover != null) book = book.copyWith(coverPath: healedCover);
      }

      if (book.filePath != original.filePath ||
          book.coverPath != original.coverPath) {
        map[entry.key] = book.toJson();
        changed = true;
      }
      books[entry.key] = book;
    }

    if (changed) await _writeMap(map);
    return books;
  }

  /// Re-resolves a stale absolute path against the current Documents
  /// directory. Returns null when the path is still valid, has no
  /// `/Documents/` segment to re-anchor, or the file is not at the new
  /// location either — in every one of those cases the caller keeps the
  /// original path rather than discarding it.
  String? _relocateInDocuments(String? path, String documentsPath) {
    if (path == null || path.isEmpty) return null;
    try {
      if (File(path).existsSync()) return null;

      final index = path.indexOf(_documentsMarker);
      if (index == -1) return null;

      final candidate =
          '$documentsPath/${path.substring(index + _documentsMarker.length)}';
      if (candidate != path && File(candidate).existsSync()) return candidate;
    } catch (e) {
      _logger.w('Failed to relocate $path: $e');
    }
    return null;
  }

  Future<String?> _writeCover(String uuid, Uint8List bytes) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final coverDir = Directory('${dir.path}/$_coverDirName');
      if (!coverDir.existsSync()) coverDir.createSync(recursive: true);
      final safeName = uuid.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final file = File('${coverDir.path}/$safeName.img');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e) {
      _logger.w('Could not cache cover for $uuid: $e');
      return null;
    }
  }
}

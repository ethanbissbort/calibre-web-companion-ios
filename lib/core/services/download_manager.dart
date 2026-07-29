import 'dart:io';
import 'dart:convert';
import 'package:docman/docman.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DownloadManager {
  final SharedPreferences _prefs;
  final Logger _logger;

  Map<String, String> _downloadedBooks = {};
  static const String _storageKey = 'downloaded_books_map';
  static const String _documentsMarker = '/Documents/';

  DownloadManager({required SharedPreferences prefs, required Logger logger})
    : _prefs = prefs,
      _logger = logger;

  Future<void> initialize() async {
    final String? jsonString = _prefs.getString(_storageKey);
    if (jsonString != null) {
      try {
        final Map<String, dynamic> decoded = json.decode(jsonString);
        _downloadedBooks = decoded.map(
          (key, value) => MapEntry(key, value.toString()),
        );
      } catch (e) {
        _logger.e('Error decoding downloaded books map: $e');
        _downloadedBooks = {};
      }
    }

    await _verifyFilesExist();
  }

  Future<bool> _doesFileExist(String path) async {
    try {
      if (Platform.isAndroid) {
        final doc = await DocumentFile.fromUri(path);
        return doc?.exists ?? false;
      } else {
        return File(path).existsSync();
      }
    } catch (e) {
      _logger.w('Failed to check existence for $path: $e');
      return false;
    }
  }

  /// On iOS (and macOS) the app sandbox container path — and with it the
  /// absolute path of the Documents directory — changes whenever the app is
  /// updated. Try to re-resolve a stale absolute path against the current
  /// Documents directory before treating the file as gone.
  Future<String?> _relocateFile(String path) async {
    if (!_canRelocate(path)) return null;

    final index = path.indexOf(_documentsMarker);
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      final candidate =
          '${documentsDir.path}/'
          '${path.substring(index + _documentsMarker.length)}';
      if (candidate != path && File(candidate).existsSync()) {
        return candidate;
      }
    } catch (e) {
      _logger.w('Failed to relocate $path: $e');
    }
    return null;
  }

  /// Whether a stale path can even be re-anchored to the current Documents
  /// directory. Always false on Android, where paths are SAF document URIs and
  /// relocation neither applies nor is needed.
  bool _canRelocate(String path) =>
      !Platform.isAndroid && path.contains(_documentsMarker);

  /// Whether a missing file is proof that the download is gone.
  ///
  /// On Android it is: paths are stable, so a missing file was deleted. On
  /// iOS/macOS a path we cannot re-anchor (no `/Documents/` segment) is
  /// inconclusive — the container may simply have moved somewhere this code
  /// does not recognise — so the registry entry is kept rather than dropped,
  /// since dropping it loses the book from the offline library for good.
  bool _isConfirmedMissing(String path) =>
      Platform.isAndroid || _canRelocate(path);

  Future<void> _verifyFilesExist() async {
    final List<String> toRemove = [];
    final Map<String, String> toRelocate = {};

    for (var entry in _downloadedBooks.entries) {
      final exists = await _doesFileExist(entry.value);

      if (!exists) {
        final relocated = await _relocateFile(entry.value);
        if (relocated != null) {
          _logger.i(
            'File for book ${entry.key} moved to $relocated. Updating path.',
          );
          toRelocate[entry.key] = relocated;
          continue;
        }

        if (!_isConfirmedMissing(entry.value)) {
          _logger.w(
            'File for book ${entry.key} not found at ${entry.value} and the '
            'path could not be re-resolved. Keeping the entry.',
          );
          continue;
        }

        _logger.i(
          'File for book ${entry.key} not found at ${entry.value}. Removing from list.',
        );
        toRemove.add(entry.key);
      }
    }

    if (toRemove.isNotEmpty || toRelocate.isNotEmpty) {
      for (var uuid in toRemove) {
        _downloadedBooks.remove(uuid);
      }
      _downloadedBooks.addAll(toRelocate);
      await _save();
    }

    _logger.i(
      'DownloadManager initialized. ${_downloadedBooks.length} books verified.',
    );
  }

  Future<bool> checkFileExistence(String uuid) async {
    final path = _downloadedBooks[uuid];
    if (path == null) return false;

    final exists = await _doesFileExist(path);
    if (!exists) {
      final relocated = await _relocateFile(path);
      if (relocated != null) {
        _logger.i(
          'Runtime check: File for $uuid moved. Updating path to $relocated.',
        );
        _downloadedBooks[uuid] = relocated;
        await _save();
        return true;
      }

      if (!_isConfirmedMissing(path)) {
        _logger.w(
          'Runtime check: File for $uuid not found at $path and the path could '
          'not be re-resolved. Keeping the entry.',
        );
        return false;
      }

      _logger.i('Runtime check: File for $uuid missing. Unregistering.');
      await unregisterDownload(uuid);
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    await _prefs.setString(_storageKey, json.encode(_downloadedBooks));
  }

  bool isBookDownloaded(String uuid) {
    return _downloadedBooks.containsKey(uuid);
  }

  String? getBookPath(String uuid) {
    return _downloadedBooks[uuid];
  }

  Map<String, String> get allDownloads => Map.unmodifiable(_downloadedBooks);

  Future<void> registerDownload(String uuid, String path) async {
    _downloadedBooks[uuid] = path;
    await _save();
    _logger.i('Registered download for book $uuid at $path');
  }

  Future<void> unregisterDownload(String uuid) async {
    if (_downloadedBooks.containsKey(uuid)) {
      _downloadedBooks.remove(uuid);
      await _save();
    }
  }
}

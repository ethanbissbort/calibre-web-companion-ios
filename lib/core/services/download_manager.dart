import 'dart:io';
import 'dart:convert';
import 'package:docman/docman.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calibre_web_companion/core/exceptions/cancellation_exception.dart';

/// Suffix of the temporary file a download is streamed into before it is
/// published to its final location.
///
/// A file at the final location is therefore always complete: the rename only
/// happens after the whole payload has arrived and been validated.
const String downloadPartSuffix = '.part';

/// Sub-directory of the app's temporary directory used to stage downloads that
/// cannot be written to their final location directly (the Android SAF path).
const String downloadStagingDirectoryName = 'cwc_downloads';

/// How stale a `.part` file must be before the startup sweep will delete it.
///
/// Guards two cases: a download running concurrently with the sweep, and a
/// user's own unrelated `.part` file sitting in the Files.app-visible Documents
/// directory, which they may have only just put there.
const Duration _partFileGracePeriod = Duration(hours: 6);

/// Cooperative cancellation for a running download.
///
/// The token is checked between chunks, so tripping it aborts the HTTP stream,
/// removes the partial file and surfaces a [CancellationException] — which
/// callers can tell apart from a genuine failure.
///
/// A token is single-use: once cancelled it stays cancelled. Create a fresh one
/// for every download.
class DownloadCancellationToken {
  DownloadCancellationToken();

  static const String defaultReason = 'Download cancelled';

  bool _isCancelled = false;
  String _reason = defaultReason;

  /// Whether the caller asked for this download to stop.
  bool get isCancelled => _isCancelled;

  /// Human readable reason, used as the message of the thrown exception.
  String get reason => _reason;

  /// Trips the token. Repeated calls are ignored, so the first reason wins.
  void cancel([String? reason]) {
    if (_isCancelled) return;
    _isCancelled = true;
    if (reason != null && reason.isNotEmpty) _reason = reason;
  }

  /// Throws a [CancellationException] when the token has been tripped.
  void throwIfCancelled() {
    if (_isCancelled) throw CancellationException(_reason);
  }
}

/// Outcome of comparing the bytes actually received with the `Content-Length`
/// the server announced.
enum DownloadSizeCheck {
  /// Received exactly as many bytes as announced.
  ok,

  /// The server did not announce a usable length (missing header, chunked
  /// transfer or a content encoding that makes the header incomparable).
  unknownLength,

  /// Nothing at all arrived.
  empty,

  /// Fewer bytes than announced — the transfer was cut short.
  truncated,

  /// More bytes than announced.
  overrun,
}

extension DownloadSizeCheckX on DownloadSizeCheck {
  /// Whether the payload may be published as a complete book.
  ///
  /// [DownloadSizeCheck.overrun] is tolerated: a proxy that rewrites the body
  /// without fixing `Content-Length` produces it, and the payload is not
  /// missing anything. Truncation and an empty body are hard failures.
  bool get isUsable =>
      this == DownloadSizeCheck.ok ||
      this == DownloadSizeCheck.unknownLength ||
      this == DownloadSizeCheck.overrun;
}

/// Compares [receivedBytes] against [contentLength].
///
/// [contentLength] of `-1` (or any non-positive value) means "the server did
/// not tell us", which is common and must not fail the download.
DownloadSizeCheck checkDownloadSize({
  required int receivedBytes,
  required int contentLength,
}) {
  if (receivedBytes <= 0) return DownloadSizeCheck.empty;
  if (contentLength <= 0) return DownloadSizeCheck.unknownLength;
  if (receivedBytes < contentLength) return DownloadSizeCheck.truncated;
  if (receivedBytes > contentLength) return DownloadSizeCheck.overrun;
  return DownloadSizeCheck.ok;
}

/// A log/error message describing [check].
String downloadSizeMessage(
  DownloadSizeCheck check, {
  required int receivedBytes,
  required int contentLength,
}) {
  switch (check) {
    case DownloadSizeCheck.ok:
      return 'Received all $receivedBytes announced bytes.';
    case DownloadSizeCheck.unknownLength:
      return 'Received $receivedBytes bytes (server announced no length).';
    case DownloadSizeCheck.empty:
      return 'The server returned an empty file.';
    case DownloadSizeCheck.truncated:
      return 'Incomplete download: got $receivedBytes of $contentLength bytes.';
    case DownloadSizeCheck.overrun:
      return 'Received $receivedBytes bytes but the server announced '
          '$contentLength.';
  }
}

/// Whether `Content-Length` describes the same bytes we count while reading the
/// decoded stream.
///
/// `Content-Length` counts the *encoded* body, so a compressed response makes
/// the comparison meaningless (and would produce bogus truncation errors).
bool isContentLengthComparable(Map<String, String> headers) {
  String? encoding;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'content-encoding') {
      encoding = entry.value;
      break;
    }
  }
  if (encoding == null) return true;
  final normalized = encoding.trim().toLowerCase();
  return normalized.isEmpty || normalized == 'identity';
}

/// Streams [source] into [sink] without ever holding the whole payload in
/// memory, reporting progress and honoring [cancelToken].
///
/// Returns the number of bytes written. Throws [CancellationException] as soon
/// as the token is tripped — leaving the loop cancels the underlying HTTP
/// subscription. The caller owns [sink] and is responsible for closing it and
/// for removing the partial file on error.
///
/// [flushEvery] bounds how much data may sit in the sink's buffer: the pump
/// awaits a flush once that many bytes have been queued, which both applies
/// back-pressure to the socket and keeps memory flat for arbitrarily large
/// books.
Future<int> pumpDownloadStream({
  required Stream<List<int>> source,
  required IOSink sink,
  int expectedLength = -1,
  void Function(int percent)? onProgress,
  DownloadCancellationToken? cancelToken,
  int flushEvery = 1 << 20,
}) async {
  cancelToken?.throwIfCancelled();

  var received = 0;
  var lastFlushedAt = 0;

  await for (final chunk in source) {
    cancelToken?.throwIfCancelled();

    sink.add(chunk);
    received += chunk.length;

    if (received - lastFlushedAt >= flushEvery) {
      await sink.flush();
      lastFlushedAt = received;
    }

    if (expectedLength > 0 && onProgress != null) {
      final percent = (received / expectedLength * 100).round().clamp(0, 100);
      onProgress(percent);
    }
  }

  cancelToken?.throwIfCancelled();
  return received;
}

/// Rate limiter for download progress updates.
///
/// A download emits a progress update per network chunk, which floods the log
/// ring buffer and rebuilds the UI hundreds of times per second. This keeps the
/// bar moving smoothly while capping updates at one per [minInterval].
class DownloadProgressThrottle {
  DownloadProgressThrottle({
    this.minInterval = const Duration(milliseconds: 250),
    this.minPercentDelta = 1,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Shortest time allowed between two updates.
  final Duration minInterval;

  /// Smallest percentage change worth reporting.
  final int minPercentDelta;

  final DateTime Function() _clock;

  int? _lastPercent;
  DateTime? _lastEmittedAt;

  /// The last percentage that passed the throttle, or `null` if none has yet.
  int? get lastPercent => _lastPercent;

  /// Whether [percent] should be reported now.
  ///
  /// The first update and the terminal 100% always pass so the bar starts and
  /// finishes exactly where it should.
  bool shouldEmit(int percent, {bool force = false}) {
    final now = _clock();

    if (force || _lastPercent == null) {
      _record(percent, now);
      return true;
    }
    if (percent == _lastPercent) return false;
    if (percent >= 100) {
      _record(percent, now);
      return true;
    }
    if ((percent - _lastPercent!).abs() < minPercentDelta) return false;
    if (now.difference(_lastEmittedAt!) < minInterval) return false;

    _record(percent, now);
    return true;
  }

  /// Forgets the previous update so the next one passes unconditionally.
  void reset() {
    _lastPercent = null;
    _lastEmittedAt = null;
  }

  void _record(int percent, DateTime at) {
    _lastPercent = percent;
    _lastEmittedAt = at;
  }
}

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
    await sweepStalePartFiles();
  }

  /// Deletes `*.part` leftovers from downloads that were interrupted by a
  /// crash, a jetsam kill or a force quit.
  ///
  /// Only staging files are touched — a finished book never carries the
  /// suffix, because it is renamed into place only after validation. Cheap
  /// enough for startup: two directory walks, and failures are non-fatal.
  ///
  /// [olderThan] overrides how stale a partial must be to qualify; tests pass
  /// [Duration.zero] to sweep files they just created.
  ///
  /// Returns the number of files removed.
  Future<int> sweepStalePartFiles({Duration? olderThan}) async {
    final grace = olderThan ?? _partFileGracePeriod;
    final directories = <Directory>[];

    try {
      directories.add(await getApplicationDocumentsDirectory());
    } catch (e) {
      _logger.w('Could not resolve documents directory for .part sweep: $e');
    }

    try {
      final temp = await getTemporaryDirectory();
      directories.add(
        Directory(p.join(temp.path, downloadStagingDirectoryName)),
      );
    } catch (e) {
      _logger.w('Could not resolve staging directory for .part sweep: $e');
    }

    var removed = 0;
    for (final directory in directories) {
      try {
        if (!directory.existsSync()) continue;
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          if (!entity.path.endsWith(downloadPartSuffix)) continue;
          // The Documents directory is user-visible in Files.app (we set
          // UIFileSharingEnabled), so a user's own file that happens to end in
          // .part must not be collateral damage. Only remove partials that are
          // still actively growing-or-abandoned, i.e. older than a launch ago;
          // a fresh one may belong to a download running right now.
          try {
            final stat = entity.statSync();
            if (DateTime.now().difference(stat.modified) < grace) continue;
          } catch (_) {
            // Unstattable: leave it alone rather than guess.
            continue;
          }
          try {
            await entity.delete();
            removed++;
          } catch (e) {
            _logger.w('Could not delete stale partial file ${entity.path}: $e');
          }
        }
      } catch (e) {
        _logger.w('Sweep of ${directory.path} failed: $e');
      }
    }

    if (removed > 0) {
      _logger.i('Removed $removed stale partial download(s).');
    }
    return removed;
  }

  /// True when `path` is a Storage Access Framework document URI rather than a
  /// plain filesystem path.
  ///
  /// Android downloads land in either form: SAF when the user has picked a
  /// download folder, and a plain sandbox path when they have not.
  static bool _isSafUri(String path) => path.startsWith('content://');

  Future<bool> _doesFileExist(String path) async {
    try {
      // Only SAF URIs can be resolved by DocumentFile. Feeding it a plain
      // sandbox path (which is what downloadBookToDevice returns when no SAF
      // folder is configured) yields null, which used to be read as "missing"
      // and silently unregistered a book that was sitting right there.
      if (Platform.isAndroid && _isSafUri(path)) {
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
  /// Whether a file reported as absent is *definitely* gone, as opposed to
  /// merely unresolvable — only the former justifies dropping the registry
  /// entry.
  ///
  /// On Android the answer from [_doesFileExist] is authoritative either way:
  /// DocumentFile resolves a SAF URI, and `File.existsSync` resolves a plain
  /// sandbox path. The one inconclusive case is an iOS/macOS path that could
  /// not be re-anchored to the current app container, since the file may still
  /// be there under a path we failed to reconstruct.
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

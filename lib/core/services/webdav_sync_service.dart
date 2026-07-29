import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;
import 'package:logger/logger.dart';

/// Outcome of an attempt to read the remote reading-progress sync file.
///
/// The distinction between [notFound] and [failed] is critical: the sync file
/// is rewritten wholesale on every save, so treating a transport/auth failure
/// as "empty remote state" would silently destroy every other book's progress
/// stored on the server.
enum WebDavFetchStatus {
  /// The sync file was read and decoded successfully (it may still be empty).
  ok,

  /// The server positively reported that the sync file does not exist yet.
  /// This is the legitimate first-run case and it is safe to write a new file.
  notFound,

  /// The remote state is UNKNOWN: network error, timeout, auth failure,
  /// unexpected status code, or an unparsable/corrupt payload.
  /// It is never safe to overwrite the remote file after this outcome.
  failed,
}

/// Result of [WebDavSyncService.fetchProgressResult].
class WebDavFetchResult {
  final WebDavFetchStatus status;

  /// Decoded remote progress. Only meaningful when [status] is
  /// [WebDavFetchStatus.ok]; empty otherwise.
  final Map<String, dynamic> data;

  /// The underlying error, when [status] is [WebDavFetchStatus.failed].
  final Object? error;

  const WebDavFetchResult({
    required this.status,
    this.data = const {},
    this.error,
  });

  const WebDavFetchResult.ok(Map<String, dynamic> remoteData)
    : status = WebDavFetchStatus.ok,
      data = remoteData,
      error = null;

  const WebDavFetchResult.notFound()
    : status = WebDavFetchStatus.notFound,
      data = const {},
      error = null;

  const WebDavFetchResult.failed(Object cause)
    : status = WebDavFetchStatus.failed,
      data = const {},
      error = cause;

  /// Whether the remote state is known well enough to safely rewrite the file.
  bool get isRemoteStateKnown =>
      status == WebDavFetchStatus.ok || status == WebDavFetchStatus.notFound;
}

/// Thrown by [WebDavSyncService.fetchProgress] when the remote reading-progress
/// file could not be read or decoded (as opposed to simply not existing yet).
class WebDavSyncException implements Exception {
  final String message;
  final Object? cause;

  const WebDavSyncException(this.message, [this.cause]);

  @override
  String toString() =>
      'WebDavSyncException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Extracts an HTTP status code from an error thrown by the webdav/dio stack,
/// or `null` when the error carries no response at all (connection refused,
/// DNS failure, timeout, TLS error, cancellation, ...).
int? webDavStatusCodeOf(Object error) {
  if (error is DioException) return error.response?.statusCode;
  return null;
}

/// Classifies an error thrown while reading the remote sync file.
///
/// Only a status code that positively means "this resource does not exist"
/// (404 Not Found, 410 Gone) maps to [WebDavFetchStatus.notFound]. Everything
/// else — including 401/403 (expired or revoked credentials), 5xx, and every
/// error without a response (timeouts, socket errors, bad certificates) — is
/// [WebDavFetchStatus.failed], because the remote file may well exist and be
/// full of other books' progress.
WebDavFetchStatus classifyWebDavReadError(Object error) {
  final code = webDavStatusCodeOf(error);
  if (code == HttpStatus.notFound || code == HttpStatus.gone) {
    return WebDavFetchStatus.notFound;
  }
  return WebDavFetchStatus.failed;
}

/// Decodes the raw bytes of the sync file.
///
/// An empty body is treated as an empty (but existing) progress map. Anything
/// that is not valid UTF-8 JSON, or that decodes to something other than a JSON
/// object, throws [WebDavSyncException] so the caller aborts rather than
/// overwriting a file it failed to understand.
Map<String, dynamic> parseWebDavProgressPayload(List<int> data) {
  if (data.isEmpty) return <String, dynamic>{};

  final String jsonString;
  try {
    jsonString = utf8.decode(data);
  } catch (e) {
    throw WebDavSyncException('Sync file is not valid UTF-8', e);
  }

  if (jsonString.trim().isEmpty) return <String, dynamic>{};

  final Object? decoded;
  try {
    decoded = jsonDecode(jsonString);
  } catch (e) {
    throw WebDavSyncException('Sync file is not valid JSON', e);
  }

  if (decoded is! Map) {
    throw WebDavSyncException(
      'Sync file is not a JSON object (got ${decoded.runtimeType})',
    );
  }

  return Map<String, dynamic>.from(decoded);
}

/// Pure decision function guarding against progress data loss.
///
/// Returns the full map that should be written back to the server, or `null`
/// when the write must be aborted because the remote state is unknown.
///
/// This is the single place that decides whether a save may proceed: an
/// [WebDavFetchStatus.failed] read must never be merged into a fallback empty
/// map, because writing that map back would erase every other book's progress.
Map<String, dynamic>? buildProgressPayloadToWrite({
  required WebDavFetchResult read,
  required String bookUuid,
  required String locatorJson,
  required int timestamp,
}) {
  if (!read.isRemoteStateKnown) return null;

  final merged = Map<String, dynamic>.from(read.data);
  merged[bookUuid] = {'locator': locatorJson, 'timestamp': timestamp};
  return merged;
}

class WebDavSyncService {
  final Logger logger;
  webdav.Client? _client;

  static const String _syncFileName =
      'calibre_web_companion_reading_progress.json';

  WebDavSyncService({required this.logger});

  void init(
    String url,
    String user,
    String password, {
    bool allowSelfSigned = false,
  }) {
    if (url.isEmpty) return;

    _client = webdav.newClient(
      url,
      user: user,
      password: password,
      debug: false,
    );

    if (allowSelfSigned) {
      _client!.c.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final httpClient = HttpClient();
          httpClient.badCertificateCallback = (cert, host, port) => true;
          return httpClient;
        },
      );
    }

    try {
      _client!.ping();
    } catch (e) {
      logger.e("WebDAV Init Error: $e");
    }
  }

  Future<void> testConnection() async {
    if (_client == null) {
      throw Exception('WebDAV client not initialized');
    }
    await _client!.ping();
  }

  /// Reads the remote sync file and reports precisely what happened.
  ///
  /// Never throws: failures are reported as [WebDavFetchStatus.failed].
  Future<WebDavFetchResult> fetchProgressResult() async {
    final client = _client;
    if (client == null) {
      return const WebDavFetchResult.failed(
        WebDavSyncException('WebDAV client not initialized'),
      );
    }

    List<int> data;
    try {
      data = await client.read(_syncFileName);
    } catch (e) {
      final status = classifyWebDavReadError(e);
      if (status == WebDavFetchStatus.notFound) {
        logger.i("WebDAV sync file does not exist yet, treating as empty");
        return const WebDavFetchResult.notFound();
      }
      logger.e("Failed to read WebDAV sync file: $e");
      return WebDavFetchResult.failed(e);
    }

    try {
      return WebDavFetchResult.ok(parseWebDavProgressPayload(data));
    } catch (e) {
      logger.e("WebDAV sync file is corrupt: $e");
      return WebDavFetchResult.failed(e);
    }
  }

  /// Returns the remote reading progress.
  ///
  /// Returns an empty map only when the sync file genuinely does not exist yet
  /// (or exists and is empty). Throws [WebDavSyncException] on any transport,
  /// authentication, or parse failure so callers cannot mistake an unreadable
  /// server for an empty one.
  Future<Map<String, dynamic>> fetchProgress() async {
    final result = await fetchProgressResult();
    switch (result.status) {
      case WebDavFetchStatus.ok:
        return result.data;
      case WebDavFetchStatus.notFound:
        return <String, dynamic>{};
      case WebDavFetchStatus.failed:
        final error = result.error;
        if (error is WebDavSyncException) throw error;
        throw WebDavSyncException(
          'Could not read WebDAV sync file',
          error,
        );
    }
  }

  Future<void> saveProgress(
    String bookUuid,
    String locatorJson,
    int timestamp,
  ) async {
    if (_client == null) return;

    try {
      final read = await fetchProgressResult();

      final payload = buildProgressPayloadToWrite(
        read: read,
        bookUuid: bookUuid,
        locatorJson: locatorJson,
        timestamp: timestamp,
      );

      if (payload == null) {
        // Aborting on purpose: the remote file may hold progress for many other
        // books and we could not read it. Writing now would destroy it.
        logger.e(
          "Aborting WebDAV progress write for $bookUuid: remote sync file "
          "could not be read (${read.error}). Refusing to overwrite it.",
        );
        return;
      }

      final String jsonString = jsonEncode(payload);
      await _client!.write(_syncFileName, utf8.encode(jsonString));
      logger.i("Progress synced to WebDAV for $bookUuid");
    } catch (e) {
      logger.e("Error saving WebDAV progress: $e");
    }
  }
}

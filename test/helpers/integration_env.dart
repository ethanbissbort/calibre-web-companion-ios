/// Credential resolution for the integration tests.
///
/// The integration tests talk to a real Calibre-Web server, so they need real
/// credentials that must never be committed. Values are resolved per key, in
/// this order (first non-empty wins):
///
///   1. the process environment — `CWC_TEST_BASE_URL=... flutter test`
///   2. a compile-time define — `--dart-define=CWC_TEST_BASE_URL=...`
///   3. the committed defaults in `test/test_env.example.dart`, which are empty
///
/// When nothing is configured, [hasIntegrationCredentials] is false and
/// [skipWithoutCredentials] returns a reason string that every integration test
/// passes to `skip:`. That is what keeps a clean clone green: the suite still
/// compiles, and the integration tests report as skipped rather than failing.
///
/// See `test/test_env.example.dart` for setup instructions.
library;

import 'dart:io';

import '../test_env.example.dart' as defaults;

const _baseUrlKey = 'CWC_TEST_BASE_URL';
const _usernameKey = 'CWC_TEST_USERNAME';
const _passwordKey = 'CWC_TEST_PASSWORD';
const _downloaderUrlKey = 'CWC_TEST_DOWNLOADER_URL';
const _downloaderUsernameKey = 'CWC_TEST_DOWNLOADER_USERNAME';
const _downloaderPasswordKey = 'CWC_TEST_DOWNLOADER_PASSWORD';

/// Returns the first non-empty of: the process environment entry for [key], the
/// compile-time [define] for the same key, and the committed [fallback].
String _resolve(String key, String define, String fallback) {
  final fromProcess = Platform.environment[key];
  if (fromProcess != null && fromProcess.isNotEmpty) return fromProcess;
  if (define.isNotEmpty) return define;
  return fallback;
}

/// The credentials the integration tests run against.
///
/// Every getter is empty unless a server has been configured, so reading one is
/// always safe — guard the *test* with [skipWithoutCredentials] instead.
abstract final class TestEnv {
  static String get baseUrl => _resolve(
    _baseUrlKey,
    const String.fromEnvironment(_baseUrlKey),
    defaults.TestEnv.baseUrl,
  );

  static String get username => _resolve(
    _usernameKey,
    const String.fromEnvironment(_usernameKey),
    defaults.TestEnv.username,
  );

  static String get password => _resolve(
    _passwordKey,
    const String.fromEnvironment(_passwordKey),
    defaults.TestEnv.password,
  );

  static String get downloaderUrl => _resolve(
    _downloaderUrlKey,
    const String.fromEnvironment(_downloaderUrlKey),
    defaults.TestEnv.downloaderUrl,
  );

  static String get downloaderUsername => _resolve(
    _downloaderUsernameKey,
    const String.fromEnvironment(_downloaderUsernameKey),
    defaults.TestEnv.downloaderUsername,
  );

  static String get downloaderPassword => _resolve(
    _downloaderPasswordKey,
    const String.fromEnvironment(_downloaderPasswordKey),
    defaults.TestEnv.downloaderPassword,
  );

  /// Whether the optional book-downloader service is configured.
  static bool get hasDownloader => downloaderUrl.isNotEmpty;
}

/// Whether a Calibre-Web server is configured for the integration tests.
bool get hasIntegrationCredentials =>
    TestEnv.baseUrl.isNotEmpty &&
    TestEnv.username.isNotEmpty &&
    TestEnv.password.isNotEmpty;

/// Pass to `test(..., skip: skipWithoutCredentials)`.
///
/// `null` when a server is configured (the test runs); otherwise the reason the
/// runner prints next to the skipped test.
String? get skipWithoutCredentials =>
    hasIntegrationCredentials
        ? null
        : 'No Calibre-Web test server configured '
            '($_baseUrlKey/$_usernameKey/$_passwordKey) — '
            'see test/test_env.example.dart';

/// Pass to `test(..., skip: skipWithoutDownloader)` for the download_service
/// tests, which need the separate downloader instance rather than Calibre-Web.
String? get skipWithoutDownloader =>
    TestEnv.hasDownloader
        ? null
        : 'No book downloader configured ($_downloaderUrlKey) — '
            'see test/test_env.example.dart';

// Template for the credentials the integration tests need.
//
// Copy this file to `test/test_env.dart` and fill in your own Calibre-Web
// server to run the integration tests:
//
//     cp test/test_env.example.dart test/test_env.dart
//     $EDITOR test/test_env.dart
//
// `test/test_env.dart` is gitignored, so your live credentials can never be
// committed by accident.
//
// IMPORTANT — how the values actually reach the tests
// ---------------------------------------------------
// Nothing imports `test/test_env.dart` any more. A clean clone does not have
// that file, and in Dart an import of a missing file is a *compile* error: it
// takes the whole test suite down before a single `skip:` can be evaluated.
// So this committed example is what gets compiled in (all values empty), and
// your real values are layered on top from the environment. Export them from
// your filled-in `test/test_env.dart` like this:
//
//     export CWC_TEST_BASE_URL='https://calibre.example.com'
//     export CWC_TEST_USERNAME='your-username'
//     export CWC_TEST_PASSWORD='your-password'
//     # Optional: only the download_service tests use these.
//     export CWC_TEST_DOWNLOADER_URL='https://downloader.example.com'
//     export CWC_TEST_DOWNLOADER_USERNAME=''
//     export CWC_TEST_DOWNLOADER_PASSWORD=''
//
//     flutter test --tags integration
//
// `--dart-define` works too, and is handy for one-offs and for CI secrets:
//
//     flutter test --tags integration \
//       --dart-define=CWC_TEST_BASE_URL=https://calibre.example.com \
//       --dart-define=CWC_TEST_USERNAME=... \
//       --dart-define=CWC_TEST_PASSWORD=...
//
// With no credentials configured, every integration test reports as SKIPPED:
// it never fails, and it never blocks the unit suite that CI runs with
// `flutter test --exclude-tags integration`.
// See `test/helpers/integration_env.dart` for the resolution order.

/// Fallback values compiled into the test suite.
///
/// Deliberately empty: an empty [baseUrl], [username] or [password] is the
/// signal that no server is configured, which makes the integration tests skip.
/// Do not put real credentials in this file — it is committed.
abstract final class TestEnv {
  /// Base URL of the Calibre-Web server, without a trailing slash.
  /// e.g. `https://calibre.example.com`
  static const String baseUrl = '';

  /// Calibre-Web username.
  static const String username = '';

  /// Calibre-Web password.
  static const String password = '';

  /// Base URL of the optional calibre-web-automated-book-downloader instance.
  /// Leave empty to skip the download_service integration tests.
  static const String downloaderUrl = '';

  /// Basic-auth username for the downloader, if it requires one.
  static const String downloaderUsername = '';

  /// Basic-auth password for the downloader, if it requires one.
  static const String downloaderPassword = '';
}

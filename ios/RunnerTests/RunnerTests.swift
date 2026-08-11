import XCTest
import integration_test

/// Bridges Flutter's `integration_test` suite into Xcode, so ⌘U (and
/// `xcodebuild test`) runs the on-device Dart tests under `integration_test/`.
///
/// This replaces the empty `testExample()` stub the Flutter template ships,
/// which passed without testing anything.
///
/// Xcode runs whichever Dart entrypoint the last `flutter build` configured, so
/// pick one before pressing ⌘U:
///
///     flutter build ios --config-only integration_test/all_tests.dart
///
/// Running `flutter test integration_test/` from the command line does the same
/// thing without Xcode, and is usually the easier path.
class RunnerTests: XCTestCase {
  func testIntegrationTest() {
    IntegrationTestIosTest().testIntegrationTest(nil)
  }
}

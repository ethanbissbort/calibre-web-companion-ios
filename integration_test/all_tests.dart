import 'package:integration_test/integration_test.dart';

import 'app_smoke_test.dart' as app_smoke;
import 'secure_credential_store_test.dart' as secure_credential_store;
import 'storage_paths_test.dart' as storage_paths;

/// Single entrypoint that runs every on-device suite in one app launch.
///
/// Xcode's test action runs whichever Dart entrypoint the last `flutter build`
/// configured, and it can only run one — so point it here to get the whole
/// suite from ⌘U:
///
///     flutter build ios --config-only integration_test/all_tests.dart
///
/// From the command line, `flutter test integration_test/` runs each file in
/// its own launch and does not need this aggregator.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  secure_credential_store.main();
  storage_paths.main();
  app_smoke.main();
}

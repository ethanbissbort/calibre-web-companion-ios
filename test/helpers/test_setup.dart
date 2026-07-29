import 'package:calibre_web_companion/core/services/api_service.dart';
import 'package:calibre_web_companion/core/services/secure_credential_store.dart';
import 'package:calibre_web_companion/features/book_view/data/datasources/book_view_remote_datasource.dart';
import 'package:calibre_web_companion/features/book_view/data/models/book_view_model.dart';
import 'package:calibre_web_companion/features/login/bloc/login_state.dart';
import 'package:calibre_web_companion/features/login/data/datasources/login_remote_datasource.dart';
import 'package:calibre_web_companion/features/login/data/models/login_credentials.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'integration_env.dart';

// Re-exported so a test only needs `import '../../helpers/test_setup.dart';` to
// get both the setup helpers and the `skip:` guard that goes with them.
export 'integration_env.dart'
    show
        TestEnv,
        hasIntegrationCredentials,
        skipWithoutCredentials,
        skipWithoutDownloader;

Future<ApiService> setupIntegrationTest() async {
  // Every integration test is declared with `skip: skipWithoutCredentials`, so
  // this is unreachable without a configured server. Fail loudly rather than
  // let a newly added, unguarded test report a confusing login failure.
  if (!hasIntegrationCredentials) {
    throw StateError(
      'setupIntegrationTest() called without integration credentials. '
      'Declare the test with `skip: skipWithoutCredentials`. '
      'See test/test_env.example.dart.',
    );
  }

  SharedPreferences.setMockInitialValues({
    'base_url': TestEnv.baseUrl,
    'username': TestEnv.username,
    'password': TestEnv.password,
    'server_type': 'calibreWeb',
  });

  final prefs = await SharedPreferences.getInstance();
  if (!GetIt.instance.isRegistered<SharedPreferences>()) {
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
  }

  // No platform keychain under `flutter test`, so the store degrades to
  // SharedPreferences — which is exactly what these tests seed.
  if (GetIt.instance.isRegistered<SecureCredentialStore>()) {
    GetIt.instance.unregister<SecureCredentialStore>();
  }
  final secureCredentials = SecureCredentialStore(
    logger: Logger(level: Level.off),
  );
  await secureCredentials.init(prefs);
  GetIt.instance.registerSingleton<SecureCredentialStore>(secureCredentials);

  if (GetIt.instance.isRegistered<ApiService>()) {
    GetIt.instance.unregister<ApiService>();
  }
  final apiService = ApiService();
  GetIt.instance.registerSingleton<ApiService>(apiService);
  await apiService.initialize();

  final logger = Logger(level: Level.off);
  final loginDataSource = LoginRemoteDataSource(
    apiService: apiService,
    logger: logger,
    secureCredentials: secureCredentials,
  );

  final success = await loginDataSource.login(
    LoginCredentials(
      baseUrl: TestEnv.baseUrl,
      username: TestEnv.username,
      password: TestEnv.password,
    ),
    ServerType.calibreWeb,
  );

  if (!success) {
    throw Exception('Login failed during integration test setup.');
  }

  return apiService;
}

SharedPreferences testPrefs() => GetIt.instance<SharedPreferences>();

Future<BookViewModel> fetchFirstBook(ApiService api) async {
  final ds = BookViewRemoteDatasource(
    apiService: api,
    logger: Logger(level: Level.off),
    preferences: testPrefs(),
  );
  final books = await ds.fetchBooks(offset: 0, limit: 1);
  if (books.isEmpty) {
    throw Exception('Library is empty!');
  }
  return books.first;
}

SecureCredentialStore testSecureCredentials() =>
    GetIt.instance<SecureCredentialStore>();

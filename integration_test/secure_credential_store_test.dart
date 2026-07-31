import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calibre_web_companion/core/services/secure_credential_store.dart';

/// On-device counterpart to `test/core/secure_credential_store_test.dart`.
///
/// The unit tests use a fake keychain, which proves the *logic* but not that
/// the platform actually stores and returns the values. This suite runs against
/// the real iOS Keychain / Android Keystore, so it catches the failures a fake
/// cannot: entitlement problems, accessibility-class mistakes that make items
/// unreadable, plugin registration gaps, and values that silently fail to
/// persist across a restart.
///
/// The credential migration is one-way and runs on every user's first launch
/// after upgrading. If it is wrong, users are logged out or — worse — left with
/// plaintext credentials they believe are encrypted. That is what this covers.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Unique per run so a failed run can never poison the next one, and so this
  // never collides with the real app's stored credentials on a dev device.
  late String suffix;
  late FlutterSecureStorage storage;

  setUp(() async {
    suffix = '__itest_${DateTime.now().microsecondsSinceEpoch}';
    storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
  });

  tearDown(() async {
    // Leave no test data in the real keychain.
    final all = await storage.readAll();
    for (final key in all.keys) {
      if (key.contains('__itest_')) {
        await storage.delete(key: key);
      }
    }
  });

  group('real platform keychain', () {
    testWidgets('a written secret survives being read back by a new client',
        (tester) async {
      final key = 'password$suffix';

      await storage.write(key: key, value: 'hunter2');
      // A fresh client instance, so this cannot be served from process state.
      const fresh = FlutterSecureStorage(
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );

      expect(await fresh.read(key: key), 'hunter2');
    });

    testWidgets('values with awkward characters round-trip intact',
        (tester) async {
      // Real passwords and cookies contain these; a naive native bridge that
      // mangles encoding would corrupt them silently.
      const nasty = r'p@ss "w/ù—ord"; sess=a.b-c_d/e+f=; 🔐 \backslash';
      final key = 'awkward$suffix';

      await storage.write(key: key, value: nasty);

      expect(await storage.read(key: key), nasty);
    });

    testWidgets('deleting a secret actually removes it', (tester) async {
      final key = 'doomed$suffix';
      await storage.write(key: key, value: 'temporary');

      await storage.delete(key: key);

      expect(await storage.read(key: key), isNull);
    });
  });

  group('migration off plaintext preferences, on device', () {
    testWidgets('moves secrets into the keychain and clears the plaintext copy',
        (tester) async {
      // Seed the pre-upgrade state: credentials sitting in SharedPreferences,
      // which is an unencrypted plist on iOS and unencrypted XML on Android.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'password': 'hunter2',
        'webdav_password': 'webdav-secret',
        'username': 'ethan',
        'base_url': 'https://books.example.com',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = SecureCredentialStore();

      await store.init(prefs);

      // Readable through the store...
      expect(store.read('password'), 'hunter2');
      expect(store.read('webdav_password'), 'webdav-secret');
      // ...gone from plaintext...
      expect(prefs.getString('password'), isNull);
      expect(prefs.getString('webdav_password'), isNull);
      // ...and non-secrets deliberately left alone.
      expect(prefs.getString('username'), 'ethan');
      expect(prefs.getString('base_url'), 'https://books.example.com');

      // Genuinely in the platform store, not just the in-memory cache.
      expect(await storage.read(key: 'password'), 'hunter2');

      await store.deleteAll();
    });

    testWidgets('survives a simulated app restart', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'password': 'persists-across-launch',
      });
      final prefs = await SharedPreferences.getInstance();
      await SecureCredentialStore().init(prefs);

      // A brand-new store, as a cold launch would construct.
      final relaunched = SecureCredentialStore();
      await relaunched.init(await SharedPreferences.getInstance());

      expect(relaunched.read('password'), 'persists-across-launch');
      expect(relaunched.isDegraded, isFalse,
          reason: 'the platform keychain should be available on a real device');

      await relaunched.deleteAll();
    });

    testWidgets('saved account list round-trips through the keychain',
        (tester) async {
      final accounts = <String>[
        jsonEncode({'baseUrl': 'https://a.example', 'username': 'john doe'}),
        jsonEncode({'baseUrl': 'https://b.example', 'username': 'x, y'}),
      ];
      SharedPreferences.setMockInitialValues(<String, Object>{
        'saved_accounts': accounts,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = SecureCredentialStore();

      await store.init(prefs);

      expect(store.readList('saved_accounts'), accounts);
      expect(prefs.getStringList('saved_accounts'), isNull);

      await store.deleteAll();
    });
  });
}

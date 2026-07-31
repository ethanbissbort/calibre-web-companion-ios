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
///
/// These tests deliberately use the REAL preference and keychain keys, because
/// the migration only recognises those names. Running on a developer's own
/// device would therefore clobber their live credentials, so every real value
/// is snapshotted before each test and restored afterwards.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// Whatever the device really had, so it can be put back.
  late Map<String, String?> keychainSnapshot;
  late Map<String, Object?> prefsSnapshot;

  const observedPrefKeys = <String>[
    ...kSecretPreferenceKeys,
    'username',
    'base_url',
  ];

  setUp(() async {
    final prefs = await SharedPreferences.getInstance();

    keychainSnapshot = <String, String?>{};
    prefsSnapshot = <String, Object?>{};

    for (final key in kSecretPreferenceKeys) {
      keychainSnapshot[key] = await storage.read(key: key);
    }
    for (final key in observedPrefKeys) {
      prefsSnapshot[key] = prefs.get(key);
    }

    // Start from a known-clean slate without destroying anything permanently.
    for (final key in kSecretPreferenceKeys) {
      await storage.delete(key: key);
    }
    for (final key in observedPrefKeys) {
      await prefs.remove(key);
    }
  });

  tearDown(() async {
    final prefs = await SharedPreferences.getInstance();

    for (final key in kSecretPreferenceKeys) {
      await storage.delete(key: key);
      final original = keychainSnapshot[key];
      if (original != null) await storage.write(key: key, value: original);
    }
    for (final key in observedPrefKeys) {
      await prefs.remove(key);
      final original = prefsSnapshot[key];
      if (original is String) {
        await prefs.setString(key, original);
      } else if (original is List<String>) {
        await prefs.setStringList(key, original);
      } else if (original is bool) {
        await prefs.setBool(key, original);
      } else if (original is int) {
        await prefs.setInt(key, original);
      } else if (original is double) {
        await prefs.setDouble(key, original);
      }
    }
  });

  group('real platform keychain', () {
    testWidgets('a written secret survives being read back by a new client',
        (tester) async {
      await storage.write(key: 'password', value: 'hunter2');

      // A separate client instance, so this cannot be served from process
      // state held by the first one.
      const fresh = FlutterSecureStorage(
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );

      expect(await fresh.read(key: 'password'), 'hunter2');
    });

    testWidgets('values with awkward characters round-trip intact',
        (tester) async {
      // Real passwords and cookies contain these; a native bridge that mangles
      // encoding would corrupt them silently and lock the user out.
      const nasty = r'p@ss "w/ù—ord"; sess=a.b-c_d/e+f=; 🔐 \backslash';

      await storage.write(key: 'password', value: nasty);

      expect(await storage.read(key: 'password'), nasty);
    });

    testWidgets('deleting a secret actually removes it', (tester) async {
      await storage.write(key: 'downloader_cookie', value: 'temporary');

      await storage.delete(key: 'downloader_cookie');

      expect(await storage.read(key: 'downloader_cookie'), isNull);
    });
  });

  group('migration off plaintext preferences, on device', () {
    testWidgets('moves secrets into the keychain and clears the plaintext copy',
        (tester) async {
      // Seed the pre-upgrade state in the REAL preference store: credentials
      // sitting in an unencrypted plist on iOS / unencrypted XML on Android.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('password', 'hunter2');
      await prefs.setString('webdav_password', 'webdav-secret');
      await prefs.setString('username', 'ethan');
      await prefs.setString('base_url', 'https://books.example.com');

      await SecureCredentialStore().init(prefs);

      // Re-read from the platform rather than trusting the in-process cache.
      await prefs.reload();

      // Secrets are gone from plaintext...
      expect(prefs.getString('password'), isNull);
      expect(prefs.getString('webdav_password'), isNull);
      // ...genuinely in the keychain...
      expect(await storage.read(key: 'password'), 'hunter2');
      expect(await storage.read(key: 'webdav_password'), 'webdav-secret');
      // ...and non-secrets deliberately left where they were.
      expect(prefs.getString('username'), 'ethan');
      expect(prefs.getString('base_url'), 'https://books.example.com');
    });

    testWidgets('a migrated credential survives a simulated cold launch',
        (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('password', 'persists-across-launch');
      await SecureCredentialStore().init(prefs);

      // A brand-new store over a fresh preferences handle, as a cold launch
      // would construct. Nothing here shares state with the first store.
      final relaunched = SecureCredentialStore();
      await relaunched.init(await SharedPreferences.getInstance());

      expect(relaunched.read('password'), 'persists-across-launch');
      expect(
        relaunched.isDegraded,
        isFalse,
        reason: 'the platform keychain should be available on a real device',
      );
    });

    testWidgets('the saved account list round-trips through the keychain',
        (tester) async {
      // Entries are JSON containing spaces, quotes and commas — a naive
      // join/split encoding would corrupt them.
      final accounts = <String>[
        jsonEncode({'baseUrl': 'https://a.example', 'username': 'john doe'}),
        jsonEncode({'baseUrl': 'https://b.example', 'username': 'x, y'}),
      ];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('saved_accounts', accounts);

      final store = SecureCredentialStore();
      await store.init(prefs);
      await prefs.reload();

      expect(store.readList('saved_accounts'), accounts);
      expect(prefs.getStringList('saved_accounts'), isNull);
    });

    testWidgets('migration is idempotent across repeated launches',
        (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('password', 'only-once');

      await SecureCredentialStore().init(prefs);
      final second = SecureCredentialStore();
      await second.init(await SharedPreferences.getInstance());
      final third = SecureCredentialStore();
      await third.init(await SharedPreferences.getInstance());

      expect(third.read('password'), 'only-once');
      expect(await storage.read(key: 'password'), 'only-once');
    });
  });
}

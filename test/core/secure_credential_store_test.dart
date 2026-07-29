import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calibre_web_companion/core/services/secure_credential_store.dart';

/// In-memory stand-in for the platform keychain.
///
/// [failing] simulates a corrupt/unavailable keystore, which is a real failure
/// mode on a minority of Android devices and must not lock the user out.
class _FakeSecureStorage implements FlutterSecureStorage {
  _FakeSecureStorage({this.failing = false});

  final bool failing;
  final Map<String, String> values = <String, String>{};

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failing) throw Exception('keystore unavailable');
    return Map<String, String>.from(values);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failing) throw Exception('keystore unavailable');
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failing) throw Exception('keystore unavailable');
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used in tests');
}

Future<SharedPreferences> _prefsWith(Map<String, Object> initial) async {
  SharedPreferences.setMockInitialValues(initial);
  return SharedPreferences.getInstance();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('migration from plaintext preferences', () {
    test('moves every secret out of preferences and into secure storage',
        () async {
      final prefs = await _prefsWith({
        'password': 'hunter2',
        'webdav_password': 'webdav-secret',
        'downloader_password': 'dl-secret',
        'downloader_cookie': 'session=abc',
        'calibre_web_cookie': 'cookie=xyz',
        'custom_login_headers': '[{"key":"Authorization","value":"Bearer t"}]',
        // Non-secrets that must be left exactly where they are.
        'username': 'ethan',
        'base_url': 'https://books.example.com',
      });
      final storage = _FakeSecureStorage();
      final store = SecureCredentialStore(storage: storage);

      await store.init(prefs);

      // Secrets are readable through the store...
      expect(store.read('password'), 'hunter2');
      expect(store.read('webdav_password'), 'webdav-secret');
      expect(store.read('downloader_cookie'), 'session=abc');
      expect(storage.values['password'], 'hunter2');

      // ...and no longer on disk in plaintext.
      expect(prefs.getString('password'), isNull);
      expect(prefs.getString('webdav_password'), isNull);
      expect(prefs.getString('custom_login_headers'), isNull);

      // Non-secrets are untouched.
      expect(prefs.getString('username'), 'ethan');
      expect(prefs.getString('base_url'), 'https://books.example.com');
    });

    test('migrates the saved_accounts string list without corrupting entries',
        () async {
      // Entries are JSON blobs that contain spaces, quotes and separators —
      // a naive join/split encoding would mangle these.
      final accounts = <String>[
        jsonEncode({'baseUrl': 'https://a.example', 'username': 'john doe'}),
        jsonEncode({'baseUrl': 'https://b.example', 'username': 'x, y'}),
      ];
      final prefs = await _prefsWith({'saved_accounts': accounts});
      final store = SecureCredentialStore(storage: _FakeSecureStorage());

      await store.init(prefs);

      expect(store.readList('saved_accounts'), accounts);
      expect(prefs.getStringList('saved_accounts'), isNull);
    });

    test('is idempotent across restarts and preserves the newer value',
        () async {
      final storage = _FakeSecureStorage();
      final prefs = await _prefsWith({'password': 'old-from-prefs'});

      await SecureCredentialStore(storage: storage).init(prefs);
      expect(storage.values['password'], 'old-from-prefs');

      // Second launch: nothing left to migrate, value survives.
      final second = SecureCredentialStore(storage: storage);
      await second.init(prefs);
      expect(second.read('password'), 'old-from-prefs');

      // A value already in secure storage must win over a stale plaintext one.
      SharedPreferences.setMockInitialValues({'password': 'stale'});
      final revived = await SharedPreferences.getInstance();
      final third = SecureCredentialStore(storage: storage);
      await third.init(revived);
      expect(third.read('password'), 'old-from-prefs');
      expect(revived.getString('password'), isNull);
    });

    test('does nothing when there is nothing to migrate', () async {
      final prefs = await _prefsWith({'username': 'ethan'});
      final storage = _FakeSecureStorage();
      final store = SecureCredentialStore(storage: storage);

      await store.init(prefs);

      expect(storage.values, isEmpty);
      expect(store.read('password'), isNull);
    });
  });

  group('read/write/delete', () {
    test('write persists to secure storage and is readable synchronously',
        () async {
      final prefs = await _prefsWith({});
      final storage = _FakeSecureStorage();
      final store = SecureCredentialStore(storage: storage);
      await store.init(prefs);

      await store.write('password', 'new-secret');

      expect(store.read('password'), 'new-secret');
      expect(storage.values['password'], 'new-secret');
      expect(prefs.getString('password'), isNull);
    });

    test('delete clears both secure storage and any legacy plaintext copy',
        () async {
      final prefs = await _prefsWith({});
      final storage = _FakeSecureStorage();
      final store = SecureCredentialStore(storage: storage);
      await store.init(prefs);
      await store.write('downloader_cookie', 'session=abc');

      await store.delete('downloader_cookie');

      expect(store.read('downloader_cookie'), isNull);
      expect(storage.values.containsKey('downloader_cookie'), isFalse);
    });

    test('deleteAll removes every managed secret', () async {
      final prefs = await _prefsWith({});
      final store = SecureCredentialStore(storage: _FakeSecureStorage());
      await store.init(prefs);
      for (final key in kSecretPreferenceKeys) {
        await store.write(key, 'value-for-$key');
      }

      await store.deleteAll();

      for (final key in kSecretPreferenceKeys) {
        expect(store.read(key), isNull, reason: '$key should be gone');
      }
    });
  });

  group('degraded mode (keystore unavailable)', () {
    test('falls back to preferences instead of losing the credential',
        () async {
      final prefs = await _prefsWith({});
      final store = SecureCredentialStore(storage: _FakeSecureStorage(failing: true));
      await store.init(prefs);

      expect(store.isDegraded, isTrue);

      await store.write('password', 'hunter2');

      // Durable, so the user is not silently logged out on next launch.
      expect(prefs.getString('password'), 'hunter2');
      expect(store.read('password'), 'hunter2');
    });

    test('leaves plaintext credentials intact rather than destroying them',
        () async {
      final prefs = await _prefsWith({'password': 'hunter2'});
      final store = SecureCredentialStore(storage: _FakeSecureStorage(failing: true));

      await store.init(prefs);

      // Migration must not delete what it could not secure.
      expect(prefs.getString('password'), 'hunter2');
      expect(store.read('password'), 'hunter2');
    });

    test('round-trips a list in degraded mode', () async {
      final prefs = await _prefsWith({});
      final store = SecureCredentialStore(storage: _FakeSecureStorage(failing: true));
      await store.init(prefs);

      await store.writeList('saved_accounts', <String>['a', 'b']);

      expect(store.readList('saved_accounts'), <String>['a', 'b']);
    });
  });
}

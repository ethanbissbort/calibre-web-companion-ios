import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keys that hold secrets and therefore belong in the platform keychain /
/// keystore rather than in `SharedPreferences`, which is a plaintext plist on
/// iOS and a plaintext XML file on Android.
///
/// Anything listed here is migrated out of `SharedPreferences` exactly once,
/// on the first launch after upgrading.
const List<String> kSecretPreferenceKeys = <String>[
  'password',
  'saved_accounts',
  'calibre_web_cookie',
  'calibre_web_session',
  'webdav_password',
  'downloader_password',
  'downloader_cookie',
  'custom_login_headers',
];

/// Keys whose legacy `SharedPreferences` representation is a `StringList`.
const Set<String> _kListValuedKeys = <String>{'saved_accounts'};

/// Stores credentials in the platform keychain (iOS) / keystore-backed
/// encrypted preferences (Android).
///
/// The app reads credentials from dozens of synchronous call sites that used to
/// do `prefs.getString('password')`. `flutter_secure_storage` is async-only, so
/// this store keeps a decrypted in-memory copy populated during [init] and
/// serves synchronous [read]s from it. That is not a weakening: the process
/// already holds these values in memory whenever it uses them. What changes is
/// what survives on disk, in device backups, and in forensic extraction.
///
/// Every write reaches durable storage before the cache is updated, so the
/// cache can never claim a value was persisted when it wasn't.
class SecureCredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage, Logger? logger})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Android encrypts by default in v10+ (the old
            // `encryptedSharedPreferences` flag is deprecated and ignored).
            // On iOS, `first_unlock_this_device` keeps the keychain item out
            // of iCloud/iTunes backups — the exact exposure being closed here
            // — while still allowing background access after the first unlock.
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          ),
      _logger = logger ?? Logger();

  final FlutterSecureStorage _storage;
  final Logger _logger;

  final Map<String, String> _cache = <String, String>{};
  SharedPreferences? _preferences;

  /// True when the platform keychain could not be used, and secrets are being
  /// served from `SharedPreferences` as before.
  ///
  /// Keystore corruption is a real failure mode on a minority of Android
  /// devices. Locking those users out of their own library would be a worse
  /// outcome than the storage weakness being fixed here, so the store degrades
  /// to the previous behavior rather than throwing.
  bool get isDegraded => _degraded;
  bool _degraded = false;

  /// Loads secrets into memory and migrates any still held in
  /// [SharedPreferences]. Safe to call more than once.
  Future<void> init(SharedPreferences preferences) async {
    _preferences = preferences;

    try {
      final stored = await _storage.readAll();
      _cache
        ..clear()
        ..addAll(stored);
    } catch (e) {
      _degraded = true;
      _logger.e(
        'Secure storage unavailable, keeping credentials in shared '
        'preferences: $e',
      );
    }

    await _migrateFromPreferences(preferences);
  }

  /// Moves any secret still held in [SharedPreferences] into secure storage and
  /// removes the plaintext copy.
  Future<void> _migrateFromPreferences(SharedPreferences preferences) async {
    if (_degraded) return;

    var migrated = 0;

    for (final key in kSecretPreferenceKeys) {
      final Object? legacy = preferences.get(key);
      if (legacy == null) continue;

      final String? value = switch (legacy) {
        String s => s,
        List<dynamic> l => jsonEncode(l.map((e) => '$e').toList()),
        _ => null,
      };

      if (value == null) {
        _logger.w(
          'Skipping migration of $key: unexpected type ${legacy.runtimeType}',
        );
        continue;
      }

      // A value already in secure storage wins — it is the newer one.
      if (!_cache.containsKey(key)) {
        if (!await _persist(key, value)) {
          // Could not secure it. Leave the plaintext copy in place rather than
          // destroy the user's credentials.
          continue;
        }
      }

      await preferences.remove(key);
      migrated++;
    }

    if (migrated > 0) {
      _logger.i('Migrated $migrated credential(s) to secure storage');
    }
  }

  /// Synchronous read, served from the cache populated by [init].
  String? read(String key) {
    if (_degraded) return _preferences?.getString(key);
    return _cache[key];
  }

  /// Reads a value previously stored with [writeList].
  List<String> readList(String key) {
    if (_degraded) return _preferences?.getStringList(key) ?? <String>[];

    final raw = _cache[key];
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => '$e').toList();
    } catch (e) {
      _logger.w('Could not decode stored list for $key: $e');
    }
    return <String>[];
  }

  Future<void> write(String key, String value) => _persist(key, value);

  Future<void> writeList(String key, List<String> values) =>
      _persist(key, jsonEncode(values), asList: values);

  Future<void> delete(String key) async {
    _cache.remove(key);
    // Always clear the legacy location too: a degraded-mode write may have
    // landed there, and a stale plaintext copy is exactly what this exists
    // to prevent.
    await _preferences?.remove(key);
    if (_degraded) return;
    try {
      await _storage.delete(key: key);
    } catch (e) {
      _logger.e('Failed to delete $key from secure storage: $e');
    }
  }

  /// Removes every secret this store manages. Used when wiping a session.
  Future<void> deleteAll() async {
    for (final key in kSecretPreferenceKeys) {
      await delete(key);
    }
  }

  /// Writes through to durable storage, updating the cache only on success.
  ///
  /// Returns false when the value could not be secured, in which case it is
  /// written to `SharedPreferences` so the user is not silently logged out on
  /// the next launch.
  Future<bool> _persist(
    String key,
    String value, {
    List<String>? asList,
  }) async {
    if (!_degraded) {
      try {
        await _storage.write(key: key, value: value);
        _cache[key] = value;
        return true;
      } catch (e) {
        _logger.e('Failed to write $key to secure storage: $e');
        _degraded = true;
      }
    }

    final prefs = _preferences;
    if (prefs == null) return false;
    if (asList != null || _kListValuedKeys.contains(key)) {
      await prefs.setStringList(key, asList ?? <String>[]);
    } else {
      await prefs.setString(key, value);
    }
    return false;
  }
}

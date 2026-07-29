import 'package:shared_preferences/shared_preferences.dart';

import 'package:calibre_web_companion/core/services/api_service.dart';
import 'package:calibre_web_companion/core/services/secure_credential_store.dart';
import 'package:calibre_web_companion/features/me/data/models/stats_model.dart';

class MeRemoteDataSource {
  final ApiService apiService;
  final SharedPreferences preferences;

  /// Secrets live in the platform keychain/keystore, not in [preferences].
  final SecureCredentialStore secureCredentials;

  MeRemoteDataSource({
    required this.apiService,
    required this.preferences,
    required this.secureCredentials,
  });

  Future<StatsModel> getStats() async {
    try {
      final serverType = preferences.getString('server_type');

      if (serverType == 'opds' ||
          serverType == 'grimmory' ||
          serverType == 'booklore') {
        return _getOpdsStats();
      }

      if (serverType == 'calibre') {
        return const StatsModel();
      }

      final jsonData = await apiService.getJson(
        endpoint: '/opds/stats',
        authMethod: AuthMethod.auto,
      );
      return StatsModel.fromJson(jsonData);
    } catch (e) {
      throw Exception('Failed to load stats: $e');
    }
  }

  Future<StatsModel> _getOpdsStats() async {
    final json = await apiService.getXmlAsJson(
      endpoint: '/catalog',
      authMethod: AuthMethod.basic,
      queryParams: {'page': '1', 'size': '1'},
    );

    int totalBooks = 0;

    if (json.containsKey('feed')) {
      final feed = json['feed'];
      if (feed is Map) {
        if (feed.containsKey('opensearch:totalResults')) {
          totalBooks =
              int.tryParse(feed['opensearch:totalResults'].toString()) ?? 0;
        } else if (feed.containsKey('totalResults')) {
          totalBooks = int.tryParse(feed['totalResults'].toString()) ?? 0;
        }
      }
    }

    return StatsModel(books: totalBooks);
  }

  Future<void> logOut() async {
    try {
      final serverType = preferences.getString('server_type');

      final hasServerLogout = serverType == null || serverType == 'calibreWeb';

      if (hasServerLogout) {
        try {
          await apiService.get(
            endpoint: '/logout',
            authMethod: AuthMethod.cookie,
          );
        } catch (e) {
          // ignore: avoid_print
          print('Server logout failed (continuing local logout): $e');
        }
      }

      for (final key in const [
        'base_url',
        'username',
        'server_type',
        'calibre_library_id',
        'calibre_library_map',
      ]) {
        await preferences.remove(key);
      }

      for (final key in const [
        'password',
        'calibre_web_session',
        'calibre_web_cookie',
        // Credentials for the auxiliary services are scoped to the server the
        // user just signed out of, so they must not outlive the session.
        // Previously they survived logout, leaving passwords on disk for
        // anyone who later got hold of the device.
        'webdav_password',
        'downloader_password',
        'downloader_cookie',
      ]) {
        await secureCredentials.delete(key);
      }

      // Deliberately preserved: `saved_accounts` (the account switcher's
      // history, which the user clears per-entry via removeAccount) and
      // `custom_login_headers` (reverse-proxy/SSO headers needed to reach the
      // server again at the next login). Both hold secrets and are kept in
      // encrypted storage rather than deleted.

      await apiService.reset();
    } catch (e) {
      throw Exception('Failed to logout: $e');
    }
  }

  bool getShowStats() => preferences.getString('server_type') != 'calibre';

  bool getIsOpds() {
    return preferences.getString('server_type') == 'opds' ||
        preferences.getString('server_type') == 'grimmory' ||
        preferences.getString('server_type') == 'booklore' ||
        preferences.getString('server_type') == 'calibre';
  }
}

import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoRouteTransitionMixin;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calibre_web_companion/main.dart' as app;

import 'package:calibre_web_companion/core/services/api_service.dart';
import 'package:calibre_web_companion/core/services/app_log_service.dart';
import 'package:calibre_web_companion/core/services/connectivity_service.dart';
import 'package:calibre_web_companion/core/services/download_manager.dart';
import 'package:calibre_web_companion/core/services/secure_credential_store.dart';
import 'package:calibre_web_companion/features/login/presentation/pages/login_page.dart';
import 'package:calibre_web_companion/features/login/presentation/widgets/login_form_widget.dart';
import 'package:calibre_web_companion/features/login_settings/presentation/pages/login_settings_page.dart';
import 'package:calibre_web_companion/features/settings/bloc/settings_bloc.dart';
import 'package:calibre_web_companion/features/settings/bloc/settings_event.dart';
import 'package:calibre_web_companion/features/settings/presentation/pages/settings_page.dart';
import 'package:calibre_web_companion/l10n/app_localizations.dart';
import 'package:calibre_web_companion/l10n/app_localizations_de.dart';

/// Cold-start smoke suite: proves the app actually boots on a device and that
/// its core, credential-free UI works.
///
/// Nothing here talks to a server. The suite deliberately runs in the
/// logged-out state, which is also the only state reachable without secrets:
/// with an empty `SharedPreferences` the launch-time session check short
/// circuits (no `base_url`, no cookie) and never issues a request, so the app
/// lands on the login screen.
///
/// The reason this exists: `main()` does all of its startup work inside
/// `runZonedGuarded`, and `SecureCredentialStore.init()` is now the very first
/// thing `di.init()` awaits. If that throws or hangs on a real device — a
/// keychain entitlement problem, a plugin that never registers — the zone
/// handler swallows it, `runApp` is never reached, and the user sees a blank
/// screen with no crash report. No unit test can see that, because a fake
/// keychain always answers. Everything below therefore asserts on concretely
/// rendered UI rather than on "no exception was thrown".
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // A known, account-free starting state. `setMockInitialValues` swaps in an
    // in-memory store, so the real device's preferences are never read or
    // written by this suite, and nothing survives into the next test.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // `di.init()` registers unconditionally and would throw on the second
    // launch in the same process.
    await GetIt.instance.reset();
  });

  tearDown(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('cold start', () {
    testWidgets('reaches the login screen with no account configured', (
      tester,
    ) async {
      await _bootApp(tester);

      // Concrete, translation-independent evidence that the first frame is a
      // real screen and not the boot spinner: the login form and its icons.
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(LoginForm), findsOneWidget);
      expect(find.byIcon(Icons.login_rounded), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);

      // The `FutureBuilder` in `MyApp` shows a `CircularProgressIndicator`
      // while the session check runs. Its absence proves the check completed
      // rather than hanging on a request that will never come back.
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'the launch-time session check should have resolved by now',
      );

      // The app bar title is the one localized string on this screen we can
      // check without hard-coding English: compare against whatever the
      // resolved locale produced.
      final localizations = _localizationsOf(tester, find.byType(LoginPage));
      expect(find.text(localizations.login), findsWidgets);
    });
  });

  group('dependency injection', () {
    testWidgets('the service locator resolves every critical singleton', (
      tester,
    ) async {
      await _bootApp(tester);

      final getIt = GetIt.instance;

      // A missing registration currently surfaces only as a crash deep inside
      // whichever feature happens to need it first, often long after launch.
      expect(getIt.isRegistered<SharedPreferences>(), isTrue);
      expect(getIt.isRegistered<SecureCredentialStore>(), isTrue);
      expect(getIt.isRegistered<Logger>(), isTrue);
      expect(getIt.isRegistered<AppLogService>(), isTrue);
      expect(getIt.isRegistered<http.Client>(), isTrue);
      expect(getIt.isRegistered<ApiService>(), isTrue);
      expect(getIt.isRegistered<DownloadManager>(), isTrue);
      expect(getIt.isRegistered<ConnectivityService>(), isTrue);

      // Resolving is the part that actually runs the lazy factories; a
      // registration whose factory throws only fails here.
      expect(getIt<SharedPreferences>(), isNotNull);
      expect(getIt<SecureCredentialStore>(), isNotNull);
      expect(getIt<Logger>(), isNotNull);
      expect(getIt<ApiService>(), isNotNull);
      expect(getIt<DownloadManager>(), isNotNull);

      // Singletons, not factories: every collaborator must share the one
      // credential store, otherwise the in-memory cache backing the
      // synchronous reads is populated in one copy and empty in another.
      expect(
        identical(
          getIt<SecureCredentialStore>(),
          getIt<SecureCredentialStore>(),
        ),
        isTrue,
      );
      expect(identical(getIt<ApiService>(), getIt<ApiService>()), isTrue);

      // `init()` completed against the real platform keychain. Degraded means
      // it fell back to an in-memory store, which on a device would silently
      // log the user out on every launch.
      expect(
        getIt<SecureCredentialStore>().isDegraded,
        isFalse,
        reason:
            'the platform keychain should be available, so startup must not '
            'have fallen back to the degraded in-memory path',
      );
    });
  });

  group('localization', () {
    testWidgets('follows the system language and renders a known key', (
      tester,
    ) async {
      await _bootApp(tester);

      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      // The default is now "follow the system language", which `MyApp`
      // expresses as a null `locale` so Flutter resolves the device locale.
      expect(
        materialApp.locale,
        isNull,
        reason: 'a fresh install must not pin an explicit locale',
      );

      final context = tester.element(find.byType(LoginPage));
      final resolved = Localizations.localeOf(context);
      expect(
        AppLocalizations.supportedLocales.map((l) => l.languageCode),
        contains(resolved.languageCode),
        reason: 'localeResolutionCallback must land on a supported locale',
      );

      // `AppLocalizations.of` returning non-null proves the delegate ran; a
      // non-empty value proves the generated table for this locale is wired up.
      final localizations = AppLocalizations.of(context);
      expect(localizations, isNotNull);
      expect(localizations!.login, isNotEmpty);
      expect(localizations.connectionSettings, isNotEmpty);
    });

    testWidgets('picking an explicit language re-renders the UI in it', (
      tester,
    ) async {
      await _bootApp(tester);

      // The full settings screen lives behind the home page, which needs an
      // account, so push it directly onto the app's own navigator. That keeps
      // the real bloc providers (they sit above `MaterialApp`) as ancestors,
      // which is what the picker writes through.
      final navigator = app.navigatorKey.currentState;
      expect(navigator, isNotNull, reason: 'the app navigator must be mounted');
      _pushPage(navigator!, const SettingsPage());
      await _pumpUntil(
        tester,
        find.byIcon(Icons.palette_rounded),
        reason: 'the settings screen never finished loading',
      );

      await tester.tap(find.byIcon(Icons.palette_rounded));
      final languagePicker = find.byType(DropdownButtonFormField<String>);
      await _pumpUntil(
        tester,
        languagePicker,
        reason: 'the appearance sub-page never showed the language picker',
      );

      // The picker sits below the fold on small screens. The sub-page uses a
      // (non-lazy) SingleChildScrollView, so the widget already exists and only
      // needs scrolling into view before it can be tapped reliably.
      await tester.ensureVisible(languagePicker);
      await _pumpFor(tester, const Duration(milliseconds: 500));

      await tester.tap(languagePicker);
      // 'Deutsch' is a hard-coded label in the picker, not a translated string,
      // so it stays findable no matter which language the UI is currently in.
      // `.last` picks the entry in the opened menu overlay rather than the copy
      // the closed button keeps in its sizing stack.
      await _pumpUntil(tester, find.text('Deutsch'));
      await tester.tap(find.text('Deutsch').last);
      await _pumpFor(tester, const Duration(seconds: 2));

      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(
        materialApp.locale,
        const Locale('de'),
        reason: 'an explicit choice must pin the locale',
      );

      // ...and the choice must actually reach the rendered tree. The section
      // headings inside the sub-page rebuild from the new localizations.
      final german = AppLocalizationsDe();
      expect(find.text(german.language), findsWidgets);
    });
  });

  group('theme', () {
    testWidgets('renders the custom seed-colour fallback instead of crashing', (
      tester,
    ) async {
      await _bootApp(tester);

      final settings = _settingsBlocOf(tester);
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));

      expect(materialApp.theme, isNotNull);
      expect(materialApp.darkTheme, isNotNull);
      expect(materialApp.theme!.colorScheme.brightness, Brightness.light);
      expect(materialApp.darkTheme!.colorScheme.brightness, Brightness.dark);

      if (Platform.isIOS) {
        // Material You dynamic colour is deliberately unavailable on iOS:
        // `MyApp` forces `ThemeSource.custom`, so both schemes must come from
        // the user's seed colour. If `DynamicColorBuilder` ever started
        // returning a scheme here, these would diverge.
        final expectedLight = ColorScheme.fromSeed(
          seedColor: settings.state.selectedColor,
          brightness: Brightness.light,
        );
        final expectedDark = ColorScheme.fromSeed(
          seedColor: settings.state.selectedColor,
          brightness: Brightness.dark,
        );
        expect(materialApp.theme!.colorScheme.primary, expectedLight.primary);
        expect(
          materialApp.darkTheme!.colorScheme.primary,
          expectedDark.primary,
        );
      }
    });

    testWidgets('survives switching theme mode and seed colour', (
      tester,
    ) async {
      await _bootApp(tester);

      final settings = _settingsBlocOf(tester);

      settings.add(const SetThemeMode(ThemeMode.dark));
      await _pumpFor(tester, const Duration(seconds: 1));
      expect(
        Theme.of(tester.element(find.byType(LoginPage))).brightness,
        Brightness.dark,
      );
      expect(find.byType(LoginForm), findsOneWidget);

      settings.add(const SetThemeMode(ThemeMode.light));
      await _pumpFor(tester, const Duration(seconds: 1));
      expect(
        Theme.of(tester.element(find.byType(LoginPage))).brightness,
        Brightness.light,
      );

      // The custom seed path: a different seed must produce a different scheme
      // and still render. 'teal' is a key from `PredefinedColors`.
      settings.add(const SetSelectedColor('teal'));
      await _pumpFor(tester, const Duration(seconds: 1));
      final themed = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(
        themed.theme!.colorScheme.primary,
        ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.light,
        ).primary,
      );
      expect(find.byType(LoginForm), findsOneWidget);
    });
  });

  group('navigation', () {
    testWidgets('pushes and pops the connection-settings route', (
      tester,
    ) async {
      await _bootApp(tester);

      // The gear on the login card is the one route reachable while logged
      // out, and it goes through `AppTransitions.createSlideRoute` — the code
      // that changed to `CupertinoPageRoute` on iOS.
      await tester.tap(find.byIcon(Icons.settings));
      await _pumpUntil(
        tester,
        find.byType(LoginSettingsPage),
        reason: 'tapping the login settings gear did not push a route',
      );

      final route = ModalRoute.of(
        tester.element(find.byType(LoginSettingsPage)),
      );
      expect(route, isA<PageRoute<dynamic>>());
      if (Platform.isIOS) {
        // Without the Cupertino mixin the system back-swipe silently stops
        // working on every screen pushed this way.
        expect(route, isA<CupertinoRouteTransitionMixin<dynamic>>());
      }

      await tester.pageBack();
      await _pumpUntil(
        tester,
        find.byType(LoginPage),
        reason: 'popping the connection-settings route did not restore login',
      );
      expect(find.byType(LoginSettingsPage), findsNothing);
    });
  });
}

/// Launches the real `main()` and waits for the login screen to be on stage.
///
/// `main()` is fire-and-forget — its startup work happens inside
/// `runZonedGuarded`, so there is no future to await and any failure is
/// swallowed by the zone handler. The only observable signal that startup
/// succeeded is a rendered screen, so that is what we wait for.
Future<void> _bootApp(WidgetTester tester) async {
  app.main();
  await _pumpUntil(
    tester,
    find.byType(LoginPage),
    timeout: const Duration(seconds: 90),
    reason:
        'the app never reached the login screen. Startup happens inside '
        'runZonedGuarded, so a throw in di.init() — most likely '
        'SecureCredentialStore.init() — never reaches runApp and leaves a '
        'blank screen instead of a crash',
  );
}

/// Pumps in bounded real-time steps until [finder] matches, then returns.
///
/// Deliberately not `pumpAndSettle`: the app can hold a permanently animating
/// widget (a shimmer skeleton, a retrying spinner) which makes "settled" a
/// state the tree may never reach, and `pumpAndSettle` would then burn its own
/// timeout and report an unrelated failure. A deadline loop is immune to that
/// and produces a message that names the real problem.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    // `Finder.evaluate` dereferences the root element, which does not exist
    // until `runApp` has attached the first tree.
    if (WidgetsBinding.instance.rootElement == null) continue;
    if (finder.evaluate().isNotEmpty) return;
  }
  fail(reason ?? 'Timed out after $timeout waiting for: $finder');
}

/// Pumps frames for a fixed wall-clock budget without ever failing.
///
/// Used where we only need to give blocs and route transitions a moment to
/// land; see [_pumpUntil] for why `pumpAndSettle` is avoided.
Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The app's own [SettingsBloc], read from above the `MaterialApp` where
/// `main()` provides it — not a fresh one from the locator, which would carry
/// none of the loaded state.
SettingsBloc _settingsBlocOf(WidgetTester tester) =>
    tester.element(find.byType(MaterialApp)).read<SettingsBloc>();

AppLocalizations _localizationsOf(WidgetTester tester, Finder finder) =>
    AppLocalizations.of(tester.element(finder))!;

/// Pushes [page] on the app navigator without awaiting the route's pop future,
/// which only completes once the route is dismissed.
void _pushPage(NavigatorState navigator, Widget page) {
  navigator.push<void>(MaterialPageRoute<void>(builder: (_) => page));
}

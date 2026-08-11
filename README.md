> [!CAUTION]
> ‼️ Android will become a locked-down platform. Learn more: https://keepandroidopen.org/

<p align="center">
    <img src="docs/icon/icon.png" alt="App Icon" width="100" />
    <br>
    v2.1.0
</p>

<p align="center">
    <a href="https://github.com/doen1el/calibre-web-companion/releases">
        <img src="https://img.shields.io/github/downloads/doen1el/calibre-web-companion/total?color=green&label=Downloads%20(GitHub)" alt="GitHub all releases">
    </a>
    <a href="https://f-droid.org/en/packages/de.doen1el.calibreWebCompanion/" >
        <img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgithub.com%2Fkitswas%2Ffdroid-metrics-dashboard%2Fraw%2Frefs%2Fheads%2Fmain%2Fprocessed%2Ftotal%2Fde.doen1el.calibreWebCompanion.json&query=%24.total_downloads&logo=fdroid&label=Downloads%20(F-Droid)">
    </a>
    <a href="https://github.com/doen1el/calibre-web-companion/releases">
        <img src="https://img.shields.io/github/v/release/doen1el/calibre-web-companion?color=green&label=download&sort=semver" alt="GitHub release (latest SemVer)">
    </a>
    <a href="https://github.com/doen1el/calibre-web-companion/actions?query=workflow%3ABuild+branch%3Adev">
        <img src="https://img.shields.io/github/actions/workflow/status/doen1el/calibre-web-companion/main.yml?branch=dev" alt="GitHub Workflow Status">
    </a>
    <a href="https://hosted.weblate.org/engage/calibre-web-companion/">
        <img src="https://hosted.weblate.org/widget/calibre-web-companion/svg-badge.svg" alt="Translation status" />
    </a>
    
    
</p>

# Calibre Web Companion

This is an unofficial companion application for [Calibre Web](https://github.com/janeczku/calibre-web) (which also works for [Calibre Web Automated](https://github.com/crocodilestick/Calibre-Web-Automated), [Grimmory](https://github.com/grimmory-tools/grimmory), [Calibre 'Sharing over the net'](https://github.com/kovidgoyal/calibre) and other OPDS providers (beta)), that allows you to browse your book collection and download books directly to your device. You can also interact with your books by marking them as read, unread or bookmarked. It is also possible to send books directly to your e-reader (Kindle/Kobo) thanks to the great work of [send2ereader](https://github.com/daniel-j/send2ereader).

The app is built with [Flutter](https://github.com/flutter/flutter) and uses **Material You**. It is available for **Android**, and for **iOS** as a sideloadable build (see [iOS](#-ios-sideloading)).

## 📦 Installation

### 🤖 Android

<p align="left">
    <a href="https://f-droid.org/en/packages/de.doen1el.calibreWebCompanion/">
        <img src="https://f-droid.org/badge/get-it-on.png" alt="Get it on F-Droid" height="80">
    </a>
    <a href="https://play.google.com/store/apps/details?id=de.doen1el.calibreWebCompanion">
        <img src="docs/badges/badge_play.png" alt="Get it on Google Play" height="80">
    </a>
    <a href="https://github.com/doen1el/calibre-web-companion/releases">
        <img src="docs/badges/badge_github.png" alt="Get it on GitHub" height="80">
    </a>
    <a href="https://github.com/doen1el/calibre-web-companion/wiki/Installing-Calibre%E2%80%90Web%E2%80%90Companion-from-GitHub-using-Obtainium">
        <img src="docs/badges/badge_obtainium.png" alt="Get it on Obtainium" height="80">
    </a>
</p>

### 🍎 iOS (Sideloading)

The iOS version is **not available on the App Store**. Calibre Web Companion is an open-source companion app for self-hosted servers and is distributed for iOS as an **unsigned `.ipa`** on the [releases page](https://github.com/ethanbissbort/calibre-web-companion-ios/releases). It requires **iOS 18.0 or later**. Since the IPA is unsigned, it has to be signed on or for your own device by sideloading it, for example with:

- [AltStore](https://altstore.io/): installs and re-signs the IPA with your own (free) Apple ID. Free Apple IDs are limited to 3 sideloaded apps and a 7-day signing period, but AltStore can refresh them automatically.
- [Sideloadly](https://sideloadly.io/): signs and installs the IPA from your Mac or PC.
- [TrollStore](https://github.com/opa334/TrollStore): permanent installation without re-signing (only on supported iOS versions).

Download `calibre_web_companion_unsigned.ipa` from the [releases page](https://github.com/ethanbissbort/calibre-web-companion-ios/releases) and install it with the tool of your choice.

#### Building from source (macOS)

Requirements:

- A Mac with [Xcode 26](https://developer.apple.com/xcode/) (iOS 26 SDK) or later
- [Flutter](https://docs.flutter.dev/get-started/install/macos) (stable channel) and [CocoaPods](https://cocoapods.org/) (`sudo gem install cocoapods` or `brew install cocoapods`)
- The app targets the latest iOS SDK with a minimum deployment target of **iOS 18.0**

To build the unsigned sideloadable IPA from the command line:

```sh
git clone https://github.com/ethanbissbort/calibre-web-companion-ios.git
cd calibre-web-companion-ios
flutter pub get
flutter gen-l10n
./ios/create_unsigned_ipa.sh
```

The script runs `flutter build ios --release --no-codesign` and packages the result into `build/ios/iphoneos/calibre_web_companion_unsigned.ipa`.

#### Building & running with Xcode

To build straight onto a device (or the simulator) from Xcode:

```sh
flutter pub get
flutter gen-l10n
cd ios && pod install && cd ..
open ios/Runner.xcworkspace
```

Then in Xcode:

1. Select the **Runner** target → **Signing & Capabilities** and choose your own team under **Team** (a free Apple ID works for on-device development; no team is checked in).
2. Pick your device or an iOS simulator as the run destination.
3. Build & run (**⌘R**). Xcode signs the app automatically for your device.

Alternatively, `flutter run` from the repo root does all of the above (including `pod install`) once the team is set in Xcode.

#### Running the tests

There are two suites, and they run in different places:

```sh
# Unit/widget tests — run on the Dart VM, no device needed. CI gates on these.
flutter test --exclude-tags integration

# On-device tests — need a booted simulator or a connected device.
flutter test integration_test/
```

The on-device suite exercises what a fake cannot: the real Keychain/Keystore, the
app sandbox paths (including the container-UUID change that invalidates stored
paths after every iOS app update), and cold-start/DI integrity. It needs no
server and no credentials.

To run it from Xcode with **⌘U**, select the aggregate entrypoint first — Xcode
runs whichever Dart entrypoint the last build configured:

```sh
flutter build ios --config-only integration_test/all_tests.dart
open ios/Runner.xcworkspace   # then ⌘U
```

The integration tests that talk to a live Calibre-Web server live under `test/`
and are tagged `integration`; they skip themselves unless credentials are
provided. Copy `test/test_env.example.dart` to `test/test_env.dart` (gitignored)
or set the `CWC_TEST_*` environment variables to enable them.

#### iOS notes

- Downloaded and offline-synced books are stored in the app's own folder, which you can browse in the **Files** app under **On My iPhone/iPad → Calibre Web Companion**.
- Plain **HTTP** servers (e.g. a local IP without TLS) are supported: the app ships with an App Transport Security exception, so your Calibre-Web instance does not have to be reachable via HTTPS.

## 💪 Features

- Connect to your Calibre-Web (Automated), Grimmory, Calibre and OPDS servers, including reverse proxy/SSO setups, custom HTTP headers and self-signed certificates.
- Browse your whole library with smooth, fast navigation.
- Discover books by category, authors, series, publishers, ratings, hot & trending, and more.
- View rich details for every book, edit its metadata, and upload new covers.
- Mark books as read or unread, archive them, and organize them into shelves.
- Create, edit and browse Magic Shelves, dynamic, rule‑based shelves (Calibre‑Web Automated only).
- Add books quickly by scanning their ISBN barcode.
- Read books in the built‑in eBook reader and sync your reading progress across devices via WebDAV.
- Send books to your e‑reader via [send2ereader](https://github.com/daniel-j/send2ereader) (or your own instance) or Calibre‑Web's email function.
- Download books straight into your collection with [shelfmark](https://github.com/calibrain/shelfmark).
  - ⚠️ This app does **not** support, encourage or facilitate the piracy of copyrighted works. Please only download content you are legally entitled to, respecting copyright is your responsibility.
- Upload books to your Calibre‑Web server.
- Sync your whole library or selected books for offline reading.
- Check your collection statistics at a glance.
- Make it yours: reorder or hide book actions, detail sections and Discover sections, choose a theme, enable e‑ink mode, and adjust the text size, available in 15 languages.

## 🖼️ Impressions

<p align="center">
    <img src="docs/feature_graphics/1.png" alt="InApp" width="32%"/>
    <img src="docs/feature_graphics/2.png" alt="Share" width="32%" />
    <img src="docs/feature_graphics/3.png" alt="OpenTracks" width="32%" />
    <img src="docs/feature_graphics/4.png" alt="OpenTracks" width="32%" />
    <img src="docs/feature_graphics/5.png" alt="OpenTracks" width="32%" />
    <img src="docs/feature_graphics/6.png" alt="OpenTracks" width="32%" />
</p>

## 🌍 l10n

You can help translate Calibre Web Companion on [Weblate](https://hosted.weblate.org/projects/calibre-web-companion/app/).

<a href="https://hosted.weblate.org/engage/calibre-web-companion/">
<img src="https://hosted.weblate.org/widget/calibre-web-companion/app/multi-auto.svg" alt="Translation status" />
</a>

## 🚀 Contributing

You can of course open issues for bugs, feedback, and feature ideas. All suggestions are very welcome :)

## 📜 Credits

- [Calibre Web](https://github.com/janeczku/calibre-web)
- [Calibre Web Automated](https://github.com/crocodilestick/Calibre-Web-Automated)
- [shelfmark](https://github.com/calibrain/shelfmark)
- [send2ereader](https://github.com/daniel-j/send2ereader)
- [Flutter](https://github.com/flutter/flutter)
- [IconKitchen](https://icon.kitchen)
- [Weblate](https://hosted.weblate.org/)
- [CosmosEpub](https://github.com/Mamasodikov/cosmos_epub)

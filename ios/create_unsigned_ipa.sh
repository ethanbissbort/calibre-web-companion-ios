#!/bin/bash
#
# Builds the Flutter iOS app without code signing and packages it into an
# unsigned .ipa for sideloading (AltStore, Sideloadly, TrollStore, ...).
#
# Usage: ./ios/create_unsigned_ipa.sh (works from the repo root or from ios/)
# Requires: macOS with Xcode, CocoaPods and Flutter installed.

set -euo pipefail

echo "Starting unsigned IPA creation script..."

# Resolve the repository root no matter where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

if [ ! -f pubspec.yaml ]; then
    echo "Error: pubspec.yaml not found in $PROJECT_ROOT" >&2
    exit 1
fi

APP_NAME=$(grep '^name:' pubspec.yaml | head -n 1 | cut -d ':' -f 2 | tr -d '[:space:]')
IPA_FILENAME="${APP_NAME:-app}_unsigned.ipa"

echo "Building flutter app without code signing..."
flutter build ios --release --no-codesign --no-tree-shake-icons

APP_PATH="build/ios/iphoneos/Runner.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found, the build did not produce Runner.app." >&2
    exit 1
fi

echo "Packing the app into an unsigned IPA..."
cd build/ios/iphoneos
rm -rf Payload "$IPA_FILENAME"
mkdir Payload

cp -R Runner.app Payload/

zip -r -q -y "$IPA_FILENAME" Payload
rm -rf Payload

echo "The IPA file is stored here: $(pwd)/$IPA_FILENAME"

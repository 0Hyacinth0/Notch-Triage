#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly VERSION="0.1.19"
readonly BUILD="19"
readonly DIST_DIR="$PROJECT_DIR/dist"
readonly DMG_PATH="$DIST_DIR/NotchTriage-${VERSION}-macOS-universal.dmg"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$DIST_DIR"
if [[ -e "$DMG_PATH" || -L "$DMG_PATH" ]]; then
  fail "refusing to overwrite existing release artifact: $DMG_PATH"
fi

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
readonly XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
[[ -x "$XCODEBUILD" ]] || fail "Xcode Beta xcodebuild not found at $XCODEBUILD (set DEVELOPER_DIR to override)"

readonly TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/notch-triage-release.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

readonly DERIVED_DATA_PATH="$TEMP_ROOT/DerivedData"
readonly STAGING_DIR="$TEMP_ROOT/dmg-root"
mkdir -p "$STAGING_DIR"

printf 'Building NotchTriage %s (build %s) for arm64 and x86_64...\n' "$VERSION" "$BUILD"
"$XCODEBUILD" \
  -project "$PROJECT_DIR/NotchTriage.xcodeproj" \
  -scheme NotchTriage \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  build

readonly APP_SOURCE="$DERIVED_DATA_PATH/Build/Products/Release/NotchTriage.app"
[[ -d "$APP_SOURCE" ]] || fail "Release build did not produce $APP_SOURCE"

ditto "$APP_SOURCE" "$STAGING_DIR/NotchTriage.app"
ln -s /Applications "$STAGING_DIR/Applications"

readonly APP_PLIST="$APP_SOURCE/Contents/Info.plist"
readonly PLISTBUDDY="/usr/libexec/PlistBuddy"
[[ -x "$PLISTBUDDY" ]] || fail "PlistBuddy is required to validate the app bundle"

bundle_version="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
bundle_build="$("$PLISTBUDDY" -c 'Print :CFBundleVersion' "$APP_PLIST")"
[[ "$bundle_version" == "$VERSION" ]] || fail "expected version $VERSION, found $bundle_version"
[[ "$bundle_build" == "$BUILD" ]] || fail "expected build $BUILD, found $bundle_build"
printf 'Validated version %s, build %s.\n' "$bundle_version" "$bundle_build"

readonly EXECUTABLE_NAME="$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$APP_PLIST")"
readonly EXECUTABLE_PATH="$APP_SOURCE/Contents/MacOS/$EXECUTABLE_NAME"
[[ -f "$EXECUTABLE_PATH" ]] || fail "app executable not found at $EXECUTABLE_PATH"

lipo -verify_arch arm64 "$EXECUTABLE_PATH"
lipo -verify_arch x86_64 "$EXECUTABLE_PATH"
readonly ARCHITECTURES="$(lipo -archs "$EXECUTABLE_PATH")"
normalized_architectures="$(printf '%s\n' "$ARCHITECTURES" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "$normalized_architectures" == 'arm64 x86_64' ]] || fail "expected arm64+x86_64 universal binary, found: $ARCHITECTURES"
printf 'Validated architectures: %s.\n' "$ARCHITECTURES"

codesign --verify --deep --strict --verbose=2 "$APP_SOURCE"
printf 'Validated code signature.\n'

printf 'Creating %s...\n' "$DMG_PATH"
hdiutil create \
  -volname "NotchTriage ${VERSION}" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  "$DMG_PATH"
hdiutil verify "$DMG_PATH"

readonly SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf 'SHA-256: %s  %s\n' "$SHA256" "$DMG_PATH"

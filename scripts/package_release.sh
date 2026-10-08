#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

readonly VERSION_CONFIG="$PROJECT_DIR/Config/Version.xcconfig"
[[ -f "$VERSION_CONFIG" ]] || fail "release version config not found: $VERSION_CONFIG"

read_xcconfig_value() {
  local key="$1"
  local value
  value="$(awk -F '=' -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value = $2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      matches++
    }
    END { if (matches != 1) exit 1 }
  ' "$VERSION_CONFIG")" || fail "expected exactly one $key in $VERSION_CONFIG"
  printf '%s' "$value"
}

readonly VERSION="$(read_xcconfig_value MARKETING_VERSION)"
readonly BUILD="$(read_xcconfig_value CURRENT_PROJECT_VERSION)"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "invalid marketing version: $VERSION"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "invalid build number: $BUILD"

readonly DIST_DIR="$PROJECT_DIR/dist"
readonly DMG_PATH="$DIST_DIR/NotchTriage-${VERSION}-macOS-universal.dmg"
readonly SOURCE_HOME_DIRECTORY="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "$SOURCE_HOME_DIRECTORY" ]] || fail "could not locate the source user's home directory"
readonly SOURCE_PREFIX_MAP="${SOURCE_HOME_DIRECTORY}=/source"
readonly OTHER_SWIFT_FLAGS_VALUE="\$(inherited) -debug-prefix-map ${SOURCE_PREFIX_MAP} -file-prefix-map ${SOURCE_PREFIX_MAP} -coverage-prefix-map ${SOURCE_PREFIX_MAP}"
readonly OTHER_C_FLAGS_VALUE="\$(inherited) -fdebug-prefix-map=${SOURCE_PREFIX_MAP} -ffile-prefix-map=${SOURCE_PREFIX_MAP} -fcoverage-prefix-map=${SOURCE_PREFIX_MAP}"
readonly OTHER_CPLUSPLUS_FLAGS_VALUE="\$(inherited) -fdebug-prefix-map=${SOURCE_PREFIX_MAP} -ffile-prefix-map=${SOURCE_PREFIX_MAP} -fcoverage-prefix-map=${SOURCE_PREFIX_MAP}"

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
readonly TEMP_DMG_PATH="$TEMP_ROOT/NotchTriage-${VERSION}-macOS-universal.dmg"
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
  ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  "OTHER_SWIFT_FLAGS=$OTHER_SWIFT_FLAGS_VALUE" \
  "OTHER_CFLAGS=$OTHER_C_FLAGS_VALUE" \
  "OTHER_CPLUSPLUSFLAGS=$OTHER_CPLUSPLUS_FLAGS_VALUE" \
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
audio_capture_usage="$("$PLISTBUDDY" -c 'Print :NSAudioCaptureUsageDescription' "$APP_PLIST")"
[[ -n "$audio_capture_usage" ]] || fail "system audio permission usage description is missing"

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
readonly SIGNING_METADATA="$(codesign -d --verbose=4 "$APP_SOURCE" 2>&1)"
readonly SIGNING_IDENTITY="$(printf '%s\n' "$SIGNING_METADATA" | sed -n 's/^Authority=//p' | head -n 1)"
readonly SIGNING_TEAM_IDENTIFIER="$(printf '%s\n' "$SIGNING_METADATA" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
[[ -n "$SIGNING_IDENTITY" ]] || fail "Release app does not have a certificate-based signing identity"
[[ -n "$SIGNING_TEAM_IDENTIFIER" && "$SIGNING_TEAM_IDENTIFIER" != 'not set' ]] || fail "Release app does not have a signing team identifier"

# Strip symbol-table debug entries from packaged Mach-O files, then restore the
# existing signing identity so the updater continues to see the same Team ID.
while IFS= read -r -d '' candidate; do
  if [[ "$(/usr/bin/file -b "$candidate")" == *Mach-O* ]]; then
    /usr/bin/strip -S "$candidate"
  fi
done < <(find "$STAGING_DIR/NotchTriage.app" -type f -print0)

codesign --force --deep --sign "$SIGNING_IDENTITY" \
  --preserve-metadata=entitlements,flags,runtime,requirements \
  "$STAGING_DIR/NotchTriage.app"
codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/NotchTriage.app"
readonly STAGING_SIGNING_METADATA="$(codesign -d --verbose=4 "$STAGING_DIR/NotchTriage.app" 2>&1)"
readonly STAGING_SIGNING_TEAM_IDENTIFIER="$(printf '%s\n' "$STAGING_SIGNING_METADATA" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
[[ "$STAGING_SIGNING_TEAM_IDENTIFIER" == "$SIGNING_TEAM_IDENTIFIER" ]] || fail "Re-signed package changed the signing team identifier"
printf 'Validated code signature and signing team.\n'

printf 'Creating %s...\n' "$DMG_PATH"
hdiutil create \
  -volname "NotchTriage ${VERSION}" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  "$TEMP_DMG_PATH"
# DiskImages can briefly return EAGAIN immediately after image creation.
verified=false
for attempt in 1 2 3; do
  if hdiutil verify "$TEMP_DMG_PATH"; then
    verified=true
    break
  fi
  sleep 1
done
[[ "$verified" == true ]] || fail "disk image integrity verification failed after three attempts"
ditto "$TEMP_DMG_PATH" "$DMG_PATH"

readonly SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf 'SHA-256: %s  %s\n' "$SHA256" "$DMG_PATH"

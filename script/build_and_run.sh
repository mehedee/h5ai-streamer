#!/bin/zsh
# Foreground native build. --isolated stages a separate app and profile for UI verification.
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD_ONLY=0
ISOLATED=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --isolated) ISOLATED=1 ;;
    *) print -u2 "Usage: $0 [--build-only] [--isolated]"; exit 2 ;;
  esac
done
BUILD_ROOT="$ROOT/.build/native-development"
if (( ISOLATED )); then BUILD_ROOT="$ROOT/.build/native-polish"; fi
APP="$BUILD_ROOT/products/Myra.app"
if (( ! BUILD_ONLY )); then
  # Stop only this development checkout's process, never an installed copy.
  pkill -f "^$APP/Contents/MacOS/Myra$" || true
fi
# Reuse this checkout's resolved packages when available; do not fetch new versions.
PACKAGE_OPTIONS=()
if [[ -d "$ROOT/.build/dmg-4.0/DerivedData/SourcePackages/checkouts" ]]; then
  PACKAGE_OPTIONS=(-clonedSourcePackagesDirPath "$ROOT/.build/dmg-4.0/DerivedData/SourcePackages" -disableAutomaticPackageResolution)
fi
xcodebuild "${PACKAGE_OPTIONS[@]}" -quiet -project "$ROOT/Myra.xcodeproj" -scheme Myra -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD_ROOT/DerivedData" \
  CONFIGURATION_BUILD_DIR="$BUILD_ROOT/products" CODE_SIGNING_ALLOWED=NO build
if (( ISOLATED )); then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.mehedee.Myra.Development' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Delete :LSEnvironment' "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:MYRA_PROFILE_DIR string $BUILD_ROOT/profile" "$APP/Contents/Info.plist"
fi
codesign --force --deep --sign - "$APP"
print "Built $APP"
if (( ! BUILD_ONLY )); then /usr/bin/open -n "$APP"; fi

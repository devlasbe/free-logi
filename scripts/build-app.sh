#!/bin/bash
# release 빌드 → build/FreeLogi.app 번들 → 서명
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="FreeLogi"
source scripts/sign-identity.sh
echo "signing identity: $SIGN_IDENTITY"
APP_PATH="build/$APP_NAME.app"

swift build -c release "$@"
BIN_PATH=$(swift build -c release "$@" --show-bin-path)

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
# 버전은 번들 사본에만 반영
if [[ -n "${APP_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_PATH/Contents/Info.plist"
fi
if [[ -n "${APP_BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP_PATH/Contents/Info.plist"
fi
# 아이콘: Icon Composer 문서 → AppIcon.icns(macOS 13~15) + Assets.car(macOS 26). actool은 Xcode 26 이상
xcrun actool design/icon/AppIcon.icon --compile "$APP_PATH/Contents/Resources" --platform macosx \
  --minimum-deployment-target 13.0 --target-device mac --app-icon AppIcon \
  --output-partial-info-plist "$(mktemp)" >/dev/null

SIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY" --options runtime)
if [[ "$SIGN_IDENTITY" == 'Developer ID Application'* ]]; then
  SIGN_OPTIONS+=(--timestamp)
fi
codesign "${SIGN_OPTIONS[@]}" "$APP_PATH"
echo "built $APP_PATH"

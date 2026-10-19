#!/bin/bash
# 앱을 빌드해 DMG로 포장
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v uvx >/dev/null 2>&1; then
  echo "DMG 생성에는 uv의 uvx가 필요합니다: brew install uv" >&2
  exit 1
fi

source scripts/sign-identity.sh
scripts/build-app.sh "$@"
# 이름 고정: README의 releases/latest/download/FreeLogi.dmg 링크
DMG_PATH="build/FreeLogi.dmg"

# Finder가 화면 배율에 맞는 이미지를 고르도록 두 해상도를 한 TIFF에 담는다.
tiffutil -cathidpicheck design/dmg/background.png design/dmg/background@2x.png \
  -out build/dmg-background.tiff
# Finder 자동화 권한 없이 창 배치와 배경을 .DS_Store에 기록한다.
uvx dmgbuild==1.6.7 -s scripts/dmg-settings.py FreeLogi "$DMG_PATH"
if [[ "$SIGN_IDENTITY" == 'Developer ID Application'* ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1); then
    printf '%s\n' "$NOTARY_OUTPUT"
  else
    printf '%s\n' "$NOTARY_OUTPUT" >&2
  fi
  if ! grep -q 'status: Accepted' <<< "${NOTARY_OUTPUT:-}"; then
    SUBMISSION_ID=$(sed -nE 's/^[[:space:]]*id:[[:space:]]*([^[:space:]]+).*/\1/p' <<< "${NOTARY_OUTPUT:-}" | head -n 1)
    [[ -z "$SUBMISSION_ID" ]] || echo "제출 ID: $SUBMISSION_ID" >&2
    echo "공증 실패. 로그 확인: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG_PATH"
fi
echo "$DMG_PATH"

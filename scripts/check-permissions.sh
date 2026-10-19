#!/bin/bash
# 02 권한 모듈 확인. 사용: scripts/build-app.sh && scripts/check-permissions.sh
# 1) 셸에서 직접 실행 → 터미널 권한을 물려받아 두 권한 "허용"
# 2) open으로 실행 → 앱 자기 권한(한 번도 허용한 적 없음)이라 두 권한 "미허용"
# 3) open으로 띄운 앱의 실제 메뉴를 손쉬운 사용(AX)으로 읽는다. 화면이 잠겨 있어도 된다.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="build/FreeLogi.app"
OUTPUT_FILE="$(mktemp)"

echo "== 직접 실행 (--permissions)"
"$APP_PATH/Contents/MacOS/FreeLogi" --permissions

echo "== open 실행 (--permissions)"
open -n --stdout "$OUTPUT_FILE" "$APP_PATH" --args --permissions
for _ in $(seq 1 20); do
    [ "$(wc -l < "$OUTPUT_FILE")" -ge 2 ] && break
    sleep 0.5
done
cat "$OUTPUT_FILE"
rm -f "$OUTPUT_FILE"
# 막 끝난 인스턴스가 정리되기 전에 open하면 새 앱이 안 뜨는 경우가 있다
sleep 1

echo "== open 실행 (메뉴)"
open "$APP_PATH"
sleep 3
osascript -e 'tell application "System Events" to tell process "FreeLogi" to get name of every menu item of menu 1 of menu bar item 1 of menu bar 1'
osascript -e 'tell application "FreeLogi" to quit'

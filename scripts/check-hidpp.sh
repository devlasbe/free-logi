#!/bin/bash
# 03 HID++ 통신 확인. 사용: scripts/build-app.sh && scripts/check-hidpp.sh
# 셸에서 직접 실행해 터미널의 입력 모니터링 권한을 물려받는다. OpenLogi(agent)가 떠 있으면 같은 장치를 같이 열어 응답이 섞이므로 먼저 종료해야 한다.
set -euo pipefail

cd "$(dirname "$0")/.."

if pgrep -qfi openlogi; then
    echo "OpenLogi가 떠 있다: osascript -e 'quit app \"OpenLogi\"' 후 agent도 kill" >&2
    exit 1
fi

OUTPUT="$(build/FreeLogi.app/Contents/MacOS/FreeLogi --dump)"
echo "$OUTPUT"

echo "$OUTPUT" | grep -q 'HID++ 4\.' || { echo "FAIL: HID++ 4.x 기기가 없다" >&2; exit 1; }
echo "$OUTPUT" | grep -q 'divertable' || { echo "FAIL: divertable 컨트롤이 없다" >&2; exit 1; }
echo "OK"

#!/bin/bash
# G5: 임시 프로필(틸트 왼쪽→F19)로 엔진을 띄우고, 설정 창을 열었다 닫은 뒤 2분 유휴 RSS·CPU를 잰다.
set -uo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); ID=$(uuidgen)
cat > "$TMP/profiles.json" <<J
{"activeID":"$ID","profiles":[{"bindings":[{"button":{"hidpp":{"_0":91}},"keys":{"keyCode":80,"modifiers":0}}],"id":"$ID","name":"측정"}]}
J
FREELOGI_PROFILES_PATH="$TMP/profiles.json" build/FreeLogi.app/Contents/MacOS/FreeLogi 2>"$TMP/log" &
PID=$!
sleep 5
echo "시작 5초: rss=$(ps -o rss= -p $PID)KB"; footprint $PID 2>/dev/null | grep "phys_footprint:"
osascript -e 'tell application "System Events" to tell process "FreeLogi" to click menu item "설정…" of menu 1 of menu bar item 1 of menu bar 1' >/dev/null 2>&1 \
  || echo "설정 메뉴 클릭 실패"
sleep 3
echo "설정 창 열림: windows=$(osascript -e 'tell application "System Events" to count windows of process "FreeLogi"') rss=$(ps -o rss= -p $PID)KB"; footprint $PID 2>/dev/null | grep "phys_footprint:"
osascript -e 'tell application "System Events" to tell process "FreeLogi" to click button 1 of window 1' >/dev/null 2>&1
sleep 120
echo "창 닫고 2분: windows=$(osascript -e 'tell application "System Events" to count windows of process "FreeLogi"') rss=$(ps -o rss= -p $PID)KB"; footprint $PID 2>/dev/null | grep "phys_footprint:"
echo "footprint:"; footprint $PID 2>/dev/null | grep -E "Footprint|phys_footprint" | head -2
top -l 6 -s 2 -pid $PID -stats pid,cpu | awk '$1=='$PID'{print $2}' | tail -5 | tr '\n' ' ' | sed 's/^/CPU 2초 간격 5회: /'; echo
echo "프로세스 수: $(pgrep -x FreeLogi | wc -l | tr -d ' ')"
kill -TERM $PID; wait $PID 2>/dev/null
echo "종료 후 divert: $(build/FreeLogi.app/Contents/MacOS/FreeLogi --dump 2>/dev/null | grep -c ' diverted$')"
rm -rf "$TMP"

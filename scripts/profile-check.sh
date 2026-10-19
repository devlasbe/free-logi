#!/bin/bash
# 09 G1 프로필 확인. 사용: scripts/build-app.sh && scripts/profile-check.sh
# 임시 profiles.json으로 메뉴에서 B를 고르고, 재실행 뒤에도 선택과 매핑(F18)이 유지되는지 본다.
# 앱은 셸에서 직접 실행해 터미널 권한을 쓰며 사용자 profiles.json은 건드리지 않는다.
set -uo pipefail

cd "$(dirname "$0")/.."

BIN="$PWD/build/FreeLogi.app/Contents/MacOS/FreeLogi"
WORK="$(mktemp -d)"
PROFILES="$WORK/profiles.json"
APP_LOG="$WORK/app.log"
REAL_PROFILES="$HOME/Library/Application Support/FreeLogi/profiles.json"
A_ID="5D498085-3D67-482E-A886-C8B77FFC62B9"
B_ID="7A0E4E3A-0E5B-4A37-9D1B-0A2C3B4D5E6F"
APP_PID=""

fail() { echo "FAIL: $*"; echo "--- 앱 로그"; cat "$APP_LOG" 2>/dev/null | tr -d '\0'; exit 1; }
wait_for() { # 조건 명령, 최대 초
    for _ in $(seq 1 $(($2 * 4))); do
        eval "$1" && return 0
        sleep 0.25
    done
    return 1
}
real_state() { stat -f '%m %z' "$REAL_PROFILES" 2>/dev/null || echo "없음"; }
menu_mark_b() {
    osascript -e 'tell application "System Events" to tell process "FreeLogi" to get value of attribute "AXMenuItemMarkChar" of menu item "B" of menu 1 of menu bar item 1 of menu bar 1'
}
saved_active_id() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["activeID"])' "$PROFILES"; }

[ -x "$BIN" ] || { echo "$BIN 이 없다: scripts/build-app.sh 먼저" >&2; rm -rf "$WORK"; exit 1; }

cleanup() {
    if [ -n "$APP_PID" ]; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    fi
    "$BIN" --undivert >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

REAL_BEFORE="$(real_state)"
echo "== 준비: 임시 프로필 $PROFILES (사용자 profiles.json: $REAL_BEFORE)"
"$BIN" --undivert >/dev/null 2>&1 || fail "시작 전 --undivert 실패"
cat >"$PROFILES" <<JSON
{"activeID":"$A_ID","profiles":[
{"bindings":[{"button":{"standard":{"_0":3}},"keys":{"keyCode":80,"modifiers":0}}],"id":"$A_ID","name":"A"},
{"bindings":[{"button":{"standard":{"_0":3}},"keys":{"keyCode":79,"modifiers":0}}],"id":"$B_ID","name":"B"}]}
JSON
swiftc -O scripts/observe-keys.swift -o "$WORK/observe-keys" 2>/dev/null || fail "observe-keys 컴파일 실패"
swiftc -O scripts/post-button.swift -o "$WORK/post-button" 2>/dev/null || fail "post-button 컴파일 실패"

start_app() {
    : >"$APP_LOG"
    FREELOGI_PROFILES_PATH="$PROFILES" "$BIN" >/dev/null 2>>"$APP_LOG" &
    APP_PID=$!
    wait_for "kill -0 '$APP_PID' 2>/dev/null" 10 || fail "앱이 시작되지 않았다"
    wait_for "menu_mark_b >/dev/null 2>&1" 15 || fail "프로필 메뉴에 접근할 수 없다"
}
assert_b_checked() {
    local mark
    mark="$(menu_mark_b)" || fail "B 체크 표시를 읽지 못했다"
    echo "B 체크: [$mark]"
    [ "$mark" = "✓" ] || fail "B에 체크 표시가 없다"
}
observe_f18() { # 버튼 3 합성 클릭에서 F18만 나오는지 확인
    local out="$WORK/observed.txt" observer
    "$WORK/observe-keys" 3 >"$out" &
    observer=$!
    wait_for "grep -q '^ready' '$out'" 10 || fail "키 관찰자가 준비되지 않았다"
    local posted
    posted="$("$WORK/post-button" 3)" || fail "합성 버튼 클릭 실패"
    wait "$observer" || fail "키 관찰자가 정상 종료되지 않았다"
    local observed expected
    observed="$(grep -v '^ready' "$out" | sed 's/ t=.*//')"
    expected="down keyCode=79 mods=fn
up keyCode=79 mods=fn"
    echo "합성 클릭: $posted / 관찰: $(echo "$observed" | tr '\n' '|')"
    echo "$posted" | grep -q 'seen=0' || fail "원래 버튼 클릭이 삼켜지지 않았다"
    [ "$observed" = "$expected" ] || fail "F18 down/up을 보지 못했거나 다른 키 이벤트가 있었다"
    ! echo "$observed" | grep -q 'keyCode=80' || fail "F19 이벤트가 관찰됐다"
}
stop_app() {
    kill -TERM "$APP_PID" 2>/dev/null || fail "SIGTERM을 보내지 못했다"
    wait_for "! kill -0 '$APP_PID' 2>/dev/null" 15 || fail "SIGTERM 뒤에도 앱이 끝나지 않았다"
    wait "$APP_PID" 2>/dev/null
    APP_PID=""
}
diverted_cids() { "$BIN" --dump | grep -a ' diverted$' | sed -E 's/.*cid=(0x[0-9A-F]+).*/\1/' | sort | tr '\n' ' ' | sed 's/ $//'; }

echo "== 1. 앱을 띄우고 메뉴에서 B 선택"
start_app
osascript -e 'tell application "System Events" to tell process "FreeLogi" to click menu item "B" of menu 1 of menu bar item 1 of menu bar 1' >/dev/null || fail "메뉴 항목 B 클릭 실패"
wait_for "[ \"\$(saved_active_id)\" = '$B_ID' ]" 10 || fail "activeID가 B로 저장되지 않았다"
assert_b_checked
observe_f18

echo "== 2. SIGTERM 후 같은 프로필 파일로 재실행"
stop_app
start_app
assert_b_checked
[ "$(saved_active_id)" = "$B_ID" ] || fail "재실행 뒤 activeID가 B가 아니다"
observe_f18

echo "== 3. 정리 및 상태 확인"
stop_app
DUMP="$("$BIN" --dump)"
ACTUAL="$(echo "$DUMP" | grep -a ' diverted$' | sed -E 's/.*cid=(0x[0-9A-F]+).*/\1/' | sort | tr '\n' ' ' | sed 's/ $//')"
echo "--dump diverted = [$ACTUAL]"
[ -z "$ACTUAL" ] || fail "종료 뒤에도 diverted CID가 남아 있다"
if pgrep -qx FreeLogi; then fail "FreeLogi 프로세스가 남아 있다"; fi
[ -d "$WORK" ] || fail "임시 디렉터리가 예정보다 일찍 사라졌다"
REAL_AFTER="$(real_state)"
echo "사용자 profiles.json: 전 [$REAL_BEFORE] 후 [$REAL_AFTER]"
[ "$REAL_BEFORE" = "$REAL_AFTER" ] || fail "사용자 profiles.json이 바뀌었다"
rm -rf "$WORK"
trap - EXIT
echo "임시 디렉터리 제거: OK"
echo "OK"

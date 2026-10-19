#!/bin/bash
# 08 설정 화면·메뉴바 확인. 사용: scripts/build-app.sh && scripts/settings-check.sh   (약 40초, 사람 필요 없음, 화면이 잠겨 있어도 된다)
# 앱을 셸에서 직접 실행하고(터미널의 권한을 쓴다) 임시 profiles.json(FREELOGI_PROFILES_PATH)으로 확인한다. 사용자 프로필은 건드리지 않는다.
# 1) "버튼 추가" 흐름: FREELOGI_DEBUG_ADD_BUTTON_KEY=80(F19)으로 띄우면 설정 창이 열리고 같은 view model 동작(startCapture → record)이
#    돈다. 인식 모드가 ready를 내면 합성 버튼 3을 post → 표에 "버튼 1=F19" 줄, profiles.json에 standard(3)→F19 저장, divert 복구.
# 2) 메뉴: 떠 있는 앱의 메뉴 항목을 System Events로 읽고(프로필 목록·체크·권한·설정…·종료), 프로필 항목을 눌러(AX click) 활성 프로필이
#    바뀌고 엔진이 따라가는지 본다(틸트 왼쪽 divert).
# 0) 인식 안내가 떠 있는 채로 SIGTERM을 보내도 앱이 끝나고 divert가 풀린다(.sheet로 띄우면 NSApp.terminate가 무시돼 안 끝났다).
# 3) 권한을 새로 받았을 때의 반응: SIGUSR1(손쉬운 사용 → 엔진 다시 시작)·SIGUSR2(입력 모니터링 → 앱 다시 실행)로 같은 함수를 부른다.
#    TCC는 건드리지 않는다. 다시 실행된 앱은 `open -n`이라 자기 번들 ID(권한 미허용)로 뜬다.
#    임시 프로필 경로는 open --env로 명시해 전달한다. 끝에 그 앱도 SIGTERM으로 끈다.
# 셸에 손쉬운 사용 권한이 있어야 메뉴를 읽을 수 있다. OpenLogi·FreeLogi가 떠 있으면 거부한다.
set -uo pipefail

cd "$(dirname "$0")/.."

BIN="$PWD/build/FreeLogi.app/Contents/MacOS/FreeLogi"
WORK="$(mktemp -d)"
PROFILES="$WORK/profiles.json"
APP_LOG="$WORK/app.log"
REAL_PROFILES="$HOME/Library/Application Support/FreeLogi/profiles.json"
BASIC_ID="5D498085-3D67-482E-A886-C8B77FFC62B9"
TILT_ID="7A0E4E3A-0E5B-4A37-9D1B-0A2C3B4D5E6F"
TILT_LEFT=0x005B
F19=80
APP_PID=""
DUMP=""

fail() { echo "FAIL: $*"; echo "--- 앱 로그"; cat "$APP_LOG" 2>/dev/null | tr -d '\0'; exit 1; }
wait_for() { # 조건 명령, 최대 초
    for _ in $(seq 1 $(($2 * 4))); do
        eval "$1" && return 0
        sleep 0.25
    done
    return 1
}
real_state() { stat -f '%m %z' "$REAL_PROFILES" 2>/dev/null || echo "없음"; }
diverted_cids() { # DUMP(--dump 출력)에서 diverted인 CID를 정렬해 공백으로 잇는다
    echo "$DUMP" | grep -a ' diverted$' | sed -E 's/.*cid=(0x[0-9A-F]+).*/\1/' | sort | tr '\n' ' ' | sed 's/ $//'
}
# --dump는 다른 프로세스라, 앱이 divert 작업 중이면 서로의 HID++ 응답이 섞인다(요청 매칭이 feature·function·swId만 본다).
# 앱 로그가 1.5초 조용해진 뒤에 돌린다.
wait_quiet() {
    local last="" current stable=0
    for _ in $(seq 1 60); do
        current="$(log_lines)"
        if [ "$current" = "$last" ]; then stable=$((stable + 1)); else stable=0; fi
        [ "$stable" -ge 6 ] && return 0
        last="$current"
        sleep 0.25
    done
    return 1
}
expect_diverted() { # 설명, 기대 CID 목록
    local actual
    if [ -n "$APP_PID" ]; then wait_quiet || fail "앱 로그가 계속 나온다"; fi
    DUMP="$("$BIN" --dump)"
    actual="$(diverted_cids)"
    echo "$1: --dump diverted = [${actual}]"
    [ "$actual" = "$2" ] || { echo "--- --dump 출력"; echo "$DUMP" | tr -d '\0'; fail "$1: 기대 [$2], 실제 [$actual]"; }
}
menu_titles() { osascript -e 'tell application "System Events" to tell process "FreeLogi" to get name of every menu item of menu 1 of menu bar item 1 of menu bar 1'; }
menu_marks() { osascript -e 'tell application "System Events" to tell process "FreeLogi" to get value of attribute "AXMenuItemMarkChar" of every menu item of menu 1 of menu bar item 1 of menu bar 1'; }
log_lines() { wc -l <"$APP_LOG" | tr -d ' '; }
log_since() { tail -n +$(($1 + 1)) "$APP_LOG" | tr -d '\0'; } # 줄 번호 이후의 로그
saved_active_id() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["activeID"])' "$PROFILES"; }
saved_bindings() { python3 -I -c '
import json,sys
state=json.load(open(sys.argv[1]))
profile=next(p for p in state["profiles"] if p["id"]==state["activeID"])
print(json.dumps(profile["bindings"],sort_keys=True,separators=(",",":")))' "$PROFILES"; }

[ -x "$BIN" ] || { echo "$BIN 이 없다: scripts/build-app.sh 먼저" >&2; exit 1; }
pgrep -qfi openlogi
PROCESS_STATUS=$?
if [ "$PROCESS_STATUS" -gt 1 ]; then
    echo "프로세스 목록을 읽을 수 없다: 샌드박스 밖 터미널에서 scripts/settings-check.sh 실행" >&2
    rm -rf "$WORK"
    exit 1
fi
if [ "$PROCESS_STATUS" -eq 0 ]; then echo "OpenLogi가 떠 있다: agent도 kill 하고 다시" >&2; rm -rf "$WORK"; exit 1; fi
if pgrep -qx FreeLogi; then echo "FreeLogi가 떠 있다: 끄고 다시" >&2; rm -rf "$WORK"; exit 1; fi

cleanup() {
    for pid in $(pgrep -x FreeLogi); do kill -TERM "$pid" 2>/dev/null; done
    wait_for "! pgrep -qx FreeLogi" 15
    "$BIN" --undivert >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

REAL_BEFORE="$(real_state)"
echo "== 준비: 임시 프로필 $PROFILES (사용자 profiles.json: $REAL_BEFORE)"
"$BIN" --undivert 2>/dev/null
expect_diverted "시작 전" ""
cat >"$PROFILES" <<JSON
{"activeID":"$BASIC_ID","profiles":[
{"id":"$BASIC_ID","name":"기본","bindings":[]},
{"id":"$TILT_ID","name":"틸트","bindings":[{"button":{"hidpp":{"_0":91}},"keys":{"keyCode":$F19,"modifiers":0}}]}]}
JSON
swiftc -O scripts/post-button.swift -o "$WORK/post-button" 2>/dev/null || fail "post-button 컴파일 실패"

echo "== 0. 인식 안내가 떠 있을 때 SIGTERM"
FREELOGI_PROFILES_PATH="$PROFILES" FREELOGI_DEBUG_ADD_BUTTON_KEY=$F19 "$BIN" >/dev/null 2>>"$APP_LOG" &
APP_PID=$!
wait_for "grep -q '^ready:' '$APP_LOG'" 15 || fail "인식 모드가 ready를 내지 않았다"
kill -TERM "$APP_PID"
wait_for "! kill -0 $APP_PID 2>/dev/null" 15 || fail "인식 안내가 떠 있을 때 SIGTERM에 안 끝났다"
wait "$APP_PID" 2>/dev/null
APP_PID=""
DUMP=""
expect_diverted "SIGTERM 뒤" ""
: >"$APP_LOG"

echo "== 1. 버튼 추가 흐름 (설정 창 열림 → 인식 → 키 지정 → 저장)"
FREELOGI_PROFILES_PATH="$PROFILES" FREELOGI_DEBUG_ADD_BUTTON_KEY=$F19 "$BIN" >/dev/null 2>>"$APP_LOG" &
APP_PID=$!
wait_for "grep -q '^ready:' '$APP_LOG'" 15 || fail "인식 모드가 ready를 내지 않았다"
POSTED="$("$WORK/post-button" 3)"
echo "합성 클릭: $POSTED"
echo "$POSTED" | grep -q 'seen=0' || fail "인식 모드 중 합성 클릭이 삼켜지지 않았다"
wait_for "grep -q '^flow:' '$APP_LOG'" 15 || fail "flow 로그가 없다"
FLOW="$(grep '^flow:' "$APP_LOG" | tr -d '\0')"
echo "$FLOW"
[ "$FLOW" = "flow: rows=버튼 1=F19" ] || fail "표에 '버튼 1=F19' 한 줄이 아니다"
BINDINGS="$(saved_bindings)"
echo "profiles.json 활성 프로필 bindings: $BINDINGS"
[ "$BINDINGS" = '[{"button":{"standard":{"_0":3}},"keys":{"keyCode":80,"modifiers":0}}]' ] || fail "profiles.json에 버튼 3 → F19가 저장되지 않았다"
expect_diverted "인식이 끝난 뒤(원래 상태)" ""

echo "== 2. 메뉴 항목과 프로필 전환"
TITLES="$(menu_titles)"
echo "메뉴: $TITLES"
for expected in "기본, 틸트" "입력 모니터링: 허용" "손쉬운 사용: 허용" "설정…" "종료"; do
    echo "$TITLES" | grep -q "$expected" || fail "메뉴에 '$expected'가 없다"
done
MARKS="$(menu_marks)"
echo "체크: $MARKS"
echo "$MARKS" | grep -q '^✓, missing value' || fail "활성 프로필(기본)에 체크가 없다"
SINCE="$(log_lines)"
osascript -e 'tell application "System Events" to tell process "FreeLogi" to click menu item "틸트" of menu 1 of menu bar item 1 of menu bar 1' >/dev/null || fail "메뉴 항목 클릭 실패"
wait_for "[ \"\$(saved_active_id)\" = '$TILT_ID' ]" 10 || fail "활성 프로필이 profiles.json에 저장되지 않았다"
wait_for "log_since $SINCE | grep -q 'cid $TILT_LEFT .*diverted=true'" 10 || fail "틸트 왼쪽 divert 로그가 없다"
expect_diverted "프로필 '틸트'로 바꾼 뒤" "$TILT_LEFT"
echo "체크: $(menu_marks)"
menu_marks | grep -q '^missing value, ✓' || fail "체크가 '틸트'로 옮겨가지 않았다"

echo "== 3. 권한을 새로 받았을 때: 엔진 다시 시작 (SIGUSR1)"
SINCE="$(log_lines)"
PID_BEFORE="$APP_PID"
kill -USR1 "$APP_PID"
wait_for "log_since $SINCE | grep -q '^engine: ready'" 15 || fail "엔진이 다시 시작되지 않았다"
wait_for "log_since $SINCE | grep -q 'cid $TILT_LEFT .*diverted=true'" 15 || fail "다시 시작한 엔진이 divert를 다시 걸지 않았다"
log_since "$SINCE" | grep -E '권한 허용 감지|engine: ready|diverted=' | sed 's/^/  /'
kill -0 "$PID_BEFORE" 2>/dev/null || fail "엔진만 다시 시작해야 하는데 프로세스가 끝났다"
expect_diverted "엔진을 다시 시작한 뒤" "$TILT_LEFT"

echo "== 4. 권한을 새로 받았을 때: 앱 다시 실행 (SIGUSR2)"
SINCE="$(log_lines)"
kill -USR2 "$APP_PID"
wait_for "! kill -0 $APP_PID 2>/dev/null" 15 || fail "SIGUSR2 뒤에도 앱이 안 끝났다"
APP_PID=""
DUMP=""
log_since "$SINCE" | grep -q '^relaunch:' || fail "relaunch 로그가 없다"
log_since "$SINCE" | grep -q "cid $TILT_LEFT .*diverted=false" || fail "이전 앱이 divert를 풀고 끝나지 않았다"
log_since "$SINCE" | grep -E '권한 허용 감지|relaunch:|diverted=' | sed 's/^/  /'
wait_for "pgrep -qx FreeLogi" 15 || fail "새 앱이 뜨지 않았다"
NEW_PID="$(pgrep -x FreeLogi | head -1)"
echo "이전 PID $PID_BEFORE → 새 PID $NEW_PID"
[ "$NEW_PID" != "$PID_BEFORE" ] || fail "PID가 같다"
wait_for "menu_titles | grep -q '설정…'" 10 || fail "새 앱의 메뉴를 읽지 못했다"
echo "새 앱 메뉴: $(menu_titles)"
kill -TERM "$NEW_PID"
wait_for "! pgrep -qx FreeLogi" 15 || fail "새 앱이 SIGTERM에 안 끝났다(인식 안내가 떠 있을 수 있다)"
expect_diverted "새 앱까지 끈 뒤" ""

REAL_AFTER="$(real_state)"
echo "사용자 profiles.json: 전 [$REAL_BEFORE] 후 [$REAL_AFTER]"
[ "$REAL_BEFORE" = "$REAL_AFTER" ] || fail "사용자 profiles.json이 바뀌었다"
echo "OK"

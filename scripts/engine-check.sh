#!/bin/bash
# 07 매핑 엔진 확인. 사용: scripts/build-app.sh && scripts/engine-check.sh   (약 1분, 사람 필요 없음)
# 앱을 셸에서 직접 실행하고(터미널의 권한을 쓴다) 임시 profiles.json(FREELOGI_PROFILES_PATH)으로 확인한다. 사용자 프로필은 건드리지 않는다.
# 매핑 키는 F19(어디에도 안 묶인 키). 1) 일반 버튼 매핑 → 합성 클릭이 삼켜지고 관찰자가 F19를 본다, 매핑을 지우면(SIGHUP) 클릭이 통과한다
# 2) HID++ 매핑 CID만 divert된다(--dump), 매핑을 바꾸면 divert 목록이 따라 바뀐다, divert를 외부에서 풀어도(기기 리셋 흉내) 다시 건다
# 3) SIGTERM·SIGINT로 끝나면 divert가 0개 4) kill -9로 남은 divert를 다음 실행이 푼다.
# 화면이 잠겨 있으면 합성 버튼 3, 아니면 9를 쓴다(통과한 클릭이 앞 앱에서 '뒤로'가 되지 않게).
# OpenLogi가 떠 있으면 divert가 충돌한다. 실제 눌림 알림과 기기 재연결은 사람이 해야 한다(12).
set -uo pipefail

cd "$(dirname "$0")/.."

BIN="$PWD/build/FreeLogi.app/Contents/MacOS/FreeLogi"
WORK="$(mktemp -d)"
PROFILES="$WORK/profiles.json"
APP_LOG="$WORK/app.log"
PROFILE_ID="5D498085-3D67-482E-A886-C8B77FFC62B9"
F19=80
TILT_LEFT=0x005B
TILT_RIGHT=0x005D
APP_PID=""

if ioreg -n Root -d1 -a | grep -A1 IOConsoleLocked | grep -q '<true/>'; then BUTTON=3; else BUTTON=9; fi
STANDARD_BUTTON="{\"standard\":{\"_0\":$BUTTON}}"
TILT_LEFT_BUTTON='{"hidpp":{"_0":91}}'
TILT_RIGHT_BUTTON='{"hidpp":{"_0":93}}'

fail() { echo "FAIL: $*"; echo "--- 앱 로그"; cat "$APP_LOG" 2>/dev/null; exit 1; }
wait_for() { # 조건 명령, 최대 초
    for _ in $(seq 1 $(($2 * 4))); do
        eval "$1" && return 0
        sleep 0.25
    done
    return 1
}

[ -x "$BIN" ] || { echo "$BIN 이 없다: scripts/build-app.sh 먼저" >&2; exit 1; }
if pgrep -qfi openlogi; then echo "OpenLogi가 떠 있다: agent도 kill 하고 다시" >&2; exit 1; fi

cleanup() {
    [ -n "$APP_PID" ] && kill -TERM "$APP_PID" 2>/dev/null
    "$BIN" --undivert >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

write_profile() { # 인자마다 "버튼JSON" 하나. F19를 매핑한다
    local bindings=""
    for button in "$@"; do bindings="$bindings${bindings:+,}{\"button\":$button,\"keys\":{\"keyCode\":$F19,\"modifiers\":0}}"; done
    echo "{\"activeID\":\"$PROFILE_ID\",\"profiles\":[{\"id\":\"$PROFILE_ID\",\"name\":\"check\",\"bindings\":[$bindings]}]}" >"$PROFILES"
}

diverted_cids() { "$BIN" --dump | grep -a ' diverted$' | sed -E 's/.*cid=(0x[0-9A-F]+).*/\1/' | sort | tr '\n' ' ' | sed 's/ $//'; }

start_app() {
    : >"$APP_LOG"
    FREELOGI_PROFILES_PATH="$PROFILES" "$BIN" >/dev/null 2>>"$APP_LOG" &
    APP_PID=$!
    wait_for "grep -q '^engine: ready' '$APP_LOG'" 10 || fail "앱이 시작되지 않았다"
}

stop_app() { # 신호 이름
    kill "-$1" "$APP_PID"
    wait_for "! kill -0 $APP_PID 2>/dev/null" 15 || fail "$1 뒤에도 앱이 안 끝났다"
    wait "$APP_PID" 2>/dev/null
    APP_PID=""
}

expect_diverted() { # 설명, 기대 CID 목록(공백 구분)
    local actual
    actual="$(diverted_cids)"
    echo "$1: --dump diverted = [${actual}]"
    [ "$actual" = "$2" ] || fail "$1: 기대 [$2], 실제 [$actual]"
}

echo "== 준비: 전체 divert 풀기 (버튼 $BUTTON, 로그 $APP_LOG)"
"$BIN" --undivert 2>/dev/null
expect_diverted "시작 전" ""

# 관찰자·합성 클릭은 한 번 컴파일해 둔다(swift 인터프리터는 실행마다 몇 초 걸린다)
swiftc -O scripts/observe-keys.swift -o "$WORK/observe-keys" 2>/dev/null || fail "observe-keys 컴파일 실패"
swiftc -O scripts/post-button.swift -o "$WORK/post-button" 2>/dev/null || fail "post-button 컴파일 실패"

observe_click() { # 합성 클릭을 post하고 관찰자가 본 키 이벤트를 OBSERVED, post 결과를 POSTED에 담는다
    local out="$WORK/observed.txt"
    "$WORK/observe-keys" 2 >"$out" &
    local observer=$!
    wait_for "grep -q '^ready' '$out'" 10 || fail "관찰자가 준비되지 않았다"
    POSTED="$("$WORK/post-button" "$BUTTON")"
    wait "$observer"
    OBSERVED="$(grep -v '^ready' "$out" | sed 's/ t=.*//')"
}

echo "== 1. 일반 버튼 $BUTTON → F19, HID++ 틸트 왼쪽($TILT_LEFT) → F19"
write_profile "$STANDARD_BUTTON" "$TILT_LEFT_BUTTON"
start_app
wait_for "grep -q 'cid $TILT_LEFT .*diverted=true' '$APP_LOG'" 10 || fail "틸트 왼쪽 divert 응답 로그가 없다"
expect_diverted "매핑된 CID만" "$TILT_LEFT"
observe_click
echo "합성 클릭: $POSTED / 관찰: $(echo "$OBSERVED" | tr '\n' '|')"
EXPECTED_KEYS="down keyCode=$F19 mods=fn
up keyCode=$F19 mods=fn"
[ "$OBSERVED" = "$EXPECTED_KEYS" ] || fail "관찰자가 F19 down·up을 못 봤다"
echo "$POSTED" | grep -q 'seen=0' || fail "원래 클릭이 삼켜지지 않았다"

echo "== 2. 매핑을 지우고 틸트 오른쪽($TILT_RIGHT)만 매핑 → SIGHUP"
write_profile "$TILT_RIGHT_BUTTON"
kill -HUP "$APP_PID"
wait_for "grep -q 'cid $TILT_RIGHT .*diverted=true' '$APP_LOG'" 10 || fail "틸트 오른쪽 divert 응답 로그가 없다"
wait_for "grep -q 'cid $TILT_LEFT .*diverted=false' '$APP_LOG'" 10 || fail "틸트 왼쪽 divert 해제 로그가 없다"
expect_diverted "프로필 변경 후" "$TILT_RIGHT"
observe_click
echo "합성 클릭: $POSTED / 관찰: ${OBSERVED:-(없음)}"
[ -z "$OBSERVED" ] || fail "매핑이 없는데 키가 나갔다"
echo "$POSTED" | grep -q 'seen=2' || fail "매핑이 없는데 원래 클릭이 통과하지 않았다"

echo "== 3. divert가 풀린 기기(재연결·잠자기 뒤 상태) → 다시 걸기"
"$BIN" --undivert 2>/dev/null
expect_diverted "외부에서 풀린 뒤" ""
: >"$APP_LOG"
kill -HUP "$APP_PID"
wait_for "grep -q 'cid $TILT_RIGHT .*diverted=true' '$APP_LOG'" 10 || fail "다시 거는 로그가 없다"
expect_diverted "다시 건 뒤" "$TILT_RIGHT"

echo "== 4. SIGTERM으로 끝내기"
stop_app TERM
expect_diverted "SIGTERM 뒤" ""

echo "== 5. SIGINT로 끝내기"
start_app
wait_for "grep -q 'cid $TILT_RIGHT .*diverted=true' '$APP_LOG'" 10 || fail "divert 응답 로그가 없다"
stop_app INT
expect_diverted "SIGINT 뒤" ""

echo "== 6. kill -9로 남은 divert를 다음 실행이 푼다"
start_app
wait_for "grep -q 'cid $TILT_RIGHT .*diverted=true' '$APP_LOG'" 10 || fail "divert 응답 로그가 없다"
kill -9 "$APP_PID"
wait "$APP_PID" 2>/dev/null
APP_PID=""
expect_diverted "kill -9 뒤(남아 있어야 한다)" "$TILT_RIGHT"
write_profile
start_app
wait_for "grep -q 'cid $TILT_RIGHT .*diverted=false' '$APP_LOG'" 10 || fail "남은 divert를 푸는 로그가 없다"
expect_diverted "매핑 없는 앱이 뜬 뒤" ""
stop_app TERM
expect_diverted "끝낸 뒤" ""

echo "OK"

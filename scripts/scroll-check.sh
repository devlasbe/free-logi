#!/bin/bash
# 47 반전·51 부드러운 스크롤 확인. scripts/build-app.sh && scripts/scroll-check.sh
# 임시 profiles.json·합성 스크롤로 반전과 픽셀 분할·거리·flags·시간을 3번 확인한다.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$PWD/build/FreeLogi.app/Contents/MacOS/FreeLogi"
WORK="$(mktemp -d)"
APP_PID=""
OBSERVER_PID=""
cleanup() {
    if [ -n "$OBSERVER_PID" ]; then kill "$OBSERVER_PID" 2>/dev/null || true; wait "$OBSERVER_PID" 2>/dev/null || true; fi
    if [ -n "$APP_PID" ]; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        for _ in $(seq 1 60); do
            kill -0 "$APP_PID" 2>/dev/null || break
            sleep 0.25
        done
        if kill -0 "$APP_PID" 2>/dev/null; then
            echo "앱 종료 지연: PID=$APP_PID, 임시 파일=$WORK" >&2
            return
        fi
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; cat "$WORK/app.log" 2>/dev/null || true; exit 1; }
wait_for() {
    for _ in $(seq 1 40); do
        grep -q "$1" "$2" && return 0
        sleep 0.25
    done
    return 1
}
[ -x "$BIN" ] || fail "scripts/build-app.sh 먼저 실행"
ps -axo comm >"$WORK/processes" || fail "프로세스 목록 조회 권한 필요"
if grep -Ei '(^|/)(FreeLogi|openlogi[^/]*)$' "$WORK/processes"; then fail "FreeLogi·OpenLogi를 종료하고 다시 실행"; fi
swiftc scripts/scroll-events.swift -o "$WORK/scroll-events"
write_profile() {
    cat >"$WORK/profiles.json" <<JSON
{"activeID":"5D498085-3D67-482E-A886-C8B77FFC62B9","profiles":[{"id":"5D498085-3D67-482E-A886-C8B77FFC62B9","name":"scroll check","bindings":[]}],"reverseVerticalScroll":$1,"reverseHorizontalScroll":$2,"smoothScrolling":${3:-false}}
JSON
}
check_event() { # phase, momentum, 기대 값
    "$WORK/scroll-events" observe >"$WORK/observed" &
    OBSERVER_PID=$!
    wait_for '^ready$' "$WORK/observed" || fail "관찰자 준비 실패"
    "$WORK/scroll-events" post "$1" "$2" >"$WORK/posted"
    wait "$OBSERVER_PID" || fail "관찰자 실패"
    OBSERVER_PID=""
    local actual
    actual="$(sed '/^ready$/d' "$WORK/observed" | cut -d' ' -f1-6)"
    [ "$actual" = "$3" ] || fail "phase=$1 momentum=$2 기대 [$3], 실제 [$actual]"
    echo "OK: phase=$1 momentum=$2 [$actual]"
}
reload_profile() {
    write_profile "$@"
    : >"$WORK/app.log"
    kill -HUP "$APP_PID"
    wait_for 'engine: 프로필 다시 읽음' "$WORK/app.log" || fail "SIGHUP 반영 실패"
    if grep -q '스크롤 탭을 만들지 못했다' "$WORK/app.log"; then fail "손쉬운 사용 권한 필요"; fi
}
check_smooth() {
    "$WORK/scroll-events" observe >"$WORK/observed" &
    OBSERVER_PID=$!
    wait_for '^ready$' "$WORK/observed" || fail "관찰자 준비 실패"
    "$WORK/scroll-events" post 0 0 >"$WORK/posted"
    wait "$OBSERVER_PID" || fail "관찰자 실패"
    OBSERVER_PID=""
    python3 - "$WORK/observed" "$WORK/posted" "$1" "$2" <<'PYTHON' || fail "부드러운 스크롤 검사 실패"
import sys
from pathlib import Path
rows = [line.split() for line in Path(sys.argv[1]).read_text().splitlines() if line != 'ready']
# 같은 때 실제 휠을 굴리면 앱이 그것도 부드럽게 보낸다. 합성 원본의 ⌘⇧가 붙은 것만 센다(2026-10-20)
rows = [row for row in rows if int(row[9]) & 0x1E0000 == 0x120000]
posted = float(Path(sys.argv[2]).read_text())
assert len(rows) >= 2, f'픽셀 이벤트가 두 개 미만: {rows}'
# flags는 수식키 4개(⇧⌃⌥⌘)만 본다. 시스템이 0x20000000 비트를 붙인다(2026-10-20)
assert all(row[6:9] == ['1', '0', '0'] for row in rows), f'원본 통과 또는 flags/phase 변경: {rows}'
assert all(0 <= float(row[10]) - posted <= 0.5 for row in rows), f'0.5초 초과: {rows}'
vertical = sum(int(row[1]) for row in rows)
horizontal = sum(int(row[4]) for row in rows)
assert (vertical, horizontal) == (int(sys.argv[3]), int(sys.argv[4])), (vertical, horizontal)
print(f'OK: smooth count={len(rows)} sum=({vertical}, {horizontal})')
PYTHON
}
write_profile true false
FREELOGI_PROFILES_PATH="$WORK/profiles.json" "$BIN" >/dev/null 2>>"$WORK/app.log" &
APP_PID=$!
wait_for '^engine: ready' "$WORK/app.log" || fail "앱 시작 실패"
for repetition in 1; do
    for axes in 'true false' 'false true' 'true true' 'false false'; do
        read -r vertical horizontal <<<"$axes"
        reload_profile "$vertical" "$horizontal"
        first='3 30 196608'
        second='-5 -50 -327680'
        if [ "$vertical" = true ]; then first='-3 -30 -196608'; fi
        if [ "$horizontal" = true ]; then second='5 50 327680'; fi
        echo "== vertical=$vertical horizontal=$horizontal"
        check_event 0 0 "$first $second"
        check_event 1 0 '3 30 196608 -5 -50 -327680'
        check_event 0 1 '3 30 196608 -5 -50 -327680'
    done
    for axes in 'false false' 'true false' 'false true' 'true true'; do
        read -r vertical horizontal <<<"$axes"
        reload_profile "$vertical" "$horizontal" true
        expected_vertical=60
        expected_horizontal=-100
        if [ "$vertical" = true ]; then expected_vertical=-60; fi
        if [ "$horizontal" = true ]; then expected_horizontal=100; fi
        check_smooth "$expected_vertical" "$expected_horizontal"
    done
    check_event 1 0 '3 30 196608 -5 -50 -327680'
    check_event 0 1 '3 30 196608 -5 -50 -327680'
    echo "OK: scroll repetition=$repetition"
done
echo OK

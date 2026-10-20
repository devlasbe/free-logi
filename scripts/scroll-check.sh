#!/bin/bash
# 47 스크롤 반전 확인. scripts/build-app.sh && scripts/scroll-check.sh
# 임시 profiles.json·합성 스크롤을 쓰고, 세션 listen 탭에서 여섯 delta 필드를 비교한다.
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
{"activeID":"5D498085-3D67-482E-A886-C8B77FFC62B9","profiles":[{"id":"5D498085-3D67-482E-A886-C8B77FFC62B9","name":"scroll check","bindings":[]}],"reverseVerticalScroll":$1,"reverseHorizontalScroll":$2}
JSON
}
check_event() { # phase, momentum, 기대 값
    "$WORK/scroll-events" observe >"$WORK/observed" &
    OBSERVER_PID=$!
    wait_for '^ready$' "$WORK/observed" || fail "관찰자 준비 실패"
    "$WORK/scroll-events" post "$1" "$2"
    wait "$OBSERVER_PID" || fail "관찰자 실패"
    OBSERVER_PID=""
    local actual
    actual="$(sed '/^ready$/d' "$WORK/observed")"
    [ "$actual" = "$3" ] || fail "phase=$1 momentum=$2 기대 [$3], 실제 [$actual]"
    echo "OK: phase=$1 momentum=$2 [$actual]"
}
write_profile true false
FREELOGI_PROFILES_PATH="$WORK/profiles.json" "$BIN" >/dev/null 2>>"$WORK/app.log" &
APP_PID=$!
wait_for '^engine: ready' "$WORK/app.log" || fail "앱 시작 실패"
for axes in 'true false' 'false true' 'true true' 'false false'; do
    read -r vertical horizontal <<<"$axes"
    write_profile "$vertical" "$horizontal"
    : >"$WORK/app.log"
    kill -HUP "$APP_PID"
    wait_for 'engine: 프로필 다시 읽음' "$WORK/app.log" || fail "SIGHUP 반영 실패"
    if grep -q '스크롤 탭을 만들지 못했다' "$WORK/app.log"; then fail "손쉬운 사용 권한 필요"; fi
    first='3 30 196608'
    second='-5 -50 -327680'
    if [ "$vertical" = true ]; then first='-3 -30 -196608'; fi
    if [ "$horizontal" = true ]; then second='5 50 327680'; fi
    echo "== vertical=$vertical horizontal=$horizontal"
    check_event 0 0 "$first $second"
    check_event 1 0 '3 30 196608 -5 -50 -327680'
    check_event 0 1 '3 30 196608 -5 -50 -327680'
done
echo OK

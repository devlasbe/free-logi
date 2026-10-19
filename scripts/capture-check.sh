#!/bin/bash
# 04 버튼 인식 확인. 사용: scripts/build-app.sh && scripts/capture-check.sh [auto]
#   인자 없음: 사람이 쓴다(10). 안내하는 버튼을 차례로 눌러 `FreeLogi --capture` 결과를 로그(.verify/capture-*.log)에 남긴다.
#              기다리는 시간은 CAPTURE_TIMEOUT(초, 기본 10). 안내된 기대값은 M585/M590 추정이다(doc/설계.md 표).
#   auto:      사람 없이 확인한다. 합성 일반 버튼(3)을 post해 `standard(3)`이 나오고 삼켜지는지 본다.
# 끝나면(Ctrl-C 포함) 인식 전과 --dump 상태를 비교하고, 달라졌으면 --undivert로 되돌린다.
# 셸에서 바이너리를 직접 실행해 터미널의 권한(입력 모니터링·손쉬운 사용)을 쓴다. OpenLogi가 떠 있으면 divert가 충돌한다.
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="build/FreeLogi.app/Contents/MacOS/FreeLogi"
TIMEOUT="${CAPTURE_TIMEOUT:-10}"
LOG=".verify/capture-$(date +%Y-%m-%d-%H%M).log"
# 안내할 버튼 "이름|기대 출력"
BUTTONS=(
    "뒤로|hidpp(0x0053)"
    "앞으로|hidpp(0x0056)"
    "가운데(휠 클릭)|hidpp(0x0052)"
    "휠 틸트 왼쪽|hidpp(0x005B)"
    "휠 틸트 오른쪽|hidpp(0x005D)"
    "제스처 버튼(MX 계열만. 없으면 그냥 기다린다)|hidpp(0x00C3)"
)

if pgrep -qfi openlogi; then
    echo "OpenLogi가 떠 있다: osascript -e 'quit app \"OpenLogi\"' 후 agent도 kill" >&2
    exit 1
fi
[ -x "$BIN" ] || { echo "$BIN 이 없다: scripts/build-app.sh 먼저" >&2; exit 1; }
mkdir -p .verify

say() { echo "$*" | tee -a "$LOG"; }
snapshot() { "$BIN" --dump | sort; }

BEFORE="$(snapshot)"
say "== 인식 전 divert 상태 ($(echo "$BEFORE" | grep -c ' diverted$')개 diverted)"

finish() {
    local after
    after="$(snapshot)"
    if [ "$after" != "$BEFORE" ]; then
        say "== divert 상태가 달라졌다 → --undivert"
        "$BIN" --undivert 2>&1 | tee -a "$LOG" >/dev/null
        after="$(snapshot)"
    fi
    if [ "$after" = "$BEFORE" ]; then
        say "== 원래 상태 복구: OK"
    else
        say "== 원래 상태 복구: FAIL (장치를 껐다 켜면 풀린다)"
        exit 1
    fi
}
trap finish EXIT
trap 'exit 130' INT TERM

if [ "${1:-}" = auto ]; then
    OUT="$(mktemp)"
    ERR="$(mktemp)"
    "$BIN" --capture "$TIMEOUT" >"$OUT" 2>"$ERR" &
    CAPTURE_PID=$!
    for _ in $(seq 1 40); do
        grep -q '^ready' "$ERR" && break
        sleep 0.25
    done
    POSTED="$(swift scripts/post-button.swift 3)"
    wait "$CAPTURE_PID" || true
    say "$(cat "$ERR")"
    say "stdout: $(cat "$OUT")"
    say "post-button: $POSTED"

    grep -q 'standard(3)' "$OUT" || { say "FAIL: standard(3)이 출력되지 않았다"; exit 1; }
    echo "$POSTED" | grep -q 'seen=0' || { say "FAIL: 합성 버튼이 삼켜지지 않았다"; exit 1; }
    grep -q 'diverted=true → 응답 받음, getCidReporting diverted=true' "$ERR" || { say "FAIL: divert 응답을 못 받았다"; exit 1; }
    grep -q '실패' "$ERR" && { say "FAIL: setCidReporting 실패가 있다"; exit 1; }
    say "OK"
    exit 0
fi

say "== 버튼을 안내대로 ${TIMEOUT}초 안에 누르세요 (로그: $LOG)"
for entry in "${BUTTONS[@]}"; do
    NAME="${entry%%|*}"
    EXPECTED="${entry##*|}"
    say "-- [$NAME]를 누르세요 (기대: $EXPECTED)"
    RESULT="$("$BIN" --capture "$TIMEOUT" 2>>"$LOG")" || RESULT="(시간 초과)"
    if [ "$RESULT" = "$EXPECTED" ]; then
        say "   → $RESULT (기대와 같음)"
    else
        say "   → $RESULT (기대와 다름)"
    fi
done

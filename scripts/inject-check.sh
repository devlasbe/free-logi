#!/bin/bash
# 06 키 주입 확인. 사용: scripts/build-app.sh && scripts/inject-check.sh
# `FreeLogi --inject`로 F19(어디에도 안 묶인 키)를 수식키 4종류로 보내고, 관찰자(scripts/observe-keys.swift)가
# 세션 탭에서 본 keyDown/keyUp의 keyCode·수식키가 기대와 같은지, 누르는 시간만큼 down과 up이 떨어져 있는지 본다.
# 화면이 잠겨 있어도, 앞 앱이 뭐든 상관없다. 셸에서 직접 실행해 터미널의 권한(입력 모니터링·손쉬운 사용)을 쓴다.
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="build/FreeLogi.app/Contents/MacOS/FreeLogi"
F19=80
HOLD_MS=300
MIN_HOLD_MS=250
OUT="$(mktemp)"
[ -x "$BIN" ] || { echo "$BIN 이 없다: scripts/build-app.sh 먼저" >&2; exit 1; }

swift scripts/observe-keys.swift 5 >"$OUT" &
OBSERVER_PID=$!
for _ in $(seq 1 120); do
    grep -q '^ready' "$OUT" && break
    sleep 0.25
done
grep -q '^ready' "$OUT" || { echo "FAIL: 관찰자가 준비되지 않았다"; cat "$OUT"; exit 1; }

"$BIN" --inject $F19 0 50
"$BIN" --inject $F19 0x20000 50           # ⇧
"$BIN" --inject $F19 0x120000 $HOLD_MS    # ⌘⇧
"$BIN" --inject $F19 0xFFFFFFFFFFFFFFFF 50 # 전부 켜도 caps lock은 걸러진다. F키는 실제 키보드처럼 fn이 붙는다
wait "$OBSERVER_PID"

OBSERVED="$(grep -v '^ready' "$OUT" | sed 's/ t=.*//')"
EXPECTED="down keyCode=80 mods=fn
up keyCode=80 mods=fn
down keyCode=80 mods=shift,fn
up keyCode=80 mods=shift,fn
down keyCode=80 mods=cmd,shift,fn
up keyCode=80 mods=cmd,shift,fn
down keyCode=80 mods=cmd,shift,opt,ctrl,fn
up keyCode=80 mods=cmd,shift,opt,ctrl,fn"
echo "$OBSERVED"
[ "$OBSERVED" = "$EXPECTED" ] || { echo "FAIL: 관찰한 이벤트가 기대와 다르다"; exit 1; }

HELD="$(awk '/mods=cmd,shift,fn t=/ { split($4, field, "="); times[++count] = field[2] } END { print times[2] - times[1] }' "$OUT")"
echo "⌘⇧ down→up ${HELD}ms (누르는 시간 ${HOLD_MS}ms)"
[ "$HELD" -ge "$MIN_HOLD_MS" ] || { echo "FAIL: 누르는 시간이 ${MIN_HOLD_MS}ms보다 짧다"; exit 1; }
echo OK

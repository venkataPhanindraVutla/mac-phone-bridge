#!/usr/bin/env bash
# Cross-language interop test: the real Swift Mac server (am-mac-sim) against
# the real Kotlin phone client (phone-sim), over real mutual TLS 1.3.
# Usage: scripts/interop-test.sh [--no-build]
# Needs JAVA_HOME pointing at a Java 21 JDK (phone-sim requires it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDS="$ROOT/protocol/testdata/identities"
WAIT_SECS=20

BUILD=1
if [[ "${1:-}" == "--no-build" ]]; then BUILD=0; fi

if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "error: JAVA_HOME must point to a Java 21 JDK (phone-sim needs it)." >&2
  exit 2
fi
export JAVA_HOME

MAC_PKG="$ROOT/mac/Packages/AMKit"
PHONE_BIN="$ROOT/android/tools/phone-sim/build/install/phone-sim/bin/phone-sim"

if [[ $BUILD -eq 1 ]]; then
  echo "== building am-mac-sim"
  swift build --package-path "$MAC_PKG" --product am-mac-sim >&2
  echo "== building phone-sim"
  (cd "$ROOT/android" && ./gradlew --console=plain -q :tools:phone-sim:installDist) >&2
fi
MAC_BIN="$(swift build --package-path "$MAC_PKG" --show-bin-path)/am-mac-sim"
for f in "$MAC_BIN" "$PHONE_BIN"; do
  [[ -x "$f" ]] || { echo "error: missing $f (run without --no-build)" >&2; exit 2; }
done

WORK="$(mktemp -d)"
PIDS=""
cleanup() {
  local p
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  for p in $PIDS; do wait "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- helpers ---------------------------------------------------------------
CASE_LOGS=""   # logs of the current case, for tail-on-failure
FAILED=0

new_dir() { mktemp -d "$WORK/$1.XXXXXX"; }

# start_bg <logfile> <cmd...>; sets BG_PID
start_bg() {
  local log="$1"; shift
  : > "$log"
  "$@" </dev/null >"$log" 2>&1 &
  BG_PID=$!
  PIDS="$PIDS $BG_PID"
  CASE_LOGS="$CASE_LOGS $log"
}

# wait_line <logfile> <ERE> [secs]: poll until a line matches; returns 0/1
wait_line() {
  local log="$1" re="$2" secs="${3:-$WAIT_SECS}" i=0 max
  max=$((secs * 5))
  while [[ $i -lt $max ]]; do
    if grep -Eq -- "$re" "$log" 2>/dev/null; then return 0; fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# wait_exit <pid> [secs]: poll until process is gone; sets EXIT_CODE
EXIT_CODE=""
wait_exit() {
  local pid="$1" secs="${2:-$WAIT_SECS}" i=0 max
  max=$((secs * 5))
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $i -ge $max ]]; then return 1; fi
    sleep 0.2
    i=$((i + 1))
  done
  EXIT_CODE=0
  wait "$pid" 2>/dev/null || EXIT_CODE=$?
  return 0
}

# first capture group of the first line matching ERE
extract() { sed -nE "s/$2/\\1/p" "$1" | head -n 1; }

fail_reason=""
need() {  # need <logfile> <ERE> <description>
  if ! wait_line "$1" "$2"; then
    fail_reason="timed out waiting for: $3"
    return 1
  fi
}

begin_case() { CASE_NAME="$1"; CASE_LOGS=""; fail_reason=""; }

end_case() {  # end_case <status>
  local st="$1" f
  if [[ "$st" -eq 0 ]]; then
    echo "PASS  $CASE_NAME"
  else
    echo "FAIL  $CASE_NAME: $fail_reason"
    FAILED=$((FAILED + 1))
    for f in $CASE_LOGS; do
      echo "  ---- tail of $(basename "$f") ----"
      tail -n 25 "$f" | sed 's/^/  | /'
    done
  fi
  stop_all
}

stop_all() {
  local p
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  for p in $PIDS; do wait "$p" 2>/dev/null || true; done
  PIDS=""
}

# start_mac <name> [extra flags...]; sets MAC_LOG, MAC_PID, MAC_STATE, URI, MAC_ID
start_mac() {
  local name="$1"; shift
  MAC_STATE="$(new_dir "$name-mac")"
  MAC_LOG="$WORK/$name-mac.log"
  start_bg "$MAC_LOG" "$MAC_BIN" --identity "$IDS/mac.p12" --state-dir "$MAC_STATE" \
    --port 0 --no-bonjour "$@"
  MAC_PID=$BG_PID
  wait_line "$MAC_LOG" '^PORT [0-9]+' || { fail_reason="mac-sim did not print PORT"; return 1; }
  URI="$(extract "$MAC_LOG" '^URI (.*)$')"
  MAC_ID="$(extract "$MAC_LOG" '^ID ([0-9a-f]+)$')"
  [[ -n "$URI" && -n "$MAC_ID" ]] || { fail_reason="mac-sim printed no URI/ID"; return 1; }
}

# start_phone <name> <subcommand> <state-dir> <identity.p12> [extra flags...]
# sets PHONE_LOG, PHONE_PID, PHONE_ID
start_phone() {
  local name="$1" sub="$2" state="$3" ident="$4"; shift 4
  PHONE_LOG="$WORK/$name-phone.log"
  start_bg "$PHONE_LOG" "$PHONE_BIN" "$sub" --state-dir "$state" --identity "$ident" "$@"
  PHONE_PID=$BG_PID
  PHONE_ID=""
}

phone_id() { extract "$PHONE_LOG" '^ID ([0-9a-f]+)$'; }

# ---- cases -----------------------------------------------------------------
PAIRED_PHONE_STATE=""   # kept from case 1 for case 4

case1() {
  begin_case "1 pair + connect"
  local pstate; pstate="$(new_dir c1-phone)"
  start_mac c1 --auto-confirm || return 1
  start_phone c1 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm
  need "$PHONE_LOG" '^EVENT connected shared=find\.v1,status\.v1$' "phone EVENT connected shared=find.v1,status.v1" || return 1
  need "$MAC_LOG" '^EVENT connected [0-9a-f]+ shared=find\.v1,status\.v1$' "mac EVENT connected shared=find.v1,status.v1" || return 1
  local pid; pid="$(phone_id)"
  need "$PHONE_LOG" "^EVENT paired $MAC_ID\$" "phone EVENT paired <mac id>" || return 1
  need "$MAC_LOG" "^EVENT paired $pid\$" "mac EVENT paired <phone id>" || return 1
  # keep a copy of the paired phone state (Mac port is rewritten in case 4)
  PAIRED_PHONE_STATE="$(new_dir c1-keep)"
  cp -R "$pstate/." "$PAIRED_PHONE_STATE/"
}

case2() {
  begin_case "2 status"
  local pstate; pstate="$(new_dir c2-phone)"
  start_mac c2 --auto-confirm || return 1
  start_phone c2 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm --status 55,true,3,wifi
  need "$MAC_LOG" '^EVENT status battery=55 charging=true signal=3 network=wifi$' "mac EVENT status battery=55 charging=true signal=3 network=wifi" || return 1
}

case3() {
  begin_case "3 ring"
  local pstate; pstate="$(new_dir c3-phone)"
  start_mac c3 --auto-confirm --ring-after-connect || return 1
  start_phone c3 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm
  need "$PHONE_LOG" '^EVENT ring$' "phone EVENT ring" || return 1
  need "$MAC_LOG" '^EVENT ring-state ringing=true silent=false$' "mac EVENT ring-state ringing=true silent=false" || return 1
}

case4() {
  begin_case "4 stranger (pinned phone state, wrong certificate)"
  [[ -n "$PAIRED_PHONE_STATE" ]] || { fail_reason="case 1 did not produce a paired phone state"; return 1; }
  local pstate; pstate="$(new_dir c4-phone)"
  cp -R "$PAIRED_PHONE_STATE/." "$pstate/"
  # A fresh Mac (no paired phones) on a new port; point the copied state at it.
  start_mac c4 --auto-confirm || return 1
  local port; port="$(extract "$MAC_LOG" '^PORT ([0-9]+)$')"
  local f="$pstate/paired-macs.json"
  [[ -f "$f" ]] || { fail_reason="phone state has no paired-macs.json"; return 1; }
  sed -E "s/(\"lastPort\"[[:space:]]*:[[:space:]]*)[0-9]+/\\1$port/" "$f" > "$f.new" && mv "$f.new" "$f"
  grep -Eq "\"lastPort\"[[:space:]]*:[[:space:]]*$port" "$f" || { fail_reason="could not rewrite lastPort in $f"; return 1; }
  start_phone c4 connect "$pstate" "$IDS/stranger.p12"
  need "$MAC_LOG" '^EVENT rejected not-paired-certificate$' "mac EVENT rejected not-paired-certificate" || return 1
  need "$PHONE_LOG" '^EVENT failed [A-Z_]+$' "phone EVENT failed <reason>" || return 1
  wait_exit "$PHONE_PID" || { fail_reason="phone-sim did not exit"; return 1; }
  [[ "$EXIT_CODE" -ne 0 ]] || { fail_reason="phone-sim exited 0, expected non-zero"; return 1; }
}

case5() {
  begin_case "5 reused QR"
  local p1 p2; p1="$(new_dir c5-phone1)"; p2="$(new_dir c5-phone2)"
  start_mac c5 --auto-confirm || return 1
  start_phone c5a pair "$p1" "$IDS/phone.p12" --uri "$URI" --auto-confirm
  need "$PHONE_LOG" '^EVENT connected shared=' "first pairing connected" || return 1
  kill "$PHONE_PID" 2>/dev/null || true
  # second pairing with the very same URI, from a clean state dir
  start_phone c5b pair "$p2" "$IDS/phone.p12" --uri "$URI" --auto-confirm
  need "$PHONE_LOG" '^EVENT failed EXPIRED$' "phone EVENT failed EXPIRED" || return 1
  wait_exit "$PHONE_PID" || { fail_reason="phone-sim did not exit"; return 1; }
  [[ "$EXIT_CODE" -eq 1 ]] || { fail_reason="phone-sim exit $EXIT_CODE, expected 1"; return 1; }
}

case6() {
  begin_case "6 notify (post, invoke with reply)"
  local pstate; pstate="$(new_dir c6-phone)"
  start_mac c6 --auto-confirm --echo-notify || return 1
  start_phone c6 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm --notify
  need "$PHONE_LOG" '^EVENT connected shared=find\.v1,notify\.v1,status\.v1$' "phone EVENT connected shared=find.v1,notify.v1,status.v1" || return 1
  need "$MAC_LOG" '^EVENT notify-posted key=0\|com\.whatsapp\|1\|null\|10123 title=Ana text=hi .* alert=true$' "mac EVENT notify-posted for the vector's notification" || return 1
  need "$PHONE_LOG" '^EVENT notify-invoke key=0\|com\.whatsapp\|1\|null\|10123 action=0 reply=hi$' "phone EVENT notify-invoke action=0 reply=hi" || return 1
  wait_exit "$PHONE_PID" || { fail_reason="phone-sim did not exit"; return 1; }
  [[ "$EXIT_CODE" -eq 0 ]] || { fail_reason="phone-sim exit $EXIT_CODE, expected 0"; return 1; }
}

run_case() {
  local rc=0
  "$1" || rc=$?
  end_case "$rc"
}

run_case case1
run_case case2
run_case case3
run_case case4
run_case case5
run_case case6

echo
if [[ $FAILED -eq 0 ]]; then
  echo "interop: all 6 cases passed"
else
  echo "interop: $FAILED case(s) failed"
  exit 1
fi

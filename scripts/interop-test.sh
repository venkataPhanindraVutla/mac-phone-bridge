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

command -v python3 >/dev/null || { echo "interop: python3 required"; exit 2; }

MAC_PKG="$ROOT/mac/Packages/AMKit"
PHONE_BIN="$ROOT/android/tools/phone-sim/build/install/phone-sim/bin/phone-sim"

if [[ $BUILD -eq 1 ]]; then
  echo "== building am-mac-sim"
  swift build --force-resolved-versions --package-path "$MAC_PKG" --product am-mac-sim >&2
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
  # A stopped process (case 11's kill -STOP) ignores SIGTERM until continued; wait would hang.
  for p in $PIDS; do kill -CONT "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
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
need() {  # need <logfile> <ERE> <description> [secs]
  if ! wait_line "$1" "$2" "${4:-$WAIT_SECS}"; then
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
  for p in $PIDS; do kill -CONT "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
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
  need "$MAC_LOG" '^EVENT status battery=55 charging=true signal=3 network=wifi restricted=false$' "mac EVENT status battery=55 charging=true signal=3 network=wifi restricted=false" || return 1
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

# files_case <n> <label> <bytes>: phone-sim sends <bytes> deterministic bytes, the Mac stores them and
# sends the file back; both sides print the SHA-256 of what they received.
EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
# SHA-256 of phone-sim's deterministic source: byte i = (i*131 + (i>>8)*7 + 17) & 0xff
source_sha() {
  python3 - "$1" <<'PY'
import hashlib, sys
n = int(sys.argv[1]); h = hashlib.sha256()
# The source repeats every 65536 bytes: hash whole periods, then the remainder.
period = bytes(((i * 131 + (i >> 8) * 7 + 17) & 0xff) for i in range(65536))
for _ in range(n // 65536):
    h.update(period)
h.update(period[: n % 65536])
print(h.hexdigest())
PY
}

files_case() {
  local n="$1" label="$2" bytes="$3" wait="${4:-$WAIT_SECS}" want
  begin_case "$n $label"
  if [[ "$bytes" -eq 0 ]]; then want="$EMPTY_SHA"; else want="$(source_sha "$bytes")"; fi
  [[ -n "$want" ]] || { fail_reason="could not compute the source sha256"; return 1; }
  local pstate fdir; pstate="$(new_dir c$n-phone)"; fdir="$(new_dir c$n-files)"
  start_mac "c$n" --auto-confirm --files "$fdir" || return 1
  start_phone "c$n" pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm --send-bytes "$bytes"
  need "$MAC_LOG" "^EVENT files-received bytes=$bytes sha256=[0-9a-f]{64} mbps=" "mac EVENT files-received bytes=$bytes" "$wait" || return 1
  need "$PHONE_LOG" "^EVENT files-received bytes=$bytes sha256=[0-9a-f]{64} mbps=" "phone EVENT files-received bytes=$bytes" "$wait" || return 1
  wait_exit "$PHONE_PID" "$wait" || { fail_reason="phone-sim did not exit"; return 1; }
  [[ "$EXIT_CODE" -eq 0 ]] || { fail_reason="phone-sim exit $EXIT_CODE, expected 0"; return 1; }
  local mac_sha phone_sha
  mac_sha="$(extract "$MAC_LOG" '^EVENT files-received bytes=[0-9]+ sha256=([0-9a-f]+) .*$')"
  phone_sha="$(extract "$PHONE_LOG" '^EVENT files-received bytes=[0-9]+ sha256=([0-9a-f]+) .*$')"
  [[ "$mac_sha" == "$want" ]] || { fail_reason="mac sha256 $mac_sha != source $want"; return 1; }
  [[ "$phone_sha" == "$want" ]] || { fail_reason="phone sha256 $phone_sha != source $want"; return 1; }
  P2M="$(extract "$MAC_LOG" '^EVENT files-received .* mbps=([0-9.]+)$')"
  M2P="$(extract "$PHONE_LOG" '^EVENT files-received .* mbps=([0-9.]+)$')"
}

P2M=""; M2P=""
case7() {
  files_case 7 "files 64 MiB both ways" 67108864 60 || return 1
  echo "interop: 64 MiB phone→mac $P2M MB/s, mac→phone $M2P MB/s"
}

case8() { files_case 8 "files 0 bytes both ways" 0; }

MEDIA_MS=""
case9() {
  begin_case "9 media toggle round trip"
  local pstate; pstate="$(new_dir c9-phone)"
  start_mac c9 --auto-confirm --media-toggle || return 1
  start_phone c9 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm --media
  need "$MAC_LOG" '^EVENT media-roundtrip ms=[0-9]+$' "mac EVENT media-roundtrip ms=<n>" || return 1
  need "$PHONE_LOG" '^EVENT media-command kind=TOGGLE playing=true$' "phone EVENT media-command kind=TOGGLE playing=true" || return 1
  MEDIA_MS="$(extract "$MAC_LOG" '^EVENT media-roundtrip ms=([0-9]+)$')"
  [[ "$MEDIA_MS" -lt 300 ]] || { fail_reason="media round trip $MEDIA_MS ms, expected < 300"; return 1; }
  wait_exit "$PHONE_PID" || { fail_reason="phone-sim did not exit after the second TOGGLE"; return 1; }
  [[ "$EXIT_CODE" -eq 0 ]] || { fail_reason="phone-sim exit $EXIT_CODE, expected 0"; return 1; }
  echo "interop: media toggle round trip $MEDIA_MS ms"
}

# liveness.v1 (SPEC 7): the Mac pings every --ping-interval-ms and drops after 3 silent intervals.
case10() {
  begin_case "10 liveness: Mac pings keep a quiet phone connected"
  local pstate pings; pstate="$(new_dir c10-phone)"
  start_mac c10 --auto-confirm --liveness --ping-interval-ms 200 || return 1
  start_phone c10 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm --liveness
  need "$PHONE_LOG" '^EVENT connected shared=find\.v1,liveness\.v1,status\.v1$' "phone EVENT connected shared=find.v1,liveness.v1,status.v1" || return 1
  need "$MAC_LOG" '^EVENT connected [0-9a-f]+ shared=find\.v1,liveness\.v1,status\.v1$' "mac EVENT connected shared=find.v1,liveness.v1,status.v1" || return 1
  # The Mac pings every 200 ms and drops the phone after 3 silent intervals (600 ms). For 3 s, five
  # drop windows, the phone must stay connected and keep answering: pings answered in each half,
  # not only at the start. The count is loose (2 of the ~7 sent per half): a busy runner delays
  # pings (once 9 of 15 in 3 s), but a Mac that stopped pinging leaves a half with none, and a
  # phone that stopped answering is dropped, which the disconnect check below catches.
  sleep 1.5
  first="$(grep -c '^EVENT mac-ping$' "$PHONE_LOG" || true)"
  sleep 1.5
  pings="$(grep -c '^EVENT mac-ping$' "$PHONE_LOG" || true)"
  [[ "$first" -ge 2 && $((pings - first)) -ge 2 ]] || {
    fail_reason="phone answered $first Mac pings in the first 1.5 s and $((pings - first)) in the next, expected >= 2 in each"
    return 1
  }
  if grep -Eq '^EVENT disconnected' "$MAC_LOG"; then fail_reason="mac dropped a phone that answers its pings"; return 1; fi
}

case11() {
  begin_case "11 liveness: frozen phone is dropped"
  local pstate rc=0; pstate="$(new_dir c11-phone)"
  start_mac c11 --auto-confirm --liveness --ping-interval-ms 200 || return 1
  start_phone c11 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm --liveness
  need "$PHONE_LOG" '^EVENT connected shared=find\.v1,liveness\.v1,status\.v1$' "phone EVENT connected shared=find.v1,liveness.v1,status.v1" || return 1
  need "$MAC_LOG" '^EVENT connected [0-9a-f]+ shared=find\.v1,liveness\.v1,status\.v1$' "mac EVENT connected shared=find.v1,liveness.v1,status.v1" || return 1
  need "$PHONE_LOG" '^EVENT mac-ping$' "phone EVENT mac-ping before the freeze" || return 1
  if grep -Eq '^EVENT disconnected' "$MAC_LOG"; then fail_reason="mac dropped the phone before the freeze"; return 1; fi
  # The socket stays open and the kernel still ACKs, but nothing answers the Mac's pings. The drop
  # rule takes 3 x 200 ms plus the TLS close; nothing else would drop a frozen phone for minutes,
  # so the 10 s bound still shows the rule at work while leaving a busy runner room.
  kill -STOP "$PHONE_PID"
  need "$MAC_LOG" '^EVENT disconnected [0-9a-f]+$' "mac EVENT disconnected <phone id> within 10 s of the freeze (3 x 200 ms plus TLS close)" 10 || rc=1
  kill -CONT "$PHONE_PID" 2>/dev/null || true
  return $rc
}

case12() {
  begin_case "12 liveness Mac, legacy phone: no pings"
  local pstate; pstate="$(new_dir c12-phone)"
  start_mac c12 --auto-confirm --liveness --ping-interval-ms 200 || return 1
  start_phone c12 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm
  need "$PHONE_LOG" '^EVENT connected shared=find\.v1,status\.v1$' "phone EVENT connected shared=find.v1,status.v1" || return 1
  need "$MAC_LOG" '^EVENT connected [0-9a-f]+ shared=find\.v1,status\.v1$' "mac EVENT connected shared=find.v1,status.v1" || return 1
  sleep 2
  if grep -q '^EVENT mac-ping$' "$PHONE_LOG"; then fail_reason="the Mac pinged a phone without liveness.v1"; return 1; fi
  if grep -Eq '^EVENT disconnected' "$MAC_LOG"; then fail_reason="mac dropped a legacy phone within 2 s"; return 1; fi
}

# An old Mac (no liveness.v1) with a new phone: 0.1 rules. The phone pings at its sim-speed 0.1
# cadence and the Mac answers; the Mac's silence rule (sim speed) never fires.
case13() {
  begin_case "13 legacy Mac, liveness phone: the phone's pings keep it up"
  local pstate; pstate="$(new_dir c13-phone)"
  start_mac c13 --auto-confirm --silence-ms 750 || return 1
  start_phone c13 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm --liveness --ping-interval-ms 300
  need "$PHONE_LOG" '^EVENT connected shared=find\.v1,status\.v1$' "phone EVENT connected shared=find.v1,status.v1 (no liveness.v1)" || return 1
  need "$MAC_LOG" '^EVENT connected [0-9a-f]+ shared=find\.v1,status\.v1$' "mac EVENT connected shared=find.v1,status.v1" || return 1
  # 3 x the phone's sim-speed 45 s (450 ms), and well past the Mac's sim-speed 75 s (750 ms).
  sleep 2
  if grep -q '^EVENT mac-ping$' "$PHONE_LOG"; then fail_reason="a Mac without liveness.v1 pinged the phone"; return 1; fi
  if grep -Eq '^EVENT disconnected' "$PHONE_LOG"; then fail_reason="phone dropped the session (its pings unanswered?)"; return 1; fi
  if grep -Eq '^EVENT disconnected' "$MAC_LOG"; then fail_reason="mac dropped a phone that pings (silence rule)"; return 1; fi
}

# Mirror relay (F-17): phone-sim plays the canned 60-frame H.264 sample (paced by its PTS) on the
# Mac's mirror.start; the Mac decodes it headless (or only parses it, when VideoToolbox can't
# decode in this session), touches the centre once, and stops after 60 frames. The frames must
# arrive over at least 900 ms (the sample spans 983 ms of PTS): proof they were paced, not a burst.
MIRROR_SAMPLE="$ROOT/protocol/testdata/mirror/sample-h264-320x640.scrcpy"
case14() {
  begin_case "14 mirror relay"
  local pstate how span; pstate="$(new_dir c14-phone)"
  start_mac c14 --auto-confirm --mirror || return 1
  local mac_pid=$MAC_PID
  start_phone c14 pair "$pstate" "$IDS/phone.p12" --uri "$URI" --auto-confirm --mirror-relay "$MIRROR_SAMPLE"
  need "$MAC_LOG" '^EVENT mirror-frames (decoded|parsed)=60 size=320x640$' "mac EVENT mirror-frames (decoded|parsed)=60 size=320x640" || return 1
  need "$PHONE_LOG" '^EVENT mirror-control type=2 action=0$' "phone EVENT mirror-control type=2 action=0" || return 1
  need "$PHONE_LOG" '^EVENT mirror-control type=2 action=1$' "phone EVENT mirror-control type=2 action=1" || return 1
  need "$PHONE_LOG" '^EVENT mirror-token-reuse refused$' "phone EVENT mirror-token-reuse refused" || return 1
  need "$PHONE_LOG" '^EVENT mirror-stop$' "phone EVENT mirror-stop" || return 1
  span="$(extract "$MAC_LOG" '^EVENT mirror-span ms=([0-9]+)$')"
  [[ -n "$span" && "$span" -ge 900 ]] || { fail_reason="frames arrived over ${span:-?} ms, expected >= 900 (paced)"; return 1; }
  wait_exit "$PHONE_PID" || { fail_reason="phone-sim did not exit after mirror-stop"; return 1; }
  [[ "$EXIT_CODE" -eq 0 ]] || { fail_reason="phone-sim exit $EXIT_CODE, expected 0"; return 1; }
  wait_exit "$mac_pid" || { fail_reason="mac-sim did not exit after the stop"; return 1; }
  [[ "$EXIT_CODE" -eq 0 ]] || { fail_reason="mac-sim exit $EXIT_CODE, expected 0"; return 1; }
  how="$(extract "$MAC_LOG" '^EVENT mirror-frames (decoded|parsed)=60 .*$')"
  echo "interop: mirror relay 60 frames 320x640 ($how) over $span ms"
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
run_case case7
run_case case8
run_case case9
run_case case10
run_case case11
run_case case12
run_case case13
run_case case14

echo
if [[ $FAILED -eq 0 ]]; then
  echo "interop: all 14 cases passed"
else
  echo "interop: $FAILED case(s) failed"
  exit 1
fi

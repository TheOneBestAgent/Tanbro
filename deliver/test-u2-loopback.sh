#!/usr/bin/env bash
# Phases 2 + 4 of the u2.jar loopback fix plan, in one command.
#
# Needs: adb (phone plugged in by USB, debugging authorized), curl, python3.
# THIS computer must be on the SAME Wi-Fi as the phone: it acts as the
# "second device" that tries to reach http://<phone-ip>:9008 over the network.
#
# Usage:   ./test-u2-loopback.sh
# Options (env vars):
#   PHONE_IP=192.168.1.23   phone's Wi-Fi IP, if auto-detection fails
#   ANDROID_SERIAL=xxxx     pick a device when more than one is attached
#   SKIP_PYTHON=1           skip the real-client (uiautomator2 3.7.1) test
#
# Writes: claude-cloud-u2-0.4.1-loopback.device-verification.txt next to this script.
# Exit code 0 only if every acceptance check passes.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHED="$HERE/claude-cloud-u2-0.4.1-loopback.jar"
PATCHED_SHA=9eb6a26c9393caf4face0898d80a520dd65e24afc2441ec2aca96e6e9627a446
UPSTREAM="$HERE/u2-0.4.1-upstream.jar"
UPSTREAM_SHA=87c8ac9505970d42aa5922baa90114808fda6f47f9e5fbd4caa0f621c2c8d30d
UPSTREAM_URL=https://github.com/openatx/android-uiautomator-server-jar/releases/download/0.4.1/u2.jar
OUT="$HERE/claude-cloud-u2-0.4.1-loopback.device-verification.txt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/u2test.XXXXXX")"
FWD=19008
CURL=(curl -s --noproxy '*')

: > "$OUT"
log()  { printf '%s\n' "$*" | tee -a "$OUT"; }
run()  { log "\$ $*"; "$@" 2>&1 | tr -d '\r' | tee -a "$OUT"; return "${PIPESTATUS[0]}"; }
die()  { log "STOP: $*"; exit 2; }
declare -a RESULTS=()
check() { # check <PASS|FAIL> <text>
  RESULTS+=("$1  $2"); log ">>> $1: $2"
}

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
ash() { adb shell "$@" 2>&1 | tr -d '\r'; }

# ---------- preflight ----------
for t in adb curl; do command -v $t >/dev/null || die "'$t' not found in PATH"; done
log "u2.jar loopback fix: device verification   $(date -u +%FT%TZ)"
log "host: $(uname -srm)   adb: $(adb version | head -1)"
n=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
if [ -z "${ANDROID_SERIAL:-}" ]; then
  [ "$n" = 1 ] || die "need exactly 1 authorized device (found $n). Set ANDROID_SERIAL to choose."
fi
log "device: $(ash getprop ro.product.manufacturer) $(ash getprop ro.product.model), Android $(ash getprop ro.build.version.release) (SDK $(ash getprop ro.build.version.sdk))"

[ -f "$PATCHED" ] || die "patched jar not found at $PATCHED"
got=$(sha256 "$PATCHED"); log "patched sha256: $got"
[ "$got" = "$PATCHED_SHA" ] || die "patched jar hash mismatch (expected $PATCHED_SHA)"
if [ ! -f "$UPSTREAM" ]; then
  log "downloading upstream 0.4.1 jar for the baseline..."
  curl -fsSL -o "$UPSTREAM" "$UPSTREAM_URL" || die "download failed: $UPSTREAM_URL"
fi
got=$(sha256 "$UPSTREAM"); log "upstream sha256: $got"
[ "$got" = "$UPSTREAM_SHA" ] || die "upstream jar hash mismatch (expected $UPSTREAM_SHA)"

if [ -z "${PHONE_IP:-}" ]; then
  PHONE_IP=$(ash ip -4 addr show wlan0 | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
  [ -n "$PHONE_IP" ] || PHONE_IP=$(ash ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[ -n "$PHONE_IP" ] || die "could not find the phone's Wi-Fi IP. Is Wi-Fi on? Re-run with PHONE_IP=..."
log "phone IP: $PHONE_IP"

KB_BEFORE=$(ash pm list packages com.github.uiautomator)

# ---------- helpers ----------
stop_server() {
  adb forward tcp:$FWD tcp:9008 >/dev/null 2>&1 && "${CURL[@]}" -m3 "http://127.0.0.1:$FWD/stop" >/dev/null 2>&1
  adb forward --remove tcp:$FWD >/dev/null 2>&1
  ash 'pkill -f com.wetest.uia2.Main' >/dev/null 2>&1
  sleep 1
}

# Prints one word: exposed | loopback | none, and logs the raw evidence.
listener_state() {
  local raw procs
  raw=$(ash 'ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null' | grep -E '[:.]9008([^0-9]|$)')
  # /proc/net is the fallback, and works without ss/netstat. 2330 = port 9008 in hex, 0A = LISTEN
  procs=$(ash 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' | awk '$4=="0A" && $2 ~ /:2330$/ {print $2}')
  { echo "  ss/netstat: ${raw:-<nothing>}"; echo "  /proc/net listen addrs: ${procs:-<nothing>}"; } >> "$OUT"
  local exposed=0 loop=0 a
  for a in $procs; do
    case "${a%:*}" in
      0100007F|0000000000000000FFFF00000100007F|00000000000000000000000001000000) loop=1 ;;
      *) exposed=1 ;;
    esac
  done
  if [ -z "$procs" ] && [ -n "$raw" ]; then   # /proc unreadable: use the ss text
    echo "$raw" | grep -qE '(\*|0\.0\.0\.0|::|\[::\]):9008' && exposed=1
    echo "$raw" | grep -qE '127\.0\.0\.1:9008' && loop=1
  fi
  if [ $exposed = 1 ]; then echo exposed; elif [ $loop = 1 ]; then echo loopback; else echo none; fi
}

# start_jar <jar>: push and launch exactly as uiautomator2 does
start_jar() {
  stop_server
  run adb push "$1" /data/local/tmp/u2.jar >/dev/null
  adb shell 'CLASSPATH=/data/local/tmp/u2.jar nohup app_process / com.wetest.uia2.Main -p 9008 >/data/local/tmp/u2.log 2>&1 </dev/null &' >/dev/null 2>&1 &
  local _i; for _i in $(seq 1 15); do sleep 1; ash 'grep -q "listening on" /data/local/tmp/u2.log && echo ready' | grep -q ready && break; done
  sleep 1
}

net_ping()    { "${CURL[@]}" -m3 "http://$PHONE_IP:9008/ping" 2>/dev/null; }
tunnel_ping() { adb forward tcp:$FWD tcp:9008 >/dev/null && "${CURL[@]}" -m3 "http://127.0.0.1:$FWD/ping" 2>/dev/null; }

# ---------- Phase 2: BASELINE (upstream) ----------
log ""; log "================ BASELINE (upstream) ================"
start_jar "$UPSTREAM"
run adb shell cat /data/local/tmp/u2.log | tail -5 >/dev/null
st=$(listener_state); log "listener: $st"
nr=$(net_ping); log "network ping from this host -> http://$PHONE_IP:9008/ping : '${nr:-<no response>}'"
tr_=$(tunnel_ping); log "tunnel ping -> '${tr_:-<no response>}'"
stop_server
BASE_NET_OK=0
[ "$st" = exposed ] && check PASS "baseline listener is on all interfaces (bug reproduced)" || check FAIL "baseline listener not exposed (state=$st)"
if [ "$nr" = pong ]; then BASE_NET_OK=1; check PASS "baseline reachable over Wi-Fi (bug reproduced)";
else check FAIL "baseline NOT reachable over Wi-Fi: this network blocks device-to-device traffic (client isolation?) or this host is not on the phone's Wi-Fi, so the network test proves nothing. Use another network."; fi

# ---------- Phase 4: PATCHED ----------
log ""; log "================ PATCHED ================"
start_jar "$PATCHED"
run adb shell cat /data/local/tmp/u2.log | tail -5 >/dev/null
ash cat /data/local/tmp/u2.log | grep -q 'listening on 127.0.0.1:9008' \
  && check PASS "log says 'listening on 127.0.0.1:9008'" || check FAIL "log line 'listening on 127.0.0.1:9008' missing"
st=$(listener_state); log "listener: $st"
[ "$st" = loopback ] && check PASS "listener is loopback only" || check FAIL "listener state is '$st' (want loopback)"
nr=$(net_ping); rc=$?; log "network ping from this host -> '${nr:-<no response>}' (curl exit $rc)"
if [ "$nr" = pong ]; then check FAIL "patched server REACHABLE over Wi-Fi";
elif [ $BASE_NET_OK = 1 ]; then check PASS "patched server not reachable over Wi-Fi";
else check FAIL "patched server not reachable over Wi-Fi, but inconclusive (baseline wasn't reachable either)"; fi
tr_=$(tunnel_ping); log "tunnel ping -> '${tr_:-<no response>}'"
[ "$tr_" = pong ] && check PASS "adb-tunnel /ping returns pong" || check FAIL "adb-tunnel /ping failed"
stop_server

# ---------- Phase 4: real Python client ----------
if [ "${SKIP_PYTHON:-0}" != 1 ]; then
  log ""; log "================ PATCHED: uiautomator2 3.7.1 client ================"
  PY=$(command -v python3 || command -v python) || die "python3 not found (or set SKIP_PYTHON=1)"
  "$PY" -m venv "$WORK/venv" || die "venv creation failed"
  VPY="$WORK/venv/bin/python"; [ -x "$VPY" ] || VPY="$WORK/venv/Scripts/python.exe"
  "$VPY" -m pip install -q 'uiautomator2==3.7.1' >> "$OUT" 2>&1 || die "pip install uiautomator2==3.7.1 failed"
  ASSETS=$("$VPY" -c "import uiautomator2,os;print(os.path.join(os.path.dirname(uiautomator2.__file__),'assets'))" | tr -d '\r')
  cp "$PATCHED" "$ASSETS/u2.jar"
  rm -f "$ASSETS/app-uiautomator.apk"        # same as Phase 6: the keyboard app can never get installed
  ash rm -f /data/local/tmp/u2.jar >/dev/null  # make the client push its own (patched) asset
  "$VPY" - > "$WORK/py.txt" 2>&1 <<'EOF'
import uiautomator2 as u2
d = u2.connect()
i = d.info
print("info:", i.get("currentPackageName"), i.get("displayWidth"), i.get("displayHeight"))
print("nodes:", d.dump_hierarchy().count("<node"))
EOF
  tr -d '\r' < "$WORK/py.txt" | tail -20 | tee -a "$OUT"
  nodes=$(awk '/^nodes:/{print $2}' "$WORK/py.txt" | tr -d '\r')
  [ "${nodes:-0}" -gt 0 ] 2>/dev/null && check PASS "python client: info + $nodes nodes" || check FAIL "python client could not read the device"
  dev_md5=$(ash md5sum /data/local/tmp/u2.jar | cut -d' ' -f1)
  log "jar on phone after client run: md5 $dev_md5"
  [ "$dev_md5" = 91d8169a62bb4d7fcdfe6a12eb4abf47 ] && check PASS "client pushed the patched jar" || check FAIL "jar on phone is not the patched one"
  st=$(listener_state); log "listener while client server runs: $st"
  [ "$st" = loopback ] && check PASS "client-launched server is loopback only" || check FAIL "client-launched server state '$st'"
  stop_server
fi

# ---------- cleanup ----------
ash rm -f /data/local/tmp/u2.jar /data/local/tmp/u2.log >/dev/null
adb forward --remove tcp:$FWD >/dev/null 2>&1
KB_AFTER=$(ash pm list packages com.github.uiautomator)
if [ -z "$KB_BEFORE" ] && [ -n "$KB_AFTER" ]; then
  log "keyboard app got installed during the test; uninstalling"; ash pm uninstall com.github.uiautomator | tee -a "$OUT"
fi
rm -rf "$WORK"

# ---------- summary ----------
log ""; log "================ SUMMARY ================"
fail=0; for r in "${RESULTS[@]}"; do log "$r"; case "$r" in FAIL*) fail=1;; esac; done
if [ $fail = 0 ]; then log "ALL CHECKS PASSED"; else log "SOME CHECKS FAILED: do not install"; fi
log "record: $OUT"
exit $fail

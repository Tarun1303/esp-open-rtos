#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

TITLE="8 Neuron Connection"
VERSION="0.3.0"
DEV_USER="fourthlaw-dev"
DEV_GROUP="fourthlaw-dev"
APP_ROOT="/var/lib/fourthlaw-dev/projects/eight-neuron-connection"
RELEASES="$APP_ROOT/releases"
SHARED="$APP_ROOT/shared"
CURRENT="$APP_ROOT/current"
SERVICE="eight-neuron-connection.service"
PORT="8788"
PUBLIC_HOST="eight-neuron-94-136-189-216.sslip.io"
SOURCE_REPO="Tarun1303/esp-open-rtos"
SOURCE_REF="fourth-law-bootstrap"
PAYLOAD_PATH="fourth-law/releases/eight-neuron-connection-v0.3.0-closed-loop/payload.tar.gz"
PAYLOAD_SHA256="6f6b780383f22cc5fea11ec136c1747edb6ea5290b1aeecabc71373b9202c331"
PAYLOAD_BYTES="30510"
RELEASE_ID="v0.3.0-${PAYLOAD_SHA256:0:12}"
NEW_RELEASE="$RELEASES/$RELEASE_ID"
REPORT_REPO="Tarun1303/factory"
REPORT_ISSUE="7"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$(mktemp -d)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
OLD_TARGET=""
UNIT_BACKUP="$TMP/service.before"
CADDY_BACKUP="$TMP/Caddyfile.before"
SWITCHED=0
UNIT_CHANGED=0

cleanup(){ rm -rf "$TMP" "$REPORT" "$BODY"; }
kv(){ printf '%-36s %s\n' "$1" "$2"; }
post_report(){
  {
    echo "## ${TITLE} — closed-loop deployment ${VERSION}"
    echo
    echo '```text'
    cat "$REPORT"
    echo '```'
  } > "$BODY"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$REPORT_ISSUE" --repo "$REPORT_REPO" --body-file "$BODY" >/dev/null 2>&1 || true
}
rollback(){
  local rc="$1"
  echo ROLLBACK_BEGIN >> "$REPORT" 2>/dev/null || true
  systemctl stop "$SERVICE" 2>/dev/null || true
  if [ "$SWITCHED" -eq 1 ] && [ -n "$OLD_TARGET" ] && [ -d "$OLD_TARGET" ]; then
    ln -sfn "$OLD_TARGET" "$CURRENT.rollback"
    mv -Tf "$CURRENT.rollback" "$CURRENT"
  fi
  if [ "$UNIT_CHANGED" -eq 1 ] && [ -f "$UNIT_BACKUP" ]; then
    cp -a "$UNIT_BACKUP" "/etc/systemd/system/$SERVICE"
  fi
  if [ -f "$CADDY_BACKUP" ] && [ -f /etc/caddy/Caddyfile ]; then
    cp -a "$CADDY_BACKUP" /etc/caddy/Caddyfile 2>/dev/null || true
    systemctl reload caddy 2>/dev/null || true
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl start "$SERVICE" 2>/dev/null || true
  echo ROLLBACK_END >> "$REPORT" 2>/dev/null || true
  kv deployment_result FAILED >> "$REPORT" 2>/dev/null || true
  kv exit_code "$rc" >> "$REPORT" 2>/dev/null || true
  post_report
}
on_error(){ local rc=$?; rollback "$rc"; cleanup; exit "$rc"; }
trap on_error ERR
trap cleanup EXIT

{
  echo EIGHT_NEURON_CONNECTION_V030_CLOSED_LOOP_DEPLOY_BEGIN
  kv timestamp_utc "$STAMP"
  kv title "$TITLE"
  kv version "$VERSION"
  kv execution_identity "$(id -un) ($(id -u):$(id -g))"
  kv hostname "$(hostname)"
  kv service_before "$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  kv current_before "$(readlink -f "$CURRENT" 2>/dev/null || true)"
  kv fourth_law_services_restarted NO
} > "$REPORT"

for cmd in python3 systemctl curl gh base64 sha256sum tar ss grep readlink; do command -v "$cmd" >/dev/null; done
id "$DEV_USER" >/dev/null
install -d -m 0750 -o "$DEV_USER" -g "$DEV_GROUP" "$APP_ROOT" "$RELEASES" "$SHARED"
chmod 0755 "$TMP"
OLD_TARGET="$(readlink -f "$CURRENT" 2>/dev/null || true)"
[ -n "$OLD_TARGET" ] && [ -d "$OLD_TARGET" ]
[ -f "/etc/systemd/system/$SERVICE" ] && cp -a "/etc/systemd/system/$SERVICE" "$UNIT_BACKUP"

HOME=/root GH_CONFIG_DIR=/root/.config/gh \
  gh api "/repos/$SOURCE_REPO/contents/$PAYLOAD_PATH?ref=$SOURCE_REF" --jq .content \
  | tr -d '\n' | base64 -d > "$TMP/payload.tar.gz"
actual_bytes="$(wc -c < "$TMP/payload.tar.gz" | tr -d ' ')"
actual_sha="$(sha256sum "$TMP/payload.tar.gz" | awk '{print $1}')"
kv payload_bytes "$actual_bytes" >> "$REPORT"
kv payload_sha256 "$actual_sha" >> "$REPORT"
[ "$actual_bytes" = "$PAYLOAD_BYTES" ]
[ "$actual_sha" = "$PAYLOAD_SHA256" ]

mkdir -p "$TMP/unpacked"
tar -xzf "$TMP/payload.tar.gz" -C "$TMP/unpacked"
chmod -R a+rX "$TMP/unpacked"
for file in app.py engine.py static/index.html static/app.js static/styles.css tests/test_engine.py experiments/closed_loop_benchmark.py; do
  [ -s "$TMP/unpacked/$file" ]
done
python3 -m py_compile "$TMP/unpacked/app.py" "$TMP/unpacked/engine.py"

unit_output="$(runuser -u "$DEV_USER" -- bash -lc "cd '$TMP/unpacked' && python3 -m unittest discover -s tests -v" 2>&1)"
printf '%s\n' "$unit_output" > "$APP_ROOT/predeploy-v030-unit-${STAMP}.log"
chown "$DEV_USER:$DEV_GROUP" "$APP_ROOT/predeploy-v030-unit-${STAMP}.log"
printf '%s\n' "$unit_output" | grep -q '^OK$'
unit_count="$(printf '%s\n' "$unit_output" | sed -n 's/^Ran \([0-9][0-9]*\) tests.*/\1/p' | tail -n1)"
kv unit_tests "${unit_count:-unknown} PASS" >> "$REPORT"

benchmark_output="$(runuser -u "$DEV_USER" -- bash -lc "cd '$TMP/unpacked' && python3 experiments/closed_loop_benchmark.py --seeds 20 --workers 4 --max-cycles 100" 2>&1)"
printf '%s\n' "$benchmark_output" > "$APP_ROOT/predeploy-v030-benchmark-${STAMP}.log"
chown "$DEV_USER:$DEV_GROUP" "$APP_ROOT/predeploy-v030-benchmark-${STAMP}.log"
benchmark_compact="$(printf '%s\n' "$benchmark_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["passed"] is True; print(json.dumps(d,separators=(",",":")))')"
kv benchmark_20_seed "$benchmark_compact" >> "$REPORT"

staging="$RELEASES/.${RELEASE_ID}.${STAMP}.tmp"
rm -rf "$staging" "$NEW_RELEASE"
mkdir -p "$staging"
cp -a "$TMP/unpacked/." "$staging/"
printf '%s\n' "$PAYLOAD_SHA256" > "$staging/RELEASE_SHA256"
chown -R "$DEV_USER:$DEV_GROUP" "$staging"
find "$staging" -type d -exec chmod 0750 {} +
find "$staging" -type f -exec chmod 0640 {} +
chmod 0750 "$staging/run.sh"
mv "$staging" "$NEW_RELEASE"

ln -sfn "$NEW_RELEASE" "$CURRENT.next"
mv -Tf "$CURRENT.next" "$CURRENT"
SWITCHED=1
cat > "/etc/systemd/system/$SERVICE" <<UNIT
[Unit]
Description=8 Neuron Connection closed-loop emergent pattern laboratory
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$DEV_USER
Group=$DEV_GROUP
WorkingDirectory=$CURRENT
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=STATE_FILE=$SHARED/state-v3.json
ExecStart=/usr/bin/python3 $CURRENT/app.py --host 127.0.0.1 --port $PORT
Restart=always
RestartSec=2
TimeoutStopSec=15
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=$SHARED
MemoryMax=512M
CPUQuota=100%

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "/etc/systemd/system/$SERVICE"
UNIT_CHANGED=1
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

health=""
for _ in $(seq 1 80); do
  health="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || true)"
  [ -n "$health" ] && break
  sleep 0.25
done
[ -n "$health" ]
python3 - "$health" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); assert v["ok"] is True; assert v["version"] == "0.3.0"
PY

if command -v caddy >/dev/null 2>&1 && [ -f /etc/caddy/Caddyfile ]; then
  cp -a /etc/caddy/Caddyfile "$CADDY_BACKUP"
  if ! grep -q "$PUBLIC_HOST" /etc/caddy/Caddyfile; then
    cat >> /etc/caddy/Caddyfile <<CADDY

# BEGIN 8 Neuron Connection
${PUBLIC_HOST} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:${PORT}
}
# END 8 Neuron Connection
CADDY
  fi
  caddy validate --config /etc/caddy/Caddyfile >/dev/null
  systemctl reload caddy
fi

# Live closed-loop acceptance. The output label is inspected only as registry metadata.
curl -fsS -X POST "http://127.0.0.1:${PORT}/api/reset/memory" -H 'Content-Type: application/json' -d '{}' >/dev/null
teach_json="$(curl -fsS --max-time 120 -X POST "http://127.0.0.1:${PORT}/api/teach/closed-loop" -H 'Content-Type: application/json' -d '{"expression":"1+1","label":"2","max_cycles":100}')"
same_json="$(curl -fsS --max-time 30 -X POST "http://127.0.0.1:${PORT}/api/ask" -H 'Content-Type: application/json' -d '{"expression":"1+1","trials":7}')"
different_json="$(curl -fsS --max-time 30 -X POST "http://127.0.0.1:${PORT}/api/ask" -H 'Content-Type: application/json' -d '{"expression":"3+4","trials":7}')"
validate_json="$(curl -fsS --max-time 60 -X POST "http://127.0.0.1:${PORT}/api/validate" -H 'Content-Type: application/json' -d '{"trials":7,"negative_limit":4}')"
state_json="$(curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/api/state")"
acceptance="$(python3 - "$teach_json" "$same_json" "$different_json" "$validate_json" "$state_json" <<'PY'
import json,sys
teach=json.loads(sys.argv[1])["result"]
same=json.loads(sys.argv[2])["result"]
different=json.loads(sys.argv[3])["result"]
validation=json.loads(sys.argv[4])["result"]
state=json.loads(sys.argv[5])
injected=state["last_teach"]["injected_symbols"]
assert injected == ["1","+","1"], injected
assert "2" not in injected
assert teach["status"] == "VALIDATED"
assert same["recognized"] is True and same["label"] == "2"
assert different["recognized"] is False and different["status"] == "UNKNOWN"
assert validation["passed"] is True
assert abs(validation["energy_residual"]) < 1e-7
print(json.dumps({
 "status":teach["status"],"stop_reason":teach["stop_reason"],"cycles_run":teach["cycles_run"],
 "pattern_id":teach["pattern"]["pattern_id"],"injected_symbols":injected,
 "same":{"label":same["label"],"score":round(same["score"],6),"threshold":round(same["threshold"],6)},
 "different":{"status":different["status"],"score":round(different["score"],6)},
 "validation":{"known":f'{validation["known_correct"]}/{validation["known_total"]}',"unknown":f'{validation["unknown_correct"]}/{validation["unknown_total"]}',"dispersion":round(validation["structural_dispersion"],6),"energy_residual":validation["energy_residual"]}
},separators=(",",":")))
PY
)"

ui_html="$(curl -fsS "http://127.0.0.1:${PORT}/")"
printf '%s' "$ui_html" | grep -q 'Teach &amp; validate'
printf '%s' "$ui_html" | grep -q 'Run full validation'
printf '%s' "$ui_html" | grep -q '<p class="kicker">TEACH</p>'
printf '%s' "$ui_html" | grep -q '<p class="kicker">ASK</p>'
printf '%s' "$ui_html" | grep -q '<p class="kicker">OUTPUT</p>'
! printf '%s' "$ui_html" | grep -q 'Teacher pattern'

public_health="$(curl -k -fsS --resolve "${PUBLIC_HOST}:443:127.0.0.1" "https://${PUBLIC_HOST}/api/health")"
python3 - "$public_health" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); assert v["ok"] is True; assert v["version"] == "0.3.0"
PY

kv service_active "$(systemctl is-active "$SERVICE")" >> "$REPORT"
kv service_enabled "$(systemctl is-enabled "$SERVICE")" >> "$REPORT"
kv current_after "$(readlink -f "$CURRENT")" >> "$REPORT"
kv listen_address "127.0.0.1:${PORT}" >> "$REPORT"
kv api_health "$health" >> "$REPORT"
kv live_acceptance "$acceptance" >> "$REPORT"
kv ui_contract "TEACH=PASS ASK=PASS OUTPUT=PASS CLOSED_LOOP=PASS" >> "$REPORT"
kv public_route "https://${PUBLIC_HOST}/" >> "$REPORT"
kv public_health PASS >> "$REPORT"
kv previous_state_preserved "$SHARED/state-v2.json" >> "$REPORT"
kv new_state_file "$SHARED/state-v3.json" >> "$REPORT"
kv packages_installed NO >> "$REPORT"
kv fourth_law_services_restarted NO >> "$REPORT"
kv deployment_result SUCCESS >> "$REPORT"
echo EIGHT_NEURON_CONNECTION_V030_CLOSED_LOOP_DEPLOY_END >> "$REPORT"

SWITCHED=0
UNIT_CHANGED=0
post_report
cat "$REPORT"

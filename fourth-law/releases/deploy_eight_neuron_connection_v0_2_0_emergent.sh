#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

TITLE="8 Neuron Connection"
VERSION="0.2.0"
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
PAYLOAD_DIR="fourth-law/releases/eight-neuron-connection-v0.2.0-emergent-r2/payload"
PAYLOAD_B64_BYTES="31760"
PAYLOAD_B64_SHA256="cf0d9fba1332285fdf7cffd5ff973f2fbd18666c38dc9a439e87f29e10f86f0c"
PAYLOAD_SHA256="5d24c181ec61eb21603e1d2d6f1b696fae3927a8a533cb4a1ee41557fb0e5429"
RELEASE_ID="v0.2.0-${PAYLOAD_SHA256:0:12}"
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
kv(){ printf '%-33s %s\n' "$1" "$2"; }
post_report(){
  {
    echo "## ${TITLE} — emergent pattern registry deployment ${VERSION}"
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
  echo EIGHT_NEURON_CONNECTION_V020_EMERGENT_DEPLOY_BEGIN
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

chunk_hashes=(
  a8795377f0c919827b3f4f4df7444bf35cc3c3284b0b29fe4c0dc2daf5fa7613
  59b941fa32cdd11861c99fe99ea1e0deea51748b0dc4d9347dd8e63f575f61c4
  5e2ba1fdc17b5f278f81a072a37c0d698f98add502a635aeee890bc962a36ac1
  8a3a1b95e765dcbd928ce7b54bf9ea08347b142f1cf92b87a50f68063481c6db
  586441d7b282cfd911c61eb583c27f7feb15a02d4d534c93c99388abcbe7fa56
  aa216cab2bb16d85bfa121d841dbf3f54c7f1b07e17054a54d6009e7fee91608
  6593048d51de4aa9e9ac122ebb0e7e3e6b9bb59bad0bc0424ba35c53e8f1944b
  33d00f135f8983263aad2f6c80c94a4df1bef6338c21b86c528175d829c2e0da
)
: > "$TMP/payload.b64"
for i in 0 1 2 3 4 5 6 7; do
  part="$(printf '%02d' "$i")"
  source_path="$PAYLOAD_DIR/chunk_${part}.txt"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$SOURCE_REPO/contents/$source_path?ref=$SOURCE_REF" --jq .content \
    | tr -d '\n' | base64 -d > "$TMP/chunk_${part}.txt"
  actual_chunk="$(sha256sum "$TMP/chunk_${part}.txt" | awk '{print $1}')"
  [ "$actual_chunk" = "${chunk_hashes[$i]}" ]
  cat "$TMP/chunk_${part}.txt" >> "$TMP/payload.b64"
done
actual_b64_bytes="$(wc -c < "$TMP/payload.b64" | tr -d ' ')"
actual_b64_sha="$(sha256sum "$TMP/payload.b64" | awk '{print $1}')"
kv payload_b64_bytes "$actual_b64_bytes" >> "$REPORT"
kv payload_b64_sha256 "$actual_b64_sha" >> "$REPORT"
[ "$actual_b64_bytes" = "$PAYLOAD_B64_BYTES" ]
[ "$actual_b64_sha" = "$PAYLOAD_B64_SHA256" ]
base64 -d "$TMP/payload.b64" > "$TMP/payload.tar.gz"
actual_payload="$(sha256sum "$TMP/payload.tar.gz" | awk '{print $1}')"
kv payload_sha256 "$actual_payload" >> "$REPORT"
[ "$actual_payload" = "$PAYLOAD_SHA256" ]

mkdir -p "$TMP/unpacked"
tar -xzf "$TMP/payload.tar.gz" -C "$TMP/unpacked"
chmod -R a+rX "$TMP/unpacked"
for file in app.py engine.py static/index.html static/app.js static/styles.css tests/test_engine.py; do [ -s "$TMP/unpacked/$file" ]; done

# Run all model, registry, UI-contract and ledger tests before changing the active release.
test_output="$(runuser -u "$DEV_USER" -- bash -lc "cd '$TMP/unpacked' && python3 -m unittest discover -s tests -v" 2>&1)"
printf '%s\n' "$test_output" > "$APP_ROOT/predeploy-v020-${STAMP}.log"
chown "$DEV_USER:$DEV_GROUP" "$APP_ROOT/predeploy-v020-${STAMP}.log"
tests_run="$(printf '%s\n' "$test_output" | sed -n 's/^Ran \([0-9][0-9]*\) tests.*/\1/p' | tail -n1)"
printf '%s\n' "$test_output" | grep -q '^OK$'
kv tests_run "${tests_run:-unknown}" >> "$REPORT"
kv tests_result PASS >> "$REPORT"

# Install immutable release, retaining the previous release for rollback.
staging="$RELEASES/.${RELEASE_ID}.${STAMP}.tmp"
rm -rf "$staging"
mkdir -p "$staging"
cp -a "$TMP/unpacked/." "$staging/"
printf '%s\n' "$PAYLOAD_SHA256" > "$staging/RELEASE_SHA256"
chown -R "$DEV_USER:$DEV_GROUP" "$staging"
find "$staging" -type d -exec chmod 0750 {} +
find "$staging" -type f -exec chmod 0640 {} +
chmod 0750 "$staging/run.sh"
rm -rf "$NEW_RELEASE"
mv "$staging" "$NEW_RELEASE"

# Switch atomically to the new release and use a version-2 state file so v1 state is preserved.
ln -sfn "$NEW_RELEASE" "$CURRENT.next"
mv -Tf "$CURRENT.next" "$CURRENT"
SWITCHED=1
cat > "/etc/systemd/system/$SERVICE" <<UNIT
[Unit]
Description=8 Neuron Connection emergent temporal pattern laboratory
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$DEV_USER
Group=$DEV_GROUP
WorkingDirectory=$CURRENT
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=STATE_FILE=$SHARED/state-v2.json
ExecStart=/usr/bin/python3 $CURRENT/app.py --host 127.0.0.1 --port $PORT
Restart=always
RestartSec=2
TimeoutStopSec=10
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
for _ in $(seq 1 60); do
  health="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || true)"
  [ -n "$health" ] && break
  sleep 0.25
done
[ -n "$health" ]
python3 - "$health" <<'PY'
import json, sys
v=json.loads(sys.argv[1])
assert v["ok"] is True
assert v["version"] == "0.2.0"
PY

# Preserve existing public route or add it if absent.
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

# Full acceptance: label is never injected; discovered temporal pattern is registered after observation.
curl -fsS -X POST "http://127.0.0.1:${PORT}/api/reset/memory" -H 'Content-Type: application/json' -d '{}' >/dev/null
teach_json="$(curl -fsS -X POST "http://127.0.0.1:${PORT}/api/teach/batch" -H 'Content-Type: application/json' -d '{"expression":"1+1","label":"2","cycles":80}')"
same_json="$(curl -fsS -X POST "http://127.0.0.1:${PORT}/api/ask" -H 'Content-Type: application/json' -d '{"expression":"1+1","trials":9}')"
different_json="$(curl -fsS -X POST "http://127.0.0.1:${PORT}/api/ask" -H 'Content-Type: application/json' -d '{"expression":"3+4","trials":9}')"
acceptance="$(python3 - "$teach_json" "$same_json" "$different_json" <<'PY'
import json, sys
teach=json.loads(sys.argv[1])
same=json.loads(sys.argv[2])["result"]
different=json.loads(sys.argv[3])["result"]
result=teach["result"]
pattern=result["pattern"]
injected=result["injected_symbols"]
assert injected == ["1", "+", "1"], injected
assert "2" not in injected
assert pattern["label"] == "2"
assert pattern["observations"] == 80
assert same["recognized"] is True and same["label"] == "2"
assert same["score"] >= same["threshold"]
assert different["recognized"] is False and different["status"] == "UNKNOWN"
print(json.dumps({
  "pattern_id": pattern["pattern_id"],
  "label": pattern["label"],
  "observations": pattern["observations"],
  "stability": round(pattern["stability"], 6),
  "injected_symbols": injected,
  "same_input": {"recognized": same["recognized"], "label": same["label"], "score": round(same["score"], 6), "threshold": round(same["threshold"], 6)},
  "different_input": {"recognized": different["recognized"], "status": different["status"], "score": round(different["score"], 6), "threshold": round(different["threshold"], 6)},
}, separators=(",", ":")))
PY
)"

ui_html="$(curl -fsS "http://127.0.0.1:${PORT}/")"
printf '%s' "$ui_html" | grep -q '<p class="kicker">TEACH</p>'
printf '%s' "$ui_html" | grep -q '<p class="kicker">ASK</p>'
printf '%s' "$ui_html" | grep -q '<p class="kicker">OUTPUT</p>'
printf '%s' "$ui_html" | grep -q 'Advanced network view'
! printf '%s' "$ui_html" | grep -q 'Teacher pattern'

public_health="$(curl -k -fsS --resolve "${PUBLIC_HOST}:443:127.0.0.1" "https://${PUBLIC_HOST}/api/health")"
python3 - "$public_health" <<'PY'
import json, sys
v=json.loads(sys.argv[1])
assert v["ok"] is True
assert v["version"] == "0.2.0"
PY

final_health="$(curl -fsS "http://127.0.0.1:${PORT}/api/health")"
energy_residual="$(python3 - "$final_health" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["activity"]["energy_residual"])
PY
)"

kv service_active "$(systemctl is-active "$SERVICE")" >> "$REPORT"
kv service_enabled "$(systemctl is-enabled "$SERVICE")" >> "$REPORT"
kv current_after "$(readlink -f "$CURRENT")" >> "$REPORT"
kv listen_address "127.0.0.1:${PORT}" >> "$REPORT"
kv api_health "$final_health" >> "$REPORT"
kv acceptance "$acceptance" >> "$REPORT"
kv energy_residual "$energy_residual" >> "$REPORT"
kv ui_contract "TEACH=PASS ASK=PASS OUTPUT=PASS teacher_pattern_absent=PASS" >> "$REPORT"
kv public_route "https://${PUBLIC_HOST}/" >> "$REPORT"
kv public_health PASS >> "$REPORT"
kv old_state_preserved "$SHARED/state.json" >> "$REPORT"
kv new_state_file "$SHARED/state-v2.json" >> "$REPORT"
kv packages_installed NO >> "$REPORT"
kv fourth_law_services_restarted NO >> "$REPORT"
kv deployment_result SUCCESS >> "$REPORT"
echo EIGHT_NEURON_CONNECTION_V020_EMERGENT_DEPLOY_END >> "$REPORT"
post_report
cat "$REPORT"

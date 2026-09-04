#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

TITLE="8 Neuron Connection"
VERSION="0.1.0"
DEV_USER="fourthlaw-dev"
DEV_GROUP="fourthlaw-dev"
APP="/var/lib/fourthlaw-dev/projects/eight-neuron-connection"
SERVICE="eight-neuron-connection.service"
PORT="8788"
SOURCE_REPO="Tarun1303/esp-open-rtos"
SOURCE_REF="fourth-law-bootstrap"
SOURCE_DIR="fourth-law/releases"
PAYLOAD_PREFIX="eight-neuron-connection-v0.1.0.payload"
PAYLOAD_SHA256="589b18250ab7ee51504de1ef9dbb215f4242f23b76a9a74ea8af486b73483667"
REPORT_REPO="Tarun1303/factory"
REPORT_ISSUE="7"
PUBLIC_HOST="eight-neuron-94-136-189-216.sslip.io"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$(mktemp -d)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
BACKUP_ROOT="/var/lib/fourthlaw-dev/backups/eight-neuron-connection"

cleanup(){ rm -rf "$TMP" "$REPORT" "$BODY"; }
trap cleanup EXIT
kv(){ printf '%-30s %s\n' "$1" "$2"; }
post_report(){
  {
    echo "## ${TITLE} — VPS deployment ${VERSION}"
    echo
    echo '```text'
    cat "$REPORT"
    echo '```'
  } > "$BODY"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$REPORT_ISSUE" --repo "$REPORT_REPO" --body-file "$BODY" >/dev/null 2>&1
}
fail(){
  rc=$?
  kv deployment_result FAILED >> "$REPORT" 2>/dev/null || true
  kv exit_code "$rc" >> "$REPORT" 2>/dev/null || true
  post_report || true
  exit "$rc"
}
trap fail ERR

{
  echo EIGHT_NEURON_CONNECTION_DEPLOY_BEGIN
  kv timestamp_utc "$STAMP"
  kv title "$TITLE"
  kv version "$VERSION"
  kv execution_identity "$(id -un) ($(id -u):$(id -g))"
  kv hostname "$(hostname)"
  kv production_app_modified NO
} > "$REPORT"

for cmd in node npm systemctl curl gh base64 sha256sum tar ss; do command -v "$cmd" >/dev/null; done
id "$DEV_USER" >/dev/null
[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -ge 18 ]

# Fetch seven immutable payload parts from the authenticated GitHub repository.
chunk_hashes=(
  3ae3d3acb2380dfa6bd346ca718c063c57245a4bebef2658178639287d75ca04
  eaa6869ff2ef63c1be2d03b54daec5e3e53fbd63fb6a7e98b7e834100f7c77e5
  d362774631df8083e0a421b09a91e1313fe92d2424545513fded855b504e052b
  9fc1be5d359d402013efa08c04f3dbf1f993e85d46a82f8472f59d855362e6f2
  dda6f126f0a26001fb28cb18a8a4093b53c06427728b14b0651515e9444ff5b1
  fa29a0516a4b876d897e45fccf400f5e6297a7c4c05729c3bc74c008e07436d2
  5ae7f814fc1020c043c0370bfa52ce201d5a29a6c5ee93c52f432896cdf76a7f
)
: > "$TMP/payload.b64"
for i in 0 1 2 3 4 5 6; do
  part="$(printf '%02d' "$i")"
  path="$SOURCE_DIR/$PAYLOAD_PREFIX.$part"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$SOURCE_REPO/contents/$path?ref=$SOURCE_REF" --jq .content \
    | tr -d '\n' | base64 -d > "$TMP/part.$part"
  actual="$(sha256sum "$TMP/part.$part" | awk '{print $1}')"
  [ "$actual" = "${chunk_hashes[$i]}" ]
  cat "$TMP/part.$part" >> "$TMP/payload.b64"
done
base64 -d "$TMP/payload.b64" > "$TMP/payload.tar.gz"
actual_payload="$(sha256sum "$TMP/payload.tar.gz" | awk '{print $1}')"
kv payload_sha256 "$actual_payload" >> "$REPORT"
[ "$actual_payload" = "$PAYLOAD_SHA256" ]
mkdir -p "$TMP/unpacked"
tar -xzf "$TMP/payload.tar.gz" -C "$TMP/unpacked"

# Refuse to occupy another application's port.
if ss -ltnp 2>/dev/null | grep -qE "127\.0\.0\.1:${PORT}[[:space:]]|0\.0\.0\.0:${PORT}[[:space:]]"; then
  systemctl is-active --quiet "$SERVICE" || { kv port_check "port ${PORT} owned by another process" >> "$REPORT"; false; }
fi

install -d -m 0750 -o "$DEV_USER" -g "$DEV_GROUP" "$APP" "$APP/runtime" "$APP/logs" "$BACKUP_ROOT"
if [ -f "$APP/package.json" ] || [ -f "$APP/server.mjs" ] || [ -d "$APP/public" ]; then
  backup="$BACKUP_ROOT/${STAMP}.tar.gz"
  tar -C "$APP" --exclude='./runtime' --exclude='./logs' -czf "$backup" . 2>/dev/null || true
  chown "$DEV_USER:$DEV_GROUP" "$backup" 2>/dev/null || true
  kv rollback_snapshot "$backup" >> "$REPORT"
else
  kv rollback_snapshot "not required (first deployment)" >> "$REPORT"
fi

systemctl stop "$SERVICE" 2>/dev/null || true
rm -rf "$APP/src" "$APP/tests" "$APP/public"
rm -f "$APP/package.json" "$APP/server.mjs" "$APP/MODEL.md" "$APP/README.md"
cp -a "$TMP/unpacked/." "$APP/"
install -d -m 0750 -o "$DEV_USER" -g "$DEV_GROUP" "$APP/runtime" "$APP/logs"
chown -R "$DEV_USER:$DEV_GROUP" "$APP"
find "$APP" -type d -exec chmod 0750 {} +
find "$APP" -type f -exec chmod 0640 {} +

test_output="$(runuser -u "$DEV_USER" -- bash -lc "cd '$APP' && npm test" 2>&1)"
printf '%s\n' "$test_output" > "$APP/logs/deploy-test-${STAMP}.log"
chown "$DEV_USER:$DEV_GROUP" "$APP/logs/deploy-test-${STAMP}.log"
test_pass="$(printf '%s\n' "$test_output" | awk '/# pass / {print $3}' | tail -n1)"
test_fail="$(printf '%s\n' "$test_output" | awk '/# fail / {print $3}' | tail -n1)"
kv tests_passed "${test_pass:-unknown}" >> "$REPORT"
kv tests_failed "${test_fail:-unknown}" >> "$REPORT"
[ "${test_fail:-1}" = 0 ]

cat > "/etc/systemd/system/$SERVICE" <<UNIT
[Unit]
Description=8 Neuron Connection physics-driven associative prototype
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$DEV_USER
Group=$DEV_GROUP
WorkingDirectory=$APP
Environment=NODE_ENV=production
Environment=HOST=127.0.0.1
Environment=PORT=$PORT
ExecStart=/usr/bin/node $APP/server.mjs
Restart=always
RestartSec=2
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$APP/runtime $APP/logs

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "/etc/systemd/system/$SERVICE"
systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null

health=""
for _ in $(seq 1 30); do
  health="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || true)"
  [ -n "$health" ] && break
  sleep 1
done
[ -n "$health" ]
state="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/state")"
html_title="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" | grep -o '<title>[^<]*' | head -n1 | sed 's/<title>//')"

# Expose only through a separate Caddy virtual host; the Node service remains localhost-only.
proxy_status="not configured"
public_url="local-only: http://127.0.0.1:${PORT}/"
if command -v caddy >/dev/null 2>&1 && [ -f /etc/caddy/Caddyfile ] && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
  caddy_backup="$TMP/Caddyfile.before"
  cp -a /etc/caddy/Caddyfile "$caddy_backup"
  if ! grep -q "# BEGIN ${TITLE}" /etc/caddy/Caddyfile; then
    cat >> /etc/caddy/Caddyfile <<CADDY

# BEGIN ${TITLE}
${PUBLIC_HOST} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:${PORT}
}
# END ${TITLE}
CADDY
  fi
  if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    systemctl reload caddy
    proxy_status="configured and Caddy reloaded"
    public_url="https://${PUBLIC_HOST}/"
  else
    cp -a "$caddy_backup" /etc/caddy/Caddyfile
    proxy_status="validation failed; original Caddyfile restored"
  fi
fi

kv service_active "$(systemctl is-active "$SERVICE")" >> "$REPORT"
kv service_enabled "$(systemctl is-enabled "$SERVICE")" >> "$REPORT"
kv listen_address "127.0.0.1:${PORT}" >> "$REPORT"
kv local_health "$health" >> "$REPORT"
kv html_title "$html_title" >> "$REPORT"
kv api_state_bytes "${#state}" >> "$REPORT"
kv reverse_proxy "$proxy_status" >> "$REPORT"
kv ui_url "$public_url" >> "$REPORT"
kv workspace "$APP" >> "$REPORT"
kv workspace_owner "$(stat -c '%U:%G' "$APP")" >> "$REPORT"
kv codex "$(codex --version 2>&1 | head -n1 || echo missing)" >> "$REPORT"
kv packages_installed NO >> "$REPORT"
kv fourth_law_services_restarted NO >> "$REPORT"
kv deployment_result SUCCESS >> "$REPORT"
echo EIGHT_NEURON_CONNECTION_DEPLOY_END >> "$REPORT"
post_report
cat "$REPORT"

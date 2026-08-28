#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="/opt/fourth-law-agent"
LOG="/var/log/fourthlaw-install.log"
cd "$PROJECT_DIR"

printf '\n=== ENV REPAIR %s ===\n' "$(date -Is)" >> "$LOG"

# Recover secrets from the already-running container without printing them.
OPENAI_API_KEY="$(docker inspect fourth-law-agent --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^OPENAI_API_KEY=//p' | head -n1 || true)"
ADMIN_TOKEN="$(docker inspect fourth-law-agent --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^ADMIN_TOKEN=//p' | head -n1 || true)"

if [[ -z "$OPENAI_API_KEY" ]]; then
  echo "Could not recover OPENAI_API_KEY from running container." >> "$LOG"
  echo "API key recovery failed. Re-run the main installer with a valid API key."
  exit 2
fi

if [[ -z "$ADMIN_TOKEN" ]]; then
  ADMIN_TOKEN="$(openssl rand -hex 24)"
fi

cp -f .env ".env.bad.$(date +%s)" 2>/dev/null || true

{
  printf 'OPENAI_API_KEY=%s\n' "$OPENAI_API_KEY"
  printf 'ADMIN_TOKEN=%s\n' "$ADMIN_TOKEN"
  printf 'SUPERVISOR_MODEL=gpt-5.6-terra\n'
  printf 'MASTER_MODEL=gpt-5.6-terra\n'
  printf 'WORKER_MODEL=gpt-5.6-luna\n'
  printf 'MAX_CONCURRENCY=4\n'
  printf 'MAX_CHILDREN=3\n'
  printf 'MAX_AGENTS=12\n'
  printf 'DEFAULT_MAX_DEPTH=2\n'
  printf 'API_RETRIES=4\n'
  printf 'NODE_RECOVERY_ATTEMPTS=2\n'
} > .env
chmod 600 .env

# Validate file structure without exposing values.
if ! grep -q '^OPENAI_API_KEY=' .env || ! grep -q '^ADMIN_TOKEN=' .env; then
  echo "env validation failed" >> "$LOG"
  exit 3
fi

echo "env rebuilt and validated" >> "$LOG"

docker compose up -d --force-recreate >> "$LOG" 2>&1

READY=0
for i in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:8787/health >> "$LOG" 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

if [[ "$READY" != "1" ]]; then
  echo "health check failed after env repair" >> "$LOG"
  docker compose logs --tail=200 >> "$LOG" 2>&1 || true
  exit 4
fi

# Probe the OpenAI Supervisor channel, logging only the HTTP response.
HTTP_CODE="$(curl -sS -o /tmp/fourthlaw-api-check.out -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check || true)"
printf '\n=== SUPERVISOR API CHECK HTTP %s ===\n' "$HTTP_CODE" >> "$LOG"
cat /tmp/fourthlaw-api-check.out >> "$LOG" 2>&1 || true
printf '\n' >> "$LOG"
rm -f /tmp/fourthlaw-api-check.out

# Install/restore watchdog and helper command regardless of API probe result.
cat > /usr/local/bin/fourthlaw-watchdog <<'EOF'
#!/usr/bin/env bash
set -u
cd /opt/fourth-law-agent || exit 0
LOG=/var/log/fourthlaw-watchdog.log
if ! curl -fsS --max-time 8 http://127.0.0.1:8787/health >/dev/null 2>&1; then
  echo "$(date -Is) agent unhealthy -> restarting" >> "$LOG"
  docker compose restart agent >> "$LOG" 2>&1 || docker compose up -d --build agent >> "$LOG" 2>&1 || true
  sleep 8
fi
if ! docker compose ps --status running tunnel 2>/dev/null | grep -q fourth-law-tunnel; then
  echo "$(date -Is) tunnel unhealthy -> restarting" >> "$LOG"
  docker compose up -d tunnel >> "$LOG" 2>&1 || true
fi
EOF
chmod +x /usr/local/bin/fourthlaw-watchdog

cat > /etc/systemd/system/fourthlaw-watchdog.service <<'EOF'
[Unit]
Description=Fourth Law Framework self-healing watchdog
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fourthlaw-watchdog
EOF

cat > /etc/systemd/system/fourthlaw-watchdog.timer <<'EOF'
[Unit]
Description=Run Fourth Law watchdog every minute

[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload >> "$LOG" 2>&1
systemctl enable --now fourthlaw-watchdog.timer >> "$LOG" 2>&1

cat > /usr/local/bin/fourthlaw <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/fourth-law-agent
ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | cut -d= -f2-)"
URL="$(docker compose logs tunnel 2>&1 | grep -Eo 'https://[A-Za-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
if [[ -z "$URL" ]]; then
  docker compose restart tunnel >/dev/null 2>&1 || true
  sleep 5
  URL="$(docker compose logs tunnel 2>&1 | grep -Eo 'https://[A-Za-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
fi
curl -fsS http://127.0.0.1:8787/health | jq .
echo
if [[ -n "$URL" ]]; then
  echo "CONTROL CONSOLE:"
  echo "${URL}/console#token=${ADMIN_TOKEN}"
else
  echo "Tunnel URL is regenerating. Run fourthlaw again shortly."
fi
EOF
chmod +x /usr/local/bin/fourthlaw

/usr/local/bin/fourthlaw-diagnostic-sync >/dev/null 2>&1 || true

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "REPAIR_OK"
else
  echo "REPAIR_ENV_OK_API_CHECK_HTTP_${HTTP_CODE}"
fi

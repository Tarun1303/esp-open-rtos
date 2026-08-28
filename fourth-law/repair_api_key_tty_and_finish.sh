#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="/opt/fourth-law-agent"
cd "$PROJECT_DIR"

if [[ ! -r /dev/tty ]]; then
  echo "NO_TTY_AVAILABLE"
  exit 2
fi

printf 'Paste fresh OpenAI API key: ' >/dev/tty
IFS= read -r -s API_KEY </dev/tty
printf '\n' >/dev/tty

if [[ -z "$API_KEY" ]]; then
  echo "EMPTY_API_KEY"
  exit 3
fi

ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
if [[ -z "$ADMIN_TOKEN" ]]; then
  ADMIN_TOKEN="$(openssl rand -hex 24)"
fi

cat > .env <<EOF
OPENAI_API_KEY=$API_KEY
ADMIN_TOKEN=$ADMIN_TOKEN
SUPERVISOR_MODEL=gpt-5.6-terra
MASTER_MODEL=gpt-5.6-terra
WORKER_MODEL=gpt-5.6-luna
MAX_CONCURRENCY=4
MAX_CHILDREN=3
MAX_AGENTS=12
DEFAULT_MAX_DEPTH=2
API_RETRIES=4
NODE_RECOVERY_ATTEMPTS=2
EOF
chmod 600 .env
unset API_KEY

docker compose up -d --force-recreate agent >/dev/null

for i in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:8787/health >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

HTTP_CODE="$(curl -sS -o /tmp/fourthlaw_api_check.out -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check || true)"
{
  echo
  echo "=== TTY API KEY REPAIR $(date -Is) ==="
  echo "API_CHECK_HTTP=$HTTP_CODE"
  cat /tmp/fourthlaw_api_check.out 2>/dev/null || true
  echo
  docker compose ps 2>&1 || true
  docker compose logs agent --tail=80 2>&1 || true
} >> /var/log/fourthlaw-install.log
rm -f /tmp/fourthlaw_api_check.out

systemctl enable --now fourthlaw-watchdog.timer >/dev/null 2>&1 || true
/usr/local/bin/fourthlaw-diagnostic-sync >/dev/null 2>&1 || true

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "FOURTHLAW_READY"
else
  echo "API_CHECK_HTTP_$HTTP_CODE"
fi

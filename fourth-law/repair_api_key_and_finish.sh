#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="/opt/fourth-law-agent"
cd "$PROJECT_DIR"

if [[ ! -f .env ]]; then
  echo "ENV_MISSING"
  exit 1
fi

ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
[[ -n "$ADMIN_TOKEN" ]] || ADMIN_TOKEN="$(openssl rand -hex 24)"

printf '\nPaste a fresh OpenAI API key (input hidden): '
read -r -s OPENAI_API_KEY
echo

if [[ -z "$OPENAI_API_KEY" ]]; then
  echo "API_KEY_EMPTY"
  exit 1
fi

cat > .env <<EOF
OPENAI_API_KEY=${OPENAI_API_KEY}
ADMIN_TOKEN=${ADMIN_TOKEN}
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
unset OPENAI_API_KEY

docker compose up -d --force-recreate agent >/dev/null

READY=0
for i in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:8787/health >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

if [[ "$READY" != "1" ]]; then
  echo "AGENT_HEALTH_FAILED"
  /usr/local/bin/fourthlaw-diagnostic-sync >/dev/null 2>&1 || true
  exit 2
fi

HTTP_CODE="$(curl -sS -o /tmp/fourthlaw_api_check.out -w '%{http_code}' -H "X-Admin-Token: ${ADMIN_TOKEN}" http://127.0.0.1:8787/api-check || true)"
{
  echo
  echo "=== API KEY REPAIR CHECK $(date -Is) ==="
  echo "HTTP ${HTTP_CODE}"
  cat /tmp/fourthlaw_api_check.out 2>/dev/null || true
  echo
} >> /var/log/fourthlaw-install.log
rm -f /tmp/fourthlaw_api_check.out

if command -v fourthlaw-diagnostic-sync >/dev/null 2>&1; then
  fourthlaw-diagnostic-sync >/dev/null 2>&1 || true
fi

if [[ "$HTTP_CODE" == "200" ]]; then
  systemctl enable --now fourthlaw-watchdog.timer >/dev/null 2>&1 || true
  echo "FOURTHLAW_READY"
  if command -v fourthlaw >/dev/null 2>&1; then
    fourthlaw || true
  fi
  exit 0
fi

echo "API_KEY_SET_BUT_API_CHECK_HTTP_${HTTP_CODE}"
exit 3

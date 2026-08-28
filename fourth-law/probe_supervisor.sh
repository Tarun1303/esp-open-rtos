#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/fourth-law-agent
source ./.env
{
  echo
  echo "=== SUPERVISOR API PROBE $(date -Is) ==="
  curl -sS -i -H "X-Admin-Token: ${ADMIN_TOKEN}" "http://127.0.0.1:8787/api-check" || true
  echo
  echo "=== HEALTH ==="
  curl -sS "http://127.0.0.1:8787/health" || true
  echo
  echo "=== AGENT LOGS ==="
  docker compose logs agent --tail=120 2>&1 || true
  echo
} >> /var/log/fourthlaw-install.log 2>&1
/usr/local/bin/fourthlaw-diagnostic-sync || true
echo DONE

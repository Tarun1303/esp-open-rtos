#!/usr/bin/env bash
set -Eeuo pipefail
UNIT='fourthlaw-release-1787930413-90a83888.service'
PROJECT=/opt/fourth-law-agent
OUT=/tmp/fourthlaw-v080-diagnostic.txt
{
  echo 'V080_DEPLOY_DIAGNOSTIC'
  echo "unit=$UNIT"
  echo '--- health ---'
  curl -sS --max-time 8 http://127.0.0.1:8787/health || true
  echo
  echo '--- bridge ---'
  systemctl is-active fourthlaw-command-bridge.service || true
  systemctl show fourthlaw-command-bridge.service -p ActiveState -p SubState -p MainPID --no-pager || true
  echo '--- release unit ---'
  systemctl show "$UNIT" -p ActiveState -p SubState -p Result -p ExecMainStatus --no-pager || true
  echo '--- agents sdk ---'
  cd "$PROJECT"
  docker compose exec -T agent python - <<'PY' 2>&1 || true
try:
 import importlib.metadata
 print('openai-agents='+importlib.metadata.version('openai-agents'))
 import agents
 print('agents_import=ok')
except Exception as e:
 print('agents_error='+repr(e))
PY
  echo '--- release journal tail ---'
  journalctl -u "$UNIT" -n 100 --no-pager 2>&1 || true
} > "$OUT"
# Redact any accidental secrets before posting.
sed -E -i 's/sk-[A-Za-z0-9_-]{12,}/[REDACTED_OPENAI_KEY]/g; s/(OPENAI_API_KEY|ADMIN_TOKEN)=[^[:space:]]+/\1=[REDACTED]/g; s/(Authorization: Bearer )[A-Za-z0-9._-]+/\1[REDACTED]/g' "$OUT"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file "$OUT" >/dev/null 2>&1 || true
rm -f "$OUT"
echo V080_DIAGNOSTIC_POSTED

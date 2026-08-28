#!/usr/bin/env bash
set -Eeuo pipefail
UNIT='fourthlaw-release-1787936541-197ea6c2.service'
TMP=$(mktemp)
{
  echo 'V092_SHARED_MEMORY_DIAGNOSTIC'
  systemctl status "$UNIT" --no-pager -l 2>&1 || true
  echo '--- JOURNAL ---'
  journalctl -u "$UNIT" -n 140 --no-pager 2>&1 || true
  echo '--- CURRENT HEALTH ---'
  curl -fsS http://127.0.0.1:8787/health 2>&1 || true
} > "$TMP"
sed -E -i 's/sk-[A-Za-z0-9_-]+/[REDACTED]/g; s/(OPENAI_API_KEY|ADMIN_TOKEN)=([^[:space:]]+)/\1=[REDACTED]/g; s/Authorization: Bearer [^[:space:]]+/Authorization: Bearer [REDACTED]/g' "$TMP"
BODY=$(python3 - "$TMP" <<'PY'
import json,sys
text=open(sys.argv[1],errors='replace').read()[-12000:]
print('V092_SHARED_MEMORY_DIAGNOSTIC '+json.dumps({'log':text}))
PY
)
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$BODY" >/dev/null
rm -f "$TMP"
echo V092_DIAGNOSTIC_POSTED

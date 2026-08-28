#!/usr/bin/env bash
set -Eeuo pipefail
UNIT='fourthlaw-release-1787940488-70478dae.service'
TMP=/tmp/v095bdiag.txt
{
  echo 'UNIT_STATE:'
  systemctl show "$UNIT" -p ActiveState -p SubState -p Result -p ExecMainStatus --no-pager || true
  echo 'JOURNAL_TAIL:'
  journalctl -u "$UNIT" -n 100 --no-pager 2>&1 | tail -100 || true
  echo 'CURRENT_HEALTH:'
  curl -fsS http://127.0.0.1:8787/health || true
} | sed -E 's/(OPENAI_API_KEY|ADMIN_TOKEN|GH_TOKEN|GITHUB_TOKEN)=[^ ]+/<REDACTED>/g' | tail -120 > "$TMP"
BODY="V095B_ARTIFACT_RELIABILITY_DIAGNOSTIC
\`\`\`
$(cat "$TMP")
\`\`\`"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$BODY" >/dev/null
rm -f "$TMP"
echo V095B_DIAG_POSTED
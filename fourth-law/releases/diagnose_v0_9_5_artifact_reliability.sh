#!/usr/bin/env bash
set -Eeuo pipefail
UNIT='fourthlaw-release-1787940040-25edbbe9.service'
echo 'V095_ARTIFACT_RELIABILITY_DIAGNOSTIC_BEGIN'
systemctl show "$UNIT" -p ActiveState -p SubState -p Result -p ExecMainStatus --no-pager || true
journalctl -u "$UNIT" -n 120 --no-pager 2>&1 | sed -E 's/(OPENAI_API_KEY|ADMIN_TOKEN|GH_TOKEN|GITHUB_TOKEN)=[^ ]+/<REDACTED>/g' | tail -120 || true
echo 'CURRENT_HEALTH:'
curl -fsS http://127.0.0.1:8787/health || true
echo
echo 'V095_ARTIFACT_RELIABILITY_DIAGNOSTIC_END'
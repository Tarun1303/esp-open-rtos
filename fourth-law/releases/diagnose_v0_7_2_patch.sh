#!/usr/bin/env bash
set -Eeuo pipefail
UNIT='fourthlaw-release-1787928201-fe090711.service'
OUT="$(journalctl -u "$UNIT" --no-pager -n 120 2>&1 || true)"
OUT="$(printf '%s' "$OUT" | sed -E 's/(OPENAI_API_KEY|ADMIN_TOKEN)=[^ ]+/\1=<redacted>/g; s/sk-[A-Za-z0-9_-]+/<redacted-key>/g' | tail -c 12000)"
BODY="V072_PATCH_DIAGNOSTIC
unit=$UNIT
agent_health=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true)
--- journal ---
$OUT"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$BODY" >/dev/null 2>&1 || true
echo V072_PATCH_DIAGNOSTIC_POSTED

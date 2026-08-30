#!/usr/bin/env bash
set -Eeuo pipefail
UNIT='fourthlaw-release-1788099509-6d7c392d.service'
OUT=/tmp/v0100b-rollback.txt
journalctl -u "$UNIT" --no-pager -n 120 2>/dev/null | grep -E 'SyntaxError|SystemExit|AssertionError|Traceback|FAILED|failed|missing|anchor|Error|V0100|ROLLBACK|exit-code|state|version|max_agents' | tail -n 70 > "$OUT" || true
python3 - <<'PY' >/tmp/v0100b-rollback-comment.txt
from pathlib import Path
s=Path('/tmp/v0100b-rollback.txt').read_text().strip() or 'No filtered error line found.'
print('V0100B_ROLLBACK_DIAGNOSTIC\n```text\n'+s+'\n```')
PY
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file /tmp/v0100b-rollback-comment.txt >/dev/null 2>&1 || true
echo V0100B_ROLLBACK_DIAGNOSTIC_READY

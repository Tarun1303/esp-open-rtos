#!/usr/bin/env bash
set -Eeuo pipefail
UNIT=$(systemctl list-units --all --type=service --no-legend | awk '/fourthlaw-release-1788099162-5a0cb140.service/{print $1; exit}')
[[ -n "$UNIT" ]] || UNIT='fourthlaw-release-1788099162-5a0cb140.service'
OUT=/tmp/v0100-rollback.txt
journalctl -u "$UNIT" --no-pager -n 100 2>/dev/null | grep -E 'SyntaxError|SystemExit|AssertionError|Traceback|FAILED|failed|missing|anchor|Error|V0100|ROLLBACK|exit-code' | tail -n 50 > "$OUT" || true
python3 - <<'PY' >/tmp/v0100-rollback-comment.txt
from pathlib import Path
s=Path('/tmp/v0100-rollback.txt').read_text().strip() or 'No filtered error line found; inspect unit exit status.'
print('V0100_ROLLBACK_DIAGNOSTIC\n```text\n'+s+'\n```')
PY
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file /tmp/v0100-rollback-comment.txt >/dev/null 2>&1 || true
echo V0100_ROLLBACK_DIAGNOSTIC_READY

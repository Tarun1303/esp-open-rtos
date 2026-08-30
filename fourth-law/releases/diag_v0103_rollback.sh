#!/usr/bin/env bash
set -Eeuo pipefail
OUT=/tmp/v0103_rollback_diag.txt
{
 echo '=== CURRENT HEALTH ==='; curl -fsS http://127.0.0.1:8787/health || true; echo
 echo '=== TMP LOGS ==='
 for f in /tmp/fl0103-build.log /tmp/fl0103-up.log /tmp/fl0103-rb-build.log /tmp/fl0103-rb-up.log; do echo "--- $f"; tail -n 120 "$f" 2>/dev/null || true; done
 echo '=== LATEST RELEASE JOURNAL ==='
 u=$(systemctl list-units --type=service --all --no-legend 'fourthlaw-release-*' | awk '{print $1}' | tail -1)
 echo "unit=$u"; [[ -n "$u" ]] && journalctl -u "$u" -n 180 --no-pager || true
} > "$OUT" 2>&1
BODY=$(python3 - <<'PY'
from pathlib import Path
s=Path('/tmp/v0103_rollback_diag.txt').read_text(errors='replace')
print('V0103_ROLLBACK_DIAG\n```text\n'+s[-50000:]+'\n```')
PY
)
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$BODY" >/dev/null
echo V0103_ROLLBACK_DIAG_POSTED

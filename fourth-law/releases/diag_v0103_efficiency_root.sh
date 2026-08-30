#!/usr/bin/env bash
set -Eeuo pipefail
E=/opt/fourth-law-agent/app/intelligence_engine.py
OUT=/tmp/v0103_efficiency_root.txt
{
 echo '=== ENGINE 1-180 ==='; sed -n '1,180p' "$E"
 echo '=== ENGINE 250-430 ==='; sed -n '250,430p' "$E"
 echo '=== ENGINE 780-930 ==='; sed -n '780,930p' "$E"
 echo '=== SEARCH ==='; grep -nE 'problem_plan|major|module|children =|root|_sdk_structured|Runner.run|reserve_child|cost_governor|SharedContextMemory' "$E" | head -n 260
} > "$OUT"
BODY=$(python3 - <<'PY'
from pathlib import Path
s=Path('/tmp/v0103_efficiency_root.txt').read_text(errors='replace')
print('V0103_EFFICIENCY_ROOT_DIAG\n```python\n'+s[:58000]+'\n```')
PY
)
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$BODY" >/dev/null
echo V0103_EFFICIENCY_ROOT_DIAG_POSTED

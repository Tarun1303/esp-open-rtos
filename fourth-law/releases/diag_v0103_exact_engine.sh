#!/usr/bin/env bash
set -Eeuo pipefail
E=/opt/fourth-law-agent/app/intelligence_engine.py
OUT=/tmp/v0103_exact_engine.txt
{
 echo '=== 120-250 ==='; nl -ba "$E" | sed -n '120,250p'
 echo '=== 300-410 ==='; nl -ba "$E" | sed -n '300,410p'
 echo '=== 470-575 ==='; nl -ba "$E" | sed -n '470,575p'
 echo '=== 780-920 ==='; nl -ba "$E" | sed -n '780,920p'
} > "$OUT"
BODY=$(python3 - <<'PY'
from pathlib import Path
s=Path('/tmp/v0103_exact_engine.txt').read_text(errors='replace')
print('V0103_EXACT_ENGINE\n```text\n'+s+'\n```')
PY
)
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$BODY" >/dev/null
echo V0103_EXACT_ENGINE_POSTED

#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
OUT=/tmp/v010-source-ranges.txt
{
  echo '=== MAIN 420-580 ==='; sed -n '420,580p' "$PROJECT/app/main.py"
  echo '=== MAIN 580-700 ==='; sed -n '580,700p' "$PROJECT/app/main.py"
  echo '=== CONTROL_ROOM 170-360 ==='; sed -n '170,360p' "$PROJECT/app/control_room.py"
  echo '=== ENGINE ARTIFACT/VERIFY CONTEXT ==='
  L=$(grep -n 'artifact_mode' "$PROJECT/app/intelligence_engine.py" | head -1 | cut -d: -f1 || true)
  if [[ -n "$L" ]]; then A=$((L-35)); ((A<1)) && A=1; B=$((L+130)); sed -n "${A},${B}p" "$PROJECT/app/intelligence_engine.py"; fi
} > "$OUT"
# Defensive redaction of literal secret-looking assignments/headers.
sed -E 's/([A-Za-z_]*(TOKEN|KEY|SECRET|PASSWORD)[A-Za-z_]*[[:space:]]*=[[:space:]]*)[^, )]+/\1<redacted>/g; s/(X-Admin-Token[^:]*:[[:space:]]*)[^, }]+/\1<redacted>/g' "$OUT" > /tmp/v010-source-ranges-safe.txt
python3 - <<'PY' >/tmp/v010-comment.txt
from pathlib import Path
s=Path('/tmp/v010-source-ranges-safe.txt').read_text()
print('V010_SOURCE_RANGES\n```python\n'+s[:55000]+'\n```')
PY
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file /tmp/v010-comment.txt >/dev/null 2>&1 || true
echo V010_SOURCE_RANGES_READY

#!/usr/bin/env bash
set -Eeuo pipefail

SRC=/opt/fourth-law-agent/dispatched-releases/v0_9_2_shared_memory_architecture.sh
[[ -f "$SRC" ]]
FIXED=/tmp/v0_9_2_shared_memory_architecture_fixed.sh
cp "$SRC" "$FIXED"

python3 - <<'PY'
from pathlib import Path
p=Path('/tmp/v0_9_2_shared_memory_architecture_fixed.sh')
s=p.read_text()
names=['_instructions','_sdk_run','_understand_and_plan','_execute_local_step','_prior_text','run_node','run']
for name in names:
    old=f"REPLACEMENTS['{name}'] = '''"
    new=f"REPLACEMENTS['{name}'] = r'''"
    if old in s:
        s=s.replace(old,new,1)
    elif new not in s:
        raise SystemExit(f'missing replacement block: {name}')
# Guard against the exact v0.9.2 generation bug.
if 'REPLACEMENTS[\'_sdk_run\'] = r\'\'\'' not in s:
    raise SystemExit('raw replacement conversion failed')
p.write_text(s)
PY

bash -n "$FIXED"
exec bash "$FIXED"

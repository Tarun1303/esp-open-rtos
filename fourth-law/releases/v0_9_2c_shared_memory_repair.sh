#!/usr/bin/env bash
set -Eeuo pipefail

SRC=/opt/fourth-law-agent/dispatched-releases/v0_9_2_shared_memory_architecture.sh
[[ -f "$SRC" ]]
FIXED=/tmp/v0_9_2_shared_memory_architecture_fixed_v2.sh
cp "$SRC" "$FIXED"

python3 - <<'PY'
from pathlib import Path
p=Path('/tmp/v0_9_2_shared_memory_architecture_fixed_v2.sh')
s=p.read_text()

# Preserve backslash escapes while generating Python source from replacement blocks.
for name in ['_instructions','_sdk_run','_understand_and_plan','_execute_local_step','_prior_text','run_node','run']:
    old=f"REPLACEMENTS['{name}'] = '''"
    new=f"REPLACEMENTS['{name}'] = r'''"
    if old in s:
        s=s.replace(old,new,1)
    elif new not in s:
        raise SystemExit(f'missing replacement block: {name}')

# A failed release must stop after rollback; never continue with errexit disabled and
# accidentally emit a success marker.
needle='\n}\ntrap rollback ERR\n'
if needle in s:
    s=s.replace(needle,'\n  exit 1\n}\ntrap rollback ERR\n',1)
elif 'exit 1\n}\ntrap rollback ERR' not in s:
    raise SystemExit('rollback boundary missing')

# Use supported Agents SDK model settings and retain cacheable stable prompt prefixes.
s=s.replace('"store": False,\n            },','"store": False,\n                "prompt_cache_retention": "24h",\n            },',1)

p.write_text(s)
PY

bash -n "$FIXED"
exec bash "$FIXED"

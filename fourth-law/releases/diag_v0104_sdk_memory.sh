#!/usr/bin/env bash
set -Eeuo pipefail
P=/opt/fourth-law-agent
{
 echo 'V0104_SDK_MEMORY'
 echo '=== AGENTS SDK TOOL API ==='
 cd "$P"
 docker compose exec -T agent python - <<'PY'
import inspect, agents
print('agents_version', getattr(agents,'__version__','?'))
for n in ['function_tool','FunctionTool','RunContextWrapper','Agent','Runner']:
    o=getattr(agents,n,None)
    print(n, bool(o), inspect.signature(o) if o and callable(o) else '')
if getattr(agents,'Agent',None):
    print('Agent_signature', inspect.signature(agents.Agent))
PY
 echo '=== SHARED MEMORY ==='
 sed -n '1,240p' "$P/app/shared_memory.py"
 echo '=== PROBLEM ENGINE 1-145 ==='
 sed -n '1,145p' "$P/app/problem_engine.py"
 echo '=== ENGINE 310-350 ==='
 sed -n '310,350p' "$P/app/intelligence_engine.py"
 echo '=== ENGINE 805-860 ==='
 sed -n '805,860p' "$P/app/intelligence_engine.py"
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

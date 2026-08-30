#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
CR="$PROJECT/app/control_room.py"
ENG="$PROJECT/app/intelligence_engine.py"
OUT=/tmp/v010-runtime-targets.txt
{
  echo '=== MAIN ROUTES / STATE ==='
  grep -nE '(@app\.(post|get).*continue|@app\.(post|get).*decision|def .*continue|def .*decision|def state|@app.get\("/state|active_nodes|max_agents|create_intelligence_problem|run_intelligence_job)' "$MAIN" | tail -n 120 || true
  echo '=== CONTROL ROOM ==='
  grep -nE '(class TaskSubmit|submit_task|_reconcile_orphaned_jobs|_delivery_state|stream_job|sanitize_job|_summary)' "$CR" | tail -n 120 || true
  echo '=== INTELLIGENCE ENGINE ==='
  grep -nE '(artifact_mode|SELF_VERIFY|COST_GOVERNOR|sdk_request_budget|force_no_delegation|max_children_per_node|async def run\(|async def _execute_node|def build_intelligence_audit)' "$ENG" | tail -n 160 || true
} > "$OUT"
# Public-safe source structure only; redact anything that resembles secrets/tokens just in case.
sed -E 's/([A-Za-z_]*(TOKEN|KEY|SECRET)[A-Za-z_]*=)[^ ]+/\1<redacted>/g' "$OUT" | head -n 360 > /tmp/v010-runtime-targets-safe.txt
BODY=$(python3 - <<'PY'
from pathlib import Path
s=Path('/tmp/v010-runtime-targets-safe.txt').read_text()
print('V010_RUNTIME_TARGETS\n```text\n'+s+'\n```')
PY
)
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$BODY" >/dev/null 2>&1 || true
echo V010_RUNTIME_TARGETS_READY

#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
ENGINE="$PROJECT/app/intelligence_engine.py"
CR="$PROJECT/app/control_room.py"
HTML="$PROJECT/app/control_room.html"
OUT=/tmp/v010_human_efficiency_code_memory.txt
: > "$OUT"

{
  echo "=== MAIN: REQUESTS / CONTINUE / DECISIONS / STATE ==="
  grep -nE 'class (ProblemRequest|TaskRequest|ContinueRequest|DecisionAnswer)|async def (create_intelligence_problem|continue_task|answer_decision|state)|@app\.(post|get)\("/(task|decisions|state|problem|intelligence)' "$MAIN" || true
  echo
  sed -n '440,590p' "$MAIN" || true

  echo
  echo "=== CONTROL ROOM BACKEND: TASK / STREAM / DECISION SURFACES ==="
  grep -nE 'TaskSubmit|api/tasks|api/stream|decision|intervention|human|pending|EventSource|StreamingResponse' "$CR" || true
  echo
  sed -n '1,280p' "$CR" || true

  echo
  echo "=== CONTROL ROOM HTML: INTERVENTION UI ==="
  grep -nEi 'intervention|decision|human|textarea|input|drawer|pending|send|submit' "$HTML" | head -n 160 || true

  echo
  echo "=== ENGINE: FANOUT / BUDGET / MEMORY / VERIFICATION ==="
  grep -nE 'agent_budget|max_children_per_node|_reserve_child|artifact_mode|shared_memory|memory|packet|children|supervisor|force_no_delegation|sdk_request_budget|prompt_char_cap' "$ENGINE" | head -n 220 || true
  echo
  sed -n '310,680p' "$ENGINE" || true
} >> "$OUT"

BODY=$(python3 - <<'PY'
from pathlib import Path
p=Path('/tmp/v010_human_efficiency_code_memory.txt')
s=p.read_text(errors='replace')
if len(s) > 60000:
    s = s[:30000] + "\n...[TRUNCATED MIDDLE]...\n" + s[-28000:]
print("V010_HUMAN_EFFICIENCY_CODE_MEMORY_DIAG\n```text\n"+s+"\n```")
PY
)
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$BODY" >/dev/null
echo V010_HUMAN_EFFICIENCY_CODE_MEMORY_DIAG_POSTED

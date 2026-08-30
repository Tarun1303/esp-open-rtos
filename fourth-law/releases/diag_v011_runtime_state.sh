#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
ENGINE="$PROJECT/app/intelligence_engine.py"
PROBLEM="$PROJECT/app/problem_engine.py"
CR="$PROJECT/app/control_room.py"
{
  echo 'V011_RUNTIME_STATE'
  echo '=== HEALTH/VERSION ==='
  curl -fsS http://127.0.0.1:8787/health || true
  echo
  echo '=== MAIN CONTINUE / DECISION / STATE ==='
  grep -nE 'def continue_task|def answer_decision|def state|active_nodes|max_agents|version.:.?0\.10' "$MAIN" | head -80 || true
  echo '=== INTELLIGENCE ROOT / RESERVE / PLANNING ==='
  grep -nE 'plan_problem|plan_intelligence_problem|root\["children"\]|_reserve_child|asyncio\.gather|agent_budget|cost_governor' "$ENGINE" | head -140 || true
  echo '=== PROBLEM PLANNER ==='
  grep -nE 'def plan_problem|def plan_intelligence_problem|exactly (3|4)|modules' "$PROBLEM" | head -140 || true
  echo '=== HUMAN INTERVENTION ==='
  grep -nE 'InterventionAnswer|answer_pending_decision|interventions/\{decision_id\}|pending_decisions' "$CR" | head -100 || true
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

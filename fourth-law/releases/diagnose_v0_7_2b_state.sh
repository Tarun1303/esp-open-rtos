#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/fourth-law-agent
HOST_MAIN="$(grep -nE '0\.7\.[0-9]+|version' app/main.py | head -n 40 || true)"
HOST_PATCH_COUNT="$(grep -c 'FINAL SEMANTIC ADJUDICATION' app/problem_engine.py 2>/dev/null || true)"
HOST_ADVISORY_COUNT="$(grep -c 'ADVISORY only' app/problem_engine.py 2>/dev/null || true)"
CONT_MAIN="$(docker exec fourth-law-agent sh -lc "grep -nE '0\\.7\\.[0-9]+|version' /app/app/main.py | head -n 40" 2>/dev/null || true)"
CONT_PATCH_COUNT="$(docker exec fourth-law-agent sh -lc "grep -c 'FINAL SEMANTIC ADJUDICATION' /app/app/problem_engine.py" 2>/dev/null || true)"
CONT_ADVISORY_COUNT="$(docker exec fourth-law-agent sh -lc "grep -c 'ADVISORY only' /app/app/problem_engine.py" 2>/dev/null || true)"
HEALTH="$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true)"
BODY="V072B_STATE_DIAGNOSTIC
health=$HEALTH
host_patch_count=$HOST_PATCH_COUNT host_advisory_count=$HOST_ADVISORY_COUNT
container_patch_count=$CONT_PATCH_COUNT container_advisory_count=$CONT_ADVISORY_COUNT
--- host main markers ---
$HOST_MAIN
--- container main markers ---
$CONT_MAIN"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$BODY" >/dev/null 2>&1 || true
echo V072B_STATE_DIAGNOSTIC_POSTED

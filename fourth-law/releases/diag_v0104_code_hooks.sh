#!/usr/bin/env bash
set -Eeuo pipefail
P=/opt/fourth-law-agent
{
 echo 'V0104_CODE_HOOKS'
 echo '=== APP FILES ==='
 find "$P/app" -maxdepth 2 -type f -printf '%P\n' | sort | head -120
 echo '=== ENGINE IMPORTS/SCHEMAS ==='
 sed -n '1,120p' "$P/app/intelligence_engine.py"
 echo '=== SDK CALL ==='
 sed -n '180,285p' "$P/app/intelligence_engine.py"
 echo '=== RESERVE / NODE EXECUTION ==='
 sed -n '310,385p' "$P/app/intelligence_engine.py"
 echo '=== ROOT RUN ==='
 sed -n '800,885p' "$P/app/intelligence_engine.py"
 echo '=== MAIN TASK CREATION ==='
 sed -n '430,590p' "$P/app/main.py"
 echo '=== MEMORY API ==='
 grep -nE 'class .*Memory|def .*memory|packet|root_planning_context|node_memory' "$P/app"/*.py | head -160 || true
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

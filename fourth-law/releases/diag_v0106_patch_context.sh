#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
{
  echo V0106_PATCH_CONTEXT
  grep -nE 'control_room|FastAPI\(|include_router|version.*0\.10|bounded-code-workspace|volumes:|./data:/data' "$PROJECT/app/main.py" "$PROJECT/app/control_room.py" "$PROJECT/compose.yaml" | tail -80
  echo HEALTH
  curl -fsS http://127.0.0.1:8787/health
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

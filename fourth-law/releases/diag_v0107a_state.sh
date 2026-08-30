#!/usr/bin/env bash
set +e
{
  echo V0107A_STATE_DIAGNOSTIC
  echo HEALTH
  curl -fsS http://127.0.0.1:8787/health
  echo
  echo SERVICE
  systemctl is-active fourthlaw-codex.service
  systemctl show fourthlaw-codex.service -p ActiveState -p SubState -p Result
  echo CONTAINERS
  docker ps --format '{{.Names}} {{.Status}}'
  echo PROJECT_VERSIONS
  grep -o 'version="[^"]*"' /opt/fourth-law-agent/app/main.py | head -2
  grep -o "'version': '[^']*'" /opt/fourth-law-agent/app/control_room.py | head -2
  echo UI_MARKERS
  grep -Eo 'Steering active turn|Workspace details|persistent memory' /opt/fourth-law-agent/app/static/codex.html | sort -u
  echo APP_LOG
  docker logs --tail 80 fourth-law-agent 2>&1
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1

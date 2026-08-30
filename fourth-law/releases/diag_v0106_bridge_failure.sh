#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
{
  echo V0106_BRIDGE_FAILURE_CONTEXT
  echo HEALTH
  curl -fsS http://127.0.0.1:8787/health
  echo HOST_SOCKET
  namei -l /run/fourthlaw-codex/app.sock || true
  systemctl is-active fourthlaw-codex.service || true
  echo CONTAINER_SOCKET
  docker exec fourth-law-agent sh -c 'id; ls -ld /run/fourthlaw-codex /run/fourthlaw-codex/app.sock 2>&1' || true
  echo SAVED_CODEX_STATE
  python3 - <<'PY'
import json
from pathlib import Path
for p in sorted(Path('/opt/fourth-law-agent/data/codex_sessions').glob('*.json'), key=lambda x:x.stat().st_mtime)[-4:]:
    d=json.loads(p.read_text())
    print(json.dumps({'id':d.get('id'),'role':d.get('role'),'status':d.get('status'),'thread_id':d.get('thread_id'),'turn_id':d.get('turn_id'),'last_error':d.get('last_error'),'events':(d.get('events') or [])[-8:]},ensure_ascii=False))
PY
  echo APP_LOGS
  docker logs --tail 100 fourth-law-agent 2>&1 | grep -E 'codex|Codex|ERROR|Traceback|websocket|WebSocket' | tail -70 || true
  echo CODEX_SERVICE_LOGS
  journalctl -u fourthlaw-codex.service -n 80 --no-pager | tail -80
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

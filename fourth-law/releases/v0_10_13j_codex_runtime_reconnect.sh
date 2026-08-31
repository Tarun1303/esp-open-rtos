#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
DEV_HOME='/var/lib/fourthlaw-dev'
UNIT='fourthlaw-codex.service'
REPORT='/tmp/fl-v01013j-codex-reconnect.txt'

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  {
    echo CODEX_RUNTIME_RECONNECT_V0_10_13_FAILED
    echo "command=$failed_command"
    tail -100 "$REPORT" 2>/dev/null || true
    curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR

: >"$REPORT"
health="$(curl -fsS http://127.0.0.1:8787/health)"
printf '%s' "$health" | grep -q '"ok":true'
printf '%s' "$health" | grep -q '"version":"0.10.13"'
test -s "$DEV_HOME/appserver-token"
test -f "/etc/systemd/system/$UNIT"

docker_ip="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
python3 -c 'import ipaddress,sys; assert ipaddress.ip_address(sys.argv[1]).is_private' "$docker_ip"

systemctl daemon-reload
systemctl restart "$UNIT" >>"$REPORT" 2>&1
ready=false
for _ in $(seq 1 40); do
  if curl -fsS "http://$docker_ip:4500/readyz" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
test "$ready" = true
systemctl is-active --quiet "$UNIT"

docker exec -i fourth-law-agent python - <<'PY' >>"$REPORT" 2>&1
import asyncio
import json
from pathlib import Path
import websockets

async def main():
    token = Path('/run/secrets/fourthlaw-codex-token').read_text().strip()
    assert len(token) >= 32
    async with websockets.connect(
        'ws://host.docker.internal:4500',
        additional_headers={'Authorization': f'Bearer {token}'},
        open_timeout=10,
    ) as ws:
        await ws.send(json.dumps({
            'method': 'initialize',
            'id': 1,
            'params': {'clientInfo': {'name': 'fourth_law_reconnect', 'title': 'Fourth Law Reconnect', 'version': '0.10.13'}},
        }))
        response = json.loads(await asyncio.wait_for(ws.recv(), 10))
        assert response.get('id') == 1 and not response.get('error'), response
        await ws.send(json.dumps({'method': 'initialized', 'params': {}}))

asyncio.run(main())
print('authenticated_websocket=true')
PY

state_report="$(python3 - "$PROJECT/data/codex_sessions" <<'PY'
import json
import os
import stat
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
ready = 0
interrupted = 0
unchanged = 0
for path in root.glob('project-*.json'):
    state = json.loads(path.read_text())
    if state.get('status') != 'disconnected':
        unchanged += 1
        continue
    old_turn = state.get('turn_id')
    if old_turn:
        state['status'] = 'interrupted'
        state['turn_id'] = None
        summary = 'Runtime reconnected; an unknown active turn was marked interrupted truthfully'
        interrupted += 1
    else:
        state['status'] = 'ready'
        summary = 'Runtime reconnected; persistent thread is ready to resume'
        ready += 1
    state['last_error'] = ''
    state['updated_at'] = time.time()
    events = state.setdefault('events', [])
    events.append({'ts': time.time(), 'type': 'runtime_reconnected', 'summary': summary})
    state['events'] = events[-500:]
    metadata = path.stat()
    temp = path.with_suffix('.reconnect.tmp')
    temp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    os.chmod(temp, stat.S_IMODE(metadata.st_mode))
    os.chown(temp, metadata.st_uid, metadata.st_gid)
    temp.replace(path)
print(f'permanent_ready_repaired={ready}')
print(f'unknown_active_marked_interrupted={interrupted}')
print(f'permanent_unchanged={unchanged}')
PY
)"

{
  echo CODEX_RUNTIME_RECONNECTED_V0_10_13
  echo service_active=true
  echo authenticated_websocket=true
  echo state_repair_scope=permanent-project-workspaces-only
  echo global_git_config_changed=false
  echo production_code_changed=false
  echo "$state_report"
  echo "health=$health"
} | report_issue

trap - ERR
echo CODEX_RUNTIME_RECONNECT_V0_10_13_READY

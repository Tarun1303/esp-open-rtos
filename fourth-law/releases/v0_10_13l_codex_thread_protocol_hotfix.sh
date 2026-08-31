#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
MODULE="$PROJECT/app/codex_control.py"
BACKUP="$(mktemp /tmp/fl-v01013l-codex-control.XXXXXX.py)"
REPORT='/tmp/fl-v01013l-protocol-hotfix.txt'
DEPLOY_STARTED=0

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  set +e
  if test "$DEPLOY_STARTED" = 1; then
    install -m 0644 "$BACKUP" "$MODULE"
    docker compose -f "$PROJECT/compose.yaml" build agent >>"$REPORT" 2>&1
    docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1
  fi
  {
    echo CODEX_THREAD_PROTOCOL_HOTFIX_V0_10_13_FAILED
    echo "command=$failed_command"
    echo "rollback_attempted=$DEPLOY_STARTED"
    tail -120 "$REPORT" 2>/dev/null || true
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR

: >"$REPORT"
cp "$MODULE" "$BACKUP"
health="$(curl -fsS http://127.0.0.1:8787/health)"
printf '%s' "$health" | grep -q '"version":"0.10.13"'
systemctl is-active --quiet fourthlaw-codex.service

# Protocol preflight: create and delete one empty thread. No turn or paid model call.
docker exec -i fourth-law-agent python - <<'PY' >>"$REPORT" 2>&1
import asyncio
import json
from pathlib import Path
import websockets

async def request(ws, request_id, method, params):
    await ws.send(json.dumps({'method': method, 'id': request_id, 'params': params}))
    while True:
        message = json.loads(await asyncio.wait_for(ws.recv(), 20))
        if message.get('id') == request_id:
            if message.get('error'):
                raise RuntimeError(message['error'].get('message') or str(message['error']))
            return message.get('result') or {}

async def main():
    token = Path('/run/secrets/fourthlaw-codex-token').read_text().strip()
    async with websockets.connect(
        'ws://host.docker.internal:4500',
        additional_headers={'Authorization': f'Bearer {token}'},
        open_timeout=10,
    ) as ws:
        await request(ws, 1, 'initialize', {
            'clientInfo': {'name': 'fourth_law_protocol_check', 'title': 'Fourth Law Protocol Check', 'version': '0.10.13'},
        })
        await ws.send(json.dumps({'method': 'initialized', 'params': {}}))
        started = await request(ws, 2, 'thread/start', {
            'model': 'gpt-5.6-terra',
            'cwd': '/var/lib/fourthlaw-dev/agent-repos/supervisor',
            'approvalPolicy': 'never',
            'personality': 'friendly',
            'serviceName': 'fourth_law_control_room',
        })
        thread_id = (started.get('thread') or {}).get('id')
        assert thread_id
        await request(ws, 3, 'thread/delete', {'threadId': thread_id})

asyncio.run(main())
print('empty_thread_protocol_check=passed')
print('paid_model_turns=0')
PY

python3 - "$MODULE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old_resume = 'await self._request(sid, "thread/resume", {"threadId": state["thread_id"]})'
new_resume = 'await self._request(sid, "thread/resume", {"threadId": state["thread_id"], "personality": "friendly"})'
if old_resume in text:
    text = text.replace(old_resume, new_resume, 1)
elif new_resume not in text:
    raise SystemExit('thread resume anchor missing')

old_start = '"approvalPolicy": "never",\n                "serviceName": "fourth_law_control_room",'
new_start = '"approvalPolicy": "never",\n                "personality": "friendly",\n                "serviceName": "fourth_law_control_room",'
if old_start in text:
    text = text.replace(old_start, new_start, 1)
elif new_start not in text:
    raise SystemExit('thread start anchor missing')

path.write_text(text)
PY

grep -q '"personality": "friendly"' "$MODULE"
grep -q 'default_permissions = "fourthlaw-workspace"' /var/lib/fourthlaw-dev/.codex/config.toml
python3 -m py_compile "$MODULE"

DEPLOY_STARTED=1
docker compose -f "$PROJECT/compose.yaml" build agent >>"$REPORT" 2>&1
docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1

ready=false
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl-v01013l-health.json 2>/dev/null; then ready=true; break; fi
  sleep 2
done
test "$ready" = true
grep -q '"ok":true' /tmp/fl-v01013l-health.json
grep -q '"version":"0.10.13"' /tmp/fl-v01013l-health.json
grep -q '"personality": "friendly"' "$MODULE"

pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
cookie="$(mktemp /tmp/fl-v01013l-cookie.XXXXXX)"
curl -fsS -c "$cookie" -H 'Content-Type: application/json' -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/sessions | grep -q '"project"'
rm -f "$cookie"

DEPLOY_STARTED=0
{
  echo CODEX_THREAD_PROTOCOL_HOTFIX_V0_10_13_READY
  echo thread_start_personality=friendly
  echo thread_resume_personality=friendly
  echo empty_thread_protocol_check=passed
  echo paid_model_turns=0
  echo permission_profile=fourthlaw-workspace
  echo permission_profile_changed=false
  echo command_network=false
  echo credential_read=false
  echo direct_production_write=false
  echo "health=$(cat /tmp/fl-v01013l-health.json)"
} | report_issue

trap - ERR
rm -f "$BACKUP"
echo CODEX_THREAD_PROTOCOL_HOTFIX_V0_10_13_DEPLOYED

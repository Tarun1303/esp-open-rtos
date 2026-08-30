#!/usr/bin/env bash
set -Eeuo pipefail
OUT=/tmp/fl-v0106-socket-client.txt
set +e
docker run --rm -i -v /run/fourthlaw-codex:/run/fourthlaw-codex:ro --entrypoint python fourth-law-agent:v0.10.6-test - <<'PY' >"$OUT" 2>&1
import asyncio,json,websockets
async def main():
    print('client_start')
    ws=await websockets.unix_connect('/run/fourthlaw-codex/app.sock',uri='ws://localhost')
    print('connected')
    await ws.send(json.dumps({'method':'initialize','id':1,'params':{'clientInfo':{'name':'diagnostic','title':'Diagnostic','version':'1'}}}))
    print((await asyncio.wait_for(ws.recv(),10))[:1000])
    await ws.close()
asyncio.run(main())
PY
code=$?
set -e
{
  echo V0106_SOCKET_CLIENT
  echo "exit=$code"
  tail -80 "$OUT"
  echo HEALTH
  curl -fsS http://127.0.0.1:8787/health
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

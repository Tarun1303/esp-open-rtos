#!/usr/bin/env bash
set -Eeuo pipefail
OUT=/tmp/fl-v0106-tcp-appserver.txt
runuser -u fourthlaw-dev -- env HOME=/var/lib/fourthlaw-dev CODEX_HOME=/var/lib/fourthlaw-dev/.codex codex app-server --listen ws://127.0.0.1:4501 >"$OUT.server" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do ss -ltn | grep -q '127.0.0.1:4501' && break; sleep 1; done
set +e
docker run --rm -i --network host --entrypoint python fourth-law-agent:v0.10.6-test - <<'PY' >"$OUT" 2>&1
import asyncio,json,websockets
async def main():
    ws=await websockets.connect('ws://127.0.0.1:4501')
    await ws.send(json.dumps({'method':'initialize','id':1,'params':{'clientInfo':{'name':'diagnostic','title':'Diagnostic','version':'1'}}}))
    print((await asyncio.wait_for(ws.recv(),10))[:2000])
    await ws.close()
asyncio.run(main())
PY
code=$?
set -e
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
trap - EXIT
{ echo V0106_TCP_APPSERVER; echo "exit=$code"; tail -60 "$OUT"; echo SERVER; tail -40 "$OUT.server"; curl -fsS http://127.0.0.1:8787/health; } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

#!/usr/bin/env bash
set -Eeuo pipefail
OUT=/tmp/fl-v0106-raw-socket.txt
set +e
runuser -u fourthlaw-dev -- python3 - <<'PY' >"$OUT" 2>&1
import asyncio,json
async def main():
    r,w=await asyncio.open_unix_connection('/run/fourthlaw-codex/app.sock')
    w.write((json.dumps({'method':'initialize','id':1,'params':{'clientInfo':{'name':'diagnostic','title':'Diagnostic','version':'1'}}})+'\n').encode())
    await w.drain()
    print((await asyncio.wait_for(r.readline(),10)).decode()[:2000])
    w.close(); await w.wait_closed()
asyncio.run(main())
PY
code=$?
set -e
{ echo V0106_RAW_SOCKET; echo "exit=$code"; tail -80 "$OUT"; curl -fsS http://127.0.0.1:8787/health; } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

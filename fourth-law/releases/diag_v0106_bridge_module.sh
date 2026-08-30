#!/usr/bin/env bash
set -Eeuo pipefail
OUT=/tmp/fl-v0106-bridge-module.txt
TOKEN="$(mktemp /var/lib/fourthlaw-dev/diag-token.XXXXXX)"
DATA="$(mktemp -d /tmp/fl-v0106-data.XXXXXX)"
openssl rand -hex 32 >"$TOKEN"; chown fourthlaw-dev:fourthlaw-dev "$TOKEN"; chmod 0600 "$TOKEN"
runuser -u fourthlaw-dev -- env HOME=/var/lib/fourthlaw-dev CODEX_HOME=/var/lib/fourthlaw-dev/.codex codex app-server --listen ws://127.0.0.1:4503 --ws-auth capability-token --ws-token-file "$TOKEN" >"$OUT.server" 2>&1 &
pid=$!; trap 'kill "$pid" 2>/dev/null || true; rm -f -- "$TOKEN"' EXIT
for _ in $(seq 1 30); do ss -ltn | grep -q '127.0.0.1:4503' && break; sleep 1; done
set +e
docker run --rm -i --network host -e ADMIN_TOKEN=diagnostic -e OPENAI_API_KEY=diagnostic -e CODEX_APP_SERVER_URL=ws://127.0.0.1:4503 -v "$TOKEN:/run/secrets/fourthlaw-codex-token:ro" -v "$DATA:/data" --entrypoint python fourth-law-agent:v0.10.6-test - <<'PY' >"$OUT" 2>&1
import asyncio,traceback
from app.codex_control import bridge
async def main():
    try:
        print(await bridge.create('efficiency','Read instructions only and reply CODEX_MODULE_READY'))
        await asyncio.sleep(20)
        print(bridge.public(bridge.read(next(iter(bridge.connections)))))
    except Exception:
        traceback.print_exc()
asyncio.run(main())
PY
code=$?; set -e
kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f -- "$TOKEN"; trap - EXIT
{ echo V0106_BRIDGE_MODULE; echo "exit=$code"; tail -120 "$OUT"; echo SERVER; tail -80 "$OUT.server"; curl -fsS http://127.0.0.1:8787/health; } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

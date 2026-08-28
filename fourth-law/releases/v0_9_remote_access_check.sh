#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/fourth-law-agent
URL="$(docker compose logs tunnel --tail=400 2>&1 | grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
[[ -n "$URL" ]]
HTTP="$(curl -L -sS --max-time 20 -o /tmp/fl09-edge.html -w '%{http_code}' "$URL/control-room" || true)"
OK=false
if [[ "$HTTP" = 200 ]] && grep -q 'Fourth Law · Control Room' /tmp/fl09-edge.html; then OK=true; fi
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "CONTROL_ROOM_V0_9_REMOTE_CHECK {\"url\":\"$URL/control-room\",\"http\":$HTTP,\"ui_marker\":$OK}" >/dev/null 2>&1 || true
[[ "$OK" = true ]]
echo CONTROL_ROOM_REMOTE_ACCESS_OK

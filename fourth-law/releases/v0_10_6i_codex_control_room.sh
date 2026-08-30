#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
DEV_HOME=/var/lib/fourthlaw-dev
TOKEN_FILE="$DEV_HOME/appserver-token"
UNIT=/etc/systemd/system/fourthlaw-codex.service
CONFIG="$DEV_HOME/.codex/config.toml"
REPORT=/tmp/fl-v0106f-report.txt
STAGE="$(mktemp -d /tmp/fl-v0106f-stage.XXXXXX)"
BACKUP="$(mktemp -d /opt/fl-v0106f-backup.XXXXXX)"
UNIT_BACKUP="$(mktemp /tmp/fourthlaw-codex.service.XXXXXX)"
CONFIG_BACKUP="$(mktemp /tmp/fourthlaw-codex.config.XXXXXX)"
BASE=https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases/v0_10_6
STEP=starting
DEPLOY_STARTED=0

fail(){
  code=$?; trap - ERR; set +e
  test -f "$UNIT_BACKUP" && install -m 0644 "$UNIT_BACKUP" "$UNIT"
  test -f "$CONFIG_BACKUP" && install -m 0600 -o fourthlaw-dev -g fourthlaw-dev "$CONFIG_BACKUP" "$CONFIG"
  if test "$DEPLOY_STARTED" = 1; then
    rsync -a --delete --exclude '.env' --exclude 'data/' "$BACKUP/" "$PROJECT/" >>"$REPORT" 2>&1
    systemctl daemon-reload
    systemctl restart fourthlaw-codex.service >>"$REPORT" 2>&1
    docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1
  fi
  { echo CODEX_CONTROL_ROOM_V0_10_6F_FAILED; echo "step=$STEP"; echo "rollback_attempted=$DEPLOY_STARTED"; tail -120 "$REPORT"; } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
  exit "$code"
}
trap fail ERR
: >"$REPORT"

STEP=stage
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$STAGE/"
install -d "$STAGE/app/static"
cp "$UNIT" "$UNIT_BACKUP"
cp "$CONFIG" "$CONFIG_BACKUP"
curl -fsSL "$BASE/codex_control_v2.py" -o "$STAGE/app/codex_control.py"
curl -fsSL "$BASE/codex.html" -o "$STAGE/app/static/codex.html"
printf '%s  %s\n' 2b159fe340109e7176f5b4e0a2e2cdfe1063042b1d87a3e80934e05d5fd3c446 "$STAGE/app/codex_control.py" | sha256sum -c - >>"$REPORT"
printf '%s  %s\n' f3195ab099fe731e78446f25e36f2cbe409743d8aa3a6f5ec65efba562104add "$STAGE/app/static/codex.html" | sha256sum -c - >>"$REPORT"

STEP=patch_integration
python3 - "$STAGE" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
p=root/'app/main.py'; s=p.read_text()
s=s.replace('from app.control_room import router as control_room_router, configure_control_room', 'from app.control_room import router as control_room_router, configure_control_room\nfrom app.codex_control import router as codex_control_router')
s=s.replace('version="0.10.4"', 'version="0.10.6"').replace('app.include_router(control_room_router)', 'app.include_router(control_room_router)\napp.include_router(codex_control_router)')
s=s.replace('"version":"0.10.4","architecture":"recursive-exact-four-way', '"version":"0.10.6","architecture":"recursive-exact-four-way').replace('+bounded-code-workspace-v0.10.4"', '+bounded-code-workspace-v0.10.4+codex-control-room-v0.10.6"').replace('return {"version":"0.10.4","supervisor"', 'return {"version":"0.10.6","supervisor"')
if not all(x in s for x in ('from app.codex_control import router as codex_control_router','app.include_router(codex_control_router)','"version":"0.10.6"')): raise SystemExit('main invariant failed')
p.write_text(s)
p=root/'app/control_room.py'; s=p.read_text().replace("return {'authenticated': _valid_session(fl_session), 'version': '0.10.2'}", "return {'authenticated': _valid_session(fl_session), 'version': '0.10.6', 'codex_workspace': '/control-room/codex'}")
if "'version': '0.10.6'" not in s: raise SystemExit('control room invariant failed')
p.write_text(s)
p=root/'requirements.txt'; s=p.read_text(); p.write_text(s if 'websockets' in s else s.rstrip()+'\nwebsockets>=15,<17\n')
p=root/'compose.yaml'; s=p.read_text(); token='      - /var/lib/fourthlaw-dev/appserver-token:/run/secrets/fourthlaw-codex-token:ro'
if token not in s:
    if '    volumes: ["./data:/data"]' in s: s=s.replace('    volumes: ["./data:/data"]','    volumes:\n      - ./data:/data\n'+token)
    else: s=s.replace('    volumes:\n      - ./data:/data','    volumes:\n      - ./data:/data\n'+token)
if 'host.docker.internal:host-gateway' not in s:
    s=s.replace(token, token+'\n    extra_hosts:\n      - "host.docker.internal:host-gateway"')
if token not in s or 'host.docker.internal:host-gateway' not in s: raise SystemExit('compose bridge invariant failed')
p.write_text(s)
PY
python3 -m py_compile "$STAGE"/app/*.py
docker build --quiet -t fourth-law-agent:v0.10.6-test "$STAGE" >>"$REPORT" 2>&1
docker run --rm --entrypoint /bin/sh fourth-law-agent:v0.10.6-test -c 'python -m py_compile /app/app/*.py' >>"$REPORT" 2>&1

STEP=configure_authenticated_appserver
docker_ip="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
python3 -c 'import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); assert ip.is_private' "$docker_ip"
if ! test -s "$TOKEN_FILE"; then openssl rand -hex 32 >"$TOKEN_FILE"; fi
chown fourthlaw-dev:fourthlaw-dev "$TOKEN_FILE"; chmod 0600 "$TOKEN_FILE"
cat >"$CONFIG" <<'TOML'
model = "gpt-5.6-terra"
model_reasoning_effort = "medium"
approval_policy = "never"
project_doc_max_bytes = 65536
default_permissions = "fourthlaw-workspace"

[shell_environment_policy]
inherit = "core"
ignore_default_excludes = false

[permissions.fourthlaw-workspace]
extends = ":workspace"

[permissions.fourthlaw-workspace.filesystem]
":root" = "deny"
":minimal" = "read"
"/var/lib/fourthlaw-dev/source/.git" = "read"
"/var/lib/fourthlaw-dev/worktrees" = "read"

[permissions.fourthlaw-workspace.filesystem.":workspace_roots"]
"." = "write"
"**/.env" = "deny"
"**/.env.*" = "deny"
"**/*secret*" = "deny"
"**/*credential*" = "deny"

[permissions.fourthlaw-workspace.network]
enabled = false
TOML
chown fourthlaw-dev:fourthlaw-dev "$CONFIG"; chmod 0600 "$CONFIG"
runuser -u fourthlaw-dev -- env HOME="$DEV_HOME" CODEX_HOME="$DEV_HOME/.codex" codex features list >/dev/null
python3 - "$UNIT" "$docker_ip" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); ip=sys.argv[2]
s=p.read_text()
line=f'ExecStart=/usr/local/bin/codex app-server --listen ws://{ip}:4500 --ws-auth capability-token --ws-token-file /var/lib/fourthlaw-dev/appserver-token'
s='\n'.join(line if x.startswith('ExecStart=') else x for x in s.splitlines())+'\n'
p.write_text(s)
PY

STEP=backup_and_install
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$BACKUP/"
DEPLOY_STARTED=1
rsync -a --delete --exclude '.env' --exclude 'data/' "$STAGE/" "$PROJECT/"
systemctl daemon-reload
systemctl restart fourthlaw-codex.service
for _ in $(seq 1 40); do curl -fsS "http://$docker_ip:4500/readyz" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://$docker_ip:4500/readyz" >/dev/null
docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1
health=''
for _ in $(seq 1 60); do health="$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true)"; echo "$health" | grep -q '"version":"0.10.6"' && break; sleep 2; done
echo "$health" | grep -q '"ok":true'; echo "$health" | grep -q '"version":"0.10.6"'

STEP=authenticated_bridge_test
pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
cookie="$STAGE/cookie"
curl -fsS -c "$cookie" -H 'Content-Type: application/json' -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null; unset pair_code
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/sessions | grep -q '"roles"'
created="$(curl -fsS -b "$cookie" -H 'Content-Type: application/json' -d '{"role":"efficiency","message":"Read the repository instructions without changing files. Reply exactly CODEX_CONTROL_ROOM_READY."}' http://127.0.0.1:8787/control-room/api/codex/sessions)"
sid="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$created")"
ready=0
for _ in $(seq 1 90); do state="$(curl -fsS -b "$cookie" "http://127.0.0.1:8787/control-room/api/codex/sessions/$sid")"; if echo "$state" | grep -q CODEX_CONTROL_ROOM_READY; then ready=1; break; fi; if echo "$state" | grep -Eq '"status":"(failed|interrupted)"'; then echo "$state" >>"$REPORT"; break; fi; sleep 2; done
test "$ready" = 1

STEP=success
DEPLOY_STARTED=0
{ echo CODEX_CONTROL_ROOM_V0_10_6F_DEPLOYED; echo transport=authenticated-docker-bridge-websocket; echo persistent_threads=true; echo active_turn_steering=true; echo role_worktrees=runtime,control-room,execution,efficiency; echo arbitrary_cwd=false; echo command_network=false; echo credential_read=false; echo direct_production_write=false; echo authenticated_bridge_test=CODEX_CONTROL_ROOM_READY; echo control_room_path=/control-room/codex; echo "health=$health"; } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
trap - ERR
rm -f -- "$UNIT_BACKUP"
rm -f -- "$CONFIG_BACKUP"
echo CODEX_CONTROL_ROOM_V0_10_6F_READY

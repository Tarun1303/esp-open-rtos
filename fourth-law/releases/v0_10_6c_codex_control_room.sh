#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
REPORT=/tmp/fl-v0106c-report.txt
STAGE="$(mktemp -d /tmp/fl-v0106c-stage.XXXXXX)"
BACKUP="$(mktemp -d /opt/fl-v0106c-backup.XXXXXX)"
BASE=https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases/v0_10_6
STEP=starting
DEPLOY_STARTED=0
fail(){ code=$?; trap - ERR; set +e; if test "$DEPLOY_STARTED" = 1; then rsync -a --delete --exclude '.env' --exclude 'data/' "$BACKUP/" "$PROJECT/" >>"$REPORT" 2>&1; docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1; fi; { echo CODEX_CONTROL_ROOM_V0_10_6C_FAILED; echo "step=$STEP"; echo "rollback_attempted=$DEPLOY_STARTED"; tail -100 "$REPORT"; } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true; rm -rf -- "$STAGE" "$BACKUP"; exit "$code"; }
trap fail ERR
: >"$REPORT"

STEP=stage_current_production
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$STAGE/"
install -d "$STAGE/app/static"

STEP=download_verified_payload
curl -fsSL "$BASE/codex_control.py" -o "$STAGE/app/codex_control.py"
curl -fsSL "$BASE/codex.html" -o "$STAGE/app/static/codex.html"
printf '%s  %s\n' 5e077d95ceabef62c780871e6dc19848a51cebfdf5053d6f2da3c97df81451e1 "$STAGE/app/codex_control.py" | sha256sum -c - >>"$REPORT"
printf '%s  %s\n' f3195ab099fe731e78446f25e36f2cbe409743d8aa3a6f5ec65efba562104add "$STAGE/app/static/codex.html" | sha256sum -c - >>"$REPORT"

STEP=patch_integration
python3 - "$STAGE" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
p=root/'app/main.py'; s=p.read_text()
s=s.replace('from app.control_room import router as control_room_router, configure_control_room', 'from app.control_room import router as control_room_router, configure_control_room\nfrom app.codex_control import router as codex_control_router')
s=s.replace('version="0.10.4"', 'version="0.10.6"')
s=s.replace('app.include_router(control_room_router)', 'app.include_router(control_room_router)\napp.include_router(codex_control_router)')
s=s.replace('"version":"0.10.4","architecture":"recursive-exact-four-way', '"version":"0.10.6","architecture":"recursive-exact-four-way')
s=s.replace('+bounded-code-workspace-v0.10.4"', '+bounded-code-workspace-v0.10.4+codex-control-room-v0.10.6"')
s=s.replace('return {"version":"0.10.4","supervisor"', 'return {"version":"0.10.6","supervisor"')
if not all(x in s for x in ('from app.codex_control import router as codex_control_router','app.include_router(codex_control_router)','"version":"0.10.6"')): raise SystemExit('main.py invariant failed')
p.write_text(s)
p=root/'app/control_room.py'; s=p.read_text(); s=s.replace("return {'authenticated': _valid_session(fl_session), 'version': '0.10.2'}", "return {'authenticated': _valid_session(fl_session), 'version': '0.10.6', 'codex_workspace': '/control-room/codex'}")
if "'version': '0.10.6'" not in s: raise SystemExit('control room invariant failed')
p.write_text(s)
p=root/'requirements.txt'; s=p.read_text(); p.write_text(s if 'websockets' in s else s.rstrip()+'\nwebsockets>=15,<17\n')
p=root/'compose.yaml'; s=p.read_text(); mount='      - /run/fourthlaw-codex:/run/fourthlaw-codex:ro'
if mount not in s:
    if '    volumes: ["./data:/data"]' in s:
        s=s.replace('    volumes: ["./data:/data"]', '    volumes:\n      - ./data:/data\n'+mount)
    else:
        s=s.replace('    volumes:\n      - ./data:/data','    volumes:\n      - ./data:/data\n'+mount)
if mount not in s: raise SystemExit('socket mount invariant failed')
p.write_text(s)
PY

STEP=static_validation
python3 -m py_compile "$STAGE"/app/*.py
grep -q 'networkAccess.*False' "$STAGE/app/codex_control.py"
grep -q 'readOnlyAccess' "$STAGE/app/codex_control.py"

STEP=container_build_test
docker build --quiet -t fourth-law-agent:v0.10.6-test "$STAGE" >>"$REPORT" 2>&1
docker run --rm --entrypoint python fourth-law-agent:v0.10.6-test -m py_compile /app/app/*.py >>"$REPORT" 2>&1

STEP=backup
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$BACKUP/"
DEPLOY_STARTED=1
STEP=install
rsync -a --delete --exclude '.env' --exclude 'data/' "$STAGE/" "$PROJECT/"
STEP=restart
docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1
health=''
for _ in $(seq 1 60); do health="$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true)"; echo "$health" | grep -q '"version":"0.10.6"' && break; sleep 2; done
echo "$health" | grep -q '"ok":true'; echo "$health" | grep -q '"version":"0.10.6"'
docker exec fourth-law-agent test -S /run/fourthlaw-codex/app.sock
systemctl is-active --quiet fourthlaw-codex.service

STEP=authenticated_bridge_test
pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
cookie="$STAGE/cookie"
curl -fsS -c "$cookie" -H 'Content-Type: application/json' -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/sessions | grep -q '"roles"'
created="$(curl -fsS -b "$cookie" -H 'Content-Type: application/json' -d '{"role":"efficiency","message":"Read the repository instructions without changing files. Reply exactly CODEX_CONTROL_ROOM_READY."}' http://127.0.0.1:8787/control-room/api/codex/sessions)"
sid="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$created")"
ready=0
for _ in $(seq 1 90); do state="$(curl -fsS -b "$cookie" "http://127.0.0.1:8787/control-room/api/codex/sessions/$sid")"; if echo "$state" | grep -q CODEX_CONTROL_ROOM_READY; then ready=1; break; fi; if echo "$state" | grep -Eq '"status":"(failed|interrupted)"'; then break; fi; sleep 2; done
test "$ready" = 1

STEP=success
DEPLOY_STARTED=0
{ echo CODEX_CONTROL_ROOM_V0_10_6C_DEPLOYED; echo persistent_threads=true; echo active_turn_steering=true; echo role_worktrees=runtime,control-room,execution,efficiency; echo arbitrary_cwd=false; echo command_network=false; echo credential_read=false; echo direct_production_write=false; echo authenticated_bridge_test=CODEX_CONTROL_ROOM_READY; echo control_room_path=/control-room/codex; echo "health=$health"; } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
trap - ERR
rm -rf -- "$STAGE" "$BACKUP"
echo CODEX_CONTROL_ROOM_V0_10_6C_READY

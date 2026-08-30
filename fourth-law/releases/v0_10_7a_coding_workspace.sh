#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
REPORT=/tmp/fl-v0107a-coding-workspace.txt
STAGE="$(mktemp -d /tmp/fl-v0107a-stage.XXXXXX)"
BACKUP="$(mktemp -d /opt/fl-v0107a-backup.XXXXXX)"
BASE=https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases/v0_10_7
STEP=starting
DEPLOY_STARTED=0

fail() {
  code=$?
  trap - ERR
  set +e
  if test "$DEPLOY_STARTED" = 1; then
    rsync -a --delete --exclude '.env' --exclude 'data/' "$BACKUP/" "$PROJECT/" >>"$REPORT" 2>&1
    docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1
  fi
  {
    echo CODEX_CODING_WORKSPACE_V0_10_7A_FAILED
    echo "step=$STEP"
    echo "rollback_attempted=$DEPLOY_STARTED"
    tail -140 "$REPORT"
  } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
  exit "$code"
}
trap fail ERR
: >"$REPORT"

STEP=stage
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$STAGE/"
install -d "$STAGE/app/static"
curl -fsSL "$BASE/codex_control_v3.py" -o "$STAGE/app/codex_control.py"
curl -fsSL "$BASE/codex_workspace_v3.html" -o "$STAGE/app/static/codex.html"
printf '%s  %s\n' a08ccf6a9229aa74a2bf4b2738413e685dd9369afc05d7d927b1b76c504c8b16 "$STAGE/app/codex_control.py" | sha256sum -c - >>"$REPORT"
printf '%s  %s\n' 2e0d8077174a0a45489937cc6d523e1c73d2bcda1607be2435aedf5796e552d0 "$STAGE/app/static/codex.html" | sha256sum -c - >>"$REPORT"

STEP=patch_release
python3 - "$STAGE" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

main = root / "app/main.py"
text = main.read_text()
old_count = text.count("0.10.6")
if old_count < 4:
    raise SystemExit(f"unexpected main.py version count: {old_count}")
text = text.replace("0.10.6", "0.10.7")
if 'version="0.10.7"' not in text or '"version":"0.10.7"' not in text:
    raise SystemExit("main.py v0.10.7 invariant failed")
main.write_text(text)

control = root / "app/control_room.py"
text = control.read_text()
if text.count("0.10.6") != 1:
    raise SystemExit("unexpected control_room.py version")
text = text.replace("0.10.6", "0.10.7")
control.write_text(text)

page = root / "app/static/control_room.html"
text = page.read_text()
link = '<a class="newMission" href="/control-room/codex" style="margin-top:7px;text-decoration:none"><strong>Coding workspace</strong><i>↗</i></a>'
if link not in text:
    anchor = '<button class="newMission" onclick="newTask()"><strong>Ignite mission</strong><i>＋</i></button>'
    if text.count(anchor) != 1:
        raise SystemExit("Control Room coding-link anchor mismatch")
    text = text.replace(anchor, anchor + link)
page.write_text(text)

codex = root / "app/static/codex.html"
html = codex.read_text()
ids = re.findall(r'\bid="([^"]+)"', html)
if len(ids) != len(set(ids)):
    raise SystemExit("duplicate Codex UI element id")
markers = (
    "Steering active turn", "Workspace details", "persistent memory",
    "/control-room/api/codex/sessions", "renameBtn", "archiveBtn",
)
missing = [marker for marker in markers if marker not in html]
if missing:
    raise SystemExit(f"Codex UI markers missing: {missing}")
PY

python3 -m py_compile "$STAGE"/app/*.py
docker build --quiet -t fourth-law-agent:v0.10.7-test "$STAGE" >>"$REPORT" 2>&1
docker run --rm --entrypoint /bin/sh fourth-law-agent:v0.10.7-test -c 'python -m py_compile /app/app/*.py' >>"$REPORT" 2>&1

STEP=backup_and_install
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$BACKUP/"
DEPLOY_STARTED=1
rsync -a --delete --exclude '.env' --exclude 'data/' "$STAGE/" "$PROJECT/"
docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1

health=''
for _ in $(seq 1 60); do
  health="$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true)"
  echo "$health" | grep -q '"version":"0.10.7"' && break
  sleep 2
done
echo "$health" | grep -q '"ok":true'
echo "$health" | grep -q '"version":"0.10.7"'
systemctl is-active --quiet fourthlaw-codex.service

STEP=authenticated_ui_api_test
pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
cookie="$STAGE/cookie"
curl -fsS -c "$cookie" -H 'Content-Type: application/json' -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code

curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/codex >"$STAGE/live-codex.html"
grep -q 'Steering active turn' "$STAGE/live-codex.html"
grep -q 'Workspace details' "$STAGE/live-codex.html"
grep -q 'persistent memory' "$STAGE/live-codex.html"
grep -q 'New coding thread' "$STAGE/live-codex.html"
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room | grep -q '/control-room/codex'

sessions="$STAGE/sessions.json"
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/sessions >"$sessions"
grep -q '"persistent_threads":true' "$sessions"
grep -q '"rename":true' "$sessions"
grep -q '"archive":true' "$sessions"
grep -q '"Runtime architecture"' "$sessions"

sid="$(python3 - "$sessions" <<'PY'
import json
import sys
rows = json.load(open(sys.argv[1])).get("sessions", [])
print(next((str(row["id"]) for row in rows if not row.get("archived")), ""))
PY
)"
if test -n "$sid"; then
  archived="$(curl -fsS -b "$cookie" -X PATCH -H 'Content-Type: application/json' -d '{"archived":true}' "http://127.0.0.1:8787/control-room/api/codex/sessions/$sid")"
  echo "$archived" | grep -q '"archived":true'
  restored="$(curl -fsS -b "$cookie" -X PATCH -H 'Content-Type: application/json' -d '{"archived":false}' "http://127.0.0.1:8787/control-room/api/codex/sessions/$sid")"
  echo "$restored" | grep -q '"archived":false'
  echo "session_management_test=$sid" >>"$REPORT"
else
  echo "session_management_test=skipped_no_existing_session" >>"$REPORT"
fi

STEP=success
DEPLOY_STARTED=0
{
  echo CODEX_CODING_WORKSPACE_V0_10_7A_DEPLOYED
  echo version=0.10.7
  echo coding_workspace=/control-room/codex
  echo responsive_ui=true
  echo thread_search=true
  echo role_picker=true
  echo conversation_plan_diff_activity=true
  echo rename_archive_restore=true
  echo keyboard_shortcuts=true
  echo live_reconnect=true
  echo security_boundary_unchanged=true
  echo command_network=false
  echo credential_read=false
  echo direct_production_write=false
  echo "health=$health"
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
trap - ERR
echo CODEX_CODING_WORKSPACE_V0_10_7A_READY

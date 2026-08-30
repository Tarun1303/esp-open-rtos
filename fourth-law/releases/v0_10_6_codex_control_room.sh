#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
DEV_HOME=/var/lib/fourthlaw-dev
SOURCE="$DEV_HOME/source"
WORKTREES="$DEV_HOME/worktrees"
BRANCH=codex-control-room-v0.10.6
EXPECTED=5d89b9c836d41d7776f8d609bc523c66669a4ff8
REPORT=/tmp/fl-v0106-report.txt
TMP="$(mktemp -d /tmp/fl-v0106.XXXXXX)"
BACKUP="$(mktemp -d /opt/fourth-law-agent-v0106-backup.XXXXXX)"
STEP=starting
DEPLOY_STARTED=0

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

rollback() {
  set +e
  if test "$DEPLOY_STARTED" = 1; then
    rsync -a --delete --exclude '.env' --exclude 'data/' "$BACKUP/" "$PROJECT/" >>"$REPORT" 2>&1
    docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1
  fi
  {
    echo CODEX_CONTROL_ROOM_V0_10_6_FAILED
    echo "step=$STEP"
    echo "rollback_attempted=$DEPLOY_STARTED"
    tail -100 "$REPORT"
  } | report_issue
  rm -rf -- "$TMP" "$BACKUP"
}
trap rollback ERR
: >"$REPORT"

STEP=fetch_exact_private_source
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth setup-git >>"$REPORT" 2>&1
git clone --quiet --branch "$BRANCH" --single-branch https://github.com/Tarun1303/factory.git "$TMP/source" >>"$REPORT" 2>&1
actual="$(git -C "$TMP/source" rev-parse HEAD)"
test "$actual" = "$EXPECTED"

STEP=static_validation
python3 -m py_compile "$TMP/source"/app/*.py
grep -q 'sandboxPolicy' "$TMP/source/app/codex_control.py"
grep -q 'networkAccess.*False' "$TMP/source/app/codex_control.py"
grep -q '/var/lib/fourthlaw-dev/worktrees' "$TMP/source/app/codex_control.py"
if grep -Eq '(/opt/fourth-law-agent|\.env|auth\.json).*writableRoots' "$TMP/source/app/codex_control.py"; then
  echo 'Unsafe writable root detected' >>"$REPORT"
  exit 41
fi

STEP=container_build_test
docker build --quiet -t fourth-law-agent:v0.10.6-test "$TMP/source" >>"$REPORT" 2>&1
docker run --rm --entrypoint python fourth-law-agent:v0.10.6-test -m py_compile /app/app/*.py >>"$REPORT" 2>&1

STEP=backup
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$BACKUP/"
DEPLOY_STARTED=1

STEP=install
rsync -a --delete --exclude '.git/' --exclude '.github/' --exclude '.env' --exclude 'data/' "$TMP/source/" "$PROJECT/"

STEP=restart
docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1
for _ in $(seq 1 60); do
  health="$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true)"
  echo "$health" | grep -q '"version":"0.10.6"' && break
  sleep 2
done
echo "$health" | grep -q '"ok":true'
echo "$health" | grep -q '"version":"0.10.6"'
docker exec fourth-law-agent test -S /run/fourthlaw-codex/app.sock
systemctl is-active --quiet fourthlaw-codex.service

STEP=authenticated_bridge_test
pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
cookie="$TMP/cookie"
curl -fsS -c "$cookie" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/sessions | grep -q '"roles"'
payload='{"role":"efficiency","message":"Read the repository instructions without changing files. Reply exactly CODEX_CONTROL_ROOM_READY."}'
created="$(curl -fsS -b "$cookie" -H 'Content-Type: application/json' -d "$payload" http://127.0.0.1:8787/control-room/api/codex/sessions)"
sid="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$created")"
test -n "$sid"
ready=0
for _ in $(seq 1 90); do
  state="$(curl -fsS -b "$cookie" "http://127.0.0.1:8787/control-room/api/codex/sessions/$sid")"
  if echo "$state" | grep -q 'CODEX_CONTROL_ROOM_READY'; then ready=1; break; fi
  if echo "$state" | grep -Eq '"status":"(failed|interrupted)"'; then break; fi
  sleep 2
done
test "$ready" = 1

STEP=sync_development_baseline
git config --global --add safe.directory "$SOURCE" || true
if test -z "$(git -C "$SOURCE" status --porcelain)"; then
  git -C "$SOURCE" fetch origin "$BRANCH" >>"$REPORT" 2>&1
  chown -R fourthlaw-dev:fourthlaw-dev "$SOURCE/.git"
  runuser -u fourthlaw-dev -- git -C "$SOURCE" merge --ff-only FETCH_HEAD >>"$REPORT" 2>&1
  for role in runtime control-room execution efficiency; do
    worktree="$WORKTREES/$role"
    if test -z "$(git -C "$worktree" status --porcelain)"; then
      runuser -u fourthlaw-dev -- git -C "$worktree" merge --ff-only main >>"$REPORT" 2>&1 || \
        echo "worktree_sync_skipped=$role" >>"$REPORT"
    else
      echo "worktree_dirty_preserved=$role" >>"$REPORT"
    fi
  done
fi

STEP=success
DEPLOY_STARTED=0
{
  echo CODEX_CONTROL_ROOM_V0_10_6_DEPLOYED
  echo "source_commit=$EXPECTED"
  echo 'persistent_threads=true'
  echo 'active_turn_steering=true'
  echo 'role_worktrees=runtime,control-room,execution,efficiency'
  echo 'arbitrary_cwd=false'
  echo 'command_network=false'
  echo 'credential_read=false'
  echo 'direct_production_write=false'
  echo 'authenticated_bridge_test=CODEX_CONTROL_ROOM_READY'
  echo 'control_room_path=/control-room/codex'
  echo "health=$health"
} | report_issue

trap - ERR
rm -rf -- "$TMP" "$BACKUP"
echo CODEX_CONTROL_ROOM_V0_10_6_READY

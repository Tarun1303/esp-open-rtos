#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
DEV_HOME=/var/lib/fourthlaw-dev
SOURCE="$DEV_HOME/source"
WORKTREES="$DEV_HOME/worktrees"
REPORT=/tmp/fl-v0106-continuity.txt
STEP=starting
fail(){ code=$?; trap - ERR; { echo CODEX_V0_10_6_CONTINUITY_FAILED; echo "step=$STEP"; tail -100 "$REPORT"; curl -fsS http://127.0.0.1:8787/health || true; } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true; exit "$code"; }
trap fail ERR
: >"$REPORT"

STEP=preconditions
curl -fsS http://127.0.0.1:8787/health | grep -q '"version":"0.10.6"'
systemctl is-active --quiet fourthlaw-codex.service
grep -q 'default_permissions = "fourthlaw-workspace"' "$DEV_HOME/.codex/config.toml"
grep -q '":root" = "deny"' "$DEV_HOME/.codex/config.toml"
grep -q 'enabled = false' "$DEV_HOME/.codex/config.toml"
for role in runtime control-room execution efficiency; do test -z "$(runuser -u fourthlaw-dev -- git -C "$WORKTREES/$role" status --porcelain)"; done

STEP=authenticate_control_room
TMP="$(mktemp -d /tmp/fl-v0106-continuity.XXXXXX)"
pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
cookie="$TMP/cookie"
curl -fsS -c "$cookie" -H 'Content-Type: application/json' -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code

wait_marker(){
  local sid=$1 marker=$2 state=''
  for _ in $(seq 1 90); do
    state="$(curl -fsS -b "$cookie" "http://127.0.0.1:8787/control-room/api/codex/sessions/$sid")"
    turn_state="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' <<<"$state")"
    if echo "$state" | grep -q "$marker" && test "$turn_state" != working; then return 0; fi
    echo "$state" | grep -Eq '"status":"(failed|interrupted|disconnected)"' && { echo "$state" >>"$REPORT"; return 1; }
    sleep 2
  done
  echo "$state" >>"$REPORT"; return 1
}

STEP=first_turn
created="$(curl -fsS -b "$cookie" -H 'Content-Type: application/json' -d '{"role":"efficiency","message":"Do not change files. Reply exactly FIRST_TURN_READY."}' http://127.0.0.1:8787/control-room/api/codex/sessions)"
sid="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$created")"
thread="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["thread_id"])' <<<"$created")"
wait_marker "$sid" FIRST_TURN_READY

STEP=same_thread_continuation
continued="$(curl -fsS -b "$cookie" -H 'Content-Type: application/json' -d '{"message":"Do not change files. Reply exactly SECOND_TURN_SAME_THREAD."}' "http://127.0.0.1:8787/control-room/api/codex/sessions/$sid/messages")"
echo "$continued" | grep -q '"action":"started"'
thread2="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["session"]["thread_id"])' <<<"$continued")"
test "$thread" = "$thread2"
wait_marker "$sid" SECOND_TURN_SAME_THREAD

STEP=active_turn_steering
curl -fsS -b "$cookie" -H 'Content-Type: application/json' -d '{"message":"Inspect AGENTS.md without changing files and prepare a short summary."}' "http://127.0.0.1:8787/control-room/api/codex/sessions/$sid/messages" >/dev/null
steered="$(curl -fsS -b "$cookie" -H 'Content-Type: application/json' -d '{"message":"Steer this active turn: instead reply exactly ACTIVE_TURN_STEERED."}' "http://127.0.0.1:8787/control-room/api/codex/sessions/$sid/messages")"
echo "$steered" | grep -q '"action":"steered"'
wait_marker "$sid" ACTIVE_TURN_STEERED

STEP=sync_managed_worktrees
test -z "$(runuser -u fourthlaw-dev -- git -C "$SOURCE" status --porcelain)"
rsync -a "$PROJECT/app/" "$SOURCE/app/"
for name in Dockerfile compose.yaml requirements.txt; do install -m 0640 -o fourthlaw-dev -g fourthlaw-dev "$PROJECT/$name" "$SOURCE/$name"; done
chown -R fourthlaw-dev:fourthlaw-dev "$SOURCE/app"
runuser -u fourthlaw-dev -- python3 -m py_compile "$SOURCE"/app/*.py
runuser -u fourthlaw-dev -- git -C "$SOURCE" add app Dockerfile compose.yaml requirements.txt
if ! runuser -u fourthlaw-dev -- git -C "$SOURCE" diff --cached --quiet; then
  runuser -u fourthlaw-dev -- git -C "$SOURCE" commit -m 'Sync verified Codex Control Room v0.10.6' >>"$REPORT" 2>&1
fi
for role in runtime control-room execution efficiency; do
  runuser -u fourthlaw-dev -- git -C "$WORKTREES/$role" merge --ff-only main >>"$REPORT" 2>&1
  test -z "$(runuser -u fourthlaw-dev -- git -C "$WORKTREES/$role" status --porcelain)"
  grep -q 'version="0.10.6"' "$WORKTREES/$role/app/main.py"
done

STEP=success
commit="$(runuser -u fourthlaw-dev -- git -C "$SOURCE" rev-parse --short=12 HEAD)"
health="$(curl -fsS http://127.0.0.1:8787/health)"
{ echo CODEX_V0_10_6_CONTINUITY_VERIFIED; echo "thread_id=$thread"; echo same_thread_continuation=true; echo active_turn_steering=true; echo worktrees_synced=runtime,control-room,execution,efficiency; echo "managed_source_commit=$commit"; echo permission_profile=fourthlaw-workspace; echo filesystem_root_read=denied; echo command_network=denied; echo "health=$health"; } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
trap - ERR
echo CODEX_V0_10_6_CONTINUITY_READY

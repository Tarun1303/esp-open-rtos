#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
DEV_HOME=/var/lib/fourthlaw-dev
SOURCE="$DEV_HOME/source"
WORKTREES="$DEV_HOME/worktrees"
REPORT=/tmp/fl-v0107-worktree-sync.txt
STEP=starting

fail() {
  code=$?
  trap - ERR
  {
    echo CODEX_V0_10_7_WORKTREE_SYNC_FAILED
    echo "step=$STEP"
    tail -120 "$REPORT"
    curl -fsS http://127.0.0.1:8787/health || true
  } | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
  exit "$code"
}
trap fail ERR
: >"$REPORT"

STEP=preconditions
curl -fsS http://127.0.0.1:8787/health | grep -q '"version":"0.10.7"'
systemctl is-active --quiet fourthlaw-codex.service
grep -q 'default_permissions = "fourthlaw-workspace"' "$DEV_HOME/.codex/config.toml"
grep -q '":root" = "deny"' "$DEV_HOME/.codex/config.toml"
grep -q 'enabled = false' "$DEV_HOME/.codex/config.toml"
test -z "$(runuser -u fourthlaw-dev -- git -C "$SOURCE" status --porcelain)"
for role in runtime control-room execution efficiency; do
  test -z "$(runuser -u fourthlaw-dev -- git -C "$WORKTREES/$role" status --porcelain)"
done

STEP=sync_managed_source
rsync -a "$PROJECT/app/" "$SOURCE/app/"
for name in Dockerfile compose.yaml requirements.txt; do
  install -m 0640 -o fourthlaw-dev -g fourthlaw-dev "$PROJECT/$name" "$SOURCE/$name"
done
chown -R fourthlaw-dev:fourthlaw-dev "$SOURCE/app"
runuser -u fourthlaw-dev -- python3 -m py_compile "$SOURCE"/app/*.py
grep -q 'version="0.10.7"' "$SOURCE/app/main.py"
grep -q 'Steering active turn' "$SOURCE/app/static/codex.html"
grep -q '/control-room/codex' "$SOURCE/app/static/control_room.html"
runuser -u fourthlaw-dev -- git -C "$SOURCE" add app Dockerfile compose.yaml requirements.txt
if ! runuser -u fourthlaw-dev -- git -C "$SOURCE" diff --cached --quiet; then
  runuser -u fourthlaw-dev -- git -C "$SOURCE" commit -m 'Sync verified coding workspace v0.10.7' >>"$REPORT" 2>&1
fi

STEP=fast_forward_role_worktrees
for role in runtime control-room execution efficiency; do
  runuser -u fourthlaw-dev -- git -C "$WORKTREES/$role" merge --ff-only main >>"$REPORT" 2>&1
  test -z "$(runuser -u fourthlaw-dev -- git -C "$WORKTREES/$role" status --porcelain)"
  grep -q 'version="0.10.7"' "$WORKTREES/$role/app/main.py"
  grep -q 'Steering active turn' "$WORKTREES/$role/app/static/codex.html"
done

STEP=success
commit="$(runuser -u fourthlaw-dev -- git -C "$SOURCE" rev-parse --short=12 HEAD)"
health="$(curl -fsS http://127.0.0.1:8787/health)"
{
  echo CODEX_V0_10_7_WORKTREES_SYNCED
  echo "managed_source_commit=$commit"
  echo worktrees=runtime,control-room,execution,efficiency
  echo all_worktrees_clean=true
  echo permission_profile=fourthlaw-workspace
  echo filesystem_root_read=denied
  echo command_network=denied
  echo "health=$health"
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
trap - ERR
echo CODEX_V0_10_7_WORKTREE_SYNC_READY

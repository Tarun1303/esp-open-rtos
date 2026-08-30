#!/usr/bin/env bash
set -Eeuo pipefail

DEV_USER=fourthlaw-dev
DEV_HOME=/var/lib/fourthlaw-dev
SOURCE="$DEV_HOME/source"
CODEX_DIR="$DEV_HOME/.codex"
REPORT=/tmp/fl-v0105b-report.txt
STEP=starting

fail() {
  rc=$?
  trap - ERR
  set +e
  {
    echo CODEX_VPS_WORKSPACE_VERIFICATION_FAILED
    echo "step=$STEP"
    tail -100 "$REPORT" 2>/dev/null || true
  } | HOME=/root GH_CONFIG_DIR=/root/.config/gh \
      gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
  exit "$rc"
}
trap fail ERR
: >"$REPORT"

STEP=local_layout
id "$DEV_USER" >>"$REPORT"
codex --version >>"$REPORT"
test -d "$SOURCE/.git"
for role in runtime control-room execution efficiency; do
  test -e "$DEV_HOME/worktrees/$role/.git"
  test -f "$DEV_HOME/worktrees/$role/AGENTS.override.md"
done
test -f "$CODEX_DIR/auth.json"
test "$(stat -c %a "$CODEX_DIR/auth.json")" = 600

STEP=codex_login
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" CODEX_HOME="$CODEX_DIR" \
  codex login status >>"$REPORT" 2>&1

STEP=codex_read_only_run
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" CODEX_HOME="$CODEX_DIR" \
  codex --ask-for-approval never --cd "$SOURCE" exec \
  --ephemeral --sandbox read-only --model gpt-5.6-terra \
  'Read AGENTS.md and Git status only. Do not edit anything. Return exactly CODEX_WORKSPACE_READY when the repository is readable, clean, and the safety contract is loaded.' \
  >"$DEV_HOME/verified-first-run.txt" 2>>"$REPORT"
grep -q CODEX_WORKSPACE_READY "$DEV_HOME/verified-first-run.txt"
test -z "$(runuser -u "$DEV_USER" -- git -C "$SOURCE" status --porcelain)"

STEP=app_server
systemctl is-active --quiet fourthlaw-codex.service
test -S /run/fourthlaw-codex/app.sock

STEP=publish_private_branch
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth setup-git >>"$REPORT" 2>&1
if git -c safe.directory="$SOURCE" -C "$SOURCE" remote get-url origin >/dev/null 2>&1; then
  git -c safe.directory="$SOURCE" -C "$SOURCE" remote set-url origin https://github.com/Tarun1303/factory.git
else
  git -c safe.directory="$SOURCE" -C "$SOURCE" remote add origin https://github.com/Tarun1303/factory.git
fi
HOME=/root GH_CONFIG_DIR=/root/.config/gh \
  git -c safe.directory="$SOURCE" -C "$SOURCE" push origin main:refs/heads/fourth-law-runtime >>"$REPORT" 2>&1
HOME=/root GH_CONFIG_DIR=/root/.config/gh \
  gh api repos/Tarun1303/factory/branches/fourth-law-runtime --jq '.commit.sha' >>"$REPORT"

STEP=production_isolation
health="$(curl -fsS http://127.0.0.1:8787/health)"
printf '%s' "$health" | grep -q '"version":"0.10.4"'

commit="$(runuser -u "$DEV_USER" -- git -C "$SOURCE" rev-parse --short=12 HEAD)"
{
  echo CODEX_VPS_WORKSPACE_VERIFIED
  echo "codex_version=$(codex --version | head -1)"
  echo "source_commit=$commit"
  echo private_branch=fourth-law-runtime
  echo app_server=active-local-unix-socket
  echo codex_read_only_run=CODEX_WORKSPACE_READY
  echo worktrees=runtime,control-room,execution,efficiency
  echo production_isolated=true
  echo production_health="$health"
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

trap - ERR
echo CODEX_VPS_WORKSPACE_VERIFIED


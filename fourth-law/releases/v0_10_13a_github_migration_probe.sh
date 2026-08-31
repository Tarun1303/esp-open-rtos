#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE=/var/lib/fourthlaw-dev/source
WORKTREES=/var/lib/fourthlaw-dev/worktrees
PROJECT=/opt/fourth-law-agent
REPORT=/tmp/fl-v01013a-github-probe.txt

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  {
    echo FOURTH_LAW_GITHUB_MIGRATION_PROBE_FAILED
    echo "command=$failed_command"
    tail -120 "$REPORT"
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
: >"$REPORT"

health="$(curl -fsS http://127.0.0.1:8787/health)"
echo "$health" | grep -q '"version":"0.10.12"'
test -d "$SOURCE/.git"

source_branch="$(git -C "$SOURCE" symbolic-ref --short HEAD)"
source_head="$(git -C "$SOURCE" rev-parse HEAD)"
source_dirty_count="$(git -C "$SOURCE" status --porcelain | wc -l | tr -d ' ')"
tracked_count="$(git -C "$SOURCE" ls-files | wc -l | tr -d ' ')"
tracked_env_count="$(git -C "$SOURCE" ls-files | grep -E '(^|/)\.env($|\.)' | wc -l | tr -d ' ')"
tracked_secret_name_count="$(git -C "$SOURCE" ls-files | grep -Ei '(^|/)(credentials?|secrets?|id_[rd]sa|.*\.(pem|key|p12|pfx))$' | wc -l | tr -d ' ')"

gh_auth=false
if HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth status -h github.com >/dev/null 2>&1; then
  gh_auth=true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth setup-git >>"$REPORT" 2>&1 || true
fi

remote_read=false
if git ls-remote https://github.com/Tarun1303/fourth-law.git >/dev/null 2>>"$REPORT"; then
  remote_read=true
fi

push_dry_run=false
if git -C "$SOURCE" push --dry-run https://github.com/Tarun1303/fourth-law.git main:main >>"$REPORT" 2>&1; then
  push_dry_run=true
fi

role_summary=''
for role in supervisor architecture runtime control-room execution efficiency; do
  path="$WORKTREES/$role"
  if test -e "$path/.git"; then
    if test -d "$path/.git"; then
      git_layout=independent
    else
      git_layout=shared-worktree
    fi
    branch="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || echo detached)"
    dirty="$(git -C "$path" status --porcelain | wc -l | tr -d ' ')"
    role_summary="${role_summary}${role}:${git_layout}:${branch}:dirty-${dirty},"
  else
    role_summary="${role_summary}${role}:missing,"
  fi
done

path_bindings="$(
  grep -E '/var/lib/fourthlaw-dev/(worktrees|agent-repos)' "$SOURCE/app/codex_control.py" "$SOURCE/compose.yaml" 2>/dev/null \
    | sed -E 's/[[:space:]]+/ /g' \
    | head -80 \
    || true
)"

{
  echo FOURTH_LAW_GITHUB_MIGRATION_PROBE_READY
  echo "source_branch=$source_branch"
  echo "source_head=$source_head"
  echo "source_dirty_count=$source_dirty_count"
  echo "tracked_count=$tracked_count"
  echo "tracked_env_count=$tracked_env_count"
  echo "tracked_secret_name_count=$tracked_secret_name_count"
  echo "gh_auth=$gh_auth"
  echo "remote_read=$remote_read"
  echo "push_dry_run=$push_dry_run"
  echo "roles=$role_summary"
  echo path_bindings_begin
  echo "$path_bindings"
  echo path_bindings_end
  echo "health=$health"
} | report_issue

trap - ERR
echo FOURTH_LAW_GITHUB_MIGRATION_PROBE_DISPATCHED

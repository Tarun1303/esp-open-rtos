#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_COMMIT='0ae0403d248d3b4271f774e22989d6736ae890fc'
SUPERVISOR_REPO='/var/lib/fourthlaw-dev/agent-repos/supervisor'

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

{
  echo FOURTH_LAW_V0_10_14_ROLE_REPOSITORY_STATUS
  echo "release_commit=$RELEASE_COMMIT"
  for role in runtime control-room execution efficiency architecture; do
    repo="/var/lib/fourthlaw-dev/agent-repos/$role"
    echo "role=$role"
    if test ! -d "$repo/.git"; then
      echo repository=missing
      continue
    fi
    echo "branch=$(git -c safe.directory="$repo" -C "$repo" branch --show-current)"
    echo "head=$(git -c safe.directory="$repo" -C "$repo" rev-parse HEAD)"
    if git -c safe.directory="$SUPERVISOR_REPO" -C "$SUPERVISOR_REPO" merge-base --is-ancestor \
      "$(git -c safe.directory="$repo" -C "$repo" rev-parse HEAD)" "$RELEASE_COMMIT"; then
      echo fast_forward_possible=true
    else
      echo fast_forward_possible=false
    fi
    status="$(git -c safe.directory="$repo" -C "$repo" status --porcelain=v1 --untracked-files=all)"
    if test -z "$status"; then
      echo clean=true
    else
      echo clean=false
      printf '%s\n' "$status" | sed -E 's/^(.{2}) /status=\1 path=/'
    fi
  done
  echo production_health="$(curl -fsS http://127.0.0.1:8787/health)"
} | report_issue

echo FOURTH_LAW_V0_10_14_ROLE_REPOSITORY_STATUS_READY

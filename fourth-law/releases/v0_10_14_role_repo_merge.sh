#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_COMMIT='0ae0403d248d3b4271f774e22989d6736ae890fc'
SOURCE_REPO='/var/lib/fourthlaw-dev/agent-repos/supervisor'
REMOTE='git@github.com:Tarun1303/fourth-law.git'
SSH_KEY='/root/.ssh/fourthlaw-github-deploy'
REPORT='/tmp/fl-v01014-role-merge.txt'

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

: >"$REPORT"
test -s "$SSH_KEY"
test "$(git -c safe.directory="$SOURCE_REPO" -C "$SOURCE_REPO" rev-parse HEAD)" = "$RELEASE_COMMIT"
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

synced=0
failed=''
for role in runtime control-room execution efficiency architecture; do
  repo="/var/lib/fourthlaw-dev/agent-repos/$role"
  branch="agent/$role"
  echo "role=$role" >>"$REPORT"
  if test ! -d "$repo/.git"; then
    echo repository_missing=true >>"$REPORT"
    failed="$failed $role:missing"
    continue
  fi
  if test "$(git -c safe.directory="$repo" -C "$repo" branch --show-current)" != "$branch"; then
    echo unexpected_branch=true >>"$REPORT"
    failed="$failed $role:branch"
    continue
  fi
  if test -n "$(git -c safe.directory="$repo" -C "$repo" status --porcelain)"; then
    echo dirty=true >>"$REPORT"
    failed="$failed $role:dirty"
    continue
  fi
  old_head="$(git -c safe.directory="$repo" -C "$repo" rev-parse HEAD)"
  if ! runuser -u fourthlaw-dev -- git -C "$repo" fetch "$SOURCE_REPO" "$RELEASE_COMMIT" >>"$REPORT" 2>&1; then
    failed="$failed $role:fetch"
    continue
  fi
  if ! runuser -u fourthlaw-dev -- git -C "$repo" \
    -c user.name='Fourth Law Integration Gate' -c user.email='fourthlaw@local.invalid' \
    merge --no-edit --no-ff "$RELEASE_COMMIT" >>"$REPORT" 2>&1; then
    runuser -u fourthlaw-dev -- git -C "$repo" merge --abort >>"$REPORT" 2>&1 || true
    test "$(git -c safe.directory="$repo" -C "$repo" rev-parse HEAD)" = "$old_head"
    failed="$failed $role:conflict"
    continue
  fi
  if ! python3 -m py_compile \
    "$repo/app/main.py" "$repo/app/control_room.py" \
    "$repo/app/codex_control.py" "$repo/app/codex_actions.py" \
    "$repo/app/efficiency_memory.py" >>"$REPORT" 2>&1 \
    || ! grep -q 'version="0.10.14"' "$repo/app/main.py" \
    || ! grep -q '"personality": "friendly"' "$repo/app/codex_control.py" \
    || test -n "$(git -c safe.directory="$repo" -C "$repo" status --porcelain)"; then
    failed="$failed $role:validation"
    continue
  fi
  if ! git -c safe.directory="$repo" -C "$repo" push "$REMOTE" "HEAD:refs/heads/$branch" >>"$REPORT" 2>&1; then
    failed="$failed $role:push"
    continue
  fi
  new_head="$(git -c safe.directory="$repo" -C "$repo" rev-parse HEAD)"
  echo "old_head=$old_head" >>"$REPORT"
  echo "new_head=$new_head" >>"$REPORT"
  echo synchronized=true >>"$REPORT"
  synced=$((synced + 1))
done

{
  echo FOURTH_LAW_V0_10_14_ROLE_REPOSITORIES_MERGED
  echo "release_commit=$RELEASE_COMMIT"
  echo "synced=$synced"
  echo "failures=${failed# }"
  echo merge_strategy=preserve-role-history-no-ff
  echo conflict_policy=abort-once-no-retry
  echo reset_used=false
  echo production_changed=false
  echo "health=$(curl -fsS http://127.0.0.1:8787/health)"
  tail -100 "$REPORT"
} | report_issue

test "$synced" -eq 5
test -z "$failed"
echo FOURTH_LAW_V0_10_14_ROLE_REPOSITORIES_READY

#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_COMMIT='0ae0403d248d3b4271f774e22989d6736ae890fc'
SOURCE_REPO='/var/lib/fourthlaw-dev/agent-repos/supervisor'
REMOTE='git@github.com:Tarun1303/fourth-law.git'
SSH_KEY='/root/.ssh/fourthlaw-github-deploy'
TEMP_MAIN="/var/lib/fourthlaw-dev/main-cleanup-v01014-$$"
REPORT='/tmp/fl-v01014-role-structure-fix.txt'
WORKTREE_ADDED=0

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  if test "$WORKTREE_ADDED" = 1; then
    runuser -u fourthlaw-dev -- git -C "$SOURCE_REPO" worktree remove --force "$TEMP_MAIN" >>"$REPORT" 2>&1 || true
  fi
}
trap cleanup EXIT

: >"$REPORT"
test -s "$SSH_KEY"
test -d "$SOURCE_REPO/.git"
test ! -e "$TEMP_MAIN"
test "$(git -c safe.directory="$SOURCE_REPO" -C "$SOURCE_REPO" rev-parse HEAD)" = "$RELEASE_COMMIT"
test -f "$SOURCE_REPO/AGENTS.override.md"
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

git -c safe.directory="$SOURCE_REPO" -C "$SOURCE_REPO" fetch "$REMOTE" \
  main:refs/remotes/structure-gate/main agent/supervisor:refs/remotes/structure-gate/supervisor >>"$REPORT" 2>&1
test "$(git -c safe.directory="$SOURCE_REPO" -C "$SOURCE_REPO" rev-parse refs/remotes/structure-gate/main)" = "$RELEASE_COMMIT"
test "$(git -c safe.directory="$SOURCE_REPO" -C "$SOURCE_REPO" rev-parse refs/remotes/structure-gate/supervisor)" = "$RELEASE_COMMIT"

runuser -u fourthlaw-dev -- git -C "$SOURCE_REPO" worktree add --detach "$TEMP_MAIN" "$RELEASE_COMMIT" >>"$REPORT" 2>&1
WORKTREE_ADDED=1
runuser -u fourthlaw-dev -- git -C "$TEMP_MAIN" rm -- AGENTS.override.md >>"$REPORT" 2>&1
runuser -u fourthlaw-dev -- git -C "$TEMP_MAIN" \
  -c user.name='Fourth Law Integration Gate' -c user.email='fourthlaw@local.invalid' \
  commit -m 'Keep canonical main role-neutral' >>"$REPORT" 2>&1
MAIN_COMMIT="$(git -c safe.directory="$TEMP_MAIN" -C "$TEMP_MAIN" rev-parse HEAD)"
if git -c safe.directory="$TEMP_MAIN" -C "$TEMP_MAIN" ls-files --error-unmatch AGENTS.override.md >/dev/null 2>&1; then
  echo canonical_override_still_tracked >>"$REPORT"
  false
fi
git -c safe.directory="$TEMP_MAIN" -C "$TEMP_MAIN" push "$REMOTE" "$MAIN_COMMIT:refs/heads/main" >>"$REPORT" 2>&1
test "$(git -c safe.directory="$SOURCE_REPO" -C "$SOURCE_REPO" rev-parse HEAD)" = "$RELEASE_COMMIT"
test -f "$SOURCE_REPO/AGENTS.override.md"

synced=0
failed=''
for role in runtime control-room execution efficiency architecture; do
  repo="/var/lib/fourthlaw-dev/agent-repos/$role"
  branch="agent/$role"
  echo "role=$role" >>"$REPORT"
  if test ! -d "$repo/.git" \
    || test "$(git -c safe.directory="$repo" -C "$repo" branch --show-current)" != "$branch" \
    || test -n "$(git -c safe.directory="$repo" -C "$repo" status --porcelain)" \
    || test ! -f "$repo/AGENTS.override.md"; then
    failed="$failed $role:precondition"
    continue
  fi
  old_head="$(git -c safe.directory="$repo" -C "$repo" rev-parse HEAD)"
  override_before="$(git -c safe.directory="$repo" -C "$repo" hash-object AGENTS.override.md)"
  if ! runuser -u fourthlaw-dev -- git -C "$repo" fetch "$SOURCE_REPO" "$MAIN_COMMIT" >>"$REPORT" 2>&1; then
    failed="$failed $role:fetch"
    continue
  fi
  if ! runuser -u fourthlaw-dev -- git -C "$repo" \
    -c user.name='Fourth Law Integration Gate' -c user.email='fourthlaw@local.invalid' \
    merge --no-edit --no-ff "$MAIN_COMMIT" >>"$REPORT" 2>&1; then
    runuser -u fourthlaw-dev -- git -C "$repo" merge --abort >>"$REPORT" 2>&1 || true
    failed="$failed $role:conflict"
    continue
  fi
  override_after="$(git -c safe.directory="$repo" -C "$repo" hash-object AGENTS.override.md)"
  if test "$override_before" != "$override_after" \
    || test -n "$(git -c safe.directory="$repo" -C "$repo" status --porcelain)" \
    || ! python3 -m py_compile \
      "$repo/app/main.py" "$repo/app/control_room.py" \
      "$repo/app/codex_control.py" "$repo/app/codex_actions.py" \
      "$repo/app/efficiency_memory.py" >>"$REPORT" 2>&1 \
    || ! grep -q 'version="0.10.14"' "$repo/app/main.py" \
    || ! grep -q '"personality": "friendly"' "$repo/app/codex_control.py"; then
    failed="$failed $role:validation"
    continue
  fi
  if ! git -c safe.directory="$repo" -C "$repo" push "$REMOTE" "HEAD:refs/heads/$branch" >>"$REPORT" 2>&1; then
    failed="$failed $role:push"
    continue
  fi
  echo "old_head=$old_head" >>"$REPORT"
  echo "new_head=$(git -c safe.directory="$repo" -C "$repo" rev-parse HEAD)" >>"$REPORT"
  echo "override_sha256=$(sha256sum "$repo/AGENTS.override.md" | cut -d' ' -f1)" >>"$REPORT"
  echo synchronized=true >>"$REPORT"
  synced=$((synced + 1))
done

{
  echo FOURTH_LAW_V0_10_14_REPOSITORY_STRUCTURE_FIXED
  echo "release_commit=$RELEASE_COMMIT"
  echo "canonical_main_commit=$MAIN_COMMIT"
  echo canonical_main_role_neutral=true
  echo supervisor_override_preserved=true
  echo "role_repositories_synced=$synced"
  echo "failures=${failed# }"
  echo role_override_hash_preservation=required
  echo conflict_policy=abort-once-no-retry
  echo reset_used=false
  echo production_changed=false
  echo "health=$(curl -fsS http://127.0.0.1:8787/health)"
  tail -120 "$REPORT"
} | report_issue

test "$synced" -eq 5
test -z "$failed"
echo FOURTH_LAW_V0_10_14_REPOSITORY_STRUCTURE_READY

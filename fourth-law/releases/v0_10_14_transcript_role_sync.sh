#!/usr/bin/env bash
set -Eeuo pipefail

ROLE_ROOT='/var/lib/fourthlaw-dev/agent-repos'
REMOTE='git@github.com:Tarun1303/fourth-law.git'
SSH_KEY='/root/.ssh/fourthlaw-github-deploy'
EXPECTED_COMMIT='ccbb352961a6ea0c612c27bba5bc76da96f73c79'
SOURCE_ROOT="$(mktemp -d /tmp/fl-v01014-transcript-sync.XXXXXX)"
SOURCE="$SOURCE_ROOT/fourth-law"
REPORT='/tmp/fl-v01014-transcript-role-sync.txt'

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

cleanup() {
  rm -rf -- "$SOURCE_ROOT"
}
trap cleanup EXIT

: >"$REPORT"
health="$(curl -fsS http://127.0.0.1:8787/health)"
printf '%s' "$health" | grep -q '"ok":true'
printf '%s' "$health" | grep -q '"version":"0.10.14"'
systemctl is-active --quiet fourthlaw-codex.service
test -s "$SSH_KEY"

export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git clone --branch main --single-branch "$REMOTE" "$SOURCE" >>"$REPORT" 2>&1
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$EXPECTED_COMMIT"
test "$(git -C "$SOURCE" show --format= --name-only "$EXPECTED_COMMIT" | sed '/^$/d' | sort | tr '\n' ' ')" = 'app/codex_control.py tests/test_codex_runtime_contract.py '
chown -R fourthlaw-dev:fourthlaw-dev "$SOURCE_ROOT"

synced=0
already_current=0
failed=''
for role in supervisor runtime control-room execution efficiency architecture; do
  repo="$ROLE_ROOT/$role"
  if test ! -d "$repo/.git" || test ! -f "$repo/AGENTS.override.md"; then
    failed="$failed $role:missing"
    continue
  fi
  chown -R fourthlaw-dev:fourthlaw-dev "$repo/.git"
  if test -n "$(runuser -u fourthlaw-dev -- git -C "$repo" status --porcelain 2>/dev/null)"; then
    failed="$failed $role:dirty"
    continue
  fi
  override_before="$(sha256sum "$repo/AGENTS.override.md" | cut -d' ' -f1)"
  if runuser -u fourthlaw-dev -- git -C "$repo" merge-base --is-ancestor "$EXPECTED_COMMIT" HEAD 2>/dev/null; then
    already_current=$((already_current + 1))
  else
    if ! runuser -u fourthlaw-dev -- git -C "$repo" fetch "$SOURCE" "$EXPECTED_COMMIT" >>"$REPORT" 2>&1; then
      failed="$failed $role:fetch"
      continue
    fi
    if test "$role" = supervisor; then
      if ! runuser -u fourthlaw-dev -- git -C "$repo" cherry-pick "$EXPECTED_COMMIT" >>"$REPORT" 2>&1; then
        runuser -u fourthlaw-dev -- git -C "$repo" cherry-pick --abort >>"$REPORT" 2>&1 || true
        failed="$failed $role:cherry-pick"
        continue
      fi
    else
      if ! runuser -u fourthlaw-dev -- git -C "$repo" merge --no-edit "$EXPECTED_COMMIT" >>"$REPORT" 2>&1; then
        runuser -u fourthlaw-dev -- git -C "$repo" merge --abort >>"$REPORT" 2>&1 || true
        failed="$failed $role:merge"
        continue
      fi
    fi
  fi
  override_after="$(sha256sum "$repo/AGENTS.override.md" | cut -d' ' -f1)"
  if test "$override_before" != "$override_after"; then
    failed="$failed $role:override-changed"
    continue
  fi
  grep -q '"final_answer": "final"' "$repo/app/codex_control.py"
  grep -q 'test_final_answer_protocol_phase_reaches_public_transcript' "$repo/tests/test_codex_runtime_contract.py"
  branch_commit="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" push "$REMOTE" "$branch_commit:refs/heads/agent/$role" >>"$REPORT" 2>&1
  chown -R fourthlaw-dev:fourthlaw-dev "$repo/.git"
  test -z "$(runuser -u fourthlaw-dev -- git -C "$repo" status --porcelain)"
  synced=$((synced + 1))
done

{
  echo FOURTH_LAW_V0_10_14_TRANSCRIPT_ROLE_SYNC_COMPLETE
  echo "main_commit=$EXPECTED_COMMIT"
  echo "role_repositories_verified=$synced"
  echo "role_repositories_already_current=$already_current"
  echo "role_repositories_failed=${failed# }"
  echo role_overrides_preserved=true
  echo production_changed=false
  echo codex_runtime_service=active
  echo "health=$health"
  tail -120 "$REPORT"
} | report_issue

test "$synced" = 6
test -z "$failed"
echo FOURTH_LAW_V0_10_14_TRANSCRIPT_ROLE_SYNC_READY

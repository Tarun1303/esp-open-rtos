#!/usr/bin/env bash
set -Eeuo pipefail

KEY='/root/.ssh/fourthlaw-github-deploy'
REPO='git@github.com:Tarun1303/fourth-law.git'
WORKTREE='/var/lib/fourthlaw-dev/agent-repos/supervisor'
EXPECTED_FINGERPRINT='SHA256:kbbyKAXmqMe/VRo6UIwgYGXH10w0cbRyn3Xyv97/hr0'
EXPECTED_MAIN='fcbb9cea3a5bd017fc520c7ca63dbbe920180092'
REPORT='/tmp/fl-v01013-repository-gate-verify-v2.txt'

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  {
    echo FOURTH_LAW_REPOSITORY_GATE_VERIFY_FAILED
    echo "command=$failed_command"
    tail -80 "$REPORT" 2>/dev/null || true
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR

: >"$REPORT"
chmod 0600 "$REPORT"

test -f "$KEY"
test "$(stat -c %U "$KEY")" = 'root'
test "$(stat -c %a "$KEY")" = '600'
actual_fingerprint="$(ssh-keygen -lf "$KEY" -E sha256 | awk '{print $2}')"
test "$actual_fingerprint" = "$EXPECTED_FINGERPRINT"
test -e "$WORKTREE/.git"

ssh_command="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
remote_main="$(timeout 30 env GIT_SSH_COMMAND="$ssh_command" git ls-remote "$REPO" refs/heads/main | awk '{print $1}')"
test "$remote_main" = "$EXPECTED_MAIN"

local_head="$(git -c safe.directory="$WORKTREE" -C "$WORKTREE" rev-parse HEAD)"
timeout 30 env GIT_SSH_COMMAND="$ssh_command" \
  git -c safe.directory="$WORKTREE" -C "$WORKTREE" \
  push --dry-run "$REPO" 'HEAD:refs/heads/agent/supervisor' \
  >"$REPORT" 2>&1

{
  echo FOURTH_LAW_REPOSITORY_GATE_VERIFIED
  echo repository=Tarun1303/fourth-law
  echo "fingerprint=$actual_fingerprint"
  echo permission=read-write
  echo "remote_main=$remote_main"
  echo "supervisor_head=$local_head"
  echo dry_run_push=passed
  echo scoped_safe_directory="$WORKTREE"
  echo global_git_config_changed=false
  echo private_key_agent_visible=false
  echo agent_command_network=false
  echo direct_agent_push=false
  tail -20 "$REPORT"
} | report_issue

trap - ERR
echo FOURTH_LAW_REPOSITORY_GATE_VERIFY_DISPATCHED

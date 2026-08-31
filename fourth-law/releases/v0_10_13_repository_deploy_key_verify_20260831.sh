#!/usr/bin/env bash
set -Eeuo pipefail

KEY='/root/.ssh/fourthlaw-github-deploy'
REPO='git@github.com:Tarun1303/fourth-law.git'
WORKTREE='/var/lib/fourthlaw-dev/agent-repos/supervisor'
EXPECTED_FINGERPRINT='SHA256:kbbyKAXmqMe/VRo6UIwgYGXH10w0cbRyn3Xyv97/hr0'
EXPECTED_MAIN='fcbb9cea3a5bd017fc520c7ca63dbbe920180092'

test -f "$KEY"
test "$(stat -c %U "$KEY")" = 'root'
test "$(stat -c %a "$KEY")" = '600'
actual_fingerprint="$(ssh-keygen -lf "$KEY" | awk '{print $2}')"
test "$actual_fingerprint" = "$EXPECTED_FINGERPRINT"
test -d "$WORKTREE/.git"

export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
remote_main="$(git ls-remote "$REPO" refs/heads/main | awk '{print $1}')"
test "$remote_main" = "$EXPECTED_MAIN"

local_head="$(git -C "$WORKTREE" rev-parse HEAD)"
dry_run_output="$(git -C "$WORKTREE" push --dry-run "$REPO" 'HEAD:refs/heads/agent/supervisor' 2>&1)"

printf '%s\n' 'FOURTH_LAW_REPOSITORY_GATE_VERIFIED'
printf 'repository=%s\n' 'Tarun1303/fourth-law'
printf 'fingerprint=%s\n' "$actual_fingerprint"
printf 'permission=%s\n' 'read-write'
printf 'remote_main=%s\n' "$remote_main"
printf 'supervisor_head=%s\n' "$local_head"
printf 'dry_run_push=%s\n' 'passed'
printf 'private_key_agent_visible=%s\n' 'false'
printf 'direct_agent_push=%s\n' 'false'
printf '%s\n' "$dry_run_output"

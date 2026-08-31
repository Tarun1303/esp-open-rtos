#!/usr/bin/env bash
set -u

KEY='/root/.ssh/fourthlaw-github-deploy'
REPO='git@github.com:Tarun1303/fourth-law.git'
WORKTREE='/var/lib/fourthlaw-dev/agent-repos/supervisor'
EXPECTED_FINGERPRINT='SHA256:kbbyKAXmqMe/VRo6UIwgYGXH10w0cbRyn3Xyv97/hr0'

key_exists=false
key_owner='missing'
key_mode='missing'
fingerprint='unavailable'
fingerprint_match=false
worktree_exists=false
read_rc=125
read_output='skipped'
push_rc=125
push_output='skipped'

if test -f "$KEY"; then
  key_exists=true
  key_owner="$(stat -c %U "$KEY" 2>/dev/null || printf 'unknown')"
  key_mode="$(stat -c %a "$KEY" 2>/dev/null || printf 'unknown')"
  fingerprint="$(ssh-keygen -lf "$KEY" 2>/dev/null | awk '{print $2}' || true)"
  if test "$fingerprint" = "$EXPECTED_FINGERPRINT"; then
    fingerprint_match=true
  fi
fi

if test -e "$WORKTREE/.git"; then
  worktree_exists=true
fi

if test "$key_exists" = true; then
  ssh_command="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  read_output="$(timeout 30 env GIT_SSH_COMMAND="$ssh_command" git ls-remote "$REPO" refs/heads/main 2>&1)"
  read_rc=$?
  if test "$worktree_exists" = true; then
    push_output="$(timeout 30 env GIT_SSH_COMMAND="$ssh_command" git -C "$WORKTREE" push --dry-run "$REPO" 'HEAD:refs/heads/agent/supervisor' 2>&1)"
    push_rc=$?
  fi
fi

printf '%s\n' 'FOURTH_LAW_REPOSITORY_GATE_DIAGNOSTIC'
printf 'key_exists=%s\n' "$key_exists"
printf 'key_owner=%s\n' "$key_owner"
printf 'key_mode=%s\n' "$key_mode"
printf 'fingerprint=%s\n' "$fingerprint"
printf 'fingerprint_match=%s\n' "$fingerprint_match"
printf 'worktree_exists=%s\n' "$worktree_exists"
printf 'read_rc=%s\n' "$read_rc"
printf 'read_output=%s\n' "$(printf '%s' "$read_output" | tr '\n' ' ' | head -c 1000)"
printf 'push_rc=%s\n' "$push_rc"
printf 'push_output=%s\n' "$(printf '%s' "$push_output" | tr '\n' ' ' | head -c 1000)"
printf 'private_key_agent_visible=%s\n' 'false'
printf 'direct_agent_push=%s\n' 'false'

exit 0

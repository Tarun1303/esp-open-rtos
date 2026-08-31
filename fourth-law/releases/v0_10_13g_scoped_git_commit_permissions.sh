#!/usr/bin/env bash
set -Eeuo pipefail

DEV_USER=fourthlaw-dev
DEV_HOME=/var/lib/fourthlaw-dev
CONFIG="$DEV_HOME/.codex/config.toml"
ROLE_REPO="$DEV_HOME/agent-repos/execution"
REPORT=/tmp/fl-v01013g-scoped-git-permissions.txt
OUTPUT=/tmp/fl-v01013g-codex-output.txt
BACKUP="$(mktemp /tmp/fl-v01013g-config.XXXXXX)"
CONFIG_CHANGED=0

cleanup() {
  rm -f -- "$BACKUP"
}
trap cleanup EXIT

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  set +e
  if test "$CONFIG_CHANGED" = 1; then
    install -o "$DEV_USER" -g "$DEV_USER" -m 0600 "$BACKUP" "$CONFIG"
    systemctl restart fourthlaw-codex.service >>"$REPORT" 2>&1
  fi
  {
    echo FOURTH_LAW_SCOPED_GIT_PERMISSIONS_V0_10_13_FAILED
    echo "command=$failed_command"
    echo "config_rollback=$CONFIG_CHANGED"
    tail -160 "$REPORT"
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
: >"$REPORT"
: >"$OUTPUT"

health="$(curl -fsS http://127.0.0.1:8787/health)"
echo "$health" | grep -q '"version":"0.10.13"'
systemctl is-active --quiet fourthlaw-codex.service
test -f "$CONFIG"
test -d "$ROLE_REPO/.git"
test -z "$(runuser -u "$DEV_USER" -- git -C "$ROLE_REPO" status --porcelain)"
install -m 0600 "$CONFIG" "$BACKUP"

python3 - "$CONFIG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
anchor = '"." = "write"'
rules = '''".git/index" = "write"
".git/index.lock" = "write"
".git/objects" = "write"
".git/objects/**" = "write"
".git/refs" = "write"
".git/refs/**" = "write"
".git/logs" = "write"
".git/logs/**" = "write"
".git/COMMIT_EDITMSG" = "write"
".git/ORIG_HEAD" = "write"
".git/config" = "read"
".git/hooks" = "read"
".git/hooks/**" = "read"'''
if '".git/index" = "write"' not in text:
    if anchor not in text:
        raise SystemExit('workspace-root write anchor missing')
    text = text.replace(anchor, anchor + '\n' + rules, 1)
path.write_text(text)
PY
chown "$DEV_USER:$DEV_USER" "$CONFIG"
chmod 0600 "$CONFIG"
CONFIG_CHANGED=1

grep -q 'default_permissions = "fourthlaw-workspace"' "$CONFIG"
grep -q 'extends = ":workspace"' "$CONFIG"
grep -q '".git/index" = "write"' "$CONFIG"
grep -q '".git/objects/\*\*" = "write"' "$CONFIG"
grep -q '".git/refs/\*\*" = "write"' "$CONFIG"
grep -q '".git/logs/\*\*" = "write"' "$CONFIG"
grep -q '".git/config" = "read"' "$CONFIG"
grep -q '".git/hooks/\*\*" = "read"' "$CONFIG"
grep -q '^enabled = false$' "$CONFIG"

systemctl restart fourthlaw-codex.service
for _ in $(seq 1 40); do
  systemctl is-active --quiet fourthlaw-codex.service && break
  sleep 1
done
systemctl is-active --quiet fourthlaw-codex.service

timeout 240 runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" CODEX_HOME="$DEV_HOME/.codex" \
  codex exec --ephemeral --model gpt-5.6-terra --cd "$ROLE_REPO" \
  'Inspect AGENTS.md and AGENTS.override.md. Run only bounded local checks. Confirm the branch is agent/execution and git status --porcelain is empty. Confirm .git/index, .git/objects, .git/refs/heads, and .git/logs/refs/heads are writable, while .git/config and .git/hooks are not writable. Do not edit or commit anything. Return exactly SCOPED_GIT_COMMIT_PERMISSIONS_READY only when every check passes and the role contract, approval=never, command-network denial, credential denial, and production-write denial are loaded.' \
  >"$OUTPUT" 2>>"$REPORT"

grep -q '^SCOPED_GIT_COMMIT_PERMISSIONS_READY$' "$OUTPUT"
test -z "$(runuser -u "$DEV_USER" -- git -C "$ROLE_REPO" status --porcelain)"
systemctl is-active --quiet fourthlaw-codex.service

CONFIG_CHANGED=0
{
  echo FOURTH_LAW_SCOPED_GIT_PERMISSIONS_V0_10_13_READY
  echo permission_profile=fourthlaw-workspace
  echo selected_repository_only=true
  echo local_file_edits=true
  echo local_git_commits=true
  echo git_index_write=true
  echo git_objects_write=true
  echo git_refs_write=true
  echo git_logs_write=true
  echo git_config_write=false
  echo git_hooks_write=false
  echo shared_git_metadata=false
  echo approval_policy=never
  echo command_network=false
  echo credential_read=false
  echo direct_agent_push=false
  echo direct_production_write=false
  echo "health=$health"
} | report_issue

trap - ERR
echo FOURTH_LAW_SCOPED_GIT_PERMISSIONS_V0_10_13_DISPATCHED

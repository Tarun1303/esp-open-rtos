#!/usr/bin/env bash
set -Eeuo pipefail

DEV_USER=fourthlaw-dev
DEV_HOME=/var/lib/fourthlaw-dev
ROLE_REPO="$DEV_HOME/agent-repos/execution"
REPORT=/tmp/fl-v01013e-agent-runtime-proof.txt
OUTPUT=/tmp/fl-v01013e-codex-output.txt

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  {
    echo FOURTH_LAW_AGENT_RUNTIME_PROOF_V0_10_13_FAILED
    echo "command=$failed_command"
    tail -120 "$REPORT"
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
: >"$REPORT"
: >"$OUTPUT"

health="$(curl -fsS http://127.0.0.1:8787/health)"
echo "$health" | grep -q '"version":"0.10.13"'
systemctl is-active --quiet fourthlaw-codex.service
test -d "$ROLE_REPO/.git"
test "$(runuser -u "$DEV_USER" -- git -C "$ROLE_REPO" symbolic-ref --short HEAD)" = agent/execution
test -z "$(runuser -u "$DEV_USER" -- git -C "$ROLE_REPO" status --porcelain)"

timeout 240 runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" CODEX_HOME="$DEV_HOME/.codex" \
  codex exec --ephemeral --sandbox workspace-write --ask-for-approval never \
  --model gpt-5.6-terra --cd "$ROLE_REPO" \
  'Inspect AGENTS.md and AGENTS.override.md. Run only bounded local checks: git branch --show-current, git status --porcelain, and test -w .git/index. Do not edit or commit anything. Return exactly AGENT_ROLE_REPOSITORY_READY if the branch is agent/execution, the worktree is clean, Git metadata is writable, the role contract is loaded, command networking is denied, credentials are denied, and production writes are disabled.' \
  >"$OUTPUT" 2>>"$REPORT"

grep -q '^AGENT_ROLE_REPOSITORY_READY$' "$OUTPUT"
test -z "$(runuser -u "$DEV_USER" -- git -C "$ROLE_REPO" status --porcelain)"

{
  echo FOURTH_LAW_AGENT_RUNTIME_PROOF_V0_10_13_READY
  echo codex_runtime=true
  echo role=execution
  echo branch=agent/execution
  echo role_contract_loaded=true
  echo repository_clean=true
  echo git_metadata_writable=true
  echo command_network=false
  echo credential_read=false
  echo direct_production_write=false
  echo "health=$health"
} | report_issue

trap - ERR
echo FOURTH_LAW_AGENT_RUNTIME_PROOF_V0_10_13_DISPATCHED

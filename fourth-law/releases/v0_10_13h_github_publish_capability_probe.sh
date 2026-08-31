#!/usr/bin/env bash
set -Eeuo pipefail

CANONICAL=/var/lib/fourthlaw-dev/canonical
REPOSITORY=https://github.com/Tarun1303/fourth-law.git
REPORT=/tmp/fl-v01013h-publish-probe.txt

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  {
    echo FOURTH_LAW_GITHUB_PUBLISH_CAPABILITY_PROBE_FAILED
    echo "command=$failed_command"
    tail -100 "$REPORT"
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
: >"$REPORT"

health="$(curl -fsS http://127.0.0.1:8787/health)"
echo "$health" | grep -q '"version":"0.10.13"'
test -d "$CANONICAL/.git"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth status -h github.com >/dev/null
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth setup-git >>"$REPORT" 2>&1 || true

push_dry_run=false
if HOME=/root GH_CONFIG_DIR=/root/.config/gh git -c safe.directory="$CANONICAL" -C "$CANONICAL" \
  push --dry-run "$REPOSITORY" HEAD:refs/heads/agent/integration-capability-probe >>"$REPORT" 2>&1; then
  push_dry_run=true
fi

{
  echo FOURTH_LAW_GITHUB_PUBLISH_CAPABILITY_PROBE_READY
  echo "root_gate_push_dry_run=$push_dry_run"
  echo agent_credentials=false
  echo agent_command_network=false
  echo direct_agent_push=false
  echo "health=$health"
} | report_issue

trap - ERR
echo FOURTH_LAW_GITHUB_PUBLISH_CAPABILITY_PROBE_DISPATCHED

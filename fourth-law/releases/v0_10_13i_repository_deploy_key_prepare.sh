#!/usr/bin/env bash
set -Eeuo pipefail

KEY=/root/.ssh/fourthlaw-github-deploy
REPORT=/tmp/fl-v01013i-deploy-key.txt

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  {
    echo FOURTH_LAW_REPOSITORY_DEPLOY_KEY_PREPARE_FAILED
    echo "command=$failed_command"
    tail -80 "$REPORT"
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
: >"$REPORT"

health="$(curl -fsS http://127.0.0.1:8787/health)"
echo "$health" | grep -q '"version":"0.10.13"'
install -d -o root -g root -m 0700 /root/.ssh

if test ! -f "$KEY"; then
  test ! -e "$KEY.pub"
  ssh-keygen -q -t ed25519 -N '' -C 'fourth-law-integration@vps' -f "$KEY" >>"$REPORT" 2>&1
fi
test -f "$KEY"
test -f "$KEY.pub"
chown root:root "$KEY" "$KEY.pub"
chmod 0600 "$KEY"
chmod 0644 "$KEY.pub"

public_key="$(cat "$KEY.pub")"
fingerprint="$(ssh-keygen -lf "$KEY.pub" -E sha256 | awk '{print $2}')"
test -n "$public_key"
test -n "$fingerprint"

{
  echo FOURTH_LAW_REPOSITORY_DEPLOY_KEY_PREPARED
  echo repository=Tarun1303/fourth-law
  echo title='Fourth Law bounded integration gate'
  echo "fingerprint=$fingerprint"
  echo "public_key=$public_key"
  echo private_key_location=root-only
  echo private_key_agent_visible=false
  echo command_network_agent=false
  echo direct_agent_push=false
  echo activation_pending=true
  echo "health=$health"
} | report_issue

trap - ERR
echo FOURTH_LAW_REPOSITORY_DEPLOY_KEY_PREPARE_DISPATCHED

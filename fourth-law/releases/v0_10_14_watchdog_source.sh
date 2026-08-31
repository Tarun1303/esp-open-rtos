#!/usr/bin/env bash
set -Eeuo pipefail

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

{
  echo FOURTH_LAW_WATCHDOG_SOURCE
  sha256sum /usr/local/bin/fourthlaw-watchdog
  grep -nE 'curl|docker|systemctl|compose|restart|health|sleep|if |then|else|fi' /usr/local/bin/fourthlaw-watchdog \
    | sed -E 's/[A-Za-z0-9_+=\/.-]{32,}/[redacted]/g'
} | report_issue

echo FOURTH_LAW_WATCHDOG_SOURCE_READY

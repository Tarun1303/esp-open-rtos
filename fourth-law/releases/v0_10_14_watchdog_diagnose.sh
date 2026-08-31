#!/usr/bin/env bash
set -Eeuo pipefail

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

{
  echo FOURTH_LAW_WATCHDOG_DIAGNOSIS
  echo timer_begin
  systemctl cat fourthlaw-watchdog.timer --no-pager 2>&1 || true
  echo timer_end
  echo service_begin
  systemctl cat fourthlaw-watchdog.service --no-pager 2>&1 || true
  systemctl show fourthlaw-watchdog.service --property=ExecStart,Result,ExecMainStatus,StateChangeTimestamp --no-pager 2>&1 || true
  echo service_end
  echo recent_journal_begin
  journalctl -u fourthlaw-watchdog.service -n 80 --no-pager -o cat 2>&1 || true
  echo recent_journal_end
} | report_issue

echo FOURTH_LAW_WATCHDOG_DIAGNOSIS_READY

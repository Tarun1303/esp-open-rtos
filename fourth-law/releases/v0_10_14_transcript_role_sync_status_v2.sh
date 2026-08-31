#!/usr/bin/env bash
set -Eeuo pipefail

UNIT='fourthlaw-release-1788183212-470a01c8.service'

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

{
  echo FOURTH_LAW_TRANSCRIPT_ROLE_SYNC_STATUS
  systemctl show "$UNIT" \
    --property=ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,StateChangeTimestamp \
    --no-pager || true
  echo health="$(curl -fsS http://127.0.0.1:8787/health)"
  echo report_tail_begin
  tail -80 /tmp/fl-v01014-transcript-role-sync.txt 2>/dev/null || true
  echo report_tail_end
  echo journal_tail_begin
  journalctl -u "$UNIT" -n 40 --no-pager -o cat 2>/dev/null || true
  echo journal_tail_end
} | report_issue

echo FOURTH_LAW_TRANSCRIPT_ROLE_SYNC_STATUS_READY

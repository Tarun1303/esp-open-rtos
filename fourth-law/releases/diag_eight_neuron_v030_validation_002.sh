#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
UNIT='fourthlaw-release-1788555295-a9f3da82.service'
APP='/var/lib/fourthlaw-dev/projects/eight-neuron-connection'
REPO='Tarun1303/factory'
ISSUE=7
REPORT="$(mktemp)"
BODY="$(mktemp)"
trap 'rm -f "$REPORT" "$BODY"' EXIT
{
  echo EIGHT_NEURON_V030_VALIDATION_DIAGNOSTIC_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo '=== release unit ==='
  systemctl show "$UNIT" -p Id -p LoadState -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus -p MainPID -p CPUUsageNSec -p MemoryCurrent 2>&1 || true
  echo '=== matching processes ==='
  pgrep -af 'final_v03_closedloop_vps.py|run_eight_neuron_v030_closed_loop_validation' || true
  echo '=== validation directories ==='
  find "$APP/validation/v0.3-closed-loop" -maxdepth 2 -type f -printf '%TY-%Tm-%TdT%TH:%TM:%TSZ %s %p\n' 2>/dev/null | sort | tail -n 25 || true
  echo '=== latest validation log tail ==='
  latest_log="$(find "$APP/validation/v0.3-closed-loop" -type f -name validation.log -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2- || true)"
  echo "latest_log=$latest_log"
  [ -n "$latest_log" ] && tail -n 80 "$latest_log" || true
  echo '=== latest result ==='
  ls -lh "$APP/shared"/final_v03_closedloop-vps*.json 2>/dev/null || true
  echo '=== live app ==='
  echo "current=$(readlink -f "$APP/current" 2>/dev/null || true)"
  echo "service=$(systemctl is-active eight-neuron-connection.service 2>/dev/null || true)"
  curl -fsS --max-time 5 http://127.0.0.1:8788/api/health 2>/dev/null || true
  echo
  echo EIGHT_NEURON_V030_VALIDATION_DIAGNOSTIC_END
} > "$REPORT" 2>&1
{
  echo '## 8 Neuron Connection — v0.3 validation diagnostic'
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPO" --body-file "$BODY" >/dev/null
cat "$REPORT"

#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
UNIT="fourthlaw-release-1788585596-b52cb821.service"
REPO="Tarun1303/factory"
ISSUE=7
REPORT="$(mktemp)"
BODY="$(mktemp)"
trap 'rm -f "$REPORT" "$BODY"' EXIT
{
  echo EIGHT_NEURON_V030_PAYLOAD_JOB_DIAGNOSTIC_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo '=== unit ==='
  systemctl show "$UNIT" -p Id -p LoadState -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus -p MainPID -p CPUUsageNSec -p MemoryCurrent 2>&1 || true
  echo '=== journal ==='
  journalctl -u "$UNIT" --no-pager -n 100 2>&1 || true
  echo '=== matching processes ==='
  pgrep -af 'inspect_eight_neuron_v030_payload|closed_loop_benchmark.py' || true
  echo '=== live service ==='
  echo "service=$(systemctl is-active eight-neuron-connection.service 2>/dev/null || true)"
  echo "current=$(readlink -f /var/lib/fourthlaw-dev/projects/eight-neuron-connection/current 2>/dev/null || true)"
  curl -fsS --max-time 5 http://127.0.0.1:8788/api/health 2>/dev/null || true
  echo
  echo EIGHT_NEURON_V030_PAYLOAD_JOB_DIAGNOSTIC_END
} > "$REPORT" 2>&1
{
  echo '## 8 Neuron Connection — v0.3 payload job diagnostic'
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPO" --body-file "$BODY" >/dev/null
cat "$REPORT"

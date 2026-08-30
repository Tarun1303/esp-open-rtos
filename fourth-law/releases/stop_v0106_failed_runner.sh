#!/usr/bin/env bash
set -Eeuo pipefail
unit=fourthlaw-release-1788112506-535c5d56.service
systemctl stop "$unit" || true
systemctl reset-failed "$unit" || true
health="$(curl -fsS http://127.0.0.1:8787/health)"
echo "$health" | grep -q '"ok":true'
echo "$health" | grep -q '"version":"0.10.4"'
{
  echo V0106_FAILED_RUNNER_STOPPED
  echo "unit=$unit"
  echo "production_health=$health"
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

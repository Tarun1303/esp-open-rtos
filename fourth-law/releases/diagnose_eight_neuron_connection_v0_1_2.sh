#!/usr/bin/env bash
set -u
umask 027
APP=/var/lib/fourthlaw-dev/projects/eight-neuron-connection
SERVICE=eight-neuron-connection.service
RELEASE=fourthlaw-release-1788529165-c7d5c370.service
REPO=Tarun1303/factory
ISSUE=7
REPORT=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$REPORT" "$BODY"' EXIT
{
  echo EIGHT_NEURON_CONNECTION_V012_FAILURE_DIAGNOSTIC_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo '=== RELEASE UNIT ==='
  systemctl show "$RELEASE" -p Id -p LoadState -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus 2>&1 || true
  echo
  echo '=== RELEASE JOURNAL ==='
  journalctl -u "$RELEASE" --no-pager -n 250 2>&1 || true
  echo
  echo '=== APP UNIT ==='
  systemctl show "$SERVICE" -p Id -p LoadState -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus -p MainPID 2>&1 || true
  echo
  echo '=== APP JOURNAL ==='
  journalctl -u "$SERVICE" --no-pager -n 160 2>&1 || true
  echo
  echo '=== CURRENT FILE STATE ==='
  grep -n "const VERSION\|version" "$APP/server.mjs" "$APP/package.json" 2>&1 | head -30 || true
  grep -n "Stop & capture pattern\|No fixed binary answer\|Get output" "$APP/public/index.html" 2>&1 || true
  sha256sum "$APP/server.mjs" "$APP/public/index.html" "$APP/public/app.js" "$APP/public/signature.js" 2>&1 || true
  echo
  echo '=== HTTP ==='
  curl -sS -i --max-time 5 http://127.0.0.1:8788/api/health 2>&1 || true
  echo
  curl -sS -i --max-time 5 http://127.0.0.1:8788/api/signatures 2>&1 || true
  echo
  echo '=== RUNTIME PERMISSIONS ==='
  namei -l "$APP/runtime" 2>&1 || true
  ls -la "$APP/runtime" 2>&1 || true
  echo EIGHT_NEURON_CONNECTION_V012_FAILURE_DIAGNOSTIC_END
} > "$REPORT"
{
  echo '## 8 Neuron Connection — v0.1.2 failure diagnostic'
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPO" --body-file "$BODY" >/dev/null 2>&1 || true
cat "$REPORT"

#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
APP=/var/lib/fourthlaw-dev/projects/eight-neuron-connection
REPO=Tarun1303/factory
ISSUE=7
REPORT=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$REPORT" "$BODY"' EXIT
{
  echo EIGHT_NEURON_UI_MODEL_DIAGNOSTIC_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "service=$(systemctl is-active eight-neuron-connection.service 2>/dev/null || true)"
  echo
  for f in package.json server.mjs src/model.mjs public/index.html public/app.js public/styles.css tests/model.test.mjs; do
    echo "===== FILE: $f ====="
    if [ -f "$APP/$f" ]; then
      sed -n '1,2200p' "$APP/$f"
    else
      echo MISSING
    fi
    echo "===== END FILE: $f ====="
    echo
  done
  echo EIGHT_NEURON_UI_MODEL_DIAGNOSTIC_END
} > "$REPORT"
{
  echo '## 8 Neuron Connection — current UI/model source diagnostic'
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPO" --body-file "$BODY" >/dev/null
cat "$REPORT"

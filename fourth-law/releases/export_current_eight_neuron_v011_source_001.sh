#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
APP=/var/lib/fourthlaw-dev/projects/eight-neuron-connection/current
REPO=Tarun1303/esp-open-rtos
BRANCH=fourth-law-bootstrap
DEST=fourth-law/snapshots/eight-neuron-current-v011-20260904
REPORT_REPO=Tarun1303/factory
ISSUE=7
REPORT=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$REPORT" "$BODY"' EXIT
upload(){
  local src="$1" rel="$2"
  [ -f "$src" ] || { echo "missing=$src" >> "$REPORT"; return 1; }
  local encoded sha response
  encoded="$(base64 -w0 "$src")"
  sha="$(sha256sum "$src" | awk '{print $1}')"
  response="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api --method PUT "/repos/$REPO/contents/$DEST/$rel" -f message="Snapshot $rel from running 8 Neuron Connection v0.1.1" -f content="$encoded" -f branch="$BRANCH" --jq '.commit.sha')"
  echo "uploaded=$rel sha256=$sha commit=$response" >> "$REPORT"
}
{
  echo EIGHT_NEURON_SOURCE_EXPORT_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "source=$(readlink -f "$APP")"
  echo "destination=$REPO:$BRANCH/$DEST"
} > "$REPORT"
upload "$APP/app.py" app.py
upload "$APP/engine.py" engine.py
upload "$APP/static/index.html" static/index.html
if [ -f "$APP/static/app.js" ]; then upload "$APP/static/app.js" static/app.js; fi
if [ -f "$APP/static/styles.css" ]; then upload "$APP/static/styles.css" static/styles.css; elif [ -f "$APP/static/style.css" ]; then upload "$APP/static/style.css" static/style.css; fi
if [ -f "$APP/tests/test_engine.py" ]; then upload "$APP/tests/test_engine.py" tests/test_engine.py; fi
if [ -f "$APP/tests/test_app.py" ]; then upload "$APP/tests/test_app.py" tests/test_app.py; fi
echo EIGHT_NEURON_SOURCE_EXPORT_END >> "$REPORT"
{
  echo '## 8 Neuron Connection — exported running v0.1.1 source snapshot'
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPORT_REPO" --body-file "$BODY" >/dev/null 2>&1 || true
cat "$REPORT"

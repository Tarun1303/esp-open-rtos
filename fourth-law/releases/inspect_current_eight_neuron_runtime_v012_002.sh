#!/usr/bin/env bash
set -u
umask 027
APP=/var/lib/fourthlaw-dev/projects/eight-neuron-connection
SERVICE=eight-neuron-connection.service
REPO=Tarun1303/factory
ISSUE=7
REPORT=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$REPORT" "$BODY"' EXIT
{
  echo EIGHT_NEURON_RUNTIME_INSPECTION_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo '=== SYSTEMD UNIT ==='
  systemctl cat "$SERVICE" 2>&1 || true
  echo
  echo '=== PROCESS ==='
  systemctl show "$SERVICE" -p MainPID -p ExecStart -p User -p Group -p WorkingDirectory -p Environment -p ActiveState -p SubState 2>&1 || true
  pid="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)"
  if [ -n "$pid" ] && [ "$pid" != 0 ]; then
    ps -fp "$pid" 2>&1 || true
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true
    echo
  fi
  echo
  echo '=== PYTHON AND SERVER FILES ==='
  find "$APP" -maxdepth 3 -type f \( -name '*.py' -o -name 'server.*' -o -name 'app.*' \) -printf '%p\n' 2>/dev/null | sort
  echo
  for f in $(find "$APP" -maxdepth 3 -type f -name '*.py' 2>/dev/null | head -20); do
    echo "===== FILE: $f ====="
    sed -n '1,500p' "$f" 2>&1 || true
    echo "===== END FILE: $f ====="
  done
  echo
  echo '=== ROUTE MARKERS ==='
  grep -RInE "api/(state|health|train|test|reset|input|output|signature)|do_GET|do_POST|BaseHTTPRequestHandler|Flask|FastAPI" "$APP" --include='*.py' --include='*.mjs' --include='*.js' 2>/dev/null | head -500 || true
  echo
  echo '=== PUBLIC HTML CONTROLS ==='
  grep -nEi "input|train|test|output|button|pattern|label" "$APP/public/index.html" 2>/dev/null | head -300 || true
  echo EIGHT_NEURON_RUNTIME_INSPECTION_END
} > "$REPORT"
{
  echo '## 8 Neuron Connection — current runtime implementation inspection'
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPO" --body-file "$BODY" >/dev/null 2>&1 || true
cat "$REPORT"

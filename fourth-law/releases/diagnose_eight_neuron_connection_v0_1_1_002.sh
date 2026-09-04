#!/usr/bin/env bash
set -uo pipefail
umask 027
export HOME=/root
export GH_CONFIG_DIR=/root/.config/gh
REL='fourthlaw-release-1788526644-7b5c2929.service'
APP='eight-neuron-connection.service'
OUT="$(mktemp)"
BODY="$(mktemp)"
cleanup(){ rm -f "$OUT" "$BODY"; }
trap cleanup EXIT
{
  echo 'EIGHT_NEURON_CONNECTION_DEPLOY_DIAGNOSTIC_BEGIN'
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo '=== RELEASE UNIT ==='
  systemctl show "$REL" -p Id -p LoadState -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus -p StateChangeTimestamp --no-pager 2>&1 || true
  echo
  echo '=== RELEASE JOURNAL ==='
  journalctl -u "$REL" -n 250 --no-pager -o cat 2>&1 || true
  echo
  echo '=== APP UNIT ==='
  systemctl show "$APP" -p Id -p LoadState -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus -p MainPID -p FragmentPath --no-pager 2>&1 || true
  echo
  echo '=== APP JOURNAL ==='
  journalctl -u "$APP" -n 150 --no-pager -o cat 2>&1 || true
  echo
  echo '=== FILESYSTEM ==='
  ls -la /var/lib/fourthlaw-dev/projects/eight-neuron-connection 2>&1 || true
  find /var/lib/fourthlaw-dev/projects/eight-neuron-connection -maxdepth 3 -type f -o -type l 2>&1 | sort || true
  echo
  echo '=== PORT AND HTTP ==='
  ss -ltnp 'sport = :8788' 2>&1 || true
  printf 'health='; curl -sS --max-time 5 -w '\nHTTP=%{http_code}\n' http://127.0.0.1:8788/health 2>&1 || true
  printf 'state='; curl -sS --max-time 5 -w '\nHTTP=%{http_code}\n' http://127.0.0.1:8788/api/state 2>&1 | head -c 5000 || true
  echo
  echo 'EIGHT_NEURON_CONNECTION_DEPLOY_DIAGNOSTIC_END'
} > "$OUT"
cat "$OUT"
{
  echo '## 8 Neuron Connection v0.1.1 deployment diagnostic'
  echo
  echo '```text'
  cat "$OUT"
  echo '```'
} > "$BODY"
if gh auth status >/dev/null 2>&1; then
  gh issue comment 7 --repo Tarun1303/factory --body-file "$BODY" >/dev/null 2>&1 || true
fi
exit 0

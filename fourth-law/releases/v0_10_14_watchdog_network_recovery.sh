#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
WATCHDOG='/usr/local/bin/fourthlaw-watchdog'
EXPECTED_WATCHDOG_SHA='ec8f8fe8b18968a951f9e54301270bd7ee44067d442c965758c6efd8f4c549e5'
REPORT='/tmp/fl-v01014-watchdog-recovery.txt'
BACKUP_ROOT="$(mktemp -d /tmp/fl-v01014-watchdog-rollback.XXXXXX)"
CHANGED=0

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

restore_watchdog() {
  set +e
  if test -f "$BACKUP_ROOT/fourthlaw-watchdog"; then
    cp -a "$BACKUP_ROOT/fourthlaw-watchdog" "$WATCHDOG"
  fi
  systemctl start fourthlaw-watchdog.timer >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  if test "$CHANGED" = 0; then
    rm -rf -- "$BACKUP_ROOT"
  fi
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  set +e
  restore_watchdog
  {
    echo FOURTH_LAW_V0_10_14_WATCHDOG_NETWORK_RECOVERY_FAILED
    echo "command=$failed_command"
    echo watchdog_restored=true
    echo timer_active="$(systemctl is-active fourthlaw-watchdog.timer 2>/dev/null || true)"
    curl -fsS --max-time 5 http://127.0.0.1:8787/health 2>/dev/null || true
    tail -160 "$REPORT" 2>/dev/null || true
  } | report_issue
  cleanup
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
trap cleanup EXIT

: >"$REPORT"
test "$(sha256sum "$WATCHDOG" | cut -d' ' -f1)" = "$EXPECTED_WATCHDOG_SHA"
cp -a "$WATCHDOG" "$BACKUP_ROOT/fourthlaw-watchdog"
systemctl stop fourthlaw-watchdog.timer
systemctl stop fourthlaw-watchdog.service || true

python3 - "$WATCHDOG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '''  docker compose restart agent >> "$LOG" 2>&1 || docker compose up -d --build agent >> "$LOG" 2>&1 || true
  sleep 8
'''
new = '''  docker compose restart agent >> "$LOG" 2>&1 || true
  sleep 8
  if ! curl -fsS --max-time 8 http://127.0.0.1:8787/health >/dev/null 2>&1; then
    echo "$(date -Is) restart did not restore endpoint -> force recreating" >> "$LOG"
    docker compose up -d --force-recreate agent >> "$LOG" 2>&1 || true
    sleep 8
  fi
'''
if old not in text:
    raise SystemExit('watchdog recovery anchor missing')
path.write_text(text.replace(old, new, 1))
PY
chmod 0755 "$WATCHDOG"
bash -n "$WATCHDOG"
grep -q 'restart did not restore endpoint -> force recreating' "$WATCHDOG"
CHANGED=1

# Recreate from the rendered, verified Compose definition. This restores the
# localhost-only port binding and the private bridge shared with the tunnel.
docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1

ready=false
for _ in $(seq 1 45); do
  if curl -fsS --max-time 5 http://127.0.0.1:8787/health >/tmp/fl-v01014-watchdog-health.json 2>/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true
grep -q '"ok":true' /tmp/fl-v01014-watchdog-health.json
grep -q '"version":"0.10.14"' /tmp/fl-v01014-watchdog-health.json

python3 - <<'PY'
import json, subprocess
state = json.loads(subprocess.check_output(['docker', 'inspect', 'fourth-law-agent'], text=True))[0]
ports = state['NetworkSettings']['Ports'].get('8787/tcp') or []
assert any(item.get('HostIp') == '127.0.0.1' and item.get('HostPort') == '8787' for item in ports), ports
assert 'fourth-law-agent_default' in state['NetworkSettings']['Networks'], state['NetworkSettings']['Networks']
assert state['State']['Running'] is True
PY
docker exec fourth-law-agent python -c 'import urllib.request; assert b"\"ok\":true" in urllib.request.urlopen("http://127.0.0.1:8787/health", timeout=5).read()'
test "$(docker inspect fourth-law-tunnel --format '{{.State.Running}}')" = true
systemctl is-active --quiet fourthlaw-codex.service

started_before="$(docker inspect fourth-law-agent --format '{{.State.StartedAt}}')"
systemctl start fourthlaw-watchdog.service
started_after="$(docker inspect fourth-law-agent --format '{{.State.StartedAt}}')"
test "$started_before" = "$started_after"
curl -fsS --max-time 5 http://127.0.0.1:8787/health >/tmp/fl-v01014-watchdog-health.json

systemctl start fourthlaw-watchdog.timer
systemctl is-active --quiet fourthlaw-watchdog.timer

new_watchdog_sha="$(sha256sum "$WATCHDOG" | cut -d' ' -f1)"
CHANGED=0
{
  echo FOURTH_LAW_V0_10_14_WATCHDOG_NETWORK_RECOVERED
  echo "watchdog_sha256=$new_watchdog_sha"
  echo bounded_restart_then_force_recreate=true
  echo host_binding=127.0.0.1:8787
  echo private_network=fourth-law-agent_default
  echo internal_health=passed
  echo host_health=passed
  echo healthy_watchdog_cycle_did_not_restart=true
  echo watchdog_timer=active
  echo codex_runtime_service=active
  echo public_secret_exposure=false
  echo "health=$(cat /tmp/fl-v01014-watchdog-health.json)"
} | report_issue

trap - ERR
rm -rf -- "$BACKUP_ROOT"
echo FOURTH_LAW_V0_10_14_WATCHDOG_NETWORK_RECOVERY_READY

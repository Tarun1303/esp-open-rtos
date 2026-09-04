#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

export HOME=/root
export GH_CONFIG_DIR=/root/.config/gh

TITLE="8 Neuron Connection"
SLUG="eight-neuron-connection"
DEV_USER="fourthlaw-dev"
REPO="Tarun1303/factory"
ISSUE=7
BASE="https://fourth-law-94-136-189-216.sslip.io"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
trap 'rm -f "$REPORT" "$BODY"' EXIT

kv(){ printf '%-28s %s\n' "$1" "$2"; }
have(){ command -v "$1" >/dev/null 2>&1; }
ver(){ local c="$1"; shift; have "$c" && kv "$c" "$(command -v "$c") | $("$c" "$@" 2>&1 | head -n1 || true)" || kv "$c" "MISSING"; }
unit(){ local u="$1"; kv "$u" "active=$(systemctl show "$u" -p ActiveState --value 2>/dev/null || echo unknown); result=$(systemctl show "$u" -p Result --value 2>/dev/null || echo unknown); exit=$(systemctl show "$u" -p ExecMainStatus --value 2>/dev/null || echo unknown)"; }

{
  echo "EIGHT_NEURON_CONNECTION_VPS_VERIFICATION_BEGIN"
  kv timestamp_utc "$STAMP"
  kv project_title "$TITLE"
  kv execution_user "$(id -un) ($(id -u):$(id -g))"
  kv hostname "$(hostname)"
  [ -r /etc/os-release ] && . /etc/os-release && kv operating_system "${PRETTY_NAME:-unknown}"
  kv kernel "$(uname -srmo)"

  echo; echo "=== CONTROL ==="
  if have curl; then
    kv control_base_http "$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$BASE/" || echo 000)"
    kv control_health_http "$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$BASE/health" || echo 000)"
  fi
  have systemctl && unit fourthlaw-release-1788518373-3fdccdca.service
  have systemctl && unit fourthlaw-release-1788518637-8cd347ab.service

  echo; echo "=== HOST ==="
  have nproc && kv cpu_threads "$(nproc)"
  have free && kv memory "$(free -h | awk '/^Mem:/ {print $2 " total, " $7 " available"}')"
  have df && kv root_disk "$(df -h / | awk 'NR==2 {print $2 " total, " $4 " available, " $5 " used"}')"

  echo; echo "=== TOOLCHAIN ==="
  ver git --version
  ver gh --version
  ver python3 --version
  ver pip3 --version
  ver node --version
  ver npm --version
  ver npx --version
  ver docker --version
  ver codex --version
  if have docker; then
    kv docker_compose "$(docker compose version 2>&1 | head -n1 || true)"
    docker info >/dev/null 2>&1 && kv docker_access OK || kv docker_access DENIED_OR_UNAVAILABLE
    docker info >/dev/null 2>&1 && kv running_containers "$(docker ps -q | wc -l | tr -d ' ')"
  fi

  echo; echo "=== IDE DISCOVERY ==="
  found=""
  for c in code-server openvscode-server code cursor windsurf coder theia; do
    if have "$c"; then kv "$c" "$(command -v "$c")"; found="$found $c"; else kv "$c" MISSING; fi
  done
  if have docker && docker info >/dev/null 2>&1; then
    containers="$(docker ps --format '{{.Names}}|{{.Image}}' | grep -Ei 'code-server|openvscode|coder|theia|cursor|windsurf|(^|[/_-])ide([:/_-]|$)' | cut -d'|' -f1 | paste -sd, - || true)"
    [ -n "$containers" ] && kv ide_containers "$containers" && found="$found containers"
  fi
  [ -n "$found" ] || kv detected_ide NONE_IN_STANDARD_PATHS_OR_CONTAINERS

  echo; echo "=== ISOLATED WORKSPACE ==="
  if id "$DEV_USER" >/dev/null 2>&1; then
    DEV_HOME="$(getent passwd "$DEV_USER" | cut -d: -f6)"
    WS="$DEV_HOME/projects/$SLUG"
    install -d -m 0750 -o "$DEV_USER" -g "$DEV_USER" "$WS" "$WS/src" "$WS/tests" "$WS/docs" "$WS/runtime" "$WS/logs"
    cat >"$WS/src/environment_smoke.py" <<'PY'
import json
n = 8
inputs = [0] * n
outputs = [0] * n
assert len(inputs) == len(outputs) == n
assert all(v in (0, 1) for v in inputs + outputs)
print(json.dumps({"status":"ok","title":"8 Neuron Connection","neurons":n,"input":inputs,"output":outputs}, separators=(",", ":")))
PY
    chown "$DEV_USER:$DEV_USER" "$WS/src/environment_smoke.py"
    smoke="$(runuser -u "$DEV_USER" -- python3 "$WS/src/environment_smoke.py" 2>&1 || true)"
    kv development_user PRESENT
    kv workspace_path "$WS"
    kv workspace_owner "$(stat -c '%U:%G' "$WS")"
    runuser -u "$DEV_USER" -- test -w "$WS" && kv workspace_write_test PASS || kv workspace_write_test FAIL
    kv python_smoke "$smoke"
    printf '%s' "$smoke" | grep -q '"status":"ok"' && kv workspace_status READY || kv workspace_status SMOKE_FAILED
    printf '%s\n' "$STAMP" >"$WS/runtime/last_verified_utc.txt"
    chown "$DEV_USER:$DEV_USER" "$WS/runtime/last_verified_utc.txt"
  else
    kv development_user MISSING
    kv workspace_status NOT_CREATED
  fi

  echo; echo "=== REPORT CHANNEL ==="
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth status >/dev/null 2>&1 && kv root_gh_auth OK || kv root_gh_auth FAILED
  echo; echo "=== SAFETY ==="
  kv production_stack_modified NO
  kv packages_installed NO
  kv services_restarted NO
  kv secrets_printed NO
  echo "EIGHT_NEURON_CONNECTION_VPS_VERIFICATION_END"
} >"$REPORT" 2>&1

{
  echo "## 8 Neuron Connection — verified VPS baseline"
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} >"$BODY"

cat "$REPORT"
if HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPO" --body-file "$BODY" >/dev/null 2>&1; then
  echo REPORT_POSTED_TO_GITHUB=YES
  exit 0
fi

echo REPORT_POSTED_TO_GITHUB=NO
exit 3

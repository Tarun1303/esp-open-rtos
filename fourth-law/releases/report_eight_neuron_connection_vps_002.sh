#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

PROJECT_TITLE="8 Neuron Connection"
PROJECT_SLUG="eight-neuron-connection"
DEV_USER="fourthlaw-dev"
REPO="Tarun1303/factory"
ISSUE="7"
CONTROL_BASE="https://fourth-law-94-136-189-216.sslip.io"
PRIOR_UNIT="fourthlaw-release-1788518373-3fdccdca.service"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP_REPORT="$(mktemp)"
TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_REPORT" "$TMP_BODY"' EXIT

kv() { printf '%-30s %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }
first_line() { "$@" 2>&1 | head -n 1 || true; }
version_or_missing() {
  local name="$1"; shift || true
  if have "$name"; then
    kv "$name" "$(command -v "$name") | $(first_line "$name" "$@")"
  else
    kv "$name" "MISSING"
  fi
}

{
  printf '%s\n' "EIGHT_NEURON_CONNECTION_VPS_REPORT_BEGIN"
  kv "timestamp_utc" "$STAMP"
  kv "project_title" "$PROJECT_TITLE"
  kv "execution_user" "$(id -un)"
  kv "execution_uid_gid" "$(id -u):$(id -g)"
  kv "hostname" "$(hostname)"
  kv "kernel" "$(uname -srmo)"
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    kv "operating_system" "${PRETTY_NAME:-unknown}"
  fi
  kv "uptime" "$(uptime -p 2>/dev/null || echo unavailable)"

  printf '\n%s\n' "=== CONTROL AND PRIOR RELEASE ==="
  if have curl; then
    kv "control_base_http" "$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$CONTROL_BASE/" || echo 000)"
    kv "control_health_http" "$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$CONTROL_BASE/health" || echo 000)"
  else
    kv "control_probe" "curl missing"
  fi

  if have systemctl; then
    active="$(systemctl show "$PRIOR_UNIT" -p ActiveState --value 2>/dev/null || true)"
    sub="$(systemctl show "$PRIOR_UNIT" -p SubState --value 2>/dev/null || true)"
    result="$(systemctl show "$PRIOR_UNIT" -p Result --value 2>/dev/null || true)"
    exit_status="$(systemctl show "$PRIOR_UNIT" -p ExecMainStatus --value 2>/dev/null || true)"
    kv "prior_release_unit" "$PRIOR_UNIT"
    kv "prior_release_state" "${active:-unknown}/${sub:-unknown}"
    kv "prior_release_result" "${result:-unknown}"
    kv "prior_release_exit_status" "${exit_status:-unknown}"
  else
    kv "prior_release_unit_check" "systemctl missing"
  fi

  printf '\n%s\n' "=== COMPUTE AND STORAGE ==="
  if have nproc; then kv "cpu_threads" "$(nproc)"; fi
  if have free; then
    kv "memory" "$(free -h | awk '/^Mem:/ {print $2 " total, " $7 " available"}')"
  fi
  if have df; then
    kv "root_disk" "$(df -h / | awk 'NR==2 {print $2 " total, " $4 " available, " $5 " used"}')"
  fi

  printf '\n%s\n' "=== DEVELOPMENT TOOLCHAIN ==="
  version_or_missing bash --version
  version_or_missing git --version
  version_or_missing gh --version
  version_or_missing python3 --version
  version_or_missing pip3 --version
  version_or_missing node --version
  version_or_missing npm --version
  version_or_missing npx --version
  version_or_missing docker --version
  version_or_missing codex --version
  if have docker; then
    kv "docker_compose" "$(first_line docker compose version)"
    if docker info >/dev/null 2>&1; then
      kv "docker_access" "OK"
      kv "running_containers" "$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
      collisions="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Ei 'eight[-_]?neuron[-_]?connection' || true)"
      if [ -n "$collisions" ]; then
        kv "project_container_collision" "YES"
      else
        kv "project_container_collision" "NO"
      fi
    else
      kv "docker_access" "DENIED_OR_UNAVAILABLE"
    fi
  fi

  printf '\n%s\n' "=== IDE DISCOVERY ==="
  found_ide=0
  for cmd in code-server openvscode-server code cursor windsurf coder theia; do
    if have "$cmd"; then
      kv "$cmd" "$(command -v "$cmd")"
      found_ide=1
    else
      kv "$cmd" "MISSING"
    fi
  done
  kv "known_ide_detected" "$found_ide"

  printf '\n%s\n' "=== GITHUB ACCESS ==="
  if have gh && gh auth status >/dev/null 2>&1; then
    kv "gh_auth_execution_user" "OK"
  else
    kv "gh_auth_execution_user" "FAILED_OR_MISSING"
  fi
  if id "$DEV_USER" >/dev/null 2>&1 && have runuser && runuser -u "$DEV_USER" -- gh auth status >/dev/null 2>&1; then
    kv "gh_auth_development_user" "OK"
  else
    kv "gh_auth_development_user" "FAILED_OR_UNAVAILABLE"
  fi

  printf '\n%s\n' "=== ISOLATED WORKSPACE AND SCRIPT EXECUTION ==="
  DEV_HOME=""
  if id "$DEV_USER" >/dev/null 2>&1; then
    DEV_HOME="$(getent passwd "$DEV_USER" | cut -d: -f6)"
    kv "development_user" "PRESENT"
    kv "development_home" "$DEV_HOME"
  else
    kv "development_user" "MISSING"
  fi

  if [ -n "$DEV_HOME" ]; then
    WORKSPACE="$DEV_HOME/projects/$PROJECT_SLUG"
    if [ "$(id -u)" -eq 0 ]; then
      install -d -m 0750 -o "$DEV_USER" -g "$DEV_USER" \
        "$WORKSPACE" "$WORKSPACE/src" "$WORKSPACE/tests" \
        "$WORKSPACE/docs" "$WORKSPACE/runtime" "$WORKSPACE/logs"
    elif [ "$(id -un)" = "$DEV_USER" ]; then
      mkdir -p "$WORKSPACE"/{src,tests,docs,runtime,logs}
      chmod 0750 "$WORKSPACE" "$WORKSPACE"/{src,tests,docs,runtime,logs}
    fi

    if [ -d "$WORKSPACE" ]; then
      kv "workspace_path" "$WORKSPACE"
      kv "workspace_owner" "$(stat -c '%U:%G' "$WORKSPACE" 2>/dev/null || echo unknown)"
      kv "workspace_permissions" "$(stat -c '%a' "$WORKSPACE" 2>/dev/null || echo unknown)"

      SMOKE="$WORKSPACE/src/environment_smoke.py"
      cat >"$SMOKE" <<'PY'
from __future__ import annotations

import json

TITLE = "8 Neuron Connection"
NEURON_COUNT = 8
input_bits = [0] * NEURON_COUNT
output_bits = [0] * NEURON_COUNT

assert len(input_bits) == NEURON_COUNT
assert len(output_bits) == NEURON_COUNT
assert set(input_bits).issubset({0, 1})
assert set(output_bits).issubset({0, 1})

print(
    json.dumps(
        {
            "status": "ok",
            "title": TITLE,
            "neurons": NEURON_COUNT,
            "input_bits": input_bits,
            "output_bits": output_bits,
        },
        separators=(",", ":"),
    )
)
PY
      if [ "$(id -u)" -eq 0 ]; then
        chown "$DEV_USER:$DEV_USER" "$SMOKE"
        smoke_out="$(runuser -u "$DEV_USER" -- python3 "$SMOKE" 2>&1 || true)"
        if runuser -u "$DEV_USER" -- test -w "$WORKSPACE"; then
          kv "workspace_write_test" "OK_AS_$DEV_USER"
        else
          kv "workspace_write_test" "FAILED_AS_$DEV_USER"
        fi
      else
        smoke_out="$(python3 "$SMOKE" 2>&1 || true)"
        if [ -w "$WORKSPACE" ]; then
          kv "workspace_write_test" "OK"
        else
          kv "workspace_write_test" "FAILED"
        fi
      fi
      kv "python_smoke_output" "$smoke_out"
      if printf '%s' "$smoke_out" | grep -q '"status":"ok"'; then
        kv "python_smoke_result" "PASS"
      else
        kv "python_smoke_result" "FAIL"
      fi
      printf '%s\n' "$STAMP" >"$WORKSPACE/runtime/last_verified_utc.txt"
      if [ "$(id -u)" -eq 0 ]; then
        chown "$DEV_USER:$DEV_USER" "$WORKSPACE/runtime/last_verified_utc.txt"
      fi
      kv "workspace_status" "READY"
    else
      kv "workspace_status" "NOT_CREATED"
    fi
  fi

  printf '\n%s\n' "=== SAFETY CHECK ==="
  kv "production_stack_changed" "NO"
  kv "packages_installed" "NO"
  kv "services_restarted" "NO"
  kv "secrets_requested_or_printed" "NO"
  printf '%s\n' "EIGHT_NEURON_CONNECTION_VPS_REPORT_END"
} >"$TMP_REPORT" 2>&1

{
  printf '%s\n\n' "## 8 Neuron Connection — VPS preflight result"
  printf '```text\n'
  cat "$TMP_REPORT"
  printf '```\n'
} >"$TMP_BODY"

posted=0
if have gh && gh auth status >/dev/null 2>&1; then
  if gh issue comment "$ISSUE" --repo "$REPO" --body-file "$TMP_BODY" >/dev/null 2>&1; then
    posted=1
  fi
fi

if [ "$posted" -eq 0 ] && id "$DEV_USER" >/dev/null 2>&1 && have runuser; then
  if runuser -u "$DEV_USER" -- gh auth status >/dev/null 2>&1; then
    if runuser -u "$DEV_USER" -- gh issue comment "$ISSUE" --repo "$REPO" --body-file "$TMP_BODY" >/dev/null 2>&1; then
      posted=1
    fi
  fi
fi

cat "$TMP_REPORT"
if [ "$posted" -eq 1 ]; then
  printf '%s\n' "REPORT_POSTED_TO_GITHUB=YES"
  exit 0
fi

printf '%s\n' "REPORT_POSTED_TO_GITHUB=NO"
exit 3

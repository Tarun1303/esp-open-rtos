#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

PROJECT_TITLE="8 Neuron Connection"
PROJECT_SLUG="eight-neuron-connection"
DEV_USER="fourthlaw-dev"
CONTROL_BASE="https://fourth-law-94-136-189-216.sslip.io"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

say() { printf '%s\n' "$*"; }
kv() { printf '%-28s %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }
version_line() {
  local cmd="$1"; shift || true
  if have "$cmd"; then
    local path out
    path="$(command -v "$cmd")"
    out="$("$cmd" "$@" 2>&1 | head -n 1 || true)"
    kv "$cmd" "${path} | ${out:-version unavailable}"
  else
    kv "$cmd" "MISSING"
  fi
}

say "EIGHT_NEURON_CONNECTION_VPS_PREFLIGHT_BEGIN"
kv "timestamp_utc" "$STAMP"
kv "project_title" "$PROJECT_TITLE"
kv "project_slug" "$PROJECT_SLUG"
kv "execution_user" "$(id -un)"
kv "execution_uid_gid" "$(id -u):$(id -g)"
kv "hostname" "$(hostname)"
kv "kernel" "$(uname -srmo)"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  kv "operating_system" "${PRETTY_NAME:-unknown}"
fi
kv "uptime" "$(uptime -p 2>/dev/null || true)"

say
say "=== CONTROL PLANE ==="
if have curl; then
  base_code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$CONTROL_BASE/" || true)"
  health_code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$CONTROL_BASE/health" || true)"
  kv "control_base_http" "${base_code:-000}"
  kv "control_health_http" "${health_code:-000}"
else
  kv "control_http_probe" "curl missing"
fi

say
say "=== COMPUTE AND STORAGE ==="
if have nproc; then kv "cpu_threads" "$(nproc)"; fi
if have free; then
  mem="$(free -h | awk '/^Mem:/ {print $2 " total, " $7 " available"}')"
  kv "memory" "$mem"
fi
if have df; then
  disk="$(df -h / | awk 'NR==2 {print $2 " total, " $4 " available, " $5 " used"}')"
  kv "root_disk" "$disk"
fi

say
say "=== DEVELOPMENT TOOLCHAIN ==="
version_line bash --version
version_line git --version
version_line gh --version
version_line python3 --version
version_line pip3 --version
version_line node --version
version_line npm --version
version_line npx --version
version_line docker --version
if have docker; then
  compose_out="$(docker compose version 2>&1 | head -n 1 || true)"
  kv "docker_compose" "${compose_out:-unavailable}"
  if docker info >/dev/null 2>&1; then
    kv "docker_access" "OK"
    container_count="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
    kv "running_containers" "$container_count"
    collisions="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '(^|[-_])eight[-_]neuron[-_]connection($|[-_])' || true)"
    if [ -n "$collisions" ]; then
      kv "project_name_collision" "YES: $(printf '%s' "$collisions" | paste -sd, -)"
    else
      kv "project_name_collision" "NO"
    fi
  else
    kv "docker_access" "DENIED_OR_UNAVAILABLE"
  fi
fi
version_line codex --version

say
say "=== IDE / REMOTE DEVELOPMENT DISCOVERY ==="
for cmd in code-server openvscode-server code cursor windsurf coder theia; do
  if have "$cmd"; then
    kv "$cmd" "$(command -v "$cmd")"
  else
    kv "$cmd" "MISSING"
  fi
done

say
say "=== GITHUB ACCESS CHECK ==="
if have gh && gh auth status >/dev/null 2>&1; then
  kv "gh_auth" "OK"
  if gh repo view Tarun1303/esp-open-rtos --json nameWithOwner >/dev/null 2>&1; then
    kv "release_repository_read" "OK"
  else
    kv "release_repository_read" "FAILED"
  fi
else
  kv "gh_auth" "FAILED_OR_MISSING"
fi

say
say "=== ISOLATED WORKSPACE ==="
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
    cat >"$WORKSPACE/README.md" <<'EOF'
# 8 Neuron Connection

Isolated VPS workspace for the small recurrent-network visual experiment.

This directory is intentionally separate from the existing Fourth Law production stack.
No model implementation has been installed yet.
EOF
    chown "$DEV_USER:$DEV_USER" "$WORKSPACE/README.md"
    printf '%s\n' "$STAMP" >"$WORKSPACE/runtime/preflight_marker_utc.txt"
    chown "$DEV_USER:$DEV_USER" "$WORKSPACE/runtime/preflight_marker_utc.txt"
    if runuser -u "$DEV_USER" -- test -w "$WORKSPACE"; then
      kv "workspace_write_test" "OK_AS_$DEV_USER"
    else
      kv "workspace_write_test" "FAILED_AS_$DEV_USER"
    fi
  elif [ "$(id -un)" = "$DEV_USER" ]; then
    mkdir -p "$WORKSPACE"/{src,tests,docs,runtime,logs}
    chmod 0750 "$WORKSPACE" "$WORKSPACE"/{src,tests,docs,runtime,logs}
    cat >"$WORKSPACE/README.md" <<'EOF'
# 8 Neuron Connection

Isolated VPS workspace for the small recurrent-network visual experiment.

This directory is intentionally separate from the existing Fourth Law production stack.
No model implementation has been installed yet.
EOF
    printf '%s\n' "$STAMP" >"$WORKSPACE/runtime/preflight_marker_utc.txt"
    kv "workspace_write_test" "OK_AS_$DEV_USER"
  else
    kv "workspace_creation" "SKIPPED_INSUFFICIENT_PRIVILEGE"
  fi

  if [ -d "$WORKSPACE" ]; then
    kv "workspace_path" "$WORKSPACE"
    kv "workspace_status" "READY"
  else
    kv "workspace_status" "NOT_CREATED"
  fi
fi

say
say "=== LANGUAGE SMOKE TESTS ==="
if have python3; then
  python3 - <<'PY'
import json
payload = {
    "python_smoke": "ok",
    "neurons": 8,
    "input_bits": [0] * 8,
    "output_bits": [0] * 8,
}
print(json.dumps(payload, separators=(",", ":")))
PY
fi
if have node; then
  node -e 'console.log(JSON.stringify({node_smoke:"ok",neurons:8}))'
fi

say
say "=== SAFETY ASSERTIONS ==="
kv "production_files_modified" "NO"
kv "production_containers_modified" "NO"
kv "packages_installed" "NO"
kv "services_restarted" "NO"
kv "secrets_printed" "NO"
say "EIGHT_NEURON_CONNECTION_VPS_PREFLIGHT_END"

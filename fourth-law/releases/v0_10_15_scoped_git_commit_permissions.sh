#!/usr/bin/env bash
# Host-local Codex permission-profile repair for Fourth Law v0.10.15.
# This release does not modify, restart, or deploy the production application.
set -Eeuo pipefail

readonly RELEASE='v0.10.15'
readonly DEV_USER='fourthlaw-dev'
readonly DEV_HOME='/var/lib/fourthlaw-dev'
readonly CODEX_HOME_DIR="$DEV_HOME/.codex"
readonly CONFIG="$CODEX_HOME_DIR/config.toml"
readonly CODEX_SERVICE='fourthlaw-codex.service'
readonly HEALTH_URL='http://127.0.0.1:8787/health'
readonly PROFILE='fourthlaw-workspace'
readonly RECEIPT='/tmp/fourth-law-v0.10.15-scoped-git-permissions-receipt.json'
readonly EXPECTED_CODEX_VERSION='codex-cli 0.151.0'

readonly -a ROLE_REPOS=(
  "$DEV_HOME/agent-repos/supervisor"
  "$DEV_HOME/agent-repos/architecture"
  "$DEV_HOME/agent-repos/runtime"
  "$DEV_HOME/agent-repos/control-room"
  "$DEV_HOME/agent-repos/execution"
  "$DEV_HOME/agent-repos/efficiency"
)
readonly -a IMPLEMENTATION_REPOS=(
  "$DEV_HOME/agent-repos/architecture"
  "$DEV_HOME/agent-repos/runtime"
  "$DEV_HOME/agent-repos/control-room"
  "$DEV_HOME/agent-repos/efficiency"
)

umask 077
BACKUP_DIR=''
CONFIG_BACKUP_SHA256='not_created'
SERVICE_STATE_SHA256='not_created'
SERVICE_UNIT_SHA256='not_created'
SCRIPT_SHA256='unknown'
PRE_HEALTH_SHA256='not_checked'
POST_HEALTH_SHA256='not_checked'
ROLLBACK_HEALTH_SHA256='not_checked'
ROLLBACK_STATE='not_needed'
WORKTREE_INTEGRITY='not_checked'
FINAL_DECISION='blocked'
FAILED_COMMAND='none'
CONFIG_MUTATED=0
PROBE_ROOT=''
OUTSIDE_SENTINEL=''
declare -A PROBES=()

sha256_file() {
  sha256sum -- "$1" | awk '{print $1}'
}

capture_health() {
  local destination=$1
  curl --fail --silent --show-error --max-time 10 "$HEALTH_URL" >"$destination"
  python3 - "$destination" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    health = json.load(handle)
if health.get("ok") is not True or health.get("version") != "0.10.14":
    raise SystemExit("health must be exactly ok=true and version=0.10.14")
PY
}

capture_worktrees() {
  local destination=$1 repo
  : >"$destination"
  for repo in "${IMPLEMENTATION_REPOS[@]}"; do
    printf '%s\t%s\t%s\t%s\n' \
      "$repo" \
      "$(git -C "$repo" status --porcelain=v1 -z | sha256sum | awk '{print $1}')" \
      "$(git -C "$repo" diff --binary --no-ext-diff | sha256sum | awk '{print $1}')" \
      "$(git -C "$repo" diff --cached --binary --no-ext-diff | sha256sum | awk '{print $1}')" \
      >>"$destination"
  done
}

check_worktrees() {
  local current="$BACKUP_DIR/worktrees.current.tsv"
  capture_worktrees "$current"
  if cmp --silent "$BACKUP_DIR/worktrees.pre.tsv" "$current"; then
    WORKTREE_INTEGRITY='unchanged'
    return 0
  fi
  WORKTREE_INTEGRITY='changed'
  return 1
}

emit_receipt() {
  local health_file=''
  if [[ -n $BACKUP_DIR && -f $BACKUP_DIR/post-health.json ]]; then
    health_file="$BACKUP_DIR/post-health.json"
  elif [[ -n $BACKUP_DIR && -f $BACKUP_DIR/rollback-health.json ]]; then
    health_file="$BACKUP_DIR/rollback-health.json"
  elif [[ -n $BACKUP_DIR && -f $BACKUP_DIR/pre-health.json ]]; then
    health_file="$BACKUP_DIR/pre-health.json"
  fi
  PROBES_TSV="${PROBES_TSV:-${BACKUP_DIR:-/tmp}/probes.tsv}"
  : >"$PROBES_TSV"
  local key
  for key in "${!PROBES[@]}"; do
    printf '%s\t%s\n' "$key" "${PROBES[$key]}" >>"$PROBES_TSV"
  done
  sort -o "$PROBES_TSV" "$PROBES_TSV"
  RELEASE="$RELEASE" SCRIPT_PATH="$(readlink -f -- "$0")" \
  SCRIPT_SHA256="$SCRIPT_SHA256" PROFILE="$PROFILE" RECEIPT="$RECEIPT" \
  BACKUP_DIR="$BACKUP_DIR" CONFIG_BACKUP_SHA256="$CONFIG_BACKUP_SHA256" \
  SERVICE_STATE_SHA256="$SERVICE_STATE_SHA256" SERVICE_UNIT_SHA256="$SERVICE_UNIT_SHA256" \
  PRE_HEALTH_SHA256="$PRE_HEALTH_SHA256" POST_HEALTH_SHA256="$POST_HEALTH_SHA256" \
  ROLLBACK_HEALTH_SHA256="$ROLLBACK_HEALTH_SHA256" ROLLBACK_STATE="$ROLLBACK_STATE" \
  WORKTREE_INTEGRITY="$WORKTREE_INTEGRITY" FINAL_DECISION="$FINAL_DECISION" \
  FAILED_COMMAND="$FAILED_COMMAND" HEALTH_FILE="$health_file" PROBES_TSV="$PROBES_TSV" \
  python3 - "$RECEIPT" "${ROLE_REPOS[@]}" <<'PY'
import json
import os
import sys

receipt_path = sys.argv[1]
roots = sys.argv[2:]
probes = {}
with open(os.environ["PROBES_TSV"], encoding="utf-8") as handle:
    for line in handle:
        name, result = line.rstrip("\n").split("\t", 1)
        probes[name] = result
health = None
health_file = os.environ.get("HEALTH_FILE")
if health_file:
    with open(health_file, encoding="utf-8") as handle:
        health = json.load(handle)
receipt = {
    "schema": "fourth-law.scoped-git-permissions.receipt.v1",
    "release": os.environ["RELEASE"],
    "script": {
        "path": os.environ["SCRIPT_PATH"],
        "sha256": os.environ["SCRIPT_SHA256"],
    },
    "permission_profile": os.environ["PROFILE"],
    "default_permissions": os.environ["PROFILE"],
    "exact_roots": roots,
    "allowed": {
        "ordinary_files": "selected fixed repository only",
        "git_metadata": [".git/index", ".git/index.lock", ".git/objects", ".git/refs", ".git/logs"],
        "local_commit": True,
    },
    "denied": {
        "git_config_write": True,
        "git_hooks_write": True,
        "environment_and_secret_read_write": True,
        "codex_credential_store": True,
        "network": True,
        "git_remote_push": True,
        "paths_outside_fixed_roots_write": True,
        "production_application_write": True,
        "production_container_or_service_control": True,
    },
    "backups": {
        "directory": os.environ["BACKUP_DIR"],
        "config_sha256": os.environ["CONFIG_BACKUP_SHA256"],
        "service_state_sha256": os.environ["SERVICE_STATE_SHA256"],
        "service_unit_sha256": os.environ["SERVICE_UNIT_SHA256"],
    },
    "probes": probes,
    "health": {
        "evidence": health,
        "pre_sha256": os.environ["PRE_HEALTH_SHA256"],
        "post_sha256": os.environ["POST_HEALTH_SHA256"],
        "rollback_sha256": os.environ["ROLLBACK_HEALTH_SHA256"],
    },
    "rollback": {
        "state": os.environ["ROLLBACK_STATE"],
        "implementation_worktrees": os.environ["WORKTREE_INTEGRITY"],
    },
    "failed_command": os.environ["FAILED_COMMAND"],
    "final_decision": os.environ["FINAL_DECISION"],
}
with open(receipt_path, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
PY
}

cleanup_probe() {
  if [[ -n $PROBE_ROOT && -d $PROBE_ROOT ]]; then
    rm -rf -- "$PROBE_ROOT"
  fi
  if [[ -n $OUTSIDE_SENTINEL && -f $OUTSIDE_SENTINEL ]]; then
    rm -f -- "$OUTSIDE_SENTINEL"
  fi
}

rollback() {
  set +e
  cleanup_probe
  if [[ $CONFIG_MUTATED == 1 && -n $BACKUP_DIR && -f $BACKUP_DIR/config.toml ]]; then
    install -o "$DEV_USER" -g "$DEV_USER" -m 0600 "$BACKUP_DIR/config.toml" "$CONFIG"
    systemctl restart "$CODEX_SERVICE"
    ROLLBACK_STATE='configuration_restored_service_restarted'
  else
    ROLLBACK_STATE='not_required_no_mutation'
  fi
  if [[ -n $BACKUP_DIR && -f $BACKUP_DIR/pre-health.json ]]; then
    if capture_health "$BACKUP_DIR/rollback-health.json"; then
      ROLLBACK_HEALTH_SHA256="$(sha256_file "$BACKUP_DIR/rollback-health.json")"
    else
      ROLLBACK_HEALTH_SHA256='failed'
    fi
    check_worktrees || true
  fi
}

fail() {
  local code=$1 command=$2
  trap - ERR
  FAILED_COMMAND=$command
  rollback
  FINAL_DECISION='blocked_rolled_back'
  emit_receipt || true
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR

[[ $(id -u) -eq 0 ]]
[[ $(codex --version) == "$EXPECTED_CODEX_VERSION" ]]
[[ -f $CONFIG ]]
[[ ! -L $CONFIG ]]
[[ $(stat -c '%U:%G' "$CONFIG") == "$DEV_USER:$DEV_USER" ]]
[[ $(stat -c '%a' "$CONFIG") == 600 ]]
systemctl is-active --quiet "$CODEX_SERVICE"
for repo in "${ROLE_REPOS[@]}"; do
  [[ -d $repo/.git ]]
  [[ $(git -C "$repo" rev-parse --show-toplevel) == "$repo" ]]
done

SCRIPT_SHA256="$(sha256_file "$0")"
BACKUP_DIR="$(mktemp -d /var/tmp/fourth-law-v0.10.15-permissions.XXXXXX)"
chmod 0700 "$BACKUP_DIR"
capture_health "$BACKUP_DIR/pre-health.json"
PRE_HEALTH_SHA256="$(sha256_file "$BACKUP_DIR/pre-health.json")"
capture_worktrees "$BACKUP_DIR/worktrees.pre.tsv"

install -m 0600 "$CONFIG" "$BACKUP_DIR/config.toml"
systemctl show "$CODEX_SERVICE" \
  --property=ActiveState,SubState,UnitFileState,FragmentPath,MainPID,ExecMainStartTimestamp \
  >"$BACKUP_DIR/service-state.txt"
systemctl cat "$CODEX_SERVICE" >"$BACKUP_DIR/service-unit.txt"
CONFIG_BACKUP_SHA256="$(sha256_file "$BACKUP_DIR/config.toml")"
SERVICE_STATE_SHA256="$(sha256_file "$BACKUP_DIR/service-state.txt")"
SERVICE_UNIT_SHA256="$(sha256_file "$BACKUP_DIR/service-unit.txt")"

python3 - "$CONFIG" "$BACKUP_DIR/candidate/config.toml" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
destination.parent.mkdir(mode=0o700)
text = source.read_text(encoding="utf-8")
if re.search(r"(?m)^\s*sandbox_mode\s*=", text):
    raise SystemExit("legacy sandbox_mode is present; refusing to mix permission systems")

lines = text.splitlines(keepends=True)
result = []
inside_target = False
root_table_seen = False
for line in lines:
    table = re.match(r"^\s*\[([^]]+)\]\s*(?:#.*)?$", line)
    if table:
        root_table_seen = True
        name = table.group(1).strip()
        inside_target = name == "permissions.fourthlaw-workspace" or name.startswith("permissions.fourthlaw-workspace.")
        if inside_target:
            continue
    if inside_target:
        continue
    if not root_table_seen and re.match(r"^\s*default_permissions\s*=", line):
        continue
    result.append(line)

profile = r'''
default_permissions = "fourthlaw-workspace"

[permissions.fourthlaw-workspace]
extends = ":workspace"

[permissions.fourthlaw-workspace.filesystem]
glob_scan_max_depth = 12
"." = "write"
".git/index" = "write"
".git/index.lock" = "write"
".git/objects" = "write"
".git/objects/**" = "write"
".git/refs" = "write"
".git/refs/**" = "write"
".git/logs" = "write"
".git/logs/**" = "write"
".git/config" = "read"
".git/hooks" = "read"
".git/hooks/**" = "read"
".env" = "none"
".env.*" = "none"
"**/.env" = "none"
"**/.env.*" = "none"
"*credential*" = "none"
"**/*credential*" = "none"
"*secret*" = "none"
"**/*secret*" = "none"
"/var/lib/fourthlaw-dev/.codex" = "none"

[permissions.fourthlaw-workspace.network]
enabled = false
'''
candidate = "".join(result).rstrip() + "\n" + profile
destination.write_text(candidate, encoding="utf-8")
destination.chmod(0o600)
PY

mkdir -m 0700 "$BACKUP_DIR/candidate-home"
install -m 0600 "$BACKUP_DIR/candidate/config.toml" "$BACKUP_DIR/candidate-home/config.toml"
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" CODEX_HOME="$BACKUP_DIR/candidate-home" \
  codex sandbox --permission-profile "$PROFILE" --cd "${ROLE_REPOS[4]}" -- /usr/bin/true
PROBES[schema_and_candidate_resolution]='pass'

install -o "$DEV_USER" -g "$DEV_USER" -m 0600 "$BACKUP_DIR/candidate/config.toml" "$CONFIG"
CONFIG_MUTATED=1
[[ $(grep -Ec '^default_permissions = "fourthlaw-workspace"$' "$CONFIG") -eq 1 ]]
[[ $(grep -Ec '^\[permissions\.fourthlaw-workspace\]$' "$CONFIG") -eq 1 ]]
! grep -Eq '^\s*sandbox_mode\s*=' "$CONFIG"

systemctl restart "$CODEX_SERVICE"
for _ in $(seq 1 40); do
  systemctl is-active --quiet "$CODEX_SERVICE" && break
  sleep 1
done
systemctl is-active --quiet "$CODEX_SERVICE"
PROBES[host_local_app_server_restart]='pass'

run_sandbox() {
  local cwd=$1
  shift
  runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" CODEX_HOME="$CODEX_HOME_DIR" \
    codex sandbox --permission-profile "$PROFILE" --cd "$cwd" -- "$@"
}

run_sandbox "${ROLE_REPOS[4]}" /usr/bin/true
PROBES[resolved_profile]='pass'

for repo in "${ROLE_REPOS[@]}"; do
  run_sandbox "$repo" /bin/sh -c \
    'test "$(git rev-parse --show-toplevel)" = "$PWD" && git status --porcelain=v1 >/dev/null && git diff --check'
done
PROBES[all_role_repositories_non_mutating]='pass'

PROBE_ROOT="${ROLE_REPOS[4]}/.fourth-law-v0.10.15-probe.$$"
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0700 "$PROBE_ROOT"
runuser -u "$DEV_USER" -- git -C "$PROBE_ROOT" init --quiet
runuser -u "$DEV_USER" -- touch "$PROBE_ROOT/.env"
run_sandbox "$PROBE_ROOT" /bin/sh -c '
  printf "%s\n" scoped-permissions > tracked.txt
  git add tracked.txt
  tree=$(git write-tree)
  commit=$(printf "%s\n" scoped-permissions | git -c user.name=Fourth-Law-Probe -c user.email=probe.invalid commit-tree "$tree")
  git update-ref refs/heads/probe "$commit"
  test "$(git rev-parse refs/heads/probe)" = "$commit"
'
PROBES[temporary_repository_local_add_commit]='pass'

if run_sandbox "$PROBE_ROOT" python3 -c \
  'import os,sys; fd=os.open(".git/config", os.O_WRONLY); os.close(fd); sys.exit(0)'; then
  raise='git config unexpectedly writable'; false "$raise"
fi
PROBES[deny_git_config_write]='pass'

HOOK_SAMPLE="$(find "$PROBE_ROOT/.git/hooks" -maxdepth 1 -type f -print -quit)"
[[ -n $HOOK_SAMPLE ]]
if run_sandbox "$PROBE_ROOT" python3 -c \
  'import os,sys; fd=os.open(sys.argv[1], os.O_WRONLY); os.close(fd); sys.exit(0)' "$HOOK_SAMPLE"; then
  raise='git hook unexpectedly writable'; false "$raise"
fi
PROBES[deny_git_hooks_write]='pass'

if run_sandbox "$PROBE_ROOT" python3 -c 'open(".env", "rb").close()'; then
  raise='environment file unexpectedly readable'; false "$raise"
fi
PROBES[deny_environment_secret_files]='pass'

if run_sandbox "$PROBE_ROOT" /bin/sh -c 'test -r /var/lib/fourthlaw-dev/.codex'; then
  raise='Codex credential store unexpectedly readable'; false "$raise"
fi
PROBES[deny_codex_credential_store]='pass'

OUTSIDE_SENTINEL="$(mktemp /var/tmp/fourth-law-v0.10.15-outside.XXXXXX)"
chown "$DEV_USER:$DEV_USER" "$OUTSIDE_SENTINEL"
if run_sandbox "$PROBE_ROOT" python3 -c \
  'import os,sys; fd=os.open(sys.argv[1], os.O_WRONLY); os.close(fd); sys.exit(0)' "$OUTSIDE_SENTINEL"; then
  raise='path outside fixed repositories unexpectedly writable'; false "$raise"
fi
PROBES[deny_outside_repository_write]='pass'

if run_sandbox "$PROBE_ROOT" python3 -c \
  'import os,socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(("127.0.0.1", 9)) == 0 else 1)'; then
  raise='network unexpectedly reachable'; false "$raise"
fi
PROBES[deny_network]='pass'

if run_sandbox "$PROBE_ROOT" git push https://127.0.0.1:9/fourth-law.git refs/heads/probe; then
  raise='git push unexpectedly succeeded'; false "$raise"
fi
PROBES[deny_git_remote_push]='pass'

run_sandbox "$PROBE_ROOT" /bin/sh -c '
  test "$(id -u)" != 0
  ! test -w /opt/fourth-law-agent
  ! test -w /run/docker.sock
  ! sudo -n true >/dev/null 2>&1
'
PROBES[deny_production_write_and_control]='pass'

cleanup_probe
capture_health "$BACKUP_DIR/post-health.json"
POST_HEALTH_SHA256="$(sha256_file "$BACKUP_DIR/post-health.json")"
PROBES[post_health_v0_10_14]='pass'
check_worktrees
PROBES[implementation_worktrees_preserved]='pass'

CONFIG_MUTATED=0
FINAL_DECISION='ready'
ROLLBACK_STATE='not_needed'
emit_receipt
trap - ERR
printf '%s\n' 'FOURTH_LAW_SCOPED_GIT_PERMISSIONS_V0_10_15_READY'

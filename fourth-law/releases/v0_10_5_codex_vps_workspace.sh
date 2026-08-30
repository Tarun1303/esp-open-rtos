#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
DEV_USER=fourthlaw-dev
DEV_HOME=/var/lib/fourthlaw-dev
SOURCE="$DEV_HOME/source"
WORKTREES="$DEV_HOME/worktrees"
CODEX_DIR="$DEV_HOME/.codex"
REPORT=/tmp/fl-v0105-codex-report.txt
STEP=starting

fail_report() {
  set +e
  {
    echo CODEX_VPS_WORKSPACE_BOOTSTRAP_FAILED
    echo "step=$STEP"
    echo 'Production application was not modified by this bootstrap.'
    test -f "$REPORT" && tail -100 "$REPORT"
  } | HOME=/root GH_CONFIG_DIR=/root/.config/gh \
      gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}
trap fail_report ERR
: >"$REPORT"

STEP=install_runtime
export DEBIAN_FRONTEND=noninteractive
apt-get update >>"$REPORT" 2>&1
apt-get install -y --no-install-recommends nodejs npm ca-certificates >>"$REPORT" 2>&1
npm install --global @openai/codex >>"$REPORT" 2>&1
codex --version >>"$REPORT"

STEP=create_identity
id "$DEV_USER" >/dev/null 2>&1 ||
  useradd --system --create-home --home-dir "$DEV_HOME" --shell /bin/bash "$DEV_USER"
passwd -l "$DEV_USER" >/dev/null 2>&1 || true
install -d -m 0750 -o "$DEV_USER" -g "$DEV_USER" "$SOURCE" "$WORKTREES" "$CODEX_DIR"

STEP=copy_sanitized_source
install -d -m 0750 -o "$DEV_USER" -g "$DEV_USER" "$SOURCE/app" "$SOURCE/app/static"
for f in "$PROJECT"/app/*.py; do
  test -f "$f" || continue
  install -m 0640 -o "$DEV_USER" -g "$DEV_USER" "$f" "$SOURCE/app/$(basename "$f")"
done
if test -d "$PROJECT/app/static"; then
  while IFS= read -r -d '' f; do
    rel="$(realpath --relative-to="$PROJECT/app/static" "$f")"
    install -D -m 0640 -o "$DEV_USER" -g "$DEV_USER" "$f" "$SOURCE/app/static/$rel"
  done < <(find "$PROJECT/app/static" -type f -print0)
fi
for name in Dockerfile compose.yaml requirements.txt; do
  test -f "$PROJECT/$name" &&
    install -m 0640 -o "$DEV_USER" -g "$DEV_USER" "$PROJECT/$name" "$SOURCE/$name"
done

STEP=write_policy
python3 - <<'PY'
from pathlib import Path
root=Path('/var/lib/fourthlaw-dev/source')
(root/'.gitignore').write_text('''.env
.env.*
*.pem
*.key
*secret*
*credential*
auth.json
.codex/
data/
backups/
dispatched-releases/
__pycache__/
*.pyc
AGENTS.override.md
''')
(root/'AGENTS.md').write_text('''# Fourth Law coding contract

Improve the platform through small, verified, reversible changes.

Mandatory safety:
- Never read, print, copy, or modify environment files, credentials, keys, or host secrets.
- Work only inside the assigned Git worktree.
- Never modify /opt/fourth-law-agent directly.
- Never deploy or restart production from a coding thread.
- Do not alter firewall, SSH, users, system services, or permission boundaries.
- Keep changes scoped and return a diff with test evidence.

Required workflow:
1. Inspect actual source before editing.
2. Make the smallest coherent patch.
3. Run python3 -m py_compile app/*.py.
4. Run focused deterministic checks.
5. Report changed files, validation, remaining risk, and rollback notes.
6. Treat every change as staged until integration and deployment gates approve it.

Architecture invariants:
- Root Supervisor creates exactly four primary modules when four-way decomposition applies.
- Depth one or deeper agents may create at most two children.
- Same-mission continuation never enters the legacy recursive task engine.
- Human authority and safety outrank efficiency.
- Never expose hidden chain-of-thought; return concise operational evidence.
''')
PY
chown "$DEV_USER:$DEV_USER" "$SOURCE/.gitignore" "$SOURCE/AGENTS.md"
chmod 0640 "$SOURCE/.gitignore" "$SOURCE/AGENTS.md"

STEP=initialize_git
test -d "$SOURCE/.git" ||
  runuser -u "$DEV_USER" -- git -C "$SOURCE" init -b main >>"$REPORT" 2>&1
runuser -u "$DEV_USER" -- git -C "$SOURCE" config user.name 'Fourth Law Codex'
runuser -u "$DEV_USER" -- git -C "$SOURCE" config user.email 'codex@fourth-law.local'
runuser -u "$DEV_USER" -- git -C "$SOURCE" add -A
if ! runuser -u "$DEV_USER" -- git -C "$SOURCE" diff --cached --quiet; then
  runuser -u "$DEV_USER" -- git -C "$SOURCE" commit -m 'Snapshot verified Fourth Law runtime source' >>"$REPORT" 2>&1
fi

STEP=create_worktrees
for role in runtime control-room execution efficiency; do
  path="$WORKTREES/$role"
  branch="agent/$role"
  if ! test -e "$path/.git"; then
    if runuser -u "$DEV_USER" -- git -C "$SOURCE" show-ref --verify --quiet "refs/heads/$branch"; then
      runuser -u "$DEV_USER" -- git -C "$SOURCE" worktree add "$path" "$branch" >>"$REPORT" 2>&1
    else
      runuser -u "$DEV_USER" -- git -C "$SOURCE" worktree add -b "$branch" "$path" main >>"$REPORT" 2>&1
    fi
  fi
done

python3 - <<'PY'
from pathlib import Path
base=Path('/var/lib/fourthlaw-dev/worktrees')
common='''# Agent worktree contract
- Obey the repository safety contract.
- Work only in this worktree; never edit or deploy production.
- Never read or expose secrets.
- Run syntax and focused tests and return a diff.
'''
roles={
'runtime': '''
Role: Runtime and orchestration.
Own intelligence_engine.py, problem_engine.py, and lifecycle portions of main.py.
Focus on continuation, bounded delegation, state reconciliation, and verifier scope.
''',
'control-room': '''
Role: Control Room and realtime interaction.
Own control_room.py and app/static.
Focus on SSE, operator conversation, human intervention, responsive UI, and truthful state.
''',
'execution': '''
Role: Execution and release safety.
Own code_workspace.py and integration contracts.
Focus on staging, deterministic tests, diffs, checksums, approvals, and rollback.
''',
'efficiency': '''
Role: Efficiency and resource governance.
Own shared_memory.py and efficiency-governor sections.
Focus on request budgets, context compression, scoped memory, and duplicate-call prevention.
'''
}
for name,body in roles.items():
    (base/name/'AGENTS.override.md').write_text(common+body)
PY
chown -R "$DEV_USER:$DEV_USER" "$DEV_HOME"
find "$WORKTREES" -name AGENTS.override.md -exec chmod 0640 {} +

STEP=authenticate
api_key=''
if test -f "$PROJECT/.env"; then
  api_key="$(sed -n 's/^OPENAI_API_KEY=//p' "$PROJECT/.env" | tail -1)"
  test -n "$api_key" || api_key="$(sed -n 's/^CODEX_API_KEY=//p' "$PROJECT/.env" | tail -1)"
fi
if test -z "$api_key"; then
  echo 'No existing OpenAI API credential was available.' >>"$REPORT"
  exit 31
fi
printf '%s' "$api_key" | runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" CODEX_HOME="$CODEX_DIR" \
  codex login --with-api-key >>"$REPORT" 2>&1
unset api_key
chmod 0700 "$CODEX_DIR"
test -f "$CODEX_DIR/auth.json" && chmod 0600 "$CODEX_DIR/auth.json"
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" CODEX_HOME="$CODEX_DIR" \
  codex login status >>"$REPORT" 2>&1

STEP=configure
python3 - <<'PY'
from pathlib import Path
Path('/var/lib/fourthlaw-dev/.codex/config.toml').write_text('''model = "gpt-5.6-terra"
model_reasoning_effort = "medium"
approval_policy = "never"
sandbox_mode = "workspace-write"
project_doc_max_bytes = 65536
''')
PY
chown "$DEV_USER:$DEV_USER" "$CODEX_DIR/config.toml"
chmod 0600 "$CODEX_DIR/config.toml"

STEP=validate
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" CODEX_HOME="$CODEX_DIR" \
  codex exec --ephemeral --sandbox read-only --ask-for-approval never \
  --model gpt-5.6-terra --cd "$SOURCE" \
  'Inspect AGENTS.md and Git status without changing files. Return exactly CODEX_WORKSPACE_READY if the repository is readable, clean, and its safety contract is loaded.' \
  >"$DEV_HOME/first-run.txt" 2>>"$REPORT"
grep -q CODEX_WORKSPACE_READY "$DEV_HOME/first-run.txt"
runuser -u "$DEV_USER" -- python3 -m py_compile "$SOURCE"/app/*.py
test -z "$(runuser -u "$DEV_USER" -- git -C "$SOURCE" status --porcelain)"

STEP=install_app_server
python3 - <<'PY'
from pathlib import Path
Path('/etc/systemd/system/fourthlaw-codex.service').write_text('''[Unit]
Description=Fourth Law local Codex app server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=fourthlaw-dev
Group=fourthlaw-dev
WorkingDirectory=/var/lib/fourthlaw-dev/source
Environment=HOME=/var/lib/fourthlaw-dev
Environment=CODEX_HOME=/var/lib/fourthlaw-dev/.codex
RuntimeDirectory=fourthlaw-codex
RuntimeDirectoryMode=0750
ExecStart=/usr/local/bin/codex app-server --listen unix:///run/fourthlaw-codex/app.sock
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/fourthlaw-dev /run/fourthlaw-codex

[Install]
WantedBy=multi-user.target
''')
PY
systemctl daemon-reload
systemctl enable --now fourthlaw-codex.service >>"$REPORT" 2>&1
for _ in $(seq 1 30); do
  systemctl is-active --quiet fourthlaw-codex.service &&
    test -S /run/fourthlaw-codex/app.sock && break
  sleep 1
done
systemctl is-active --quiet fourthlaw-codex.service
test -S /run/fourthlaw-codex/app.sock

STEP=publish_private_branch
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth setup-git >>"$REPORT" 2>&1
git config --global --add safe.directory "$SOURCE"
git -C "$SOURCE" remote get-url origin >/dev/null 2>&1 ||
  git -C "$SOURCE" remote add origin https://github.com/Tarun1303/factory.git
git -C "$SOURCE" push --force-with-lease origin main:refs/heads/fourth-law-runtime >>"$REPORT" 2>&1

STEP=success
commit="$(runuser -u "$DEV_USER" -- git -C "$SOURCE" rev-parse --short=12 HEAD)"
{
  echo CODEX_VPS_WORKSPACE_BOOTSTRAPPED
  echo "codex_version=$(codex --version | head -1)"
  echo "source_commit=$commit"
  echo private_branch=fourth-law-runtime
  echo production_modified=false
  echo app_server=active-local-unix-socket
  echo worktrees=runtime,control-room,execution,efficiency
  echo secret_policy=denied
  echo direct_production_write=false
  echo codex_first_run=CODEX_WORKSPACE_READY
  echo production_health=
  curl -fsS http://127.0.0.1:8787/health || true
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

trap - ERR
echo CODEX_VPS_WORKSPACE_READY


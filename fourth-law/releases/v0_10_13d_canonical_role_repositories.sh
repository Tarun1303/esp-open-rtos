#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
DEV_USER=fourthlaw-dev
DEV_HOME=/var/lib/fourthlaw-dev
LEGACY_SOURCE="$DEV_HOME/source"
LEGACY_WORKTREES="$DEV_HOME/worktrees"
CANONICAL="$DEV_HOME/canonical"
ROLE_REPOS="$DEV_HOME/agent-repos"
PRESERVED="$DEV_HOME/preserved-workspaces/v0.10.13"
CODEX_CONFIG="$DEV_HOME/.codex/config.toml"
CODEX_UNIT=/etc/systemd/system/fourthlaw-codex.service
REPOSITORY=https://github.com/Tarun1303/fourth-law.git
REPORT=/tmp/fl-v01013d-role-repositories.txt
STAGE="$(mktemp -d /tmp/fl-v01013d-stage.XXXXXX)"
BACKUP="$(mktemp -d /opt/fl-v01013d-backup.XXXXXX)"
CONFIG_BACKUP="$(mktemp /tmp/fl-v01013d-config.XXXXXX)"
UNIT_BACKUP="$(mktemp /tmp/fl-v01013d-unit.XXXXXX)"
STEP=starting
DEPLOY_STARTED=0
SERVICE_CHANGED=0

MAIN_SHA=fcbb9cea3a5bd017fc520c7ca63dbbe920180092
SUPERVISOR_SHA=a2b1a9534909bcd1ea9fd307fa8b69de4093fb8b
ARCHITECTURE_SHA=a56143b1ff4d12627c9e7b0573968f434530d94f
RUNTIME_SHA=a7c9e3a272cd14e31945fc4354ffae725f4f5407
CONTROL_ROOM_SHA=f142015fcf92b5541887d77d8801951a68ed4894
EXECUTION_SHA=cbb83d0901540537717062883903f7456a9deef9
EFFICIENCY_SHA=948b482d667d90853be79eb32fad3a3d59a0c544

cleanup() {
  rm -rf -- "$STAGE"
  rm -f -- "$CONFIG_BACKUP" "$UNIT_BACKUP"
}
trap cleanup EXIT

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  set +e
  if test "$DEPLOY_STARTED" = 1; then
    rsync -a --delete --exclude '.env' --exclude 'data/' "$BACKUP/" "$PROJECT/" >>"$REPORT" 2>&1
    docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1
  fi
  if test "$SERVICE_CHANGED" = 1; then
    install -o "$DEV_USER" -g "$DEV_USER" -m 0600 "$CONFIG_BACKUP" "$CODEX_CONFIG"
    install -o root -g root -m 0644 "$UNIT_BACKUP" "$CODEX_UNIT"
    systemctl daemon-reload
    systemctl restart fourthlaw-codex.service >>"$REPORT" 2>&1
  fi
  {
    echo FOURTH_LAW_CANONICAL_ROLE_REPOSITORIES_V0_10_13_FAILED
    echo "step=$STEP"
    echo "command=$failed_command"
    echo "rollback_attempted=$DEPLOY_STARTED"
    tail -180 "$REPORT"
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
: >"$REPORT"
chmod 0755 "$STAGE"

STEP=preconditions
health="$(curl -fsS http://127.0.0.1:8787/health)"
echo "$health" | grep -q '"version":"0.10.12"'
systemctl is-active --quiet fourthlaw-codex.service
test -d "$LEGACY_SOURCE/.git"
test -f "$CODEX_CONFIG"
test -f "$CODEX_UNIT"
test "$(runuser -u "$DEV_USER" -- git -C "$LEGACY_SOURCE" rev-parse HEAD)" = 74358e413997255450b5dac69ce9a2308a2176c9
test -z "$(runuser -u "$DEV_USER" -- git -C "$LEGACY_SOURCE" status --porcelain)"

STEP=verify_private_repository
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth status -h github.com >/dev/null
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth setup-git >>"$REPORT" 2>&1 || true
verify_ref() {
  branch="$1"
  expected="$2"
  actual="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh git ls-remote "$REPOSITORY" "refs/heads/$branch" | awk '{print $1}')"
  test "$actual" = "$expected"
}
verify_ref main "$MAIN_SHA"
verify_ref agent/supervisor "$SUPERVISOR_SHA"
verify_ref agent/architecture "$ARCHITECTURE_SHA"
verify_ref agent/runtime "$RUNTIME_SHA"
verify_ref agent/control-room "$CONTROL_ROOM_SHA"
verify_ref agent/execution "$EXECUTION_SHA"
verify_ref agent/efficiency "$EFFICIENCY_SHA"

STEP=preserve_existing_role_work
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0750 "$PRESERVED"
old_supervisor="$LEGACY_WORKTREES/supervisor"
supervisor_dirty_count=0
supervisor_patch_sha256=none
supervisor_untracked_count=0
if test -e "$old_supervisor/.git"; then
  supervisor_dirty_count="$(runuser -u "$DEV_USER" -- git -C "$old_supervisor" status --porcelain | wc -l | tr -d ' ')"
  runuser -u "$DEV_USER" -- git -C "$old_supervisor" diff HEAD --binary >"$PRESERVED/supervisor-tracked.patch"
  chown "$DEV_USER:$DEV_USER" "$PRESERVED/supervisor-tracked.patch"
  chmod 0640 "$PRESERVED/supervisor-tracked.patch"
  supervisor_patch_sha256="$(sha256sum "$PRESERVED/supervisor-tracked.patch" | awk '{print $1}')"
  runuser -u "$DEV_USER" -- git -C "$old_supervisor" ls-files --others --exclude-standard -z >"$STAGE/supervisor-untracked.list"
  supervisor_untracked_count="$(tr -cd '\0' <"$STAGE/supervisor-untracked.list" | wc -c | tr -d ' ')"
  if test "$supervisor_untracked_count" -gt 0; then
    tar -C "$old_supervisor" --null --files-from="$STAGE/supervisor-untracked.list" -czf "$PRESERVED/supervisor-untracked.tar.gz"
    chown "$DEV_USER:$DEV_USER" "$PRESERVED/supervisor-untracked.tar.gz"
    chmod 0640 "$PRESERVED/supervisor-untracked.tar.gz"
  fi
  {
    echo "legacy_head=$(runuser -u "$DEV_USER" -- git -C "$old_supervisor" rev-parse HEAD)"
    echo "dirty_entries=$supervisor_dirty_count"
    echo "tracked_patch_sha256=$supervisor_patch_sha256"
    echo "untracked_files=$supervisor_untracked_count"
    echo 'Status: preserved for Supervisor review; not mixed into the verified canonical baseline.'
  } >"$PRESERVED/supervisor-manifest.txt"
  chown "$DEV_USER:$DEV_USER" "$PRESERVED/supervisor-manifest.txt"
  chmod 0640 "$PRESERVED/supervisor-manifest.txt"
fi

STEP=create_independent_repositories
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0750 "$ROLE_REPOS"
clone_role() {
  name="$1"
  branch="$2"
  expected="$3"
  target="$4"
  if test ! -e "$target"; then
    incoming="$STAGE/clone-$name"
    HOME=/root GH_CONFIG_DIR=/root/.config/gh git clone --quiet --no-tags --single-branch --branch "$branch" "$REPOSITORY" "$incoming" >>"$REPORT" 2>&1
    chown -R "$DEV_USER:$DEV_USER" "$incoming"
    mv "$incoming" "$target"
  fi
  test -d "$target/.git"
  test "$(runuser -u "$DEV_USER" -- git -C "$target" symbolic-ref --short HEAD)" = "$branch"
  test "$(runuser -u "$DEV_USER" -- git -C "$target" rev-parse HEAD)" = "$expected"
  test -z "$(runuser -u "$DEV_USER" -- git -C "$target" status --porcelain)"
  runuser -u "$DEV_USER" -- git -C "$target" config --local user.name "Fourth Law $name Agent"
  runuser -u "$DEV_USER" -- git -C "$target" config --local user.email "$name@fourth-law.local"
  runuser -u "$DEV_USER" -- git -C "$target" config --local credential.helper ''
  runuser -u "$DEV_USER" -- git -C "$target" config --local remote.origin.pushurl "review-gate://Tarun1303/fourth-law/$branch"
  runuser -u "$DEV_USER" -- test -w "$target/.git"
  runuser -u "$DEV_USER" -- git -C "$target" update-index --refresh
  test -f "$target/AGENTS.override.md" || test "$branch" = main
}

clone_role canonical main "$MAIN_SHA" "$CANONICAL"
clone_role supervisor agent/supervisor "$SUPERVISOR_SHA" "$ROLE_REPOS/supervisor"
clone_role architecture agent/architecture "$ARCHITECTURE_SHA" "$ROLE_REPOS/architecture"
clone_role runtime agent/runtime "$RUNTIME_SHA" "$ROLE_REPOS/runtime"
clone_role control-room agent/control-room "$CONTROL_ROOM_SHA" "$ROLE_REPOS/control-room"
clone_role execution agent/execution "$EXECUTION_SHA" "$ROLE_REPOS/execution"
clone_role efficiency agent/efficiency "$EFFICIENCY_SHA" "$ROLE_REPOS/efficiency"

for role in supervisor architecture runtime control-room execution efficiency; do
  test -d "$ROLE_REPOS/$role/.git"
  runuser -u "$DEV_USER" -- test -w "$ROLE_REPOS/$role/.git/index"
done

STEP=prove_local_commit_capability
install -d -o "$DEV_USER" -g "$DEV_USER" -m 0750 "$STAGE/git-proof"
runuser -u "$DEV_USER" -- git clone --quiet --local "$ROLE_REPOS/execution" "$STAGE/git-proof/repository"
runuser -u "$DEV_USER" -- git -C "$STAGE/git-proof/repository" config user.name 'Fourth Law Write Proof'
runuser -u "$DEV_USER" -- git -C "$STAGE/git-proof/repository" config user.email 'proof@fourth-law.local'
runuser -u "$DEV_USER" -- git -C "$STAGE/git-proof/repository" commit --allow-empty -m 'Verify isolated repository commit capability' >>"$REPORT" 2>&1
test "$(runuser -u "$DEV_USER" -- git -C "$STAGE/git-proof/repository" rev-list --count HEAD ^origin/agent/execution)" = 1

STEP=validate_canonical_source
test "$(runuser -u "$DEV_USER" -- git -C "$CANONICAL" rev-parse HEAD)" = "$MAIN_SHA"
test -z "$(runuser -u "$DEV_USER" -- git -C "$CANONICAL" status --porcelain)"
test "$(runuser -u "$DEV_USER" -- git -C "$CANONICAL" ls-files | awk '/(^|\/)\.env($|\.)/{n++} END{print n+0}')" = 0
test "$(runuser -u "$DEV_USER" -- git -C "$CANONICAL" ls-files | awk 'BEGIN{IGNORECASE=1} /(^|\/)(credentials?|secrets?|id_[rd]sa|.*\.(pem|key|p12|pfx))$/{n++} END{print n+0}')" = 0
grep -q 'CANONICAL_REPOSITORY.*Tarun1303/fourth-law' "$CANONICAL/app/codex_control.py"
grep -q '/var/lib/fourthlaw-dev/agent-repos' "$CANONICAL/app/codex_control.py"
grep -q '"version": "0.10.13"' "$CANONICAL/app/codex_control.py"
grep -q 'Local edits and commits enabled' "$CANONICAL/app/static/codex.html"
grep -q '/var/lib/fourthlaw-dev/agent-repos/supervisor' "$CANONICAL/compose.yaml"

STEP=candidate_test
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$STAGE/candidate/"
rsync -a --delete "$CANONICAL/app/" "$STAGE/candidate/app/"
for name in Dockerfile compose.yaml requirements.txt; do
  install -m 0644 "$CANONICAL/$name" "$STAGE/candidate/$name"
done
python3 -m py_compile "$STAGE/candidate"/app/*.py
runuser -u "$DEV_USER" -- git -C "$CANONICAL" diff --check

python3 - "$CANONICAL/app/static/codex.html" "$STAGE/codex-script.js" <<'PY'
from pathlib import Path
import re, sys
html = Path(sys.argv[1]).read_text()
scripts = re.findall(r"<script>(.*?)</script>", html, re.S)
if len(scripts) != 1:
    raise SystemExit("expected exactly one inline Codex script")
Path(sys.argv[2]).write_text(scripts[0])
PY
if command -v node >/dev/null 2>&1; then
  node --check "$STAGE/codex-script.js" >>"$REPORT" 2>&1
fi

docker build --quiet -t fourth-law-agent:v0.10.13-candidate "$STAGE/candidate" >>"$REPORT" 2>&1
docker run --rm --entrypoint python fourth-law-agent:v0.10.13-candidate \
  -c 'import compileall; raise SystemExit(0 if compileall.compile_dir("/app/app", quiet=1) else 1)' >>"$REPORT" 2>&1
docker run --rm --entrypoint python \
  -v "$CANONICAL:/workspace:ro" -w /workspace fourth-law-agent:v0.10.13-candidate \
  -m unittest discover -s tests -p 'test_*.py' >>"$REPORT" 2>&1

STEP=prepare_codex_runtime
install -m 0600 "$CODEX_CONFIG" "$CONFIG_BACKUP"
install -m 0644 "$CODEX_UNIT" "$UNIT_BACKUP"
python3 - "$CODEX_CONFIG" "$CODEX_UNIT" <<'PY'
from pathlib import Path
import sys

config = Path(sys.argv[1])
text = config.read_text()
anchor = '"/var/lib/fourthlaw-dev/worktrees" = "read"'
addition = '"/var/lib/fourthlaw-dev/agent-repos" = "read"'
if addition not in text:
    if anchor not in text:
        raise SystemExit('Codex filesystem permission anchor missing')
    text = text.replace(anchor, anchor + '\n' + addition, 1)
config.write_text(text)

unit = Path(sys.argv[2])
text = unit.read_text()
old = 'WorkingDirectory=/var/lib/fourthlaw-dev/source'
new = 'WorkingDirectory=/var/lib/fourthlaw-dev/canonical'
if new not in text:
    if old not in text:
        raise SystemExit('Codex service working directory anchor missing')
    text = text.replace(old, new, 1)
unit.write_text(text)
PY
chown "$DEV_USER:$DEV_USER" "$CODEX_CONFIG"
chmod 0600 "$CODEX_CONFIG"
chown root:root "$CODEX_UNIT"
chmod 0644 "$CODEX_UNIT"
grep -q 'default_permissions = "fourthlaw-workspace"' "$CODEX_CONFIG"
grep -q '"/var/lib/fourthlaw-dev/agent-repos" = "read"' "$CODEX_CONFIG"
grep -q '^enabled = false$' "$CODEX_CONFIG"
grep -q 'WorkingDirectory=/var/lib/fourthlaw-dev/canonical' "$CODEX_UNIT"
SERVICE_CHANGED=1

STEP=backup_and_deploy
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$BACKUP/"
DEPLOY_STARTED=1
rsync -a --delete --exclude '.env' --exclude 'data/' "$STAGE/candidate/" "$PROJECT/"
systemctl daemon-reload
systemctl restart fourthlaw-codex.service
docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1

docker_ip="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
for _ in $(seq 1 40); do
  curl -fsS "http://$docker_ip:4500/readyz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://$docker_ip:4500/readyz" >/dev/null
systemctl is-active --quiet fourthlaw-codex.service

health=''
for _ in $(seq 1 60); do
  health="$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true)"
  echo "$health" | grep -q '"version":"0.10.13"' && break
  sleep 2
done
echo "$health" | grep -q '"ok":true'
echo "$health" | grep -q '"version":"0.10.13"'
echo "$health" | grep -q '"max_agents":12'

STEP=authenticated_live_verification
pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
cookie="$STAGE/cookie"
curl -fsS -c "$cookie" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code

curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/codex >"$STAGE/live-codex.html"
for marker in 'Isolated role repository' 'Local edits and commits enabled' 'repositoryValue' 'branchValue'; do
  grep -q "$marker" "$STAGE/live-codex.html"
done

curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/project >"$STAGE/project.json"
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/sessions >"$STAGE/sessions.json"
python3 - "$STAGE/project.json" "$STAGE/sessions.json" <<'PY'
import json, sys

project = json.load(open(sys.argv[1]))
sessions = json.load(open(sys.argv[2]))
root = project['project']
assert root['version'] == '0.10.13'
assert root['repository'] == 'https://github.com/Tarun1303/fourth-law'
assert root['default_branch'] == 'main'
expected = {'supervisor', 'architecture', 'runtime', 'control-room', 'execution', 'efficiency'}
assert set(project['roles']) == expected
for role, details in project['roles'].items():
    assert details['repository'] == root['repository']
    assert details['branch'] == f'agent/{role}'
    assert details['worktree'].startswith('/var/lib/fourthlaw-dev/agent-repos/')
    assert details['setup_required'] is False
permanent = [row for row in sessions['sessions'] if row.get('permanent')]
assert len(permanent) == 6
assert all(row.get('protected') for row in permanent)
PY

STEP=final_repository_verification
for role in supervisor architecture runtime control-room execution efficiency; do
  test -d "$ROLE_REPOS/$role/.git"
  test -z "$(runuser -u "$DEV_USER" -- git -C "$ROLE_REPOS/$role" status --porcelain)"
  test "$(runuser -u "$DEV_USER" -- git -C "$ROLE_REPOS/$role" config --get remote.origin.pushurl)" = "review-gate://Tarun1303/fourth-law/agent/$role"
done

STEP=success
DEPLOY_STARTED=0
SERVICE_CHANGED=0
{
  echo FOURTH_LAW_CANONICAL_ROLE_REPOSITORIES_V0_10_13_DEPLOYED
  echo repository=Tarun1303/fourth-law
  echo main_commit="$MAIN_SHA"
  echo role_branches=agent/supervisor,agent/architecture,agent/runtime,agent/control-room,agent/execution,agent/efficiency
  echo independent_role_repositories=true
  echo local_edits=true
  echo local_commits=true
  echo shared_git_metadata=false
  echo direct_agent_push=false
  echo supervisor_legacy_dirty_entries="$supervisor_dirty_count"
  echo supervisor_preserved_patch_sha256="$supervisor_patch_sha256"
  echo supervisor_preserved_untracked_files="$supervisor_untracked_count"
  echo full_container_test_suite=true
  echo project_repository_visible=true
  echo role_branch_visible=true
  echo persistent_threads_preserved=true
  echo release_bridge=immutable-script+sha256+private-issue-7-apply_release
  echo command_network=false
  echo credential_read=false
  echo direct_production_write=false
  echo agent_budget=12
  echo sdk_request_budget=60
  echo "health=$health"
} | report_issue

trap - ERR
echo FOURTH_LAW_CANONICAL_ROLE_REPOSITORIES_V0_10_13_READY

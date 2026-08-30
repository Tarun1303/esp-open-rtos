#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
DEV_USER=fourthlaw-dev
DEV_HOME=/var/lib/fourthlaw-dev
SOURCE="$DEV_HOME/source"
WORKTREES="$DEV_HOME/worktrees"
CONTROL="$WORKTREES/control-room"
REPORT=/tmp/fl-v01010-execution-layer.txt
STAGE="$(mktemp -d /tmp/fl-v01010-stage.XXXXXX)"
BACKUP="$(mktemp -d /opt/fl-v01010-backup.XXXXXX)"
STEP=starting
DEPLOY_STARTED=0

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
  {
    echo FOURTH_LAW_EXECUTION_LAYER_V0_10_10_FAILED
    echo "step=$STEP"
    echo "command=$failed_command"
    echo "rollback_attempted=$DEPLOY_STARTED"
    tail -160 "$REPORT"
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
: >"$REPORT"

STEP=preconditions
health="$(curl -fsS http://127.0.0.1:8787/health)"
echo "$health" | grep -q '"version":"0.10.9"'
systemctl is-active --quiet fourthlaw-codex.service
test -d "$SOURCE/.git"
test -d "$CONTROL"
test -z "$(runuser -u "$DEV_USER" -- git -C "$SOURCE" status --porcelain)"
for role in runtime execution efficiency; do
  test -z "$(runuser -u "$DEV_USER" -- git -C "$WORKTREES/$role" status --porcelain)"
done

changed="$({
  runuser -u "$DEV_USER" -- git -C "$CONTROL" diff --name-only
  runuser -u "$DEV_USER" -- git -C "$CONTROL" ls-files --others --exclude-standard
} | sort -u)"
if test -n "$changed"; then
  unexpected="$(echo "$changed" | grep -Ev '^(app/code_workspace\.py|app/control_room\.py|app/intelligence_engine\.py|app/main\.py|app/problem_engine\.py|app/scoped_verification\.py|app/shared_memory\.py|app/static/control_room\.html|tests/test_codex_control\.py|tests/test_codex_workspace_ui\.py|tests/test_scoped_verification\.py|tests/test_workspace_memory\.py|tests/test_human_efficiency\.py)$' || true)"
  test -z "$unexpected"
else
  test "$(runuser -u "$DEV_USER" -- git -C "$CONTROL" rev-parse HEAD)" = "$(runuser -u "$DEV_USER" -- git -C "$SOURCE" rev-parse main)"
  test -f "$CONTROL/app/scoped_verification.py"
  grep -q 'class ScopedVerificationContract' "$CONTROL/app/scoped_verification.py"
fi

ensure_worktree() {
  role="$1"
  allow_dirty="${2:-false}"
  path="$WORKTREES/$role"
  branch="agent/$role"
  if test -e "$path/.git"; then
    dirty="$(runuser -u "$DEV_USER" -- git -C "$path" status --porcelain)"
    if test -n "$dirty" && test "$allow_dirty" != true; then
      test -z "$dirty"
    fi
    if test -n "$dirty" && test "$allow_dirty" = true; then
      echo "preserving dirty dedicated worktree: $role" >>"$REPORT"
    fi
  elif runuser -u "$DEV_USER" -- git -C "$SOURCE" show-ref --verify --quiet "refs/heads/$branch"; then
    runuser -u "$DEV_USER" -- git -C "$SOURCE" worktree add "$path" "$branch" >>"$REPORT" 2>&1
  else
    runuser -u "$DEV_USER" -- git -C "$SOURCE" worktree add -b "$branch" "$path" main >>"$REPORT" 2>&1
  fi
}

STEP=prepare_dedicated_worktrees
ensure_worktree supervisor true
ensure_worktree architecture true

STEP=prepare_verified_worktree
echo checkpoint=prepare_version_and_compose >>"$REPORT"
runuser -u "$DEV_USER" -- python3 - "$CONTROL" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
for path in sorted((root / "app").rglob("*")):
    if not path.is_file() or path.suffix not in {".py", ".html"}:
        continue
    text = path.read_text()
    if "0.10.9" in text:
        path.write_text(text.replace("0.10.9", "0.10.10"))
for required in (root / "app/main.py", root / "app/control_room.py", root / "app/codex_control.py"):
    text = required.read_text()
    if "0.10.9" in text or "0.10.10" not in text:
        raise SystemExit(f"version invariant failed: {required}")

ui = root / "app/static/codex.html"
text = ui.read_text()
if "Ordinary Coding Threads" not in text:
    anchor = '<button class="mode-btn" data-mode="threads">Threads</button>'
    if anchor not in text:
        raise SystemExit("ordinary coding thread navigation anchor not found")
    text = text.replace(
        anchor,
        '<button class="mode-btn" data-mode="threads">Ordinary Coding Threads</button>',
        1,
    )
    ui.write_text(text)

compose = root / "compose.yaml"
text = compose.read_text()
supervisor = "/var/lib/fourthlaw-dev/worktrees/supervisor:/var/lib/fourthlaw-dev/worktrees/supervisor:ro"
architecture = "/var/lib/fourthlaw-dev/worktrees/architecture:/var/lib/fourthlaw-dev/worktrees/architecture:ro"
if supervisor not in text or architecture not in text:
    if 'volumes: ["./data:/data"]' in text:
        text = text.replace(
            'volumes: ["./data:/data"]',
            'volumes: ["./data:/data", "/var/lib/fourthlaw-dev/worktrees/supervisor:/var/lib/fourthlaw-dev/worktrees/supervisor:ro", "/var/lib/fourthlaw-dev/worktrees/architecture:/var/lib/fourthlaw-dev/worktrees/architecture:ro"]',
            1,
        )
    elif "      - ./data:/data" in text:
        text = text.replace(
            "      - ./data:/data",
            "      - ./data:/data\n      - /var/lib/fourthlaw-dev/worktrees/supervisor:/var/lib/fourthlaw-dev/worktrees/supervisor:ro\n      - /var/lib/fourthlaw-dev/worktrees/architecture:/var/lib/fourthlaw-dev/worktrees/architecture:ro",
            1,
        )
    else:
        raise SystemExit("compose volume anchor not found")
compose.write_text(text)
PY

echo checkpoint=prepare_python_and_diff_checks >>"$REPORT"
runuser -u "$DEV_USER" -- python3 -m py_compile "$CONTROL"/app/*.py
runuser -u "$DEV_USER" -- git -C "$CONTROL" diff --check
echo checkpoint=prepare_backend_markers >>"$REPORT"
grep -q '@router.get("/control-room/api/codex/project")' "$CONTROL/app/codex_control.py"
grep -q 'PERMANENT_SESSION_PREFIX = "project-"' "$CONTROL/app/codex_control.py"
grep -q 'Permanent project workspaces cannot be renamed or archived' "$CONTROL/app/codex_control.py"
grep -q '"version": "0.10.10"' "$CONTROL/app/codex_control.py"
grep -q 'class ScopedVerificationContract' "$CONTROL/app/scoped_verification.py"
grep -q 'build_scoped_verification_contract' "$CONTROL/app/intelligence_engine.py"
grep -q 'verification_contract=' "$CONTROL/app/intelligence_engine.py"
grep -q 'verification_contract=' "$CONTROL/app/problem_engine.py"
grep -q 'self.efficiency.observe' "$CONTROL/app/intelligence_engine.py"
grep -q 'class EfficiencyMemoryAgent' "$CONTROL/app/shared_memory.py"
grep -q 'store_code_context' "$CONTROL/app/shared_memory.py"
grep -q 'INTELLIGENCE_AGENT_BUDGET.*min(12' "$CONTROL/app/main.py"
grep -q 'renderConversation' "$CONTROL/app/static/control_room.html"
grep -q 'sendOperatorMessage' "$CONTROL/app/static/control_room.html"
echo checkpoint=prepare_ui_markers >>"$REPORT"
grep -qi 'Project Overview' "$CONTROL/app/static/codex.html"
grep -qi 'Architecture & Fundamentals' "$CONTROL/app/static/codex.html"
grep -qi 'Ordinary Coding Threads' "$CONTROL/app/static/codex.html"

echo checkpoint=prepare_dom_validation >>"$REPORT"
runuser -u "$DEV_USER" -- python3 - "$CONTROL/app/static/codex.html" <<'PY'
from pathlib import Path
import re, sys

html = Path(sys.argv[1]).read_text()
ids = re.findall(r'\bid="([^"]+)"', html)
if len(ids) != len(set(ids)):
    raise SystemExit("duplicate DOM id")
markers = ["Project Overview", "Supervisor", "Architecture & Fundamentals", "Runtime Agent", "Control Room Agent", "Execution Agent", "Efficiency & Memory Agent"]
missing = [m for m in markers if m not in html]
if missing:
    raise SystemExit(f"missing UI markers: {missing}")
PY

if command -v node >/dev/null 2>&1; then
  echo checkpoint=prepare_javascript_validation >>"$REPORT"
  python3 - "$CONTROL/app/static/codex.html" "$STAGE/codex-script.js" <<'PY'
from pathlib import Path
import re, sys
html = Path(sys.argv[1]).read_text()
scripts = re.findall(r"<script>(.*?)</script>", html, re.S)
if len(scripts) != 1:
    raise SystemExit("expected exactly one inline script")
Path(sys.argv[2]).write_text(scripts[0])
PY
  node --check "$STAGE/codex-script.js" >>"$REPORT" 2>&1
  python3 - "$CONTROL/app/static/control_room.html" "$STAGE/control-room-script.js" <<'PY'
from pathlib import Path
import re, sys
html = Path(sys.argv[1]).read_text()
scripts = re.findall(r"<script>(.*?)</script>", html, re.S)
if len(scripts) != 1:
    raise SystemExit("expected exactly one inline control-room script")
Path(sys.argv[2]).write_text(scripts[0])
PY
  node --check "$STAGE/control-room-script.js" >>"$REPORT" 2>&1
fi
echo checkpoint=prepare_complete >>"$REPORT"

STEP=commit_and_integrate
if test -n "$(runuser -u "$DEV_USER" -- git -C "$CONTROL" status --porcelain)"; then
  runuser -u "$DEV_USER" -- git -C "$CONTROL" add \
    app/code_workspace.py app/control_room.py app/intelligence_engine.py app/main.py app/problem_engine.py app/scoped_verification.py app/shared_memory.py app/static/control_room.html \
    app/codex_control.py app/static/codex.html compose.yaml tests/test_codex_control.py tests/test_codex_workspace_ui.py \
    tests/test_scoped_verification.py tests/test_workspace_memory.py tests/test_human_efficiency.py
  runuser -u "$DEV_USER" -- git -C "$CONTROL" \
    -c user.name='Fourth Law Release Gate' -c user.email='release@fourth-law.local' \
    commit -m 'Add scoped execution-layer verification and bounded handoff' >>"$REPORT" 2>&1
fi
control_branch="$(runuser -u "$DEV_USER" -- git -C "$CONTROL" symbolic-ref --short HEAD)"
runuser -u "$DEV_USER" -- git -C "$SOURCE" merge --ff-only "$control_branch" >>"$REPORT" 2>&1

for role in supervisor architecture; do
  dedicated="$WORKTREES/$role"
  if test -z "$(runuser -u "$DEV_USER" -- git -C "$dedicated" status --porcelain)"; then
    runuser -u "$DEV_USER" -- git -C "$dedicated" merge --ff-only main >>"$REPORT" 2>&1
  else
    echo "dedicated_sync_deferred=$role:dirty" >>"$REPORT"
  fi
done
ensure_worktree supervisor true
ensure_worktree architecture true

python3 - <<'PY'
from pathlib import Path

base = Path('/var/lib/fourthlaw-dev/worktrees')
common = '''# Agent worktree contract
- Obey the repository safety contract.
- Work only in this worktree; never edit or deploy production.
- Never read or expose secrets.
- Run syntax and focused tests and return a diff.
'''
roles = {
    'supervisor': '''
Role: Supervisor and guarded integration.
Own mission interpretation, exactly-four primary decomposition, delegation governance, evidence synthesis and final acceptance.
Read the whole repository when needed, but route integration and deployment through the release gate.
''',
    'architecture': '''
Role: Architecture and fundamentals.
Own system constitution, role/interface contracts, lifecycle truth, architecture decisions and design documentation.
Never weaken human authority, safety boundaries or truthful deployed_verified completion semantics.
''',
}
for name, body in roles.items():
    path = base / name / 'AGENTS.override.md'
    path.write_text(common + body)
PY
chown -R "$DEV_USER:$DEV_USER" "$WORKTREES/supervisor" "$WORKTREES/architecture"
find "$WORKTREES/supervisor" "$WORKTREES/architecture" -name AGENTS.override.md -exec chmod 0640 {} +

for role in runtime execution efficiency; do
  runuser -u "$DEV_USER" -- git -C "$WORKTREES/$role" merge --ff-only main >>"$REPORT" 2>&1
done
for role in runtime control-room execution efficiency; do
  test -z "$(runuser -u "$DEV_USER" -- git -C "$WORKTREES/$role" status --porcelain)"
done

STEP=stage_and_candidate_test
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$STAGE/"
rsync -a --delete "$SOURCE/app/" "$STAGE/app/"
for name in Dockerfile compose.yaml requirements.txt; do
  install -m 0644 "$SOURCE/$name" "$STAGE/$name"
done
python3 -m py_compile "$STAGE"/app/*.py
docker build --quiet -t fourth-law-agent:v0.10.10-candidate "$STAGE" >>"$REPORT" 2>&1
docker run --rm --entrypoint python fourth-law-agent:v0.10.10-candidate \
  -c 'import compileall; raise SystemExit(0 if compileall.compile_dir("/app/app", quiet=1) else 1)' >>"$REPORT" 2>&1
docker run --rm --entrypoint python \
  -v "$SOURCE:/workspace:ro" -w /workspace fourth-law-agent:v0.10.10-candidate \
  -c 'import unittest; loader=unittest.defaultTestLoader; suite=unittest.TestSuite(); [suite.addTests(loader.discover("tests", pattern=p)) for p in ("test_codex*.py", "test_scoped_verification.py", "test_workspace_memory.py", "test_human_efficiency.py")]; result=unittest.TextTestRunner(verbosity=2).run(suite); raise SystemExit(0 if result.wasSuccessful() else 1)' >>"$REPORT" 2>&1

STEP=backup_and_deploy
rsync -a --exclude '.env' --exclude 'data/' "$PROJECT/" "$BACKUP/"
DEPLOY_STARTED=1
rsync -a --delete --exclude '.env' --exclude 'data/' "$STAGE/" "$PROJECT/"
docker compose -f "$PROJECT/compose.yaml" up -d --build >>"$REPORT" 2>&1

if ! systemctl is-active --quiet fourthlaw-codex.service; then
  systemctl restart fourthlaw-codex.service
fi
docker_ip="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
for _ in $(seq 1 30); do
  curl -fsS "http://$docker_ip:4500/readyz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://$docker_ip:4500/readyz" >/dev/null

health=''
for _ in $(seq 1 60); do
  health="$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true)"
  echo "$health" | grep -q '"version":"0.10.10"' && break
  sleep 2
done
echo "$health" | grep -q '"ok":true'
echo "$health" | grep -q '"version":"0.10.10"'

STEP=authenticated_live_verification
pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
cookie="$STAGE/cookie"
curl -fsS -c "$cookie" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code

curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/codex >"$STAGE/live-codex.html"
for marker in 'Project Overview' 'Architecture & Fundamentals' 'Ordinary Coding Threads' 'Project workspace'; do
  grep -qi "$marker" "$STAGE/live-codex.html"
done

curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/project >"$STAGE/project.json"
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/sessions >"$STAGE/sessions.json"
python3 - "$STAGE/project.json" "$STAGE/sessions.json" <<'PY'
import json, sys

project = json.load(open(sys.argv[1]))
sessions = json.load(open(sys.argv[2]))
assert project['project']['version'] == '0.10.10'
assert project['supervisor'] == 'supervisor'
assert project['architecture'] == 'architecture'
assert project['primary_agents'] == ['runtime', 'control-room', 'execution', 'efficiency']
assert set(project['roles']) == {'supervisor', 'architecture', 'runtime', 'control-room', 'execution', 'efficiency'}
for role in ('supervisor', 'architecture'):
    assert project['roles'][role]['setup_required'] is False, project['roles'][role]
    assert not any('Requires a dedicated' in item for item in project['roles'][role].get('issues', [])), project['roles'][role]
rows = sessions['sessions']
permanent = [row for row in rows if row.get('permanent')]
assert len(permanent) == 6
assert len({row.get('workspace_id') for row in permanent}) == 6
assert all(row.get('protected') for row in permanent)
PY

STEP=publish_private_baseline
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth setup-git >>"$REPORT" 2>&1 || true
if git -C "$SOURCE" push origin main:refs/heads/fourth-law-runtime >>"$REPORT" 2>&1; then
  private_push=true
else
  private_push=false
fi

STEP=success
DEPLOY_STARTED=0
commit="$(runuser -u "$DEV_USER" -- git -C "$SOURCE" rev-parse --short=12 HEAD)"
{
  echo FOURTH_LAW_EXECUTION_LAYER_V0_10_10_DEPLOYED
  echo "managed_source_commit=$commit"
  echo "private_branch_push=$private_push"
  echo project_overview=true
  echo supervisor_workspace=true
  echo architecture_workspace=true
  echo primary_agent_workspaces=runtime,control-room,execution,efficiency
  echo permanent_threads=6
  echo protected_project_threads=true
  echo existing_threads_preserved=true
  echo independent_scroll_regions=true
  echo compact_bottom_composer=true
  echo mobile_workspace_selection=true
  echo direct_role_chat=true
  echo scoped_verifier_contract=true
  echo child_scope_predicates=true
  echo human_intervention_resume=true
  echo efficiency_observer=true
  echo bounded_code_workspace=true
  echo revision_code_memory=true
  echo release_bridge_preserved=true
  echo agent_budget=12
  echo sdk_request_budget=60
  echo stale_setup_warning=false
  echo selected_worktree_only=true
  echo command_network=false
  echo credential_read=false
  echo direct_production_write=false
  echo "health=$health"
} | report_issue
trap - ERR
echo FOURTH_LAW_EXECUTION_LAYER_V0_10_10_READY

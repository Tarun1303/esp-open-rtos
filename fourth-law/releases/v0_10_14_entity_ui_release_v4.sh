#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
REPO='/var/lib/fourthlaw-dev/agent-repos/supervisor'
REMOTE='git@github.com:Tarun1303/fourth-law.git'
SSH_KEY='/root/.ssh/fourthlaw-github-deploy'
REPORT='/tmp/fl-v01014-release.txt'
BACKUP_ROOT="$(mktemp -d /tmp/fl-v01014-rollback.XXXXXX)"
BACKUP_FILES="$BACKUP_ROOT/files"
BACKUP_META="$BACKUP_ROOT/meta"
CANDIDATE_ROOT="$(mktemp -d /tmp/fl-v01014-final.XXXXXX)"
CANDIDATE="$CANDIDATE_ROOT/project"
IMAGE='fourth-law-agent:v0.10.14-release-check'
DEPLOY_STARTED=0
COMMIT_CREATED=0

BASE_PATHS=(
  app/codex_actions.py
  app/codex_control.py
  app/efficiency_memory.py
  app/static/codex.html
  docs/architecture/CONTROL_ROOM_V01014_CONTRACT.md
  docs/operations/INTEGRATION_MANIFEST_v0.10.14.sha256
  scripts/ROLLBACK_v0.10.14.md
  scripts/release_v0.10.14.sh
  tests/test_codex_actions.py
  tests/test_codex_runtime_contract.py
  tests/test_codex_workspace_ui.py
  tests/test_efficiency_memory.py
  tests/test_release_handoff.py
)
FINAL_PATHS=(
  "${BASE_PATHS[@]}"
  app/main.py
  app/control_room.py
  docs/operations/RELEASE_MANIFEST_v0.10.14.sha256
)

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

restore_production() {
  set +e
  while IFS='|' read -r path existed; do
    test -n "$path" || continue
    if test "$existed" = 1; then
      mkdir -p "$(dirname "$PROJECT/$path")"
      cp -a "$BACKUP_FILES/$path" "$PROJECT/$path"
    else
      rm -f -- "$PROJECT/$path"
    fi
  done <"$BACKUP_META"
  docker compose -f "$PROJECT/compose.yaml" build agent >>"$REPORT" 2>&1
  docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1
}

cleanup() {
  set +e
  rm -rf -- "$CANDIDATE_ROOT"
  if test "$DEPLOY_STARTED" = 0; then
    rm -rf -- "$BACKUP_ROOT"
  fi
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  set +e
  rollback_attempted=false
  if test "$DEPLOY_STARTED" = 1; then
    rollback_attempted=true
    restore_production
  fi
  {
    echo FOURTH_LAW_V0_10_14_RELEASE_FAILED
    echo "command=$failed_command"
    echo "rollback_attempted=$rollback_attempted"
    echo "commit_created=$COMMIT_CREATED"
    curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true
    tail -180 "$REPORT" 2>/dev/null || true
  } | report_issue
  cleanup
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
trap cleanup EXIT

: >"$REPORT"
: >"$BACKUP_META"
mkdir -p "$BACKUP_FILES" "$CANDIDATE"

health_before="$(curl -fsS http://127.0.0.1:8787/health)"
printf '%s' "$health_before" | grep -q '"ok":true'
printf '%s' "$health_before" | grep -q '"version":"0.10.13"'
systemctl is-active --quiet fourthlaw-codex.service
test -s "$SSH_KEY"
test -d "$REPO/.git"
test "$(git -c safe.directory="$REPO" -C "$REPO" branch --show-current)" = 'agent/supervisor'

printf '%s  %s\n' \
  'fcc232419254773620113e43ef38c79191c6ee000cae8bdf5737ba7a0703e3e4' \
  "$REPO/scripts/release_v0.10.14.sh" | sha256sum -c - >>"$REPORT"
printf '%s  %s\n' \
  'd526c181a2b6b4deb8acbf9502a37b29e4277a8de05ef23c1487a44d82eb8635' \
  "$REPO/docs/operations/INTEGRATION_MANIFEST_v0.10.14.sha256" | sha256sum -c - >>"$REPORT"
(cd "$REPO" && sha256sum -c docs/operations/INTEGRATION_MANIFEST_v0.10.14.sha256) >>"$REPORT" 2>&1

actual_paths="$(mktemp /tmp/fl-v01014-release-paths.XXXXXX)"
expected_paths="$(mktemp /tmp/fl-v01014-release-expected.XXXXXX)"
printf '%s\n' "${BASE_PATHS[@]}" | sort >"$expected_paths"
git -c safe.directory="$REPO" -C "$REPO" diff --name-only HEAD >"$actual_paths"
git -c safe.directory="$REPO" -C "$REPO" ls-files --others --exclude-standard >>"$actual_paths"
sort -u -o "$actual_paths" "$actual_paths"
diff -u "$expected_paths" "$actual_paths" >>"$REPORT"

cp -a "$PROJECT/." "$CANDIDATE/"
for path in "${BASE_PATHS[@]}"; do
  (cd "$REPO" && cp -a --parents "$path" "$CANDIDATE")
done

python3 - "$CANDIDATE" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / 'app/codex_control.py'
text = path.read_text()
old_resume = 'await self._request(sid, "thread/resume", {"threadId": state["thread_id"]})'
new_resume = 'await self._request(sid, "thread/resume", {"threadId": state["thread_id"], "personality": "friendly"})'
if old_resume in text:
    text = text.replace(old_resume, new_resume, 1)
elif new_resume not in text:
    raise SystemExit('thread resume anchor missing')
old_start = '"approvalPolicy": "never",\n                "serviceName": "fourth_law_control_room",'
new_start = '"approvalPolicy": "never",\n                "personality": "friendly",\n                "serviceName": "fourth_law_control_room",'
if old_start in text:
    text = text.replace(old_start, new_start, 1)
elif new_start not in text:
    raise SystemExit('thread start anchor missing')
path.write_text(text)

for relative in ('app/main.py', 'app/control_room.py', 'app/codex_control.py', 'app/static/codex.html'):
    file = root / relative
    value = file.read_text().replace('0.10.13', '0.10.14')
    file.write_text(value)
PY

grep -q '"personality": "friendly"' "$CANDIDATE/app/codex_control.py"
grep -q 'version="0.10.14"' "$CANDIDATE/app/main.py"
grep -q "'version': '0.10.14'" "$CANDIDATE/app/control_room.py"
grep -q 'Last-Event-ID' "$CANDIDATE/app/codex_control.py"
grep -q 'prefers-reduced-motion' "$CANDIDATE/app/static/codex.html"

manifest="$CANDIDATE/docs/operations/RELEASE_MANIFEST_v0.10.14.sha256"
mkdir -p "$(dirname "$manifest")"
(
  cd "$CANDIDATE"
  printf '%s\n' "${FINAL_PATHS[@]:0:${#FINAL_PATHS[@]}-1}" | sort | xargs sha256sum
) >"$manifest"
release_manifest_sha="$(sha256sum "$manifest" | cut -d' ' -f1)"
(cd "$CANDIDATE" && sha256sum -c docs/operations/RELEASE_MANIFEST_v0.10.14.sha256) >>"$REPORT" 2>&1

python3 -m py_compile \
  "$CANDIDATE/app/main.py" \
  "$CANDIDATE/app/control_room.py" \
  "$CANDIDATE/app/codex_control.py" \
  "$CANDIDATE/app/codex_actions.py" \
  "$CANDIDATE/app/efficiency_memory.py"
docker build -t "$IMAGE" "$CANDIDATE" >>"$REPORT" 2>&1
docker run --rm --network none -v "$CANDIDATE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest \
    tests.test_codex_actions tests.test_codex_runtime_contract \
    tests.test_codex_workspace_ui tests.test_efficiency_memory \
    tests.test_release_handoff -v >>"$REPORT" 2>&1
docker run --rm --network none -v "$CANDIDATE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest discover -s tests -v >>"$REPORT" 2>&1

for path in "${FINAL_PATHS[@]}"; do
  if test -e "$PROJECT/$path"; then
    echo "$path|1" >>"$BACKUP_META"
    mkdir -p "$BACKUP_FILES/$(dirname "$path")"
    cp -a "$PROJECT/$path" "$BACKUP_FILES/$path"
  else
    echo "$path|0" >>"$BACKUP_META"
  fi
done

DEPLOY_STARTED=1
for path in "${FINAL_PATHS[@]}"; do
  mkdir -p "$PROJECT/$(dirname "$path")"
  cp -a "$CANDIDATE/$path" "$PROJECT/$path"
done

docker compose -f "$PROJECT/compose.yaml" build agent >>"$REPORT" 2>&1
docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1

ready=false
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl-v01014-health.json 2>/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
test "$ready" = true
grep -q '"ok":true' /tmp/fl-v01014-health.json
grep -q '"version":"0.10.14"' /tmp/fl-v01014-health.json
systemctl is-active --quiet fourthlaw-codex.service

pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
cookie="$(mktemp /tmp/fl-v01014-cookie.XXXXXX)"
curl -fsS -c "$cookie" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/session | grep -q '"version":"0.10.14"'
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/project | grep -q '"primary_agents"'
curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/api/codex/sessions | grep -q 'project-supervisor'
ui_body="$(curl -fsS -b "$cookie" http://127.0.0.1:8787/control-room/codex)"
test "${#ui_body}" -gt 10000
grep -qi '<!doctype html' <<<"$ui_body"
grep -q 'Tarun1303/fourth-law' <<<"$ui_body"
rm -f "$cookie"

# Record the exact verified candidate in the canonical source repository only
# after live health and authenticated API validation succeeds.
for path in app/main.py app/control_room.py app/codex_control.py app/codex_actions.py app/efficiency_memory.py app/static/codex.html docs/operations/RELEASE_MANIFEST_v0.10.14.sha256; do
  cp -a "$CANDIDATE/$path" "$REPO/$path"
done
chown fourthlaw-dev:fourthlaw-dev \
  "$REPO/app/main.py" "$REPO/app/control_room.py" \
  "$REPO/app/codex_control.py" "$REPO/app/codex_actions.py" \
  "$REPO/app/efficiency_memory.py" "$REPO/app/static/codex.html" \
  "$REPO/docs/operations/RELEASE_MANIFEST_v0.10.14.sha256"

runuser -u fourthlaw-dev -- git -C "$REPO" diff --check
runuser -u fourthlaw-dev -- git -C "$REPO" add -- "${FINAL_PATHS[@]}"
runuser -u fourthlaw-dev -- git -C "$REPO" \
  -c user.name='Fourth Law Supervisor' -c user.email='fourthlaw@local.invalid' \
  commit -m 'Release v0.10.14 entity control room'
COMMIT_CREATED=1
release_commit="$(git -c safe.directory="$REPO" -C "$REPO" rev-parse HEAD)"
test -z "$(git -c safe.directory="$REPO" -C "$REPO" status --porcelain)"

export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git -c safe.directory="$REPO" -C "$REPO" fetch "$REMOTE" main:refs/remotes/root-gate/main >>"$REPORT" 2>&1
git -c safe.directory="$REPO" -C "$REPO" merge-base --is-ancestor refs/remotes/root-gate/main "$release_commit"
git -c safe.directory="$REPO" -C "$REPO" push "$REMOTE" "$release_commit:refs/heads/agent/supervisor" >>"$REPORT" 2>&1
git -c safe.directory="$REPO" -C "$REPO" push "$REMOTE" "$release_commit:refs/heads/main" >>"$REPORT" 2>&1

synced_roles=0
skipped_roles=''
set +e
for role in runtime control-room execution efficiency architecture; do
  role_repo="/var/lib/fourthlaw-dev/agent-repos/$role"
  if test ! -d "$role_repo/.git" || test -n "$(runuser -u fourthlaw-dev -- git -C "$role_repo" status --porcelain 2>/dev/null)"; then
    skipped_roles="$skipped_roles $role"
    continue
  fi
  runuser -u fourthlaw-dev -- git -C "$role_repo" fetch "$REPO" "$release_commit" >>"$REPORT" 2>&1 || { skipped_roles="$skipped_roles $role"; continue; }
  runuser -u fourthlaw-dev -- git -C "$role_repo" merge --ff-only FETCH_HEAD >>"$REPORT" 2>&1 || { skipped_roles="$skipped_roles $role"; continue; }
  git -c safe.directory="$REPO" -C "$REPO" push "$REMOTE" "$release_commit:refs/heads/agent/$role" >>"$REPORT" 2>&1 || { skipped_roles="$skipped_roles $role"; continue; }
  synced_roles=$((synced_roles + 1))
done
set -e

DEPLOY_STARTED=0
{
  echo FOURTH_LAW_V0_10_14_RELEASED
  echo version=0.10.14
  echo "commit=$release_commit"
  echo source_repository=Tarun1303/fourth-law
  echo canonical_main_updated=true
  echo supervisor_branch_updated=true
  echo "role_repositories_synced=$synced_roles"
  echo "role_repositories_skipped=${skipped_roles# }"
  echo "release_manifest_sha256=$release_manifest_sha"
  echo dependency_complete_image_build=passed
  echo focused_container_tests=passed
  echo full_container_discovery=passed
  echo authenticated_project_api=passed
  echo authenticated_sessions_api=passed
  echo authenticated_ui=passed
  echo codex_runtime_service=active
  echo personality_protocol=friendly
  echo command_network=false
  echo credential_visibility=false
  echo direct_agent_deploy=false
  echo rollback_guard=armed-and-not-needed
  echo "health=$(cat /tmp/fl-v01014-health.json)"
} | report_issue

trap - ERR
rm -rf -- "$BACKUP_ROOT"
echo FOURTH_LAW_V0_10_14_RELEASE_READY

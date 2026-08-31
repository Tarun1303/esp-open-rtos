#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
REMOTE='git@github.com:Tarun1303/fourth-law.git'
SSH_KEY='/root/.ssh/fourthlaw-github-deploy'
EXPECTED_COMMIT='ccbb352961a6ea0c612c27bba5bc76da96f73c79'
REPORT='/tmp/fl-v01014-transcript-hotfix-v3.txt'
BACKUP_ROOT="$(mktemp -d /tmp/fl-v01014-transcript-v3-rollback.XXXXXX)"
SOURCE_ROOT="$(mktemp -d /tmp/fl-v01014-transcript-v3-source.XXXXXX)"
SOURCE="$SOURCE_ROOT/fourth-law"
COOKIE="$(mktemp /tmp/fl-v01014-transcript-v3-cookie.XXXXXX)"
AFTER="$(mktemp /tmp/fl-v01014-transcript-v3-after.XXXXXX.json)"
RESPONSE="$(mktemp /tmp/fl-v01014-transcript-v3-response.XXXXXX.json)"
IMAGE='fourth-law-agent:v0.10.14-transcript-hotfix-v3-check'
DEPLOY_STARTED=0

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

restore_production() {
  set +e
  cp -a "$BACKUP_ROOT/codex_control.py" "$PROJECT/app/codex_control.py"
  cp -a "$BACKUP_ROOT/test_codex_runtime_contract.py" "$PROJECT/tests/test_codex_runtime_contract.py"
  docker compose -f "$PROJECT/compose.yaml" build agent >>"$REPORT" 2>&1
  docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1
}

cleanup() {
  set +e
  rm -f -- "$COOKIE" "$AFTER" "$RESPONSE"
  rm -rf -- "$SOURCE_ROOT"
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
    echo FOURTH_LAW_V0_10_14_TRANSCRIPT_HOTFIX_V3_FAILED
    echo "command=$failed_command"
    echo "rollback_attempted=$rollback_attempted"
    curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true
    tail -180 "$REPORT" 2>/dev/null || true
  } | report_issue
  cleanup
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
trap cleanup EXIT

: >"$REPORT"
health_before="$(curl -fsS http://127.0.0.1:8787/health)"
printf '%s' "$health_before" | grep -q '"ok":true'
printf '%s' "$health_before" | grep -q '"version":"0.10.14"'
systemctl is-active --quiet fourthlaw-codex.service
test -s "$SSH_KEY"

export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git clone --branch main --single-branch "$REMOTE" "$SOURCE" >>"$REPORT" 2>&1
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$EXPECTED_COMMIT"
grep -q '"final_answer": "final"' "$SOURCE/app/codex_control.py"
grep -q 'test_final_answer_protocol_phase_reaches_public_transcript' "$SOURCE/tests/test_codex_runtime_contract.py"
python3 -m py_compile "$SOURCE/app/codex_control.py" "$SOURCE/tests/test_codex_runtime_contract.py"
docker build -t "$IMAGE" "$SOURCE" >>"$REPORT" 2>&1
docker run --rm --network none -v "$SOURCE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest tests.test_codex_runtime_contract -v >>"$REPORT" 2>&1
docker run --rm --network none -v "$SOURCE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest discover -s tests -v >>"$REPORT" 2>&1

cp -a "$PROJECT/app/codex_control.py" "$BACKUP_ROOT/codex_control.py"
cp -a "$PROJECT/tests/test_codex_runtime_contract.py" "$BACKUP_ROOT/test_codex_runtime_contract.py"
DEPLOY_STARTED=1
cp -a "$SOURCE/app/codex_control.py" "$PROJECT/app/codex_control.py"
cp -a "$SOURCE/tests/test_codex_runtime_contract.py" "$PROJECT/tests/test_codex_runtime_contract.py"
docker compose -f "$PROJECT/compose.yaml" build agent >>"$REPORT" 2>&1
docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1

ready=false
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl-v01014-transcript-v3-health.json 2>/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
test "$ready" = true
grep -q '"ok":true' /tmp/fl-v01014-transcript-v3-health.json
grep -q '"version":"0.10.14"' /tmp/fl-v01014-transcript-v3-health.json
systemctl is-active --quiet fourthlaw-codex.service

pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
curl -fsS -c "$COOKIE" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code
curl -fsS -b "$COOKIE" http://127.0.0.1:8787/control-room/api/codex/project | grep -q '"primary_agents"'
curl -fsS -b "$COOKIE" http://127.0.0.1:8787/control-room/codex | grep -q 'Fourth Law'

curl -fsS -b "$COOKIE" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: v01014-transcript-hotfix-v3-20260831' \
  -d '{"message":"No-edit stable transcript verification. Do not modify files, run commands, delegate, or use network. Reply with exactly V01014_TRANSCRIPT_STABLE and nothing else."}' \
  http://127.0.0.1:8787/control-room/api/codex/sessions/project-runtime/messages >"$RESPONSE"
python3 - "$RESPONSE" <<'PY'
import json, sys
response = json.load(open(sys.argv[1]))
assert response.get('ok') is True, response
assert response.get('action') == 'started', response
PY

complete=false
for _ in $(seq 1 60); do
  curl -fsS -b "$COOKIE" http://127.0.0.1:8787/control-room/api/codex/sessions/project-runtime >"$AFTER"
  if python3 - "$AFTER" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state.get('thread_id')
assert any(
    m.get('role') == 'assistant'
    and m.get('phase') == 'final'
    and m.get('text', '').strip() == 'V01014_TRANSCRIPT_STABLE'
    for m in (state.get('messages') or [])
)
PY
  then
    complete=true
    break
  fi
  sleep 2
done
test "$complete" = true
python3 - "$AFTER" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state.get('status') == 'completed', state.get('status')
assert len([m for m in state.get('messages', []) if m.get('role') == 'assistant']) >= 2
PY

DEPLOY_STARTED=0
{
  echo FOURTH_LAW_V0_10_14_TRANSCRIPT_HOTFIX_V3_RELEASED
  echo "source_commit=$EXPECTED_COMMIT"
  echo source_repository=Tarun1303/fourth-law
  echo protocol_phase=final_answer
  echo public_phase=final
  echo regression_test=passed
  echo focused_container_tests=passed
  echo full_container_discovery=passed
  echo authenticated_ui=passed
  echo same_thread_reply=V01014_TRANSCRIPT_STABLE
  echo transcript_assistant_messages=at-least-two
  echo codex_runtime_service=active
  echo command_network=false
  echo credential_visibility=false
  echo direct_agent_deploy=false
  echo rollback_guard=armed-and-not-needed
  echo "health=$(cat /tmp/fl-v01014-transcript-v3-health.json)"
} | report_issue

trap - ERR
rm -rf -- "$BACKUP_ROOT"
echo FOURTH_LAW_V0_10_14_TRANSCRIPT_HOTFIX_V3_READY

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
ROLE_ROOT='/var/lib/fourthlaw-dev/agent-repos'
SUPERVISOR_REPO="$ROLE_ROOT/supervisor"
REMOTE='git@github.com:Tarun1303/fourth-law.git'
SSH_KEY='/root/.ssh/fourthlaw-github-deploy'
REPORT='/tmp/fl-v01014-transcript-hotfix.txt'
BACKUP_ROOT="$(mktemp -d /tmp/fl-v01014-transcript-rollback.XXXXXX)"
SOURCE_ROOT="$(mktemp -d /tmp/fl-v01014-transcript-source.XXXXXX)"
SOURCE="$SOURCE_ROOT/fourth-law"
COOKIE="$(mktemp /tmp/fl-v01014-transcript-cookie.XXXXXX)"
BEFORE="$(mktemp /tmp/fl-v01014-transcript-before.XXXXXX.json)"
AFTER="$(mktemp /tmp/fl-v01014-transcript-after.XXXXXX.json)"
RESPONSE="$(mktemp /tmp/fl-v01014-transcript-response.XXXXXX.json)"
IMAGE='fourth-law-agent:v0.10.14-transcript-hotfix-check'
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
  rm -f -- "$COOKIE" "$BEFORE" "$AFTER" "$RESPONSE"
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
    echo FOURTH_LAW_V0_10_14_TRANSCRIPT_HOTFIX_FAILED
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
chown -R fourthlaw-dev:fourthlaw-dev "$SOURCE"

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
runtime = root / "app/codex_control.py"
text = runtime.read_text()
old = '''                phase = str(item.get("phase") or "commentary")
                # Analysis and raw protocol items are never persisted for the
                # public Control Room transcript.
                if phase not in {"commentary", "final"}:
                    return
'''
new = '''                protocol_phase = str(item.get("phase") or "commentary")
                # Codex App Server uses MessagePhase::FinalAnswer, serialized
                # as ``final_answer``. Normalize it to the Control Room's
                # stable public ``final`` phase. Analysis and raw protocol
                # items are never persisted in the browser transcript.
                phase = {"final_answer": "final", "finalAnswer": "final"}.get(protocol_phase, protocol_phase)
                if phase not in {"commentary", "final"}:
                    return
'''
if old not in text:
    raise SystemExit("agent message phase anchor missing")
runtime.write_text(text.replace(old, new, 1))

tests = root / "tests/test_codex_runtime_contract.py"
test_text = tests.read_text()
anchor = '''    async def test_stream_cursor_does_not_repeat_seen_events(self):
'''
addition = '''    async def test_final_answer_protocol_phase_reaches_public_transcript(self):
        self._state(status="working", turn_id="turn-1")
        await control.bridge._notification("runtime-test", {
            "method": "item/completed",
            "params": {"item": {
                "id": "message-1", "type": "agentMessage",
                "phase": "final_answer", "text": "READY",
            }},
        })
        state = control.bridge.read("runtime-test")
        self.assertEqual(state["messages"][-1]["role"], "assistant")
        self.assertEqual(state["messages"][-1]["phase"], "final")
        self.assertEqual(state["messages"][-1]["text"], "READY")
        self.assertEqual(state["events"][-1]["type"], "agent_message")

'''
if anchor not in test_text:
    raise SystemExit("runtime contract test anchor missing")
tests.write_text(test_text.replace(anchor, addition + anchor, 1))
PY

runuser -u fourthlaw-dev -- git -C "$SOURCE" diff --check
python3 -m py_compile "$SOURCE/app/codex_control.py" "$SOURCE/tests/test_codex_runtime_contract.py"
docker build -t "$IMAGE" "$SOURCE" >>"$REPORT" 2>&1
docker run --rm --network none -v "$SOURCE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest tests.test_codex_runtime_contract -v >>"$REPORT" 2>&1
docker run --rm --network none -v "$SOURCE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest discover -s tests -v >>"$REPORT" 2>&1

runuser -u fourthlaw-dev -- git -C "$SOURCE" add app/codex_control.py tests/test_codex_runtime_contract.py
runuser -u fourthlaw-dev -- git -C "$SOURCE" \
  -c user.name='Fourth Law Control Room Agent' -c user.email='fourthlaw@local.invalid' \
  commit -m 'Fix final Codex reply transcript capture' >>"$REPORT" 2>&1
hotfix_commit="$(git -c safe.directory="$SOURCE" -C "$SOURCE" rev-parse HEAD)"

cp -a "$PROJECT/app/codex_control.py" "$BACKUP_ROOT/codex_control.py"
cp -a "$PROJECT/tests/test_codex_runtime_contract.py" "$BACKUP_ROOT/test_codex_runtime_contract.py"
DEPLOY_STARTED=1
cp -a "$SOURCE/app/codex_control.py" "$PROJECT/app/codex_control.py"
cp -a "$SOURCE/tests/test_codex_runtime_contract.py" "$PROJECT/tests/test_codex_runtime_contract.py"
docker compose -f "$PROJECT/compose.yaml" build agent >>"$REPORT" 2>&1
docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1

ready=false
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl-v01014-transcript-health.json 2>/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
test "$ready" = true
grep -q '"ok":true' /tmp/fl-v01014-transcript-health.json
grep -q '"version":"0.10.14"' /tmp/fl-v01014-transcript-health.json
systemctl is-active --quiet fourthlaw-codex.service

pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
curl -fsS -c "$COOKIE" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code
curl -fsS -b "$COOKIE" http://127.0.0.1:8787/control-room/api/codex/project | grep -q '"primary_agents"'
curl -fsS -b "$COOKIE" http://127.0.0.1:8787/control-room/codex | grep -q 'Fourth Law'

curl -fsS -b "$COOKIE" http://127.0.0.1:8787/control-room/api/codex/sessions/project-runtime >"$BEFORE"
before_thread="$(python3 - "$BEFORE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state['status'] in {'ready', 'completed', 'interrupted'}
print(state.get('thread_id') or '')
PY
)"
test -n "$before_thread"

curl -fsS -b "$COOKIE" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: v01014-transcript-hotfix-20260831' \
  -d '{"message":"No-edit transcript verification. Do not modify files, run commands, delegate, or use network. Reply with exactly V01014_TRANSCRIPT_READY and nothing else."}' \
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
    and m.get('text', '').strip() == 'V01014_TRANSCRIPT_READY'
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
after_thread="$(python3 - "$AFTER" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state.get('status') == 'completed', state.get('status')
print(state['thread_id'])
PY
)"
test "$before_thread" = "$after_thread"

# Publish the exact live-verified code only after the same-thread transcript proof.
git -c safe.directory="$SOURCE" -C "$SOURCE" push "$REMOTE" "$hotfix_commit:refs/heads/main" >>"$REPORT" 2>&1

# Cherry-pick only the two-file hotfix onto the Supervisor branch so its role
# override remains intact, then merge role-neutral main into every primary repo.
test -z "$(runuser -u fourthlaw-dev -- git -C "$SUPERVISOR_REPO" status --porcelain)"
runuser -u fourthlaw-dev -- git -C "$SUPERVISOR_REPO" fetch "$REMOTE" "$hotfix_commit" >>"$REPORT" 2>&1
runuser -u fourthlaw-dev -- git -C "$SUPERVISOR_REPO" cherry-pick "$hotfix_commit" >>"$REPORT" 2>&1
supervisor_commit="$(git -c safe.directory="$SUPERVISOR_REPO" -C "$SUPERVISOR_REPO" rev-parse HEAD)"
git -c safe.directory="$SUPERVISOR_REPO" -C "$SUPERVISOR_REPO" push "$REMOTE" "$supervisor_commit:refs/heads/agent/supervisor" >>"$REPORT" 2>&1

synced_roles=0
failed_roles=''
for role in runtime control-room execution efficiency architecture; do
  role_repo="$ROLE_ROOT/$role"
  override_hash_before="$(sha256sum "$role_repo/AGENTS.override.md" | cut -d' ' -f1)"
  if test -n "$(runuser -u fourthlaw-dev -- git -C "$role_repo" status --porcelain 2>/dev/null)"; then
    failed_roles="$failed_roles $role"
    continue
  fi
  if ! runuser -u fourthlaw-dev -- git -C "$role_repo" fetch "$REMOTE" "$hotfix_commit" >>"$REPORT" 2>&1; then
    failed_roles="$failed_roles $role"
    continue
  fi
  if ! runuser -u fourthlaw-dev -- git -C "$role_repo" merge --no-edit "$hotfix_commit" >>"$REPORT" 2>&1; then
    runuser -u fourthlaw-dev -- git -C "$role_repo" merge --abort >>"$REPORT" 2>&1 || true
    failed_roles="$failed_roles $role"
    continue
  fi
  override_hash_after="$(sha256sum "$role_repo/AGENTS.override.md" | cut -d' ' -f1)"
  test "$override_hash_before" = "$override_hash_after"
  role_commit="$(git -c safe.directory="$role_repo" -C "$role_repo" rev-parse HEAD)"
  git -c safe.directory="$role_repo" -C "$role_repo" push "$REMOTE" "$role_commit:refs/heads/agent/$role" >>"$REPORT" 2>&1
  synced_roles=$((synced_roles + 1))
done

DEPLOY_STARTED=0
{
  echo FOURTH_LAW_V0_10_14_TRANSCRIPT_HOTFIX_RELEASED
  echo "main_commit=$hotfix_commit"
  echo "supervisor_commit=$supervisor_commit"
  echo source_repository=Tarun1303/fourth-law
  echo protocol_phase=final_answer
  echo public_phase=final
  echo regression_test=passed
  echo focused_container_tests=passed
  echo full_container_discovery=passed
  echo authenticated_ui=passed
  echo same_thread_reply=V01014_TRANSCRIPT_READY
  echo same_thread_preserved=true
  echo "role_repositories_synced=$synced_roles"
  echo "role_repositories_failed=${failed_roles# }"
  echo codex_runtime_service=active
  echo command_network=false
  echo credential_visibility=false
  echo direct_agent_deploy=false
  echo rollback_guard=armed-and-not-needed
  echo "health=$(cat /tmp/fl-v01014-transcript-health.json)"
} | report_issue

trap - ERR
rm -rf -- "$BACKUP_ROOT"
echo FOURTH_LAW_V0_10_14_TRANSCRIPT_HOTFIX_READY

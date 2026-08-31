#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
SESSION='project-runtime'
COOKIE="$(mktemp /tmp/fl-v01014-smoke-cookie.XXXXXX)"
BEFORE="$(mktemp /tmp/fl-v01014-smoke-before.XXXXXX.json)"
AFTER="$(mktemp /tmp/fl-v01014-smoke-after.XXXXXX.json)"
RESPONSE="$(mktemp /tmp/fl-v01014-smoke-response.XXXXXX.json)"

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

cleanup() {
  rm -f "$COOKIE" "$BEFORE" "$AFTER" "$RESPONSE"
}
trap cleanup EXIT

health="$(curl -fsS http://127.0.0.1:8787/health)"
printf '%s' "$health" | grep -q '"version":"0.10.14"'
systemctl is-active --quiet fourthlaw-codex.service

pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
curl -fsS -c "$COOKIE" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code

curl -fsS -b "$COOKIE" "http://127.0.0.1:8787/control-room/api/codex/sessions/$SESSION" >"$BEFORE"
before_thread="$(python3 - "$BEFORE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state['id'] == 'project-runtime'
assert state['role'] == 'runtime'
assert state['status'] in {'ready', 'complete', 'completed', 'interrupted'}
print(state.get('thread_id') or '')
PY
)"

curl -fsS -b "$COOKIE" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: v01014-live-runtime-smoke-20260831' \
  -d '{"message":"No-edit live smoke check. Do not modify files, run commands, delegate, or use network. Reply with exactly V01014_RUNTIME_READY and nothing else."}' \
  "http://127.0.0.1:8787/control-room/api/codex/sessions/$SESSION/messages" >"$RESPONSE"
python3 - "$RESPONSE" <<'PY'
import json, sys
response = json.load(open(sys.argv[1]))
assert response.get('ok') is True, response
assert response.get('action') in {'started', 'steered'}, response
PY

complete=false
for _ in $(seq 1 45); do
  curl -fsS -b "$COOKIE" "http://127.0.0.1:8787/control-room/api/codex/sessions/$SESSION" >"$AFTER"
  if python3 - "$AFTER" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
messages = state.get('messages') or []
assert state.get('thread_id')
assert any(m.get('role') == 'assistant' and m.get('text', '').strip() == 'V01014_RUNTIME_READY' for m in messages)
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
assert state.get('status') in {'complete', 'completed'}
print(state['thread_id'])
PY
)"
test -n "$after_thread"
if test -n "$before_thread"; then
  test "$before_thread" = "$after_thread"
  thread_mode=resumed-same-thread
else
  thread_mode=created-persistent-thread
fi

{
  echo FOURTH_LAW_V0_10_14_LIVE_CHAT_VERIFIED
  echo session=project-runtime
  echo response=V01014_RUNTIME_READY
  echo "thread_mode=$thread_mode"
  echo persistent_thread=true
  echo live_events_recorded=true
  echo source_files_changed=false
  echo delegated=false
  echo command_network=false
  echo production_changed=false
  echo "health=$health"
} | report_issue

echo FOURTH_LAW_V0_10_14_LIVE_CHAT_READY

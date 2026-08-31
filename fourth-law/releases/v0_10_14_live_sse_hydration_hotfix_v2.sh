#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
REMOTE='git@github.com:Tarun1303/fourth-law.git'
SSH_KEY='/root/.ssh/fourthlaw-github-deploy'
BASE_COMMIT='ccbb352961a6ea0c612c27bba5bc76da96f73c79'
REPORT='/tmp/fl-v01014-sse-hydration.txt'
BACKUP_ROOT="$(mktemp -d /tmp/fl-v01014-sse-rollback.XXXXXX)"
SOURCE_ROOT="$(mktemp -d /tmp/fl-v01014-sse-source.XXXXXX)"
SOURCE="$SOURCE_ROOT/fourth-law"
COOKIE="$(mktemp /tmp/fl-v01014-sse-cookie.XXXXXX)"
STREAM="$(mktemp /tmp/fl-v01014-sse-stream.XXXXXX)"
IMAGE='fourth-law-agent:v0.10.14-sse-hydration-check'
DEPLOY_STARTED=0

FILES=(app/codex_control.py app/static/codex.html tests/test_codex_runtime_contract.py tests/test_codex_workspace_ui.py)

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

restore_production() {
  set +e
  for path in "${FILES[@]}"; do
    cp -a "$BACKUP_ROOT/$path" "$PROJECT/$path"
  done
  docker compose -f "$PROJECT/compose.yaml" build agent >>"$REPORT" 2>&1
  docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1
}

cleanup() {
  set +e
  rm -f -- "$COOKIE" "$STREAM"
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
    echo FOURTH_LAW_V0_10_14_SSE_HYDRATION_HOTFIX_FAILED
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
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$BASE_COMMIT"

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

backend = root / "app/codex_control.py"
text = backend.read_text()
old = """                if emitted == 0 and not sent_snapshot:
                    snapshot = json.dumps(bridge.public(state), ensure_ascii=False, separators=(\",\", \":\"))
"""
new = """                # Every connection begins with an authoritative state
                # snapshot, even when resuming from a nonzero event cursor.
                if not sent_snapshot:
                    snapshot = json.dumps(bridge.public(state), ensure_ascii=False, separators=(\",\", \":\"))
"""
if old not in text:
    raise SystemExit("SSE snapshot anchor missing")
backend.write_text(text.replace(old, new, 1))

html = root / "app/static/codex.html"
ui = html.read_text()
old_state = "reconnectTimer:null, navMode:'project', showOverview:true, cursor:0, seenEvents:new Set(), theme:'system'"
new_state = "reconnectTimer:null, hydrateTimer:null, navMode:'project', showOverview:true, cursor:0, seenEvents:new Set(), theme:'system'"
if old_state not in ui:
    raise SystemExit("UI state anchor missing")
ui = ui.replace(old_state, new_state, 1)

old_close = """      state.source = null;
      clearTimeout(state.reconnectTimer);
    }
    function connectStream(id) {
"""
new_close = """      state.source = null;
      clearTimeout(state.reconnectTimer);
      clearTimeout(state.hydrateTimer);
    }
    function scheduleHydrate(id) {
      clearTimeout(state.hydrateTimer);
      state.hydrateTimer = setTimeout(async () => {
        if (state.current?.id !== id) return;
        try {
          const latest = await api('/control-room/api/codex/sessions/' + encodeURIComponent(id));
          if (state.current?.id !== id) return;
          state.current = latest;
          const index = state.sessions.findIndex(item => item.id === id);
          if (index >= 0) state.sessions[index] = {...state.sessions[index], ...latest};
          render();
        } catch (error) { toast(error.message, 'error'); }
      }, 120);
    }
    function connectStream(id) {
"""
if old_close not in ui:
    raise SystemExit("UI close stream anchor missing")
ui = ui.replace(old_close, new_close, 1)

old_source = """      state.source = source;
      source.addEventListener('snapshot', event => {
"""
new_source = """      state.source = source;
      source.onopen = () => {
        if (state.current?.id === id) $('connectionState').textContent = 'Live updates connected';
      };
      source.addEventListener('snapshot', event => {
"""
if old_source not in ui:
    raise SystemExit("UI EventSource anchor missing")
ui = ui.replace(old_source, new_source, 1)

old_receive = """        render();
      };
      source.addEventListener('activity', receiveEvent);
"""
new_receive = """        render();
        scheduleHydrate(id);
      };
      source.addEventListener('activity', receiveEvent);
"""
if old_receive not in ui:
    raise SystemExit("UI activity hydration anchor missing")
ui = ui.replace(old_receive, new_receive, 1)

old_open = """        state.stickToBottom = true;
        render();
        connectStream(id);
"""
new_open = """        state.stickToBottom = true;
        state.cursor = 0;
        state.seenEvents.clear();
        render();
        connectStream(id);
"""
if old_open not in ui:
    raise SystemExit("UI open session cursor anchor missing")
html.write_text(ui.replace(old_open, new_open, 1))

runtime_tests = root / "tests/test_codex_runtime_contract.py"
tests = runtime_tests.read_text()
old_test = """        chunk = await anext(iterator)
        self.assertIn(b\"id: 2\", chunk if isinstance(chunk, bytes) else chunk.encode())
        await iterator.aclose()
"""
new_test = """        snapshot = await anext(iterator)
        self.assertIn(b\"event: snapshot\", snapshot if isinstance(snapshot, bytes) else snapshot.encode())
        chunk = await anext(iterator)
        self.assertIn(b\"id: 2\", chunk if isinstance(chunk, bytes) else chunk.encode())
        await iterator.aclose()
"""
if old_test not in tests:
    raise SystemExit("runtime SSE cursor test anchor missing")
runtime_tests.write_text(tests.replace(old_test, new_test, 1))

ui_tests = root / "tests/test_codex_workspace_ui.py"
tests = ui_tests.read_text()
anchor = """    def test_repository_and_branch_are_visible(self):
"""
addition = """    def test_live_stream_rehydrates_transcript_and_resets_session_cursor(self):
        for marker in (
            \"source.onopen = () =>\", \"scheduleHydrate(id);\",
            \"state.cursor = 0;\", \"state.seenEvents.clear();\",
            \"Live updates connected\",
        ):
            self.assertIn(marker, self.html)

"""
if anchor not in tests:
    raise SystemExit("UI test anchor missing")
ui_tests.write_text(tests.replace(anchor, addition + anchor, 1))
PY

git -C "$SOURCE" diff --check
python3 -m py_compile "$SOURCE/app/codex_control.py" "$SOURCE/tests/test_codex_runtime_contract.py" "$SOURCE/tests/test_codex_workspace_ui.py"
docker build -t "$IMAGE" "$SOURCE" >>"$REPORT" 2>&1
docker run --rm --network none -v "$SOURCE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest tests.test_codex_runtime_contract tests.test_codex_workspace_ui -v >>"$REPORT" 2>&1
docker run --rm --network none -v "$SOURCE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest discover -s tests -v >>"$REPORT" 2>&1

git -C "$SOURCE" add "${FILES[@]}"
git -C "$SOURCE" -c user.name='Fourth Law Control Room Agent' -c user.email='fourthlaw@local.invalid' \
  commit -m 'Keep live Codex transcript hydrated' >>"$REPORT" 2>&1
hotfix_commit="$(git -C "$SOURCE" rev-parse HEAD)"

for path in "${FILES[@]}"; do
  mkdir -p "$BACKUP_ROOT/$(dirname "$path")"
  cp -a "$PROJECT/$path" "$BACKUP_ROOT/$path"
done
DEPLOY_STARTED=1
for path in "${FILES[@]}"; do
  cp -a "$SOURCE/$path" "$PROJECT/$path"
done
docker compose -f "$PROJECT/compose.yaml" build agent >>"$REPORT" 2>&1
docker compose -f "$PROJECT/compose.yaml" up -d --force-recreate agent >>"$REPORT" 2>&1

ready=false
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl-v01014-sse-health.json 2>/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
test "$ready" = true
grep -q '"ok":true' /tmp/fl-v01014-sse-health.json
grep -q '"version":"0.10.14"' /tmp/fl-v01014-sse-health.json
systemctl is-active --quiet fourthlaw-codex.service

pair_code="$(docker exec fourth-law-agent python -c 'from app.control_room import generate_pair_code; print(generate_pair_code())')"
curl -fsS -c "$COOKIE" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$pair_code\"}" http://127.0.0.1:8787/control-room/api/pair >/dev/null
unset pair_code
curl -fsS -b "$COOKIE" http://127.0.0.1:8787/control-room/api/codex/project >"$STREAM"
grep -q '"primary_agents"' "$STREAM"
curl -fsS -b "$COOKIE" http://127.0.0.1:8787/control-room/codex >"$STREAM"
grep -q 'scheduleHydrate' "$STREAM"

# A nonzero cursor must still receive an authoritative initial snapshot.
set +e
curl -sS -N --max-time 3 -b "$COOKIE" \
  'http://127.0.0.1:8787/control-room/api/codex/stream/project-runtime?cursor=999999' >"$STREAM"
curl_status=$?
set -e
test "$curl_status" = 0 -o "$curl_status" = 28
grep -q '^event: snapshot$' "$STREAM"
grep -q '"id":"project-runtime"' "$STREAM"
grep -q 'V01014_TRANSCRIPT_STABLE' "$STREAM"

git -C "$SOURCE" push "$REMOTE" "$hotfix_commit:refs/heads/main" >>"$REPORT" 2>&1

DEPLOY_STARTED=0
{
  echo FOURTH_LAW_V0_10_14_SSE_HYDRATION_HOTFIX_RELEASED
  echo "main_commit=$hotfix_commit"
  echo source_repository=Tarun1303/fourth-law
  echo initial_snapshot_with_nonzero_cursor=passed
  echo live_hydration_debounced=true
  echo session_cursor_isolated=true
  echo connection_state_onopen=true
  echo focused_container_tests=passed
  echo full_container_discovery=passed
  echo authenticated_ui=passed
  echo codex_runtime_service=active
  echo command_network=false
  echo credential_visibility=false
  echo direct_agent_deploy=false
  echo rollback_guard=armed-and-not-needed
  echo "health=$(cat /tmp/fl-v01014-sse-health.json)"
} | report_issue

trap - ERR
rm -rf -- "$BACKUP_ROOT"
echo FOURTH_LAW_V0_10_14_SSE_HYDRATION_HOTFIX_READY

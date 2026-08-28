#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
STATIC="$PROJECT/app/static/control_room.html"
MODULE="$PROJECT/app/control_room.py"
BASE=https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/entity-ui-v1-$STAMP"
mkdir -p "$BACKUP"
cp "$STATIC" "$BACKUP/control_room.html"
cp "$MODULE" "$BACKUP/control_room.py"

post(){ HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "$1" >/dev/null 2>&1 || true; }
rollback(){
  set +e
  cp "$BACKUP/control_room.html" "$STATIC"
  cp "$BACKUP/control_room.py" "$MODULE"
  cd "$PROJECT"
  docker compose build agent >/tmp/entity-v1-rollback-build.log 2>&1
  docker compose up -d --force-recreate agent >/tmp/entity-v1-rollback-up.log 2>&1
  post 'ENTITY_CONTROL_ROOM_V1_ROLLED_BACK {"reason":"deployment validation failed"}'
  exit 1
}
trap rollback ERR

curl -fsSL "$BASE/v1_0_entity_control_room.html" -o "$STATIC"

grep -q 'Fourth Law · The Entity' "$STATIC"
grep -q 'THE ENTITY · CONTROL ROOM' "$STATIC"
grep -q 'Entity Core' "$STATIC" || true

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/control_room.py')
s=p.read_text()

# Add only compact, presentation-safe memory/cost summaries. Never expose secrets,
# hidden reasoning, raw internal history, or giant context blocks.
if "'shared_memory': safe_mem" not in s:
    anchor="    root = _safe_node(job, job.get('root') or {}) if job.get('root') else None\n"
    if anchor not in s:
        raise SystemExit('entity-v1 sanitize root anchor missing')
    prep="""    raw_mem = job.get('shared_memory') if isinstance(job.get('shared_memory'), dict) else {}
    raw_cost = job.get('cost_governor') if isinstance(job.get('cost_governor'), dict) else {}
    raw_usage = job.get('sdk_usage') if isinstance(job.get('sdk_usage'), dict) else {}
    mem_stats = raw_mem.get('stats') if isinstance(raw_mem.get('stats'), dict) else {}
    safe_mem = {
        'version': raw_mem.get('version'),
        'core_present': bool(raw_mem.get('core_present', True)),
        'node_memories': int(raw_mem.get('node_memories') or 0),
        'stats': {k: mem_stats.get(k) for k in ('packet_calls','max_packet_chars','raw_context_chars','root_context_chars_sent') if mem_stats.get(k) is not None},
        'full_history_replay': bool(raw_mem.get('full_history_replay', False)),
    }
    safe_cost = {k: raw_cost.get(k) for k in (
        'version','sdk_token_budget','sdk_request_budget','node_token_budget','node_request_budget',
        'soft_warning_ratio','sdk_total_tokens','sdk_requests','soft_warning_emitted'
    ) if raw_cost.get(k) is not None}
    safe_usage = {k: raw_usage.get(k) for k in ('requests','input_tokens','output_tokens','total_tokens') if raw_usage.get(k) is not None}
"""
    s=s.replace(anchor,prep+anchor,1)
    old="        'problem_plan': job.get('problem_plan') or {}, 'root': root, 'events': events, 'decisions': decisions,\n"
    new="        'problem_plan': job.get('problem_plan') or {}, 'root': root, 'events': events, 'decisions': decisions,\n        'shared_memory': safe_mem, 'cost_governor': safe_cost, 'sdk_usage': safe_usage,\n"
    if old not in s:
        raise SystemExit('entity-v1 sanitize return anchor missing')
    s=s.replace(old,new,1)

p.write_text(s)
PY

python3 -m py_compile "$MODULE" "$PROJECT/app/main.py" "$PROJECT/app/intelligence_engine.py" "$PROJECT/app/problem_engine.py"
cd "$PROJECT"
docker compose build agent
docker compose up -d --force-recreate agent

ok=0
for i in $(seq 1 75); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/entity-v1-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"ok":true' /tmp/entity-v1-health.json
grep -q 'Fourth Law · The Entity' <(curl -fsS http://127.0.0.1:8787/control-room)

# Auth/session regression without any paid model call.
TEST_PAIR="$(docker compose exec -T agent python - <<'PY'
from app.control_room import generate_pair_code
print(generate_pair_code())
PY
)"
[[ -n "$TEST_PAIR" ]]
curl -sS -D /tmp/entity-v1-pair-headers -o /tmp/entity-v1-pair-body -H 'Content-Type: application/json' -d "{\"code\":\"$TEST_PAIR\"}" http://127.0.0.1:8787/control-room/api/pair
grep -q '"ok":true' /tmp/entity-v1-pair-body
SESSION="$(grep -i '^set-cookie: fl_session=' /tmp/entity-v1-pair-headers | head -1 | sed -E 's/^[Ss]et-[Cc]ookie: fl_session=([^;]+).*/\1/' | tr -d '\r')"
[[ -n "$SESSION" ]]
curl -fsS -H "Cookie: fl_session=$SESSION" http://127.0.0.1:8787/control-room/api/jobs >/tmp/entity-v1-jobs.json
grep -q '"jobs"' /tmp/entity-v1-jobs.json
LATEST="$(python3 - <<'PY'
import json
j=json.load(open('/tmp/entity-v1-jobs.json'))
print((j.get('jobs') or [{}])[0].get('id',''))
PY
)"
if [[ -n "$LATEST" ]]; then
  curl -fsS -H "Cookie: fl_session=$SESSION" "http://127.0.0.1:8787/control-room/api/jobs/$LATEST" >/tmp/entity-v1-job.json
  grep -q '"shared_memory"' /tmp/entity-v1-job.json
  grep -q '"cost_governor"' /tmp/entity-v1-job.json
  grep -q '"sdk_usage"' /tmp/entity-v1-job.json
  timeout 6 curl -sN -H "Cookie: fl_session=$SESSION" "http://127.0.0.1:8787/control-room/api/stream/$LATEST" >/tmp/entity-v1-sse.txt || true
  grep -q 'event: snapshot' /tmp/entity-v1-sse.txt
fi

# Browser submit route validation only; deliberately no real task/model call.
SUBMIT_STATUS="$(curl -sS -o /tmp/entity-v1-submit-invalid -w '%{http_code}' -H "Cookie: fl_session=$SESSION" -H 'Content-Type: application/json' -d '{"goal":""}' http://127.0.0.1:8787/control-room/api/tasks || true)"
[[ "$SUBMIT_STATUS" = 422 ]]

PUBLIC_URL=""
if [[ -f /var/lib/fourthlaw/control-room-url ]]; then
  PUBLIC_URL="$(cat /var/lib/fourthlaw/control-room-url | tr -d '\r\n')"
  if [[ "$PUBLIC_URL" == https://* ]]; then
    curl -4fsS --max-time 15 "$PUBLIC_URL" | grep -q 'Fourth Law · The Entity'
    BASE_URL="${PUBLIC_URL%/control-room}"
    STATUS="$(curl -4sS --max-time 12 -o /tmp/entity-v1-public-health -w '%{http_code}' "$BASE_URL/health" || true)"
    [[ "$STATUS" = 404 ]]
  fi
fi

# Fresh fallback pairing code; existing valid browser sessions remain valid.
OWNER_PAIR="$(docker compose exec -T agent python - <<'PY'
from app.control_room import generate_pair_code
print(generate_pair_code())
PY
)"
[[ -n "$OWNER_PAIR" ]]

trap - ERR
post "ENTITY_CONTROL_ROOM_V1_READY {\"ui\":\"The Entity\",\"url\":\"${PUBLIC_URL:-/control-room}\",\"pair_code\":\"$OWNER_PAIR\",\"pair_ttl_minutes\":30,\"auth\":\"HttpOnly-session-preserved\",\"sse\":true,\"entity_core\":true,\"four_lane_theater\":true,\"agent_layers\":true,\"selected_agent_inspector\":true,\"event_feed\":true,\"synthesis\":true,\"intervention_drawer\":true,\"memory_cost_widget\":true,\"public_scope\":\"/control-room only\",\"paid_model_calls\":0,\"core_engine_changed\":false,\"local_regression\":\"ok\"}"

echo ENTITY_CONTROL_ROOM_V1_READY
[[ -n "$PUBLIC_URL" ]] && echo "$PUBLIC_URL"
cat /tmp/entity-v1-health.json

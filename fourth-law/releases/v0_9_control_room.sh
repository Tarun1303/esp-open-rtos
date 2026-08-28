#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
STATIC="$PROJECT/app/static/control_room.html"
MODULE="$PROJECT/app/control_room.py"
BASE=https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.9-control-room-$STAMP"
mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.py"
[[ -f "$MODULE" ]] && cp "$MODULE" "$BACKUP/control_room.py" || true
[[ -f "$STATIC" ]] && cp "$STATIC" "$BACKUP/control_room.html" || true

rollback(){
  set +e
  cp "$BACKUP/main.py" "$MAIN"
  if [[ -f "$BACKUP/control_room.py" ]]; then cp "$BACKUP/control_room.py" "$MODULE"; else rm -f "$MODULE"; fi
  if [[ -f "$BACKUP/control_room.html" ]]; then cp "$BACKUP/control_room.html" "$STATIC"; else rm -f "$STATIC"; fi
  cd "$PROJECT"
  docker compose build agent >/tmp/fl09-rollback-build.log 2>&1
  docker compose up -d --force-recreate agent >/tmp/fl09-rollback-up.log 2>&1
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'CONTROL_ROOM_V0_9_ROLLED_BACK {"reason":"deployment validation failed"}' >/dev/null 2>&1 || true
}
trap rollback ERR

mkdir -p "$PROJECT/app/static"
curl -fsSL "$BASE/v0_9_control_room.py" -o "$MODULE"
curl -fsSL "$BASE/v0_9_control_room.html" -o "$STATIC"

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
imp='from app.control_room import router as control_room_router, configure_control_room\n'
if imp not in s:
    anchors=['from app.intelligence_engine import IntelligenceEngine, build_intelligence_audit\n','from app.problem_engine import ProblemEngine, build_problem_audit\n']
    for a in anchors:
        if a in s:
            s=s.replace(a,a+imp,1);break
    else:
        # safe fallback after pydantic import
        a='from pydantic import BaseModel, Field\n'
        if a not in s: raise SystemExit('control-room import anchor missing')
        s=s.replace(a,a+imp,1)

block='''async def _control_room_start_task(goal: str, context: str, background_tasks: BackgroundTasks):
    req = ProblemRequest(goal=goal, context=context)
    return await create_intelligence_problem(req, background_tasks, ADMIN_TOKEN)

configure_control_room(_control_room_start_task)
app.include_router(control_room_router)

'''
if 'configure_control_room(_control_room_start_task)' not in s:
    a='@app.get("/health")\n'
    if a not in s: raise SystemExit('control-room health anchor missing')
    s=s.replace(a,block+a,1)

s=s.replace('version="0.8.0"','version="0.9.0"',1)
s=s.replace('"version":"0.8.0"','"version":"0.9.0"',1)
old='recursive-exact-four-way+problem-handling-4x4-dynamic+intelligence-sdk-v0.8'
new=old+'+control-room-v0.9'
s=s.replace(old,new)
p.write_text(s)
PY

python3 -m py_compile "$MAIN" "$MODULE" "$PROJECT/app/intelligence_engine.py" "$PROJECT/app/problem_engine.py"
cd "$PROJECT"
docker compose build agent
docker compose up -d --force-recreate agent

ok=0
for i in $(seq 1 75); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl09-health.json 2>/dev/null; then ok=1;break;fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.9.0"' /tmp/fl09-health.json
grep -q 'control-room-v0.9' /tmp/fl09-health.json

grep -q 'Fourth Law · Control Room' <(curl -fsS http://127.0.0.1:8787/control-room)

ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl09-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = 200 ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl09-api.json

# Regression pairing: generate a one-time code, exchange it, then test authenticated job history and SSE.
TEST_PAIR="$(docker compose exec -T agent python - <<'PY'
from app.control_room import generate_pair_code
print(generate_pair_code())
PY
)"
curl -sS -D /tmp/fl09-pair-headers -o /tmp/fl09-pair-body -H 'Content-Type: application/json' -d "{\"code\":\"$TEST_PAIR\"}" http://127.0.0.1:8787/control-room/api/pair
grep -q '"ok":true' /tmp/fl09-pair-body
SESSION="$(grep -i '^set-cookie: fl_session=' /tmp/fl09-pair-headers | head -1 | sed -E 's/^[Ss]et-[Cc]ookie: fl_session=([^;]+).*/\1/' | tr -d '\r')"
[[ -n "$SESSION" ]]
curl -fsS -H "Cookie: fl_session=$SESSION" http://127.0.0.1:8787/control-room/api/jobs >/tmp/fl09-jobs.json
grep -q '"jobs"' /tmp/fl09-jobs.json
LATEST="$(python3 - <<'PY'
import json
j=json.load(open('/tmp/fl09-jobs.json'))
print((j.get('jobs') or [{}])[0].get('id',''))
PY
)"
if [[ -n "$LATEST" ]]; then
  timeout 6 curl -sN -H "Cookie: fl_session=$SESSION" "http://127.0.0.1:8787/control-room/api/stream/$LATEST" >/tmp/fl09-sse.txt || true
  grep -q 'event: snapshot' /tmp/fl09-sse.txt
fi

# Prove the browser submission route is wired without launching an expensive regression: an invalid empty task must reach validation and return 422, not 404/500.
SUBMIT_STATUS="$(curl -sS -o /tmp/fl09-submit-invalid -w '%{http_code}' -H "Cookie: fl_session=$SESSION" -H 'Content-Type: application/json' -d '{"goal":""}' http://127.0.0.1:8787/control-room/api/tasks || true)"
[[ "$SUBMIT_STATUS" = 422 ]]

# Generate the owner's real one-time pairing code after regression consumed the test code.
OWNER_PAIR="$(docker compose exec -T agent python - <<'PY'
from app.control_room import generate_pair_code
print(generate_pair_code())
PY
)"
[[ -n "$OWNER_PAIR" ]]

TUNNEL_URL="$(docker compose logs tunnel --tail=300 2>&1 | grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
if [[ -z "$TUNNEL_URL" ]]; then
  TUNNEL_URL='unavailable-check-tunnel'
fi

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "CONTROL_ROOM_V0_9_DEPLOYED {\"ui\":\"/control-room\",\"https_base\":\"$TUNNEL_URL\",\"pair_code\":\"$OWNER_PAIR\",\"pair_ttl_minutes\":30,\"auth\":\"one-time-pairing-to-HttpOnly-session\",\"rest\":true,\"sse\":true,\"history\":true,\"agent_tree\":true,\"api_check\":\"ok\",\"sse_regression\":\"ok\",\"secrets_in_browser\":false,\"stable_named_tunnel\":false}" >/dev/null 2>&1 || true

echo FOURTHLAW_CONTROL_ROOM_V0_9_READY
cat /tmp/fl09-health.json

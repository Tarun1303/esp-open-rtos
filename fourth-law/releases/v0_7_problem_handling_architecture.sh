#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
BRIDGE=/usr/local/lib/fourthlaw-bridge/bridge.py
BASE=https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases
[[ $EUID -eq 0 ]]
[[ -f "$MAIN" && -f "$PROJECT/.env" && -f "$BRIDGE" ]]
cd "$PROJECT"
cp "$MAIN" "$MAIN.bak-v0.7-problem-handling"
cp "$BRIDGE" "$BRIDGE.bak-v1.4-problem-handling"
curl -fsSL "$BASE/v0_7_problem_engine.py" -o app/problem_engine.py

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()

if 'from app.problem_engine import ProblemEngine, build_problem_audit' not in s:
    anchor='from pydantic import BaseModel, Field\n'
    if anchor not in s:
        raise SystemExit('main import anchor missing')
    s=s.replace(anchor, anchor+'from app.problem_engine import ProblemEngine, build_problem_audit\n', 1)

if 'class ProblemRequest(BaseModel):' not in s:
    anchor='''class ContinueRequest(BaseModel):\n'''
    insert='''class ProblemRequest(BaseModel):\n    goal: str = Field(min_length=3, max_length=16000)\n    context: str = Field(default="", max_length=50000)\n\n'''
    if anchor not in s:
        raise SystemExit('ProblemRequest anchor missing')
    s=s.replace(anchor, insert+anchor, 1)

if 'problem_engine = ProblemEngine(' not in s:
    anchor='''@app.get("/health")\n'''
    block='''problem_engine = ProblemEngine(\n    raw_response=raw_response,\n    parse_json_object=parse_json_object,\n    supervisor_consult=supervisor_consult,\n    emit=emit,\n    persist=persist,\n    supervisor_model=SUPERVISOR_MODEL,\n    master_model=MASTER_MODEL,\n    worker_model=WORKER_MODEL,\n    recovery_attempts=NODE_RECOVERY_ATTEMPTS,\n)\n\nasync def run_problem_job(job_id: str):\n    job = load_job(job_id)\n    await problem_engine.run(job)\n\n@app.post("/problem")\nasync def create_problem(req: ProblemRequest, background_tasks: BackgroundTasks, x_admin_token: str = Header(default="")):\n    require_auth(x_admin_token)\n    jid = uuid.uuid4().hex[:14]\n    root = {\n        "id": uuid.uuid4().hex[:12],\n        "name": "Problem Supervisor",\n        "role": "Problem Supervisor / Four-Module Orchestrator",\n        "goal": req.goal,\n        "depth": 0,\n        "status": "queued",\n        "mode": "problem_supervisor",\n        "children": [],\n        "result": "",\n        "error": "",\n    }\n    job = {\n        "id": jid,\n        "architecture": "problem-handling-supervisor-4x4-dynamic-sequential",\n        "goal": req.goal,\n        "context": req.context,\n        "max_depth": 2,\n        "agent_budget": 5,\n        "agents_created": 1,\n        "tool_capability": "reasoning-only; external actions must be explicitly installed later",\n        "status": "queued",\n        "created_at": time.time(),\n        "completed_at": None,\n        "result": "",\n        "error": "",\n        "root": root,\n        "problem_plan": {},\n        "decisions": [],\n        "events": [],\n    }\n    write_job(job)\n    background_tasks.add_task(run_problem_job, jid)\n    return {\n        "ok": True,\n        "job_id": jid,\n        "status": "queued",\n        "architecture": job["architecture"],\n        "major_agents": 4,\n        "supervisor_work_packages_per_agent": 4,\n        "dynamic_steps_per_agent": "2-10 sequential",\n    }\n\n@app.get("/problem/{job_id}/audit")\nasync def problem_audit(job_id: str, x_admin_token: str = Header(default="")):\n    require_auth(x_admin_token)\n    job = load_job(job_id)\n    if not str(job.get("architecture", "")).startswith("problem-handling-"):\n        raise HTTPException(status_code=400, detail="Not a Problem Handling job")\n    return build_problem_audit(job)\n\n'''
    if anchor not in s:
        raise SystemExit('problem endpoint insertion anchor missing')
    s=s.replace(anchor, block+anchor, 1)

# Version bump and architecture visibility.
s=s.replace('0.6.3', '0.7.0')
s=s.replace('"architecture":"recursive-exact-four-way"', '"architecture":"recursive-exact-four-way+problem-handling-4x4-dynamic"')
# control-state carries a lightweight capability declaration without changing legacy mission semantics.
needle='"spawn_mode":"logical-on-demand","recursive":True}'
if needle in s:
    s=s.replace(needle, '"spawn_mode":"logical-on-demand","recursive":True,"problem_mode":"4 major agents; 4 supervisor work packages each; 2-10 sequential execution steps"}', 1)
p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/usr/local/lib/fourthlaw-bridge/bridge.py')
s=p.read_text()
if 'if typ=="problem":' not in s:
    anchor='    if typ=="mission":\n'
    insert='''    if typ=="problem":\n        p={"goal":str(c.get("goal","")),"context":str(c.get("context",""))}\n        s,b=req("POST","/problem",p);return cid,200<=s<300,{"http":s,"body":b[:16000]}\n    if typ=="problem_audit":\n        jid=str(c.get("job_id",""));s,b=req("GET",f"/problem/{jid}/audit");return cid,s==200,{"http":s,"body":b[:30000]}\n'''
    if anchor not in s:
        raise SystemExit('bridge mission anchor missing')
    s=s.replace(anchor, insert+anchor, 1)
s=s.replace('"job_result","mission"', '"job_result","problem","problem_audit","mission"')
s=s.replace("'version':'1.3'", "'version':'1.4'")
s=s.replace('"version":"1.3"', '"version":"1.4"')
p.write_text(s)
PY

python3 -m py_compile app/main.py app/problem_engine.py "$BRIDGE"
docker compose build agent
docker compose up -d agent

ok=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl070-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.7.0"' /tmp/fl070-health.json

ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl070-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl070-api.json

systemctl restart fourthlaw-command-bridge.service
sleep 2
systemctl is-active --quiet fourthlaw-command-bridge.service
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'PROBLEM_ARCHITECTURE_V0_7_DEPLOYED {"supervisor_modules":4,"work_packages_each":4,"dynamic_steps_each":"2-10","execution":"sequential-per-module","api_check":"ok","bridge":"1.4"}' >/dev/null 2>&1 || true

echo FOURTHLAW_V0_7_PROBLEM_ARCHITECTURE_READY
cat /tmp/fl070-health.json

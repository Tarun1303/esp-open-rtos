#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
BRIDGE=/usr/local/lib/fourthlaw-bridge/bridge.py
REQ="$PROJECT/requirements.txt"
ENVFILE="$PROJECT/.env"
BASE=https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.8-intelligence-$STAMP"

[[ $EUID -eq 0 ]]
[[ -f "$MAIN" && -f "$BRIDGE" && -f "$REQ" && -f "$ENVFILE" ]]
mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.py"
cp "$BRIDGE" "$BACKUP/bridge.py"
cp "$REQ" "$BACKUP/requirements.txt"
cp "$ENVFILE" "$BACKUP/.env"

rollback() {
  set +e
  cp "$BACKUP/main.py" "$MAIN"
  cp "$BACKUP/bridge.py" "$BRIDGE"
  cp "$BACKUP/requirements.txt" "$REQ"
  cp "$BACKUP/.env" "$ENVFILE"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl080-rollback-build.log 2>&1
  docker compose up -d --force-recreate agent >/tmp/fl080-rollback-up.log 2>&1
  systemctl restart fourthlaw-command-bridge.service >/dev/null 2>&1
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'INTELLIGENCE_LAYER_V0_8_ROLLED_BACK {"reason":"deployment validation failed"}' >/dev/null 2>&1 || true
}
trap rollback ERR

cd "$PROJECT"
curl -fsSL "$BASE/v0_8_intelligence_engine.py" -o app/intelligence_engine.py

python3 - <<'PY'
from pathlib import Path

req=Path('/opt/fourth-law-agent/requirements.txt')
lines=req.read_text().splitlines()
if not any(x.strip().startswith('openai-agents') for x in lines):
    lines.append('openai-agents==0.22.0')
req.write_text('\n'.join(lines).rstrip()+'\n')

env=Path('/opt/fourth-law-agent/.env')
s=env.read_text()
settings={
    'INTELLIGENCE_MODEL':'gpt-5.6-terra',
    'INTELLIGENCE_EXECUTION_MODEL':'gpt-5.6-luna',
    'INTELLIGENCE_ESCALATION_MODEL':'gpt-5.6-sol',
    'INTELLIGENCE_MAX_DEPTH':'3',
    'INTELLIGENCE_AGENT_BUDGET':'85',
    'INTELLIGENCE_MAX_CHILDREN':'4',
    'OPENAI_AGENTS_TRACE_INCLUDE_SENSITIVE_DATA':'0',
}
rows=[]
seen=set()
for line in s.splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k=line.split('=',1)[0].strip()
        if k in settings:
            rows.append(f'{k}={settings[k]}');seen.add(k);continue
    rows.append(line)
for k,v in settings.items():
    if k not in seen: rows.append(f'{k}={v}')
env.write_text('\n'.join(rows).rstrip()+'\n')
PY
chmod 600 "$ENVFILE"

python3 - <<'PY'
from pathlib import Path

p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()

imp='from app.intelligence_engine import IntelligenceEngine, build_intelligence_audit\n'
if imp not in s:
    anchor='from app.problem_engine import ProblemEngine, build_problem_audit\n'
    if anchor not in s:
        raise SystemExit('v0.8 main import anchor missing')
    s=s.replace(anchor, anchor+imp, 1)

cfg='''INTELLIGENCE_MODEL = os.getenv("INTELLIGENCE_MODEL", MASTER_MODEL)
INTELLIGENCE_EXECUTION_MODEL = os.getenv("INTELLIGENCE_EXECUTION_MODEL", WORKER_MODEL)
INTELLIGENCE_ESCALATION_MODEL = os.getenv("INTELLIGENCE_ESCALATION_MODEL", "gpt-5.6-sol")
INTELLIGENCE_MAX_DEPTH = max(1, min(4, int(os.getenv("INTELLIGENCE_MAX_DEPTH", "3"))))
INTELLIGENCE_AGENT_BUDGET = max(5, min(341, int(os.getenv("INTELLIGENCE_AGENT_BUDGET", "85"))))
INTELLIGENCE_MAX_CHILDREN = max(1, min(4, int(os.getenv("INTELLIGENCE_MAX_CHILDREN", "4"))))
'''
if 'INTELLIGENCE_MODEL = os.getenv(' not in s:
    anchor='WORKER_MODEL = os.getenv("WORKER_MODEL", "gpt-5.6-luna")\n'
    if anchor not in s:
        raise SystemExit('v0.8 model config anchor missing')
    s=s.replace(anchor, anchor+cfg, 1)

engine_block='''intelligence_engine = IntelligenceEngine(
    problem_engine=problem_engine,
    supervisor_consult=supervisor_consult,
    emit=emit,
    persist=persist,
    constitution=CONSTITUTION,
    supervisor_model=SUPERVISOR_MODEL,
    intelligence_model=INTELLIGENCE_MODEL,
    execution_model=INTELLIGENCE_EXECUTION_MODEL,
    escalation_model=INTELLIGENCE_ESCALATION_MODEL,
    max_children_per_node=INTELLIGENCE_MAX_CHILDREN,
    recovery_attempts=NODE_RECOVERY_ATTEMPTS,
)

'''
if 'intelligence_engine = IntelligenceEngine(' not in s:
    anchor='async def run_problem_job(job_id: str):\n'
    if anchor not in s:
        raise SystemExit('v0.8 problem engine anchor missing')
    s=s.replace(anchor, engine_block+anchor, 1)

endpoint_block='''async def run_intelligence_job(job_id: str):
    job = load_job(job_id)
    await intelligence_engine.run(job)

@app.post("/intelligence/problem")
async def create_intelligence_problem(req: ProblemRequest, background_tasks: BackgroundTasks, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token)
    jid = uuid.uuid4().hex[:14]
    root = {
        "id": uuid.uuid4().hex[:12],
        "parent_id": None,
        "name": "Problem Supervisor",
        "role": "Governance Supervisor / Intelligence Orchestrator",
        "goal": req.goal,
        "depth": 0,
        "status": "queued",
        "mode": "intelligence_supervisor",
        "children": [],
        "result": "",
        "error": "",
    }
    job = {
        "id": jid,
        "architecture": "intelligence-layer-sdk-v0.8-manager-recursive",
        "goal": req.goal,
        "context": req.context,
        "max_depth": INTELLIGENCE_MAX_DEPTH,
        "agent_budget": INTELLIGENCE_AGENT_BUDGET,
        "agents_created": 1,
        "tool_capability": "reasoning+recursive-delegation+supervisor; external executors not yet installed",
        "status": "queued",
        "created_at": time.time(),
        "completed_at": None,
        "result": "",
        "error": "",
        "root": root,
        "problem_plan": {},
        "decisions": [],
        "events": [],
    }
    write_job(job)
    background_tasks.add_task(run_intelligence_job, jid)
    return {
        "ok": True,
        "job_id": jid,
        "status": "queued",
        "architecture": job["architecture"],
        "intelligence_kernel": "UNDERSTAND->PLAN->EXECUTE_OR_DELEGATE->VERIFY->SYNTHESIZE->REPORT",
        "manager_pattern": True,
        "isolated_agent_sessions": True,
        "max_depth": INTELLIGENCE_MAX_DEPTH,
        "agent_budget": INTELLIGENCE_AGENT_BUDGET,
    }

@app.get("/intelligence/{job_id}/audit")
async def intelligence_audit(job_id: str, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token)
    job = load_job(job_id)
    if not str(job.get("architecture", "")).startswith("intelligence-layer-sdk-"):
        raise HTTPException(status_code=400, detail="Not an Intelligence Layer job")
    return build_intelligence_audit(job)

'''
if '@app.post("/intelligence/problem")' not in s:
    anchor='@app.get("/health")\n'
    if anchor not in s:
        raise SystemExit('v0.8 health endpoint anchor missing')
    s=s.replace(anchor, endpoint_block+anchor, 1)

s=s.replace('version="0.7.2"', 'version="0.8.0"')
s=s.replace('"version":"0.7.2"', '"version":"0.8.0"')
s=s.replace('"architecture":"recursive-exact-four-way+problem-handling-4x4-dynamic"',
            '"architecture":"recursive-exact-four-way+problem-handling-4x4-dynamic+intelligence-sdk-v0.8"')

p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path

p=Path('/usr/local/lib/fourthlaw-bridge/bridge.py')
s=p.read_text()

if 'if typ=="intelligence_problem":' not in s:
    anchor='    if typ=="problem":\n'
    if anchor not in s:
        raise SystemExit('v0.8 bridge problem anchor missing')
    insert='''    if typ=="intelligence_problem":
        p={"goal":str(c.get("goal","")),"context":str(c.get("context",""))}
        st,b=req("POST","/intelligence/problem",p);return cid,200<=st<300,{"http":st,"body":b[:16000]}
    if typ=="intelligence_audit":
        jid=str(c.get("job_id",""));st,b=req("GET",f"/intelligence/{jid}/audit");return cid,st==200,{"http":st,"body":b[:30000]}
'''
    s=s.replace(anchor, insert+anchor, 1)

lines=[]
for line in s.splitlines():
    if 'BRIDGE_ONLINE' in line and '"accepted"' in line:
        if '"intelligence_problem"' not in line:
            if '"problem_audit"' in line:
                line=line.replace('"problem_audit"', '"problem_audit","intelligence_problem","intelligence_audit"')
            elif '"mission"' in line:
                line=line.replace('"mission"', '"intelligence_problem","intelligence_audit","mission"')
        line=line.replace('"version":"1.4"', '"version":"1.5"').replace("'version':'1.4'", "'version':'1.5'")
    lines.append(line)
p.write_text('\n'.join(lines)+'\n')
PY

python3 -m py_compile app/main.py app/problem_engine.py app/intelligence_engine.py "$BRIDGE"

docker compose build agent
docker compose up -d --force-recreate agent

ok=0
for i in $(seq 1 75); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl080-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.8.0"' /tmp/fl080-health.json
grep -q 'intelligence-sdk-v0.8' /tmp/fl080-health.json

ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl080-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl080-api.json

docker compose exec -T agent python - <<'PY'
import asyncio
import importlib.metadata
from agents import Agent, Runner, RunConfig
from pydantic import BaseModel

class Smoke(BaseModel):
    status: str

async def main():
    ver=importlib.metadata.version("openai-agents")
    assert ver=="0.22.0", ver
    a=Agent(name="Fourth Law SDK Smoke", instructions="Return status exactly INTELLIGENCE_SDK_OK.", model="gpt-5.6-luna", output_type=Smoke)
    r=await Runner.run(a, "Perform the smoke check.", max_turns=2, run_config=RunConfig(workflow_name="Fourth Law SDK Smoke", trace_include_sensitive_data=False))
    assert r.final_output.status=="INTELLIGENCE_SDK_OK", r.final_output.status
    print("OPENAI_AGENTS_SDK_0_22_0_OK")
asyncio.run(main())
PY

systemctl restart fourthlaw-command-bridge.service
sleep 2
systemctl is-active --quiet fourthlaw-command-bridge.service

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'INTELLIGENCE_LAYER_V0_8_DEPLOYED {"sdk":"openai-agents-0.22.0","pattern":"manager+code-orchestration","node_kernel":"understand-plan-execute/delegate-verify-synthesize-report","isolated_sessions":true,"max_depth":3,"agent_budget":85,"trace_sensitive_data":false,"api_check":"ok","sdk_smoke":"ok"}' >/dev/null 2>&1 || true

echo FOURTHLAW_INTELLIGENCE_V0_8_READY
cat /tmp/fl080-health.json

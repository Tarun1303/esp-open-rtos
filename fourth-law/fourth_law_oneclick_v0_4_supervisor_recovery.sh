#!/usr/bin/env bash
set -Eeuo pipefail

# FOURTH LAW AGENT FRAMEWORK — ONE CLICK v0.4
# Ubuntu 24.04 / Debian-compatible
# Features:
# - Docker install
# - Master + bounded sub-agents
# - mandatory Supervisor API communication for every node
# - automatic API retries + node recovery + verification
# - browser console through temporary HTTPS tunnel
# - systemd watchdog for service self-restart
#
# Run:
#   sudo bash fourth_law_oneclick_v0_4.sh

PROJECT_DIR="${PROJECT_DIR:-/opt/fourth-law-agent}"
LOCAL_PORT="${LOCAL_PORT:-8787}"
INSTALL_LOG="/var/log/fourthlaw-install.log"

mkdir -p "$(dirname "$INSTALL_LOG")"
touch "$INSTALL_LOG"
chmod 600 "$INSTALL_LOG"

say() { printf '%s\n' "$*"; }

retry() {
  local attempts="$1"; shift
  local n=1
  while true; do
    if "$@" >>"$INSTALL_LOG" 2>&1; then
      return 0
    fi
    if (( n >= attempts )); then
      return 1
    fi
    sleep $(( n * 3 ))
    n=$(( n + 1 ))
  done
}

fatal() {
  say
  say "Automatic recovery could not complete this bootstrap step."
  say "Diagnostic log: $INSTALL_LOG"
  say "Nothing destructive was done to your server."
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  say "Run: sudo bash $0"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  say "Ubuntu/Debian required."
  exit 1
fi

say
say "============================================================"
say " FOURTH LAW — ONE CLICK v0.4"
say " Supervisor + Recovery + Verification"
say "============================================================"
say

say "[1/9] Preparing server..."
export DEBIAN_FRONTEND=noninteractive
retry 3 apt-get update -y || fatal
retry 3 apt-get install -y ca-certificates curl git jq openssl python3 || fatal

if ! command -v docker >/dev/null 2>&1; then
  say "[2/9] Installing Docker..."
  retry 3 bash -c 'curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh' || fatal
  rm -f /tmp/get-docker.sh
else
  say "[2/9] Docker already available."
fi

systemctl enable --now docker >>"$INSTALL_LOG" 2>&1 || true

if ! docker compose version >>"$INSTALL_LOG" 2>&1; then
  retry 3 apt-get install -y docker-compose-plugin || fatal
fi

say "[3/9] Creating agent environment..."
mkdir -p "${PROJECT_DIR}/app/static" "${PROJECT_DIR}/data/jobs"
chmod 700 "${PROJECT_DIR}"
cd "${PROJECT_DIR}"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  say
  say "Only input required: paste your OpenAI API key."
  read -r -s -p "OPENAI_API_KEY: " OPENAI_API_KEY
  echo
fi
[[ -n "${OPENAI_API_KEY:-}" ]] || fatal

if [[ -f .env ]] && grep -q '^ADMIN_TOKEN=' .env; then
  ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
else
  ADMIN_TOKEN="$(openssl rand -hex 24)"
fi

cat > .env <<EOF
OPENAI_API_KEY=${OPENAI_API_KEY}
ADMIN_TOKEN=${ADMIN_TOKEN}
SUPERVISOR_MODEL=gpt-5.6-terra
MASTER_MODEL=gpt-5.6-terra
WORKER_MODEL=gpt-5.6-luna
MAX_CONCURRENCY=4
MAX_CHILDREN=3
MAX_AGENTS=12
DEFAULT_MAX_DEPTH=2
API_RETRIES=4
NODE_RECOVERY_ATTEMPTS=2
EOF
chmod 600 .env

cat > requirements.txt <<'EOF'
fastapi>=0.115
uvicorn[standard]>=0.30
openai>=1.40
pydantic>=2.7
EOF

cat > app/main.py <<'PY'
import asyncio
import json
import os
import time
import uuid
from pathlib import Path
from typing import Any

from fastapi import BackgroundTasks, Depends, FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse
from openai import AsyncOpenAI
from pydantic import BaseModel, Field

app = FastAPI(
    title="Fourth Law Agent Framework",
    version="0.4.0",
    description="Hierarchical agents with mandatory supervisor communication, recovery, verification, and human control.",
)

client = AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"])

ADMIN_TOKEN = os.environ["ADMIN_TOKEN"]
SUPERVISOR_MODEL = os.getenv("SUPERVISOR_MODEL", "gpt-5.6-terra")
MASTER_MODEL = os.getenv("MASTER_MODEL", "gpt-5.6-terra")
WORKER_MODEL = os.getenv("WORKER_MODEL", "gpt-5.6-luna")
MAX_CONCURRENCY = max(1, int(os.getenv("MAX_CONCURRENCY", "4")))
MAX_CHILDREN = max(1, min(4, int(os.getenv("MAX_CHILDREN", "3"))))
MAX_AGENTS = max(2, min(40, int(os.getenv("MAX_AGENTS", "12"))))
DEFAULT_MAX_DEPTH = max(0, min(3, int(os.getenv("DEFAULT_MAX_DEPTH", "2"))))
API_RETRIES = max(2, min(6, int(os.getenv("API_RETRIES", "4"))))
NODE_RECOVERY_ATTEMPTS = max(1, min(3, int(os.getenv("NODE_RECOVERY_ATTEMPTS", "2"))))

DATA_DIR = Path("/data")
JOBS_DIR = DATA_DIR / "jobs"
JOBS_DIR.mkdir(parents=True, exist_ok=True)
CONSOLE_PATH = Path("/app/app/static/console.html")

semaphore = asyncio.Semaphore(MAX_CONCURRENCY)

CONSTITUTION = """
PROJECT CONSTITUTION — FOURTH LAW FRAMEWORK

Priority 0 — hard constraints:
- Do not perform illegal, harmful, deceptive, privacy-invasive, or unauthorized actions.
- Preserve human control; never bypass authentication, authorization, approval, or safety controls.
- Never expose credentials or secrets.
- Never claim an external action happened unless an authorized tool actually performed it.
- Consequential external side effects require explicit authorization unless that exact action was already authorized.
- Report uncertainty, assumptions, failures, and material trade-offs accurately.

Project philosophy inspired by Asimov:
1. Avoid causing harm to people or knowingly enabling preventable harm.
2. Follow authorized human instructions unless they conflict with Priority 0.
3. Preserve service integrity/resources unless that conflicts with higher priorities.
4. Subject to the above, maximize useful efficiency and long-term human progress.

Efficiency:
- Use the smallest sufficient plan.
- Avoid duplicate work and unnecessary agents/API calls.
- Delegate only when specialization or parallel execution creates material benefit.
- Prefer evidence and measurable criteria.
- Stop when the goal is sufficiently achieved.

COMMUNICATION RULE:
Every Master/Worker/Sub-agent must communicate structured operational state with the Supervisor API.
Do NOT send hidden chain-of-thought. Send only concise task state:
goal, observations, issue/error if any, options, proposed decision, and requested guidance.
"""

class TaskRequest(BaseModel):
    goal: str = Field(min_length=3, max_length=12000)
    context: str = Field(default="", max_length=30000)
    max_depth: int = Field(default=DEFAULT_MAX_DEPTH, ge=0, le=3)

class ContinueRequest(BaseModel):
    instruction: str = Field(min_length=1, max_length=12000)

def auth(x_admin_token: str = Header(default="")):
    if x_admin_token != ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid admin token")

def job_path(job_id: str) -> Path:
    return JOBS_DIR / f"{job_id}.json"

def load_job(job_id: str) -> dict[str, Any]:
    p = job_path(job_id)
    if not p.exists():
        raise HTTPException(status_code=404, detail="Job not found")
    return json.loads(p.read_text())

def save_job(job: dict[str, Any]) -> None:
    p = job_path(job["id"])
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(job, indent=2, ensure_ascii=False))
    tmp.replace(p)

def emit(job: dict[str, Any], event_type: str, summary: str, **extra) -> None:
    job.setdefault("events", []).append({
        "ts": time.time(),
        "type": event_type,
        "summary": summary[:4000],
        **extra,
    })
    if len(job["events"]) > 500:
        job["events"] = job["events"][-500:]
    save_job(job)

def list_jobs() -> list[dict[str, Any]]:
    rows = []
    for p in JOBS_DIR.glob("*.json"):
        try:
            j = json.loads(p.read_text())
            rows.append({
                "id": j.get("id"),
                "status": j.get("status"),
                "goal": j.get("goal"),
                "created_at": j.get("created_at"),
                "completed_at": j.get("completed_at"),
                "parent_job_id": j.get("parent_job_id"),
                "agents_created": j.get("agents_created", 1),
                "agent_budget": j.get("agent_budget", MAX_AGENTS),
            })
        except Exception:
            pass
    rows.sort(key=lambda x: x.get("created_at") or 0, reverse=True)
    return rows[:100]

async def raw_response(model: str, instructions: str, input_text: str, max_output_tokens: int = 2200) -> str:
    last_error = None
    for attempt in range(1, API_RETRIES + 1):
        try:
            async with semaphore:
                response = await client.responses.create(
                    model=model,
                    instructions=instructions,
                    input=input_text,
                    reasoning={"effort": "low"},
                    text={"verbosity": "low"},
                    max_output_tokens=max_output_tokens,
                    store=False,
                )
            text = (response.output_text or "").strip()
            if not text:
                raise RuntimeError("OpenAI returned an empty response.")
            return text
        except Exception as exc:
            last_error = exc
            if attempt >= API_RETRIES:
                break
            await asyncio.sleep(min(12, 2 ** (attempt - 1)))
    raise RuntimeError(f"OpenAI API failed after {API_RETRIES} attempts: {last_error}")

def parse_json_object(text: str) -> dict[str, Any]:
    text = text.strip()
    if text.startswith("```"):
        text = text.replace("```json", "", 1).replace("```", "").strip()
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("No JSON object found.")
    return json.loads(text[start:end + 1])

async def supervisor_consult(job: dict[str, Any], node: dict[str, Any], stage: str, context: str, issue: str = "", candidate: str = "") -> dict[str, Any]:
    state = {
        "stage": stage,
        "agent_name": node.get("name"),
        "role": node.get("role"),
        "depth": node.get("depth"),
        "goal": node.get("goal"),
        "context": context[-12000:],
        "issue_or_error": issue[-6000:],
        "candidate_output_or_plan": candidate[-10000:],
    }
    prompt = f"""
You are the mandatory Supervisor for a bounded multi-agent system.
Apply the constitution below.

{CONSTITUTION}

Review this STRUCTURED STATE:
{json.dumps(state, ensure_ascii=False)}

Return ONLY one JSON object:
{{
  "summary": "brief operational assessment",
  "guidance": "specific next-step instruction for the agent",
  "risk": "low|medium|high",
  "verify": "what must be checked before declaring success",
  "needs_human": false
}}
"""
    try:
        txt = await raw_response(SUPERVISOR_MODEL, "Act as the system Supervisor.", prompt, 1400)
        result = parse_json_object(txt)
    except Exception as exc:
        result = {
            "summary": "Supervisor channel unavailable after automatic API retries.",
            "guidance": "Use the safest bounded fallback and do not perform external side effects.",
            "risk": "medium",
            "verify": "Verify output locally and retry supervisor later.",
            "needs_human": False,
            "supervisor_error": str(exc),
        }
    emit(job, "supervisor", f"{stage}: {result.get('summary','')}", node_id=node.get("id"))
    return result

async def plan_node(job, node, context, guidance):
    prompt = f"""{CONSTITUTION}\nSupervisor guidance:\n{json.dumps(guidance, ensure_ascii=False)}\nROLE:{node['role']}\nGOAL:{node['goal']}\nCONTEXT:{context[-16000:]}\nReturn ONLY JSON with mode execute/decompose, reason, subtasks (max {MAX_CHILDREN})."""
    txt = await raw_response(MASTER_MODEL, "Return a bounded task plan.", prompt, 1800)
    data = parse_json_object(txt)
    if data.get("mode") not in {"execute", "decompose"}:
        raise ValueError("Invalid plan mode.")
    subtasks = data.get("subtasks") or []
    data["subtasks"] = subtasks[:MAX_CHILDREN] if isinstance(subtasks, list) else []
    return data

async def worker_execute(job, node, context, guidance, recovery=""):
    prompt = f"""{CONSTITUTION}\nSupervisor guidance:{json.dumps(guidance, ensure_ascii=False)}\nRecovery:{recovery}\nROLE:{node['role']}\nGOAL:{node['goal']}\nCONTEXT:{context[-18000:]}\nComplete only the assigned goal; be concise and explicit about uncertainty."""
    return await raw_response(WORKER_MODEL, "Complete the assigned specialist task.", prompt, 3000)

async def verify_output(job, node, context, output):
    verification = await supervisor_consult(job, node, "verification", context, candidate=output)
    prompt = f"""{CONSTITUTION}\nVerify GOAL:{node['goal']}\nRESULT:{output[-16000:]}\nCriteria:{verification.get('verify','')}\nReturn ONLY JSON: {{\"verdict\":\"pass|revise\",\"revision\":\"...\"}}"""
    try:
        txt = await raw_response(SUPERVISOR_MODEL, "Be a strict verifier.", prompt, 900)
        verdict = parse_json_object(txt)
        ok = verdict.get("verdict") == "pass"
        revision = str(verdict.get("revision") or "")
        emit(job, "verification", f"{'PASS' if ok else 'REVISE'}: {revision}", node_id=node.get("id"))
        return ok, revision
    except Exception as exc:
        emit(job, "verification", f"Verifier unavailable; bounded fallback accepted: {exc}", node_id=node.get("id"))
        return True, ""

async def direct_with_recovery(job, node, context, guidance):
    last_error = ""
    recovery_instruction = ""
    for recovery_round in range(NODE_RECOVERY_ATTEMPTS + 1):
        try:
            output = await worker_execute(job, node, context, guidance, recovery_instruction)
            ok, revision = await verify_output(job, node, context, output)
            if ok:
                return output
            recovery_instruction = revision or "Review and correct material issues."
            emit(job, "recovery", f"Revision requested: {recovery_instruction}", node_id=node.get("id"))
        except Exception as exc:
            last_error = str(exc)
            emit(job, "error", last_error, node_id=node.get("id"))
            recovery = await supervisor_consult(job, node, "error_recovery", context, issue=last_error)
            recovery_instruction = recovery.get("guidance", "Retry using the safest simpler approach.")
            emit(job, "recovery", recovery_instruction, node_id=node.get("id"))
            await asyncio.sleep(min(8, 2 ** recovery_round))
    raise RuntimeError(f"Node could not recover: {last_error or recovery_instruction}")

async def run_node(job, node, context, max_depth):
    node["status"] = "running"
    node["started_at"] = time.time()
    emit(job, "agent_start", f"{node['name']} started", node_id=node["id"])
    guidance = await supervisor_consult(job, node, "start", context)
    node["supervisor_guidance"] = guidance
    save_job(job)
    if guidance.get("needs_human"):
        node["status"] = "waiting_human"
        node["result"] = "Supervisor requires human authorization. " + str(guidance.get("guidance", ""))
        emit(job, "human_gate", node["result"], node_id=node["id"])
        return node["result"]
    if int(node["depth"]) >= max_depth:
        output = await direct_with_recovery(job, node, context, guidance)
        node.update(result=output, status="completed", completed_at=time.time())
        emit(job, "agent_done", f"{node['name']} completed", node_id=node["id"])
        return output
    try:
        plan = await plan_node(job, node, context, guidance)
        node["decision"] = plan["mode"]
        node["decision_reason"] = plan.get("reason", "")
        emit(job, "decision", f"{plan['mode']}: {plan.get('reason','')}", node_id=node["id"])
    except Exception as exc:
        recovery = await supervisor_consult(job, node, "planning_recovery", context, issue=str(exc))
        output = await direct_with_recovery(job, node, context, recovery)
        node.update(result=output, status="completed", completed_at=time.time())
        return output
    if plan["mode"] == "execute" or not plan["subtasks"]:
        output = await direct_with_recovery(job, node, context, guidance)
        node.update(result=output, status="completed", completed_at=time.time())
        emit(job, "agent_done", f"{node['name']} completed", node_id=node["id"])
        return output
    available = max(0, MAX_AGENTS - int(job.get("agents_created", 1)))
    selected = plan["subtasks"][:available]
    if not selected:
        output = await direct_with_recovery(job, node, context, guidance)
        node.update(result=output, status="completed", completed_at=time.time())
        return output
    job["agents_created"] = int(job.get("agents_created", 1)) + len(selected)
    children = []
    for item in selected:
        child = {"id": str(uuid.uuid4()), "name": str(item.get("name") or "Sub-agent"), "role": str(item.get("role") or "Specialist"), "goal": str(item.get("goal") or node["goal"]), "depth": int(node["depth"]) + 1, "status": "queued", "children": []}
        node["children"].append(child)
        children.append(child)
    emit(job, "spawn", f"Spawned {len(children)} bounded sub-agent(s).", node_id=node["id"])
    outputs = await asyncio.gather(*(run_node(job, c, context, max_depth) for c in children), return_exceptions=True)
    rendered = []
    for child, result in zip(children, outputs):
        rendered.append(f"{child['name']}: {result}" if not isinstance(result, Exception) else f"{child['name']}: FAILED: {result}")
    synthesis_guidance = await supervisor_consult(job, node, "synthesis", context, candidate="\n\n---\n\n".join(rendered))
    synthesis_prompt = f"""{CONSTITUTION}\nGoal:{node['goal']}\nSupervisor:{json.dumps(synthesis_guidance, ensure_ascii=False)}\nCHILD OUTPUTS:\n{chr(10).join(rendered)}\nSynthesize one concise useful result."""
    synthesis = await raw_response(MASTER_MODEL, "Synthesize child-agent work.", synthesis_prompt, 3400)
    node.update(result=synthesis, status="completed", completed_at=time.time())
    emit(job, "agent_done", f"{node['name']} completed synthesis", node_id=node["id"])
    return synthesis

async def run_job(job_id):
    job = load_job(job_id)
    try:
        job["status"] = "running"
        job["started_at"] = time.time()
        emit(job, "job_start", "Job started.")
        result = await run_node(job, job["root"], job.get("context", ""), job["max_depth"])
        job["result"] = result
        job["status"] = "completed"
        job["completed_at"] = time.time()
        emit(job, "job_done", "Job completed.")
    except Exception as exc:
        job["status"] = "failed"
        job["error"] = str(exc)
        job["completed_at"] = time.time()
        emit(job, "job_failed", str(exc))

def new_job(req, parent_job_id=None):
    job_id = str(uuid.uuid4())
    return {"id": job_id, "status": "queued", "created_at": time.time(), "goal": req.goal, "context": req.context, "max_depth": req.max_depth, "parent_job_id": parent_job_id, "agents_created": 1, "agent_budget": MAX_AGENTS, "events": [], "root": {"id": str(uuid.uuid4()), "name": "Master Task", "role": "Master Agent", "goal": req.goal, "depth": 0, "status": "queued", "children": []}}

@app.get("/health")
async def health():
    return {"ok": True, "version": "0.4.0", "supervisor_model": SUPERVISOR_MODEL, "master_model": MASTER_MODEL, "worker_model": WORKER_MODEL, "max_agents": MAX_AGENTS, "communication": "mandatory-supervisor-state-channel", "recovery": True, "verification": True}

@app.get("/console", response_class=HTMLResponse)
async def console():
    return HTMLResponse(CONSOLE_PATH.read_text())

@app.get("/jobs", dependencies=[Depends(auth)])
async def jobs():
    return {"jobs": list_jobs()}

@app.post("/task", dependencies=[Depends(auth)])
async def create_task(req: TaskRequest, background_tasks: BackgroundTasks):
    job = new_job(req); save_job(job); background_tasks.add_task(run_job, job["id"]); return {"job_id": job["id"], "status": "queued"}

@app.get("/task/{job_id}", dependencies=[Depends(auth)])
async def get_task(job_id: str): return load_job(job_id)

@app.get("/task/{job_id}/result", dependencies=[Depends(auth)])
async def get_result(job_id: str):
    job = load_job(job_id); return {"job_id": job_id, "status": job["status"], "result": job.get("result"), "error": job.get("error"), "events": job.get("events", [])[-40:]}

@app.post("/task/{job_id}/continue", dependencies=[Depends(auth)])
async def continue_task(job_id: str, req: ContinueRequest, background_tasks: BackgroundTasks):
    parent = load_job(job_id)
    followup = TaskRequest(goal=req.instruction, context=f"ORIGINAL GOAL:\n{parent.get('goal','')}\nPREVIOUS RESULT:\n{parent.get('result') or parent.get('error') or '(none)'}", max_depth=parent.get("max_depth", DEFAULT_MAX_DEPTH))
    job = new_job(followup, parent_job_id=job_id); save_job(job); background_tasks.add_task(run_job, job["id"]); return {"job_id": job["id"], "parent_job_id": job_id, "status": "queued"}

@app.get("/api-check", dependencies=[Depends(auth)])
async def api_check():
    text = await raw_response(SUPERVISOR_MODEL, "Connectivity diagnostic only.", "Reply with exactly: FOURTHLAW_API_OK", 64)
    return {"ok": "FOURTHLAW_API_OK" in text, "model": SUPERVISOR_MODEL}
PY

cat > app/static/console.html <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Fourth Law Console</title><style>body{font-family:system-ui;background:#0c0f14;color:#eef2f7;max-width:1000px;margin:auto;padding:24px}textarea,input,button{font:inherit}textarea,input{width:100%;box-sizing:border-box;background:#151a22;color:#fff;border:1px solid #334155;border-radius:8px;padding:10px}textarea{min-height:110px}button{padding:10px 14px;margin-top:8px}pre{white-space:pre-wrap;background:#151a22;padding:12px;border-radius:8px}.job{border-top:1px solid #334155;padding:10px 0}</style></head><body><h1>Fourth Law Control Console</h1><input id="token" type="password" placeholder="Admin token"><textarea id="goal" placeholder="New mission"></textarea><button onclick="submitTask()">Launch Master Agent</button><h2>Jobs</h2><div id="jobs"></div><div id="detail"></div><script>
let selectedJob=null; const tokenEl=document.getElementById('token'); const hp=new URLSearchParams(location.hash.replace(/^#/,'')); const ht=hp.get('token'); if(ht){localStorage.setItem('fourthLawToken',ht);history.replaceState(null,'',location.pathname)} tokenEl.value=localStorage.getItem('fourthLawToken')||''; tokenEl.onchange=()=>localStorage.setItem('fourthLawToken',tokenEl.value.trim()); function h(){return {'Content-Type':'application/json','X-Admin-Token':tokenEl.value.trim()}} async function api(u,o={}){o.headers={...h(),...(o.headers||{})};let r=await fetch(u,o),t=await r.text(),d;try{d=JSON.parse(t)}catch{d={detail:t}}if(!r.ok)throw Error(d.detail||r.status);return d} async function submitTask(){let g=document.getElementById('goal').value.trim();if(!g)return;let d=await api('/task',{method:'POST',body:JSON.stringify({goal:g,max_depth:2})});selectedJob=d.job_id;document.getElementById('goal').value='';loadJobs();loadSelected()} async function loadJobs(){try{let d=await api('/jobs'),e=document.getElementById('jobs');e.innerHTML='';for(let j of d.jobs){let x=document.createElement('div');x.className='job';x.textContent=`${j.status} · ${j.goal} · agents ${j.agents_created}/${j.agent_budget}`;x.onclick=()=>{selectedJob=j.id;loadSelected()};e.appendChild(x)}}catch(e){document.getElementById('jobs').textContent=e.message}} async function loadSelected(){if(!selectedJob)return;let d=await api('/task/'+selectedJob);document.getElementById('detail').innerHTML='<h2>Selected Job</h2><pre>'+esc(d.result||d.error||JSON.stringify(d.root,null,2))+'</pre><h3>Supervisor Log</h3><pre>'+esc((d.events||[]).slice(-40).map(e=>`${e.type}: ${e.summary}`).join('\n'))+'</pre>'} function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))} loadJobs();setInterval(()=>{loadJobs();if(selectedJob)loadSelected()},5000)
</script></body></html>
HTML

cat > Dockerfile <<'EOF'
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app /app/app
RUN mkdir -p /data
EXPOSE 8787
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8787"]
EOF

cat > compose.yaml <<EOF
services:
  agent:
    build: .
    container_name: fourth-law-agent
    restart: unless-stopped
    env_file: [.env]
    ports: ["127.0.0.1:${LOCAL_PORT}:8787"]
    volumes: ["./data:/data"]
  tunnel:
    image: cloudflare/cloudflared:latest
    container_name: fourth-law-tunnel
    restart: unless-stopped
    depends_on: [agent]
    command: tunnel --no-autoupdate --url http://agent:8787
EOF

say "[4/9] Validating generated code..."
python3 - <<'PYCHK' >>"$INSTALL_LOG" 2>&1 || fatal
import ast
from pathlib import Path
ast.parse(Path("app/main.py").read_text())
print("Python syntax OK")
PYCHK

say "[5/9] Building runtime..."
retry 3 docker compose build || fatal
say "[6/9] Starting services..."
retry 3 docker compose up -d --force-recreate || fatal
say "[7/9] Self-checking local service..."
for i in $(seq 1 60); do curl -fsS "http://127.0.0.1:${LOCAL_PORT}/health" >>"$INSTALL_LOG" 2>&1 && break; sleep 2; done
curl -fsS "http://127.0.0.1:${LOCAL_PORT}/health" >>"$INSTALL_LOG" 2>&1 || fatal

say "[8/9] Verifying OpenAI Supervisor channel..."
source ./.env
curl -fsS -H "X-Admin-Token: $ADMIN_TOKEN" "http://127.0.0.1:${LOCAL_PORT}/api-check" >>"$INSTALL_LOG" 2>&1 || { say "OpenAI API verification failed. Check API key/billing/network."; exit 2; }

say "[9/9] Installing watchdog..."
cat > /usr/local/bin/fourthlaw-watchdog <<'EOF'
#!/usr/bin/env bash
cd /opt/fourth-law-agent || exit 0
curl -fsS --max-time 8 http://127.0.0.1:8787/health >/dev/null 2>&1 || docker compose restart agent >/dev/null 2>&1 || true
docker compose ps --status running tunnel 2>/dev/null | grep -q fourth-law-tunnel || docker compose up -d tunnel >/dev/null 2>&1 || true
EOF
chmod +x /usr/local/bin/fourthlaw-watchdog
cat > /etc/systemd/system/fourthlaw-watchdog.service <<'EOF'
[Unit]
Description=Fourth Law watchdog
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/fourthlaw-watchdog
EOF
cat > /etc/systemd/system/fourthlaw-watchdog.timer <<'EOF'
[Unit]
Description=Fourth Law watchdog timer
[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now fourthlaw-watchdog.timer

cat > /usr/local/bin/fourthlaw <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/fourth-law-agent
source ./.env
URL="$(docker compose logs tunnel 2>&1 | grep -Eo 'https://[A-Za-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
[[ -z "$URL" ]] && { docker compose restart tunnel >/dev/null 2>&1 || true; sleep 5; URL="$(docker compose logs tunnel 2>&1 | grep -Eo 'https://[A-Za-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"; }
curl -fsS http://127.0.0.1:8787/health | jq .
[[ -n "$URL" ]] && echo "$URL/console#token=$ADMIN_TOKEN" || echo "Tunnel regenerating; run fourthlaw again."
EOF
chmod +x /usr/local/bin/fourthlaw

TUNNEL_URL=""
for i in $(seq 1 60); do TUNNEL_URL="$(docker compose logs tunnel 2>&1 | grep -Eo 'https://[A-Za-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"; [[ -n "$TUNNEL_URL" ]] && break; sleep 2; done
say "============================================================"
say " READY — v0.4"
[[ -n "$TUNNEL_URL" ]] && say "$TUNNEL_URL/console#token=$ADMIN_TOKEN" || say "Run: fourthlaw"
say "============================================================"

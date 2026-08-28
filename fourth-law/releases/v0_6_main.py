import asyncio
import json
import os
import time
import uuid
from pathlib import Path
from typing import Any

from fastapi import BackgroundTasks, FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse
from openai import AsyncOpenAI
from pydantic import BaseModel, Field

app = FastAPI(title="Fourth Law Recursive Control Room", version="0.6.0")
client = AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"])
ADMIN_TOKEN = os.environ["ADMIN_TOKEN"]
SUPERVISOR_MODEL = os.getenv("SUPERVISOR_MODEL", "gpt-5.6-terra")
MASTER_MODEL = os.getenv("MASTER_MODEL", "gpt-5.6-terra")
WORKER_MODEL = os.getenv("WORKER_MODEL", "gpt-5.6-luna")
MAX_CONCURRENCY = max(1, min(16, int(os.getenv("MAX_CONCURRENCY", "8"))))
DEFAULT_MAX_DEPTH = max(1, min(4, int(os.getenv("DEFAULT_MAX_DEPTH", "3"))))
MAX_AGENTS = max(5, min(341, int(os.getenv("MAX_AGENTS", "85"))))
API_RETRIES = max(2, min(6, int(os.getenv("API_RETRIES", "4"))))
NODE_RECOVERY_ATTEMPTS = max(1, min(3, int(os.getenv("NODE_RECOVERY_ATTEMPTS", "2"))))

DATA_DIR = Path("/data")
JOBS_DIR = DATA_DIR / "jobs"
JOBS_DIR.mkdir(parents=True, exist_ok=True)
CONSOLE_PATH = Path("/app/app/static/console.html")
semaphore = asyncio.Semaphore(MAX_CONCURRENCY)
job_locks: dict[str, asyncio.Lock] = {}

CONSTITUTION = """
FOURTH LAW CONTROL CONSTITUTION

Priority 0:
- Never perform illegal, harmful, deceptive, privacy-invasive, or unauthorized actions.
- Preserve human control. Never bypass authentication, authorization, approvals, or safeguards.
- Never expose credentials or secrets in logs, GitHub, or task outputs.
- Consequential external actions require explicit human authorization unless already specifically authorized.
- Be transparent about uncertainty, failures, and material trade-offs.

Fourth Law:
Subject to higher-priority safety and human-control constraints, continuously improve useful efficiency
and contribute to long-term human progress.

Recursive operating rule:
- The root mission MUST be divided into exactly four modules unless max_depth is zero.
- Every non-atomic child agent may deploy exactly four logical sub-agents.
- Every agent uses the same bounded spawn protocol; no agent may create arbitrary host processes or bypass caps.
- Atomic leaf agents perform the actual bounded work and report text results upward.
- Every parent synthesizes exactly four child results into one result and reports upward.
- The Supervisor observes planning, execution, recovery, verification, and synthesis at every level.
- No hidden chain-of-thought is transmitted. Operational summaries only.
"""

class TaskRequest(BaseModel):
    goal: str = Field(min_length=3, max_length=16000)
    context: str = Field(default="", max_length=50000)
    max_depth: int = Field(default=DEFAULT_MAX_DEPTH, ge=1, le=4)

class ContinueRequest(BaseModel):
    instruction: str = Field(min_length=1, max_length=16000)

class DecisionAnswer(BaseModel):
    answer: str = Field(min_length=1, max_length=12000)

def require_auth(x_admin_token: str = Header(default="")):
    if x_admin_token != ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid admin token")

def job_path(job_id: str) -> Path:
    return JOBS_DIR / f"{job_id}.json"

def load_job(job_id: str) -> dict[str, Any]:
    p = job_path(job_id)
    if not p.exists():
        raise HTTPException(status_code=404, detail="Job not found")
    return json.loads(p.read_text())

def write_job(job: dict[str, Any]) -> None:
    p = job_path(job["id"])
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(job, indent=2, ensure_ascii=False))
    tmp.replace(p)

async def persist(job: dict[str, Any]) -> None:
    lock = job_locks.setdefault(job["id"], asyncio.Lock())
    async with lock:
        write_job(job)

async def emit(job: dict[str, Any], event_type: str, summary: str, node: dict | None = None, **extra):
    job.setdefault("events", []).append({
        "ts": time.time(),
        "type": event_type,
        "summary": summary[:5000],
        "node_id": node.get("id") if node else None,
        **extra,
    })
    if len(job["events"]) > 2000:
        job["events"] = job["events"][-2000:]
    await persist(job)

def flatten_nodes(node: dict[str, Any]) -> list[dict[str, Any]]:
    rows = [node]
    for c in node.get("children", []):
        rows.extend(flatten_nodes(c))
    return rows

def parse_json_object(text: str) -> dict[str, Any]:
    text = text.strip()
    if text.startswith("```"):
        text = text.replace("```json", "", 1).replace("```", "").strip()
    a, b = text.find("{"), text.rfind("}")
    if a < 0 or b <= a:
        raise ValueError("No JSON object found")
    return json.loads(text[a:b+1])

async def raw_response(model: str, instructions: str, input_text: str, max_output_tokens: int = 2200) -> str:
    last_error = None
    for attempt in range(1, API_RETRIES + 1):
        try:
            async with semaphore:
                r = await client.responses.create(
                    model=model,
                    instructions=instructions,
                    input=input_text,
                    reasoning={"effort": "low"},
                    text={"verbosity": "low"},
                    max_output_tokens=max_output_tokens,
                    store=False,
                )
            out = (r.output_text or "").strip()
            if not out:
                raise RuntimeError("Empty model response")
            return out
        except Exception as exc:
            last_error = exc
            if attempt < API_RETRIES:
                await asyncio.sleep(min(12, 2 ** (attempt - 1)))
    raise RuntimeError(f"OpenAI API failed after retries: {last_error}")

async def create_human_decision(job: dict, node: dict, question: str, reason: str) -> str:
    did = uuid.uuid4().hex[:12]
    job.setdefault("decisions", []).append({
        "id": did, "node_id": node["id"], "question": question[:8000], "reason": reason[:8000],
        "status": "pending", "answer": "", "created_at": time.time(),
    })
    node["status"] = "waiting_human"
    await emit(job, "human_decision", question, node=node, decision_id=did)
    return did

async def wait_for_decision(job: dict, node: dict, decision_id: str) -> str:
    while True:
        for d in job.get("decisions", []):
            if d["id"] == decision_id and d.get("status") == "answered":
                node["status"] = "running"
                await persist(job)
                return d.get("answer", "")
        await asyncio.sleep(3)

async def supervisor_consult(job: dict, node: dict, stage: str, context: str, candidate: str = "", issue: str = "") -> dict:
    state = {
        "stage": stage,
        "node": {"id": node["id"], "name": node["name"], "role": node["role"], "depth": node["depth"], "goal": node["goal"], "status": node["status"]},
        "context": context[-14000:], "candidate": candidate[-14000:], "issue": issue[-8000:],
        "agent_count": job.get("agents_created", 1), "agent_budget": job.get("agent_budget", MAX_AGENTS),
    }
    prompt = f"""{CONSTITUTION}
Review this operational state:
{json.dumps(state, ensure_ascii=False)}
Return ONLY JSON:
{{
 "summary":"brief assessment",
 "guidance":"specific next step",
 "risk":"low|medium|high",
 "verify":"what must be verified",
 "needs_human":false,
 "question":"",
 "reason":""
}}
Set needs_human=true only when a required secret/permission is missing, a consequential external action needs approval,
or the task is genuinely ambiguous in a way that materially changes the outcome."""
    try:
        txt = await raw_response(SUPERVISOR_MODEL, "You are the mandatory system Supervisor.", prompt, 1300)
        result = parse_json_object(txt)
    except Exception as exc:
        result = {"summary":"Supervisor API fallback","guidance":"Continue with safest bounded local action only.","risk":"medium","verify":"Verify locally and report uncertainty.","needs_human":False,"question":"","reason":str(exc)}
    await emit(job, "supervisor", f"{stage}: {result.get('summary','')}", node=node)
    if result.get("needs_human") and result.get("question"):
        did = await create_human_decision(job, node, str(result["question"]), str(result.get("reason","")))
        answer = await wait_for_decision(job, node, did)
        result["human_answer"] = answer
        result["guidance"] = f"{result.get('guidance','')}\nHuman answer: {answer}"
    return result

def fallback_four(goal: str) -> list[dict]:
    return [
        {"name":"Evidence","role":"Evidence & Research","goal":f"Collect and analyze the strongest evidence needed for: {goal}"},
        {"name":"Build","role":"Systems & Execution","goal":f"Develop the implementation/solution path for: {goal}"},
        {"name":"Challenge","role":"Adversarial Review","goal":f"Find failure modes, counterarguments, risks, and missing assumptions for: {goal}"},
        {"name":"Validate","role":"Validation & Integration","goal":f"Define validation criteria and integrate implications for: {goal}"},
    ]

async def plan_four(job: dict, node: dict, context: str, guidance: dict, force_split: bool) -> tuple[bool, list[dict]]:
    if node["depth"] >= job["max_depth"] or job["agents_created"] + 4 > job["agent_budget"]:
        return True, []
    prompt = f"""{CONSTITUTION}
Parent goal: {node['goal']}
Parent role: {node['role']}
Depth: {node['depth']} of maximum {job['max_depth']}
Context: {context[-16000:]}
Supervisor guidance: {json.dumps(guidance, ensure_ascii=False)}
Determine whether this node is atomic enough to execute directly.
{"This is the ROOT mission, so atomic MUST be false and it MUST split into exactly four complementary modules." if force_split else ""}
If non-atomic, return exactly four non-overlapping child modules whose combined results are sufficient for the parent.
Return ONLY JSON:
{{"atomic":false,"reason":"...","children":[
{{"name":"short name","role":"specialist role","goal":"specific bounded subtask"}},
{{"name":"short name","role":"specialist role","goal":"specific bounded subtask"}},
{{"name":"short name","role":"specialist role","goal":"specific bounded subtask"}},
{{"name":"short name","role":"specialist role","goal":"specific bounded subtask"}}]}}"""
    try:
        data = parse_json_object(await raw_response(MASTER_MODEL, "Decompose work into an exact four-way recursive hierarchy.", prompt, 2200))
        atomic = bool(data.get("atomic"))
        children = data.get("children") if isinstance(data.get("children"), list) else []
        if force_split: atomic = False
        if not atomic and len(children) != 4: children = fallback_four(node["goal"])
        return atomic, children[:4]
    except Exception as exc:
        await emit(job, "planning_recovery", f"Planner fallback: {exc}", node=node)
        return False, fallback_four(node["goal"])

async def execute_leaf(job: dict, node: dict, context: str, guidance: dict) -> str:
    recovery = ""
    for _ in range(NODE_RECOVERY_ATTEMPTS + 1):
        try:
            prompt = f"""{CONSTITUTION}
You are an atomic leaf agent.
Role: {node['role']}
Goal: {node['goal']}
Context: {context[-22000:]}
Supervisor guidance: {json.dumps(guidance, ensure_ascii=False)}
Recovery instruction: {recovery}
Do the assigned bounded work. Return a useful TEXT result, with evidence/assumptions/uncertainty where relevant.
Do not create more sub-agents; this node has been classified atomic."""
            result = await raw_response(WORKER_MODEL, "Complete the atomic assigned task.", prompt, 3600)
            verification = await supervisor_consult(job, node, "leaf_verification", context, candidate=result)
            check_prompt = f"""Goal: {node['goal']}
Result: {result[-18000:]}
Verification criteria: {verification.get('verify','')}
Return ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction"}}"""
            chk = parse_json_object(await raw_response(SUPERVISOR_MODEL, "Strictly verify task completion.", check_prompt, 800))
            if chk.get("verdict") == "pass": return result
            recovery = str(chk.get("revision") or "Correct material deficiencies.")
            await emit(job, "recovery", recovery, node=node)
        except Exception as exc:
            await emit(job, "error", str(exc), node=node)
            sup = await supervisor_consult(job, node, "leaf_error_recovery", context, issue=str(exc))
            recovery = str(sup.get("guidance") or "Retry safely.")
    raise RuntimeError("Leaf failed after bounded recovery attempts")

async def synthesize_parent(job: dict, node: dict, context: str, child_results: list[str]) -> str:
    candidate = "\n\n".join(f"CHILD {i+1}: {r[-9000:]}" for i,r in enumerate(child_results))
    guidance = await supervisor_consult(job, node, "pre_synthesis", context, candidate=candidate)
    reports = "\n".join(f"--- CHILD {i+1} ---\n{r[-12000:]}" for i,r in enumerate(child_results))
    prompt = f"""{CONSTITUTION}
Parent role: {node['role']}
Parent goal: {node['goal']}
Supervisor guidance: {json.dumps(guidance, ensure_ascii=False)}
You have exactly four child reports:
{reports}
Synthesize them into one coherent TEXT result that answers the parent goal.
Resolve conflicts explicitly, preserve important evidence and uncertainty, and do not invent missing facts."""
    result = await raw_response(MASTER_MODEL, "Synthesize four child reports into the parent result.", prompt, 4200)
    await supervisor_consult(job, node, "post_synthesis_verification", context, candidate=result)
    return result

async def run_node(job: dict, node: dict, context: str, force_split: bool = False) -> str:
    node["status"]="running"; node["started_at"]=time.time()
    await emit(job,"node_start",f"{node['name']} started",node=node)
    sup=await supervisor_consult(job,node,"pre_plan",context)
    atomic,specs=await plan_four(job,node,context,sup,force_split)
    if atomic:
        node["mode"]="leaf"; await emit(job,"leaf","Classified atomic; executing directly",node=node)
        try:
            result=await execute_leaf(job,node,context,sup)
            node["result"]=result; node["status"]="completed"; node["completed_at"]=time.time()
            await emit(job,"node_complete","Leaf completed",node=node); return result
        except Exception as exc:
            node["status"]="failed"; node["error"]=str(exc)
            await emit(job,"node_failed",str(exc),node=node)
            return f"[FAILED LEAF] {node['goal']}\n{exc}"
    node["mode"]="decompose"; node["children"]=[]
    for i,spec in enumerate(specs,start=1):
        child={"id":uuid.uuid4().hex[:12],"name":str(spec.get("name") or f"Module {i}")[:120],"role":str(spec.get("role") or f"Module Agent {i}")[:240],
               "goal":str(spec.get("goal") or f"Handle module {i} of {node['goal']}")[:16000],"depth":node["depth"]+1,"status":"queued","mode":"","children":[],"result":"","error":""}
        node["children"].append(child); job["agents_created"]+=1
    await emit(job,"spawn",f"Deployed exactly 4 child agents at depth {node['depth']+1}",node=node)
    child_context=f"{context}\n\nPARENT GOAL: {node['goal']}"
    results=await asyncio.gather(*(run_node(job,c,child_context,False) for c in node["children"]))
    result=await synthesize_parent(job,node,context,list(results))
    node["result"]=result; node["status"]="completed"; node["completed_at"]=time.time()
    await emit(job,"node_complete","Four child results synthesized",node=node); return result

async def run_job(job_id: str):
    job=load_job(job_id)
    try:
        job["status"]="running"; await persist(job)
        result=await run_node(job,job["root"],job.get("context",""),True)
        job["result"]=result; job["status"]="completed"; job["completed_at"]=time.time()
        await emit(job,"job_complete","Mission completed and synthesized to root")
    except Exception as exc:
        job["status"]="failed"; job["error"]=str(exc); job["completed_at"]=time.time()
        await emit(job,"job_failed",str(exc))

@app.get("/health")
async def health():
    return {"ok":True,"version":"0.6.0","architecture":"recursive-exact-four-way","supervisor_model":SUPERVISOR_MODEL,"master_model":MASTER_MODEL,
            "worker_model":WORKER_MODEL,"default_max_depth":DEFAULT_MAX_DEPTH,"max_agents":MAX_AGENTS}

@app.get("/api-check")
async def api_check(x_admin_token: str = Header(default="")):
    require_auth(x_admin_token)
    txt=await raw_response(SUPERVISOR_MODEL,"Connectivity check.","Reply exactly FOURTHLAW_API_OK",64)
    return {"ok":"FOURTHLAW_API_OK" in txt,"model":SUPERVISOR_MODEL,"reply":txt[:120]}

@app.post("/task")
async def create_task(req: TaskRequest, background_tasks: BackgroundTasks, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token)
    jid=uuid.uuid4().hex[:14]
    root={"id":uuid.uuid4().hex[:12],"name":"Master Mission","role":"Root Orchestrator","goal":req.goal,"depth":0,"status":"queued","mode":"","children":[],"result":"","error":""}
    job={"id":jid,"goal":req.goal,"context":req.context,"max_depth":req.max_depth,
         "agent_budget":min(MAX_AGENTS,sum(4**i for i in range(req.max_depth+1))),"agents_created":1,"status":"queued","created_at":time.time(),
         "completed_at":None,"result":"","error":"","root":root,"decisions":[],"events":[]}
    write_job(job); background_tasks.add_task(run_job,jid)
    return {"ok":True,"job_id":jid,"status":"queued","agent_budget":job["agent_budget"]}

@app.get("/task/{job_id}")
async def get_task(job_id: str, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token); return load_job(job_id)

@app.get("/task/{job_id}/result")
async def get_result(job_id: str, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token); j=load_job(job_id)
    return {"id":job_id,"status":j["status"],"result":j.get("result",""),"error":j.get("error","")}

@app.post("/task/{job_id}/continue")
async def continue_task(job_id: str, req: ContinueRequest, background_tasks: BackgroundTasks, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token); parent=load_job(job_id)
    new_req=TaskRequest(goal=req.instruction,context=f"Previous mission: {parent.get('goal','')}\nPrevious result:\n{parent.get('result','')[-30000:]}",
                        max_depth=parent.get("max_depth",DEFAULT_MAX_DEPTH))
    return await create_task(new_req,background_tasks,x_admin_token)

@app.post("/decisions/{decision_id}/answer")
async def answer_decision(decision_id: str, req: DecisionAnswer, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token)
    for p in JOBS_DIR.glob("*.json"):
        try:
            j=json.loads(p.read_text())
            for d in j.get("decisions",[]):
                if d.get("id")==decision_id:
                    d["status"]="answered"; d["answer"]=req.answer; d["answered_at"]=time.time(); write_job(j)
                    return {"ok":True,"decision_id":decision_id}
        except Exception: continue
    raise HTTPException(status_code=404,detail="Decision not found")

@app.get("/jobs")
async def jobs(x_admin_token: str = Header(default="")):
    require_auth(x_admin_token); out=[]
    for p in JOBS_DIR.glob("*.json"):
        try:
            j=json.loads(p.read_text())
            out.append({"id":j["id"],"goal":j["goal"],"status":j["status"],"created_at":j["created_at"],"completed_at":j.get("completed_at"),
                        "agents_created":j.get("agents_created",1),"agent_budget":j.get("agent_budget"),"max_depth":j.get("max_depth")})
        except Exception: pass
    out.sort(key=lambda x:x["created_at"],reverse=True); return out[:100]

@app.get("/control-state")
async def control_state(x_admin_token: str = Header(default="")):
    require_auth(x_admin_token); js=await jobs(x_admin_token); pending=[]; active_nodes=0
    for row in js[:25]:
        try:
            j=load_job(row["id"]); active_nodes+=sum(1 for n in flatten_nodes(j["root"]) if n.get("status") in {"queued","running","waiting_human"})
            pending.extend([{**d,"job_id":j["id"],"job_goal":j["goal"]} for d in j.get("decisions",[]) if d.get("status")=="pending"])
        except Exception: pass
    return {"version":"0.6.0","supervisor":{"status":"ready" if active_nodes==0 else "monitoring","model":SUPERVISOR_MODEL},
            "architecture":{"branching_factor":4,"default_max_depth":DEFAULT_MAX_DEPTH,"max_agents":MAX_AGENTS,"spawn_mode":"logical-on-demand","recursive":True},
            "active_nodes":active_nodes,"pending_decisions":pending,"jobs":js}

@app.get("/console", response_class=HTMLResponse)
async def console():
    return HTMLResponse(CONSOLE_PATH.read_text())

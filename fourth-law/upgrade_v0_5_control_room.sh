#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="/opt/fourth-law-agent"
CONTROL_DIR="/opt/fourth-law-control"
LOG="/var/log/fourthlaw-control-upgrade.log"
REPO="Tarun1303/factory"
ISSUE="7"
mkdir -p "$CONTROL_DIR/app" "$CONTROL_DIR/data"
touch "$LOG" && chmod 600 "$LOG"
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi
if [[ ! -f "$PROJECT_DIR/.env" ]]; then echo "FOURTHLAW_BASE_NOT_FOUND"; exit 1; fi
cd "$PROJECT_DIR"
API_KEY="$(grep '^OPENAI_API_KEY=' .env | head -1 | cut -d= -f2-)"
ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
[[ -n "$API_KEY" && -n "$ADMIN_TOKEN" ]] || { echo "FOURTHLAW_ENV_MISSING"; exit 1; }
cat > "$CONTROL_DIR/.env" <<EOF
OPENAI_API_KEY=$API_KEY
ADMIN_TOKEN=$ADMIN_TOKEN
SUPERVISOR_MODEL=gpt-5.6-terra
WORKER_MODEL=gpt-5.6-luna
EOF
chmod 600 "$CONTROL_DIR/.env"
cat > "$CONTROL_DIR/requirements.txt" <<'EOF'
fastapi>=0.115
uvicorn[standard]>=0.30
openai>=1.40
pydantic>=2.7
EOF
cat > "$CONTROL_DIR/Dockerfile" <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8790"]
EOF
cat > "$CONTROL_DIR/app/main.py" <<'PY'
import asyncio, json, os, time, uuid
from pathlib import Path
from typing import Any
from fastapi import BackgroundTasks, FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse
from openai import AsyncOpenAI
from pydantic import BaseModel, Field

app=FastAPI(title="Fourth Law Control Room",version="0.5.0")
client=AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"])
TOKEN=os.environ["ADMIN_TOKEN"]
SUP=os.getenv("SUPERVISOR_MODEL","gpt-5.6-terra")
WORK=os.getenv("WORKER_MODEL","gpt-5.6-luna")
DATA=Path("/data"); DATA.mkdir(exist_ok=True)
STATE_FILE=DATA/"state.json"
LOCK=asyncio.Lock()
AGENT_DEFS={
 "research":{"name":"Research & Evidence","mission":"Find evidence, assumptions, benchmarks, prior art and falsifiable claims."},
 "systems":{"name":"Systems & Engineering","mission":"Turn ideas into bounded architecture, implementation plans, tests and measurable system behavior."},
 "adversarial":{"name":"Adversarial Reviewer","mission":"Attack assumptions, find failure modes, contradictions, edge cases and unsafe optimization paths."},
 "governance":{"name":"Human Progress & Governance","mission":"Evaluate human control, long-term benefit, governance, incentives and philosophical consistency."}
}
CONSTITUTION="""Priority 0: obey law, authorization, safety and privacy constraints; preserve human control; never bypass safeguards; never expose secrets; never claim external action without evidence. Fourth-Law project principle: subject to higher-priority constraints, maximize useful efficiency and long-term human progress. Use concise operational state, not hidden chain-of-thought. Ask a human only when a real decision or missing authorization blocks safe progress."""

def base_state():
 return {"version":"0.5.0","supervisor":{"status":"idle","current":""},"agents":{k:{"name":v["name"],"status":"idle","current":"","last":""} for k,v in AGENT_DEFS.items()},"missions":{},"decisions":{},"updated":time.time()}

def load():
 try:
  s=json.loads(STATE_FILE.read_text())
 except Exception: s=base_state()
 for k,v in AGENT_DEFS.items(): s.setdefault("agents",{}).setdefault(k,{"name":v["name"],"status":"idle","current":"","last":""})
 s.setdefault("missions",{}); s.setdefault("decisions",{}); s.setdefault("supervisor",{"status":"idle","current":""})
 return s

def save(s):
 s["updated"]=time.time(); tmp=STATE_FILE.with_suffix(".tmp"); tmp.write_text(json.dumps(s,ensure_ascii=False,indent=2)); tmp.replace(STATE_FILE)

def auth(x_admin_token:str=Header(default="")):
 if x_admin_token!=TOKEN: raise HTTPException(401,"Invalid token")

async def ask(model,instructions,text,max_tokens=2200):
 last=None
 for i in range(4):
  try:
   r=await client.responses.create(model=model,instructions=instructions,input=text,reasoning={"effort":"low"},text={"verbosity":"low"},max_output_tokens=max_tokens,store=False)
   out=(r.output_text or "").strip()
   if out:return out
   raise RuntimeError("empty response")
  except Exception as e:
   last=e; await asyncio.sleep(min(8,2**i))
 raise RuntimeError(str(last))

def obj(txt):
 a=txt.find("{"); b=txt.rfind("}")
 if a<0 or b<a: raise ValueError("json expected")
 return json.loads(txt[a:b+1])

async def set_agent(k,**kw):
 async with LOCK:
  s=load(); s["agents"][k].update(kw); save(s)

async def create_decision(mid,agent,question,options):
 did=str(uuid.uuid4())[:8]
 async with LOCK:
  s=load(); s["decisions"][did]={"id":did,"mission_id":mid,"agent":agent,"question":question,"options":options,"status":"pending","answer":"","created":time.time()}; s["missions"][mid]["status"]="waiting_human"; save(s)
 return did

async def wait_decision(did):
 while True:
  await asyncio.sleep(2)
  d=load()["decisions"].get(did,{})
  if d.get("status")=="answered": return d.get("answer","")

async def consult(mid,k,goal,context):
 p=f'''{CONSTITUTION}\nYou are Supervisor. Fixed agent: {AGENT_DEFS[k]["name"]}.\nGoal: {goal}\nContext: {context[-12000:]}\nReturn ONLY JSON: {{"guidance":"...","needs_human":false,"question":"","options":[]}}. needs_human=true only when progress is genuinely blocked by a human decision/authorization.'''
 try: return obj(await ask(SUP,"Supervise a bounded specialist agent.",p,1000))
 except Exception as e: return {"guidance":"Proceed conservatively and state uncertainty.","needs_human":False,"question":"","options":[],"error":str(e)}

async def run_agent(mid,k,goal,context):
 await set_agent(k,status="consulting",current=goal)
 g=await consult(mid,k,goal,context)
 if g.get("needs_human"):
  await set_agent(k,status="waiting_human")
  did=await create_decision(mid,k,str(g.get("question") or "Human decision required"),g.get("options") or [])
  ans=await wait_decision(did)
  g["human_answer"]=ans
  async with LOCK:
   s=load(); s["missions"][mid]["status"]="running"; save(s)
 await set_agent(k,status="running")
 prompt=f'''{CONSTITUTION}\nROLE: {AGENT_DEFS[k]["name"]}\nMANDATE: {AGENT_DEFS[k]["mission"]}\nSUPERVISOR GUIDANCE: {json.dumps(g,ensure_ascii=False)}\nMISSION: {goal}\nCONTEXT: {context[-16000:]}\nProduce a concise, evidence-aware result. Include uncertainties and a short handoff to the Supervisor.'''
 out=await ask(WORK,"Act only in the assigned fixed specialist role.",prompt,3000)
 await set_agent(k,status="idle",current="",last=out[:1200])
 return out

async def run_mission(mid):
 async with LOCK:
  s=load(); m=s["missions"][mid]; m["status"]="running"; s["supervisor"]={"status":"planning","current":m["goal"]}; save(s)
 goal=m["goal"]; context=m.get("context","")
 try:
  tasks=[run_agent(mid,k,goal,context) for k in AGENT_DEFS]
  outs=await asyncio.gather(*tasks,return_exceptions=True)
  results={}
  for k,o in zip(AGENT_DEFS,outs): results[k]=f"ERROR: {o}" if isinstance(o,Exception) else o
  async with LOCK:
   s=load(); s["supervisor"]={"status":"synthesizing","current":goal}; save(s)
  synth=f'''{CONSTITUTION}\nYou are the Master/Supervisor. Synthesize the four fixed-agent reports into one decision-quality mission result. Identify agreements, conflicts, unresolved questions, recommended next steps, and measurable success criteria.\nMISSION:{goal}\nREPORTS:{json.dumps(results,ensure_ascii=False)[:50000]}'''
  final=await ask(SUP,"Synthesize fixed specialist-agent work.",synth,4200)
  async with LOCK:
   s=load(); m=s["missions"][mid]; m.update({"status":"completed","results":results,"final":final,"completed":time.time()}); s["supervisor"]={"status":"idle","current":""}; save(s)
 except Exception as e:
  async with LOCK:
   s=load(); s["missions"][mid]["status"]="failed"; s["missions"][mid]["error"]=str(e); s["supervisor"]={"status":"idle","current":""}; save(s)
  for k in AGENT_DEFS: await set_agent(k,status="idle",current="")

class Mission(BaseModel):
 goal:str=Field(min_length=3,max_length=12000); context:str=Field(default="",max_length=30000)
class Answer(BaseModel): answer:str=Field(min_length=1,max_length=12000)
class BridgeCommand(BaseModel): command:str; payload:dict[str,Any]={}

@app.on_event("startup")
async def startup():
 s=load()
 for a in s["agents"].values():
  if a.get("status") not in {"idle","waiting_human"}: a["status"]="idle"; a["current"]=""
 if s["supervisor"].get("status")!="idle": s["supervisor"]={"status":"idle","current":""}
 save(s)

@app.get("/health")
def health(): return {"ok":True,"version":"0.5.0","fixed_agents":4,"bridge":"github"}
@app.get("/api/state")
def state(_:None=__import__('fastapi').Depends(auth)): return load()
@app.post("/api/mission")
async def mission(req:Mission,bg:BackgroundTasks,_:None=__import__('fastapi').Depends(auth)):
 mid=str(uuid.uuid4())[:8]
 async with LOCK:
  s=load(); s["missions"][mid]={"id":mid,"goal":req.goal,"context":req.context,"status":"queued","created":time.time(),"final":""}; save(s)
 bg.add_task(run_mission,mid); return {"ok":True,"mission_id":mid}
@app.post("/api/decision/{did}/answer")
async def answer(did:str,req:Answer,_:None=__import__('fastapi').Depends(auth)):
 async with LOCK:
  s=load(); d=s["decisions"].get(did)
  if not d: raise HTTPException(404,"decision not found")
  d["answer"]=req.answer; d["status"]="answered"; d["answered"]=time.time(); save(s)
 return {"ok":True}
@app.get("/bridge/status")
def bridge_status(_:None=__import__('fastapi').Depends(auth)):
 s=load(); pending=[d for d in s["decisions"].values() if d.get("status")=="pending"]
 active=[{"id":m["id"],"goal":m["goal"],"status":m["status"]} for m in s["missions"].values() if m.get("status") in {"queued","running","waiting_human"}]
 return {"pending_decisions":pending,"active_missions":active,"agents":s["agents"],"supervisor":s["supervisor"]}
@app.post("/bridge/command")
async def bridge_command(c:BridgeCommand,bg:BackgroundTasks,_:None=__import__('fastapi').Depends(auth)):
 if c.command=="answer_decision":
  did=str(c.payload.get("decision_id","")); ans=str(c.payload.get("answer",""))
  if not did or not ans: raise HTTPException(400,"decision_id and answer required")
  return await answer(did,Answer(answer=ans),None)
 if c.command=="submit_mission": return await mission(Mission(goal=str(c.payload.get("goal","")),context=str(c.payload.get("context",""))),bg,None)
 raise HTTPException(400,"unsupported command")

UI='''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Fourth Law Control Room</title><style>body{font-family:Inter,system-ui;background:#0b0d10;color:#eef2f7;margin:0}main{max-width:1200px;margin:auto;padding:24px}.top{display:flex;justify-content:space-between;align-items:center}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px}.card{background:#151920;border:1px solid #2b313a;border-radius:16px;padding:16px}.idle{color:#7ee787}.running,.planning,.synthesizing{color:#58a6ff}.waiting_human{color:#f2cc60}textarea,input{width:100%;box-sizing:border-box;background:#0d1117;color:white;border:1px solid #30363d;border-radius:10px;padding:10px;margin:6px 0}button{background:#238636;color:white;border:0;border-radius:10px;padding:10px 16px;cursor:pointer}.small{font-size:12px;color:#9aa4af;white-space:pre-wrap}.mission{margin-top:10px}.decision{border-color:#7d651b}h1{margin:0 0 4px}h2{margin-top:28px}</style></head><body><main><div class="top"><div><h1>Fourth Law Control Room</h1><div class="small">Supervisor + 4 fixed agents + GitHub decision bridge</div></div><div id="sup"></div></div><h2>Agents</h2><div class="grid" id="agents"></div><h2>New Mission</h2><div class="card"><textarea id="goal" rows="3" placeholder="Give the Master/Supervisor a mission..."></textarea><textarea id="ctx" rows="2" placeholder="Optional context"></textarea><button onclick="submitMission()">Start mission</button></div><h2>Human Decisions</h2><div id="decisions"></div><h2>Missions</h2><div id="missions"></div></main><script>let token=localStorage.fl_token||'';if(location.hash.startsWith('#token=')){token=decodeURIComponent(location.hash.slice(7));localStorage.fl_token=token;history.replaceState(null,'',location.pathname)}if(!token){token=prompt('Admin token');localStorage.fl_token=token||''}const H=()=>({'X-Admin-Token':token,'Content-Type':'application/json'});async function load(){let r=await fetch('/api/state',{headers:H()});if(!r.ok)return;let s=await r.json();sup.innerHTML='Supervisor: <b class="'+s.supervisor.status+'">'+s.supervisor.status+'</b>';agents.innerHTML=Object.entries(s.agents).map(([k,a])=>'<div class="card"><b>'+a.name+'</b><div class="'+a.status+'">'+a.status+'</div><div class="small">'+(a.current||a.last||'Ready for command')+'</div></div>').join('');let ds=Object.values(s.decisions).filter(d=>d.status==='pending');decisions.innerHTML=ds.length?ds.map(d=>'<div class="card decision"><b>'+d.agent+'</b><div>'+d.question+'</div><div class="small">'+(d.options||[]).join(' | ')+'</div><input id="a_'+d.id+'" placeholder="Your decision"><button onclick="ans(\''+d.id+'\')">Answer</button></div>').join(''):'<div class="small">No pending decisions.</div>';missions.innerHTML=Object.values(s.missions).sort((a,b)=>b.created-a.created).map(m=>'<div class="card mission"><b>'+m.goal+'</b> — <span class="'+m.status+'">'+m.status+'</span><div class="small">'+(m.final||m.error||'')+'</div></div>').join('')}async function submitMission(){await fetch('/api/mission',{method:'POST',headers:H(),body:JSON.stringify({goal:goal.value,context:ctx.value})});goal.value='';ctx.value='';load()}async function ans(id){let v=document.getElementById('a_'+id).value;await fetch('/api/decision/'+id+'/answer',{method:'POST',headers:H(),body:JSON.stringify({answer:v})});load()}setInterval(load,2500);load()</script></body></html>'''
@app.get("/",response_class=HTMLResponse)
def ui(): return UI
PY
cat > "$CONTROL_DIR/compose.yaml" <<'EOF'
services:
  control:
    build: .
    container_name: fourth-law-control
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:8790:8790"
  tunnel:
    image: cloudflare/cloudflared:latest
    container_name: fourth-law-control-tunnel
    restart: unless-stopped
    depends_on:
      - control
    command: tunnel --no-autoupdate --url http://control:8790
EOF
cd "$CONTROL_DIR"
docker compose up -d --build --force-recreate >>"$LOG" 2>&1
for i in $(seq 1 30); do curl -fsS http://127.0.0.1:8790/health >/dev/null 2>&1 && break; sleep 2; done
curl -fsS http://127.0.0.1:8790/health >/dev/null || { echo "CONTROL_ROOM_START_FAILED"; exit 1; }
cat > /usr/local/bin/fourthlaw-bridge <<'BRIDGE'
#!/usr/bin/env bash
set -u
REPO="Tarun1303/factory"; ISSUE="7"; DIR="/var/lib/fourthlaw-bridge"; mkdir -p "$DIR"
TOKEN="$(grep '^ADMIN_TOKEN=' /opt/fourth-law-control/.env | cut -d= -f2-)"
LAST="$DIR/last_comment"; [[ -f "$LAST" ]] || echo 0 > "$LAST"
STATEHASH="$DIR/statehash"; [[ -f "$STATEHASH" ]] || : > "$STATEHASH"
while true; do
  S="$(curl -fsS -H "X-Admin-Token: $TOKEN" http://127.0.0.1:8790/bridge/status 2>/dev/null || true)"
  if [[ -n "$S" ]]; then
    H="$(printf '%s' "$S" | sha256sum | cut -d' ' -f1)"; OLD="$(cat "$STATEHASH" 2>/dev/null || true)"
    if [[ "$H" != "$OLD" ]]; then
      printf '%s' "$H" > "$STATEHASH"
      gh issue comment "$ISSUE" --repo "$REPO" --body "SERVER_STATE $(date -Is)\n\n\`\`\`json\n$S\n\`\`\`" >/dev/null 2>&1 || true
    fi
  fi
  L="$(cat "$LAST")"
  gh api "repos/$REPO/issues/$ISSUE/comments?per_page=100" 2>/dev/null | jq -c --argjson l "$L" '.[]|select(.id>$l and (.body|startswith("CHATGPT_COMMAND ")))|{id,body}' | while read -r row; do
    id="$(jq -r .id <<<"$row")"; body="$(jq -r .body <<<"$row")"; payload="${body#CHATGPT_COMMAND }"
    curl -fsS -X POST -H "X-Admin-Token: $TOKEN" -H 'Content-Type: application/json' --data "$payload" http://127.0.0.1:8790/bridge/command >/dev/null 2>&1 || true
    echo "$id" > "$LAST"
  done
  sleep 15
done
BRIDGE
chmod +x /usr/local/bin/fourthlaw-bridge
cat > /etc/systemd/system/fourthlaw-bridge.service <<'EOF'
[Unit]
Description=Fourth Law GitHub command bridge
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/fourthlaw-bridge
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now fourthlaw-bridge.service >>"$LOG" 2>&1 || true
URL=""
for i in $(seq 1 30); do URL="$(docker compose logs tunnel 2>&1 | grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -1 || true)"; [[ -n "$URL" ]] && break; sleep 2; done
cat > /usr/local/bin/fourthlaw-control <<'EOF'
#!/usr/bin/env bash
cd /opt/fourth-law-control
TOKEN="$(grep '^ADMIN_TOKEN=' .env | cut -d= -f2-)"
URL="$(docker compose logs tunnel 2>&1 | grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -1)"
echo "$URL/#token=$TOKEN"
EOF
chmod +x /usr/local/bin/fourthlaw-control
/usr/local/bin/fourthlaw-diagnostic-sync >/dev/null 2>&1 || true
if [[ -n "$URL" ]]; then echo "FOURTHLAW_CONTROL_ROOM_READY"; echo "$URL/#token=$ADMIN_TOKEN"; else echo "FOURTHLAW_CONTROL_ROOM_READY_LOCAL"; echo "Run: fourthlaw-control"; fi

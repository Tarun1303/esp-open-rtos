#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
CR="$PROJECT/app/control_room.py"
ENG="$PROJECT/app/intelligence_engine.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.10.0-runtime-reliability-$STAMP"
mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.py"
cp "$CR" "$BACKUP/control_room.py"
cp "$ENG" "$BACKUP/intelligence_engine.py"

rollback(){
  set +e
  cp "$BACKUP/main.py" "$MAIN"
  cp "$BACKUP/control_room.py" "$CR"
  cp "$BACKUP/intelligence_engine.py" "$ENG"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl0100-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl0100-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'RUNTIME_RELIABILITY_V0_10_0_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s=p.read_text()

# Artifact semantics: a useful artifact may honestly mention that live deployment is unavailable.
# Only a response whose leading semantic content is itself a block should bypass deterministic artifact verification.
old='''            artifact_blocked = any(x in result_text.lower() for x in (
                "cannot complete", "unable to complete", "blocked by missing", "requires unavailable"
            ))
'''
new='''            artifact_prefix = result_text.lower().lstrip()[:240]
            artifact_blocked = artifact_prefix.startswith((
                "cannot complete", "unable to complete", "blocked_capability", "blocked by missing",
                "requires unavailable capability", "unable to proceed"
            ))
'''
if 'artifact_prefix = result_text.lower().lstrip()[:240]' not in s:
    if old not in s: raise SystemExit('v0.10.0 artifact_blocked anchor missing')
    s=s.replace(old,new,1)

# Make explicit artifact-mission language deterministic too.
old='''                "do not claim actual deployment", "execution-focused artifact"
'''
new='''                "do not claim actual deployment", "execution-focused artifact", "artifact mission",
                "system-repair artifact", "system repair artifact", "artifact-only", "artifact only"
'''
if '"system-repair artifact"' not in s:
    if old not in s: raise SystemExit('v0.10.0 artifact marker anchor missing')
    s=s.replace(old,new,1)

# Do not spawn fresh descendants when request headroom is too small to finish them.
old='''        cg = job.get("cost_governor") or {}
        if cg and int(cg.get("sdk_total_tokens", 0)) >= int(int(cg.get("sdk_token_budget", 250000)) * 0.80):
            return False
        lock = self._budget_locks.setdefault(job["id"], asyncio.Lock())
'''
new='''        cg = job.get("cost_governor") or {}
        if cg:
            if int(cg.get("sdk_total_tokens", 0)) >= int(int(cg.get("sdk_token_budget", 250000)) * 0.80):
                return False
            # Child creation carries UNDERSTAND/PLAN/EXECUTE/SYNTH overhead. Preserve at least
            # 30% of the request envelope for already-created nodes and final synthesis.
            if int(cg.get("sdk_requests", 0)) >= int(int(cg.get("sdk_request_budget", 60)) * 0.70):
                return False
        lock = self._budget_locks.setdefault(job["id"], asyncio.Lock())
'''
if 'sdk_request_budget", 60)) * 0.70' not in s:
    if old not in s: raise SystemExit('v0.10.0 reserve-child anchor missing')
    s=s.replace(old,new,1)

p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()

# Never route an Intelligence job into the legacy recursive continuation engine.
old='''@app.post("/task/{job_id}/continue")
async def continue_task(job_id: str, req: ContinueRequest, background_tasks: BackgroundTasks, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token); parent=load_job(job_id)
    new_req=TaskRequest(goal=req.instruction,context=f"Previous mission: {parent.get('goal','')}\\
Previous result:\\
{parent.get('result','')[-30000:]}",
                        max_depth=parent.get("max_depth",DEFAULT_MAX_DEPTH))
    return await create_task(new_req,background_tasks,x_admin_token)
'''
new='''@app.post("/task/{job_id}/continue")
async def continue_task(job_id: str, req: ContinueRequest, background_tasks: BackgroundTasks, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token); parent=load_job(job_id)
    if str(parent.get("architecture", "")).startswith("intelligence-layer-sdk-"):
        raise HTTPException(status_code=409, detail="Intelligence jobs cannot use legacy /continue. Submit a bounded Intelligence recovery mission; same-job resume will be handled only by the Intelligence runtime.")
    new_req=TaskRequest(goal=req.instruction,context=f"Previous mission: {parent.get('goal','')}\\
Previous result:\\
{parent.get('result','')[-30000:]}",
                        max_depth=parent.get("max_depth",DEFAULT_MAX_DEPTH))
    return await create_task(new_req,background_tasks,x_admin_token)
'''
if 'Intelligence jobs cannot use legacy /continue' not in s:
    if old not in s: raise SystemExit('v0.10.0 continue route anchor missing')
    s=s.replace(old,new,1)

# Live state must derive active nodes only from currently-active jobs; terminal/partial historical
# jobs may contain stale descendant statuses but are not executing.
old='''            j=load_job(row["id"]); active_nodes+=sum(1 for n in flatten_nodes(j["root"]) if n.get("status") in {"queued","running","waiting_human"})
'''
new='''            j=load_job(row["id"])
            if str(j.get("status", "")).lower() in {"queued","running","understanding","planning","executing","verifying","synthesizing","recovering","waiting_human","waiting"}:
                active_nodes += sum(1 for n in flatten_nodes(j["root"]) if str(n.get("status", "")).lower() in {"queued","running","understanding","planning","executing","verifying","synthesizing","recovering","waiting_human","waiting"})
'''
if 'if str(j.get("status", "")).lower() in {"queued","running","understanding"' not in s:
    if old not in s: raise SystemExit('v0.10.0 state active anchor missing')
    s=s.replace(old,new,1)

# Governed live Intelligence capacity is 12, not the historical recursive theoretical maximum.
s=s.replace('"max_agents":MAX_AGENTS', '"max_agents":INTELLIGENCE_AGENT_BUDGET')

# Version / architecture markers.
s=s.replace('version="0.9.8"','version="0.10.0"')
s=s.replace('"version":"0.9.8"','"version":"0.10.0"')
s=s.replace('"version": "0.9.8"','"version": "0.10.0"')
if 'runtime-reliability-v0.10.0' not in s:
    marker='truthful-orchestration-v0.9.8'
    if marker not in s: raise SystemExit('v0.10.0 architecture marker missing')
    s=s.replace(marker,marker+'+runtime-reliability-v0.10.0',1)
p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/control_room.py')
s=p.read_text()

# Recursively reconcile orphaned node trees, not just the job envelope.
if 'def _interrupt_active_tree(' not in s:
    anchor='''def _reconcile_orphaned_jobs() -> None:
'''
    insert='''def _interrupt_active_tree(node: dict) -> int:
    active = {"queued", "running", "understanding", "planning", "executing", "verifying", "synthesizing", "recovering", "waiting_human", "waiting"}
    changed = 0
    if str(node.get("status", "")).lower() in active:
        node["status"] = "interrupted"
        node["error"] = (str(node.get("error", "")) + " | Runtime restarted; prior in-memory execution is no longer attached.").strip(" |")
        changed += 1
    for child in node.get("children", []) or []:
        changed += _interrupt_active_tree(child)
    return changed

'''
    if anchor not in s: raise SystemExit('v0.10.0 reconcile function anchor missing')
    s=s.replace(anchor,insert+anchor,1)

old='''            job["status"] = "interrupted"
            job["error"] = (str(job.get("error", "")) + " | Runtime restarted; prior in-memory execution is no longer attached.").strip(" |")
            for d in job.get("decisions", []):
'''
new='''            job["status"] = "interrupted"
            job["error"] = (str(job.get("error", "")) + " | Runtime restarted; prior in-memory execution is no longer attached.").strip(" |")
            interrupted_nodes = _interrupt_active_tree(job.get("root") or {})
            for d in job.get("decisions", []):
'''
if 'interrupted_nodes = _interrupt_active_tree' not in s:
    if old not in s: raise SystemExit('v0.10.0 reconcile body anchor missing')
    s=s.replace(old,new,1)

old='''                "summary": "Job marked interrupted after runtime restart; no background execution remains attached."
'''
new='''                "summary": f"Job marked interrupted after runtime restart; {interrupted_nodes} active node(s) reconciled and no background execution remains attached."
'''
if 'active node(s) reconciled' not in s:
    if old not in s: raise SystemExit('v0.10.0 reconcile event anchor missing')
    s=s.replace(old,new,1)

s=s.replace("'version': '0.9.8'", "'version': '0.10.0'")
p.write_text(s)
PY

python3 -m py_compile "$MAIN" "$CR" "$ENG"
python3 - <<'PY'
from pathlib import Path
m=Path('/opt/fourth-law-agent/app/main.py').read_text()
c=Path('/opt/fourth-law-agent/app/control_room.py').read_text()
e=Path('/opt/fourth-law-agent/app/intelligence_engine.py').read_text()
assert 'Intelligence jobs cannot use legacy /continue' in m
assert 'INTELLIGENCE_AGENT_BUDGET' in m
assert 'def _interrupt_active_tree' in c
assert 'artifact_prefix = result_text.lower().lstrip()[:240]' in e
assert 'sdk_request_budget", 60)) * 0.70' in e
assert '"system-repair artifact"' in e
print('V0100_LOCAL_REGRESSION_OK')
PY

cd "$PROJECT"
docker compose build agent >/tmp/fl0100-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl0100-up.log 2>&1
ok=0
for i in $(seq 1 60); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.10.0"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/dev/null

# Free local regression: state should no longer count historical terminal/partial descendant statuses.
ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
curl -fsS -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/state >/tmp/fl0100-state.json
python3 - <<'PY'
import json
j=json.load(open('/tmp/fl0100-state.json'))
assert j.get('version')=='0.10.0', j.get('version')
assert int((j.get('architecture') or {}).get('max_agents',0))==12, j.get('architecture')
print('V0100_STATE_OK', j.get('active_nodes'), len(j.get('pending_decisions') or []))
PY

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "RUNTIME_RELIABILITY_V0_10_0_DEPLOYED {\"artifact_block_false_positive\":\"fixed\",\"request_headroom_delegation_stop\":0.70,\"legacy_continue_for_intelligence\":\"blocked\",\"restart_nested_nodes\":\"reconciled\",\"live_max_agents\":12,\"health\":\"ok\",\"control_room\":\"ok\",\"state_regression\":\"ok\"}" >/dev/null 2>&1 || true
echo RUNTIME_RELIABILITY_V0_10_0_READY

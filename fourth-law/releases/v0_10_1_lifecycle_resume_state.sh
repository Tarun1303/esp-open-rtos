#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
CR="$PROJECT/app/control_room.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.10.1-lifecycle-resume-$STAMP"
mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.py"; cp "$CR" "$BACKUP/control_room.py"
rollback(){
 set +e
 cp "$BACKUP/main.py" "$MAIN"; cp "$BACKUP/control_room.py" "$CR"
 cd "$PROJECT"; docker compose build agent >/tmp/fl0101-rb-build.log 2>&1 || true; docker compose up -d --force-recreate agent >/tmp/fl0101-rb-up.log 2>&1 || true
 HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'LIFECYCLE_RESUME_V0_10_1_ROLLED_BACK' >/dev/null 2>&1 || true
 exit 1
}
trap rollback ERR
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/opt/fourth-law-agent/app/main.py'); s=p.read_text()
# Replace the mixed legacy continuation route structurally. Intelligence continuations create a linked
# Intelligence recovery attempt, never a legacy recursive job.
pat=re.compile(r'@app\.post\("/task/\{job_id\}/continue"\)\nasync def continue_task\(.*?\n(?=@app\.post\("/decisions/\{decision_id\}/answer"\))',re.S)
if 'resume_of' not in s[s.find('@app.post("/task/{job_id}/continue")'):s.find('@app.post("/decisions/{decision_id}/answer")')]:
    new=r'''@app.post("/task/{job_id}/continue")
async def continue_task(job_id: str, req: ContinueRequest, background_tasks: BackgroundTasks, x_admin_token: str = Header(default="")):
    require_auth(x_admin_token)
    parent=load_job(job_id)
    inherited = "Previous mission: " + str(parent.get("goal", "")) + "\nPrevious result:\n" + str(parent.get("result", ""))[-30000:]
    if str(parent.get("architecture", "")).startswith("intelligence-layer-sdk-"):
        if str(parent.get("status", "")).lower() in {"queued","running","understanding","planning","executing","verifying","synthesizing","recovering","waiting_human","waiting"}:
            raise HTTPException(status_code=409, detail="Intelligence job is still active; resume is only allowed for a terminal/interrupted attempt.")
        out = await create_intelligence_problem(ProblemRequest(goal=req.instruction, context=inherited), background_tasks, x_admin_token)
        child=load_job(out["job_id"])
        child["resume_of"] = job_id
        child["attempt_kind"] = "intelligence_resume"
        child["resume_instruction"] = req.instruction
        write_job(child)
        return {**out, "resume_of": job_id, "runtime": "intelligence"}
    new_req=TaskRequest(goal=req.instruction, context=inherited, max_depth=parent.get("max_depth",DEFAULT_MAX_DEPTH))
    return await create_task(new_req,background_tasks,x_admin_token)

'''
    s,n=pat.subn(lambda m:new,s,count=1)
    if n!=1: raise SystemExit(f'continue structural match count={n}')
# Truthful active-node accounting: only active jobs can contribute active nodes.
old='''            j=load_job(row["id"]); active_nodes+=sum(1 for n in flatten_nodes(j["root"]) if n.get("status") in {"queued","running","waiting_human"})
'''
new='''            j=load_job(row["id"])
            if str(j.get("status", "")).lower() in {"queued","running","understanding","planning","executing","verifying","synthesizing","recovering","waiting_human","waiting"}:
                active_nodes += sum(1 for n in flatten_nodes(j["root"]) if str(n.get("status", "")).lower() in {"queued","running","understanding","planning","executing","verifying","synthesizing","recovering","waiting_human","waiting"})
'''
if 'if str(j.get("status", "")).lower() in {"queued","running","understanding"' not in s:
    if old not in s: raise SystemExit('state active anchor missing')
    s=s.replace(old,new,1)
s=s.replace('"max_agents":MAX_AGENTS','"max_agents":INTELLIGENCE_AGENT_BUDGET')
p.write_text(s)
PY
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/control_room.py'); s=p.read_text()
if 'def _interrupt_active_tree(' not in s:
    anchor='def _reconcile_orphaned_jobs() -> None:\n'
    insert='''def _interrupt_active_tree(node: dict) -> int:
    active={"queued","running","understanding","planning","executing","verifying","synthesizing","recovering","waiting_human","waiting"}
    changed=0
    if str(node.get("status", "")).lower() in active:
        node["status"]="interrupted"
        node["error"]=(str(node.get("error", ""))+" | Runtime restarted; prior in-memory execution is no longer attached.").strip(" |")
        changed+=1
    for child in node.get("children", []) or []:
        changed += _interrupt_active_tree(child)
    return changed

'''
    if anchor not in s: raise SystemExit('reconcile anchor missing')
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
    if old not in s: raise SystemExit('reconcile body anchor missing')
    s=s.replace(old,new,1)
old='''                "summary": "Job marked interrupted after runtime restart; no background execution remains attached."
'''
new='''                "summary": f"Job marked interrupted after runtime restart; {interrupted_nodes} active node(s) reconciled and no background execution remains attached."
'''
if 'active node(s) reconciled' not in s:
    if old not in s: raise SystemExit('reconcile summary anchor missing')
    s=s.replace(old,new,1)
p.write_text(s)
PY
python3 -m py_compile "$MAIN" "$CR"
python3 - <<'PY'
from pathlib import Path
m=Path('/opt/fourth-law-agent/app/main.py').read_text(); c=Path('/opt/fourth-law-agent/app/control_room.py').read_text()
assert 'attempt_kind"] = "intelligence_resume"' in m
assert 'runtime": "intelligence"' in m
assert '"max_agents":INTELLIGENCE_AGENT_BUDGET' in m
assert 'def _interrupt_active_tree' in c
print('LIFECYCLE_RESUME_V0101_LOCAL_OK')
PY
cd "$PROJECT"
docker compose build agent >/tmp/fl0101-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl0101-up.log 2>&1
ok=0
for i in $(seq 1 60); do if curl -fsS http://127.0.0.1:8787/health >/tmp/fl0101-health.json 2>/dev/null; then ok=1; break; fi; sleep 1; done
[[ "$ok" = 1 ]]
ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
curl -fsS -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/state >/tmp/fl0101-state.json
python3 - <<'PY'
import json
j=json.load(open('/tmp/fl0101-state.json'))
assert int((j.get('architecture') or {}).get('max_agents',0))==12, j.get('architecture')
assert not (j.get('pending_decisions') or []), j.get('pending_decisions')
# No active paid job should survive a restart; reconciliation must make this zero.
assert int(j.get('active_nodes',-1))==0, j.get('active_nodes')
print('LIFECYCLE_RESUME_V0101_STATE_OK')
PY
curl -fsS http://127.0.0.1:8787/control-room >/dev/null
trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'LIFECYCLE_RESUME_V0_10_1_DEPLOYED {"intelligence_continue":"linked-intelligence-recovery","legacy_crossrouting":false,"resume_lineage":true,"nested_restart_reconcile":true,"active_nodes":0,"max_agents":12,"pending_decisions":0,"health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true
echo LIFECYCLE_RESUME_V0_10_1_READY

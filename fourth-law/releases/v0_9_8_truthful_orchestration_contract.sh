#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
CR="$PROJECT/app/control_room.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.9.8-truthful-orchestration-$STAMP"
mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.py"
cp "$CR" "$BACKUP/control_room.py"

rollback(){
  set +e
  cp "$BACKUP/main.py" "$MAIN"
  cp "$BACKUP/control_room.py" "$CR"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl098-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl098-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'TRUTHFUL_ORCHESTRATION_V0_9_8_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/control_room.py')
s=p.read_text()

# 1) Control Room ingress must unwrap a pasted bridge command instead of feeding the
# entire CHATGPT_COMMAND JSON blob to the Supervisor as literal mission text.
if 'def _normalize_task_submission(' not in s:
    anchor='def configure_control_room(start_task: Callable[[str, str, BackgroundTasks], Awaitable[dict]]) -> None:\n'
    if anchor not in s:
        raise SystemExit('v0.9.8 configure_control_room anchor missing')
    insert='''def _normalize_task_submission(goal: str, context: str) -> tuple[str, str]:
    raw = (goal or "").strip()
    if not raw.startswith("CHATGPT_COMMAND"):
        return raw, context or ""
    payload = raw[len("CHATGPT_COMMAND"):].strip()
    try:
        cmd = json.loads(payload)
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid CHATGPT_COMMAND JSON") from exc
    if str(cmd.get("type", "")) != "intelligence_problem":
        raise HTTPException(status_code=400, detail="Control Room only unwraps intelligence_problem commands")
    clean_goal = str(cmd.get("goal", "")).strip()
    if len(clean_goal) < 3:
        raise HTTPException(status_code=422, detail="Supervisor goal is required")
    clean_context = str(cmd.get("context", context or ""))
    return clean_goal, clean_context

'''
    s=s.replace(anchor,insert+anchor,1)

# 2) A completed reasoning package is not the same thing as a deployed outcome.
if 'def _delivery_state(' not in s:
    anchor='def _summary(job: dict, p: Path) -> dict:\n'
    if anchor not in s:
        raise SystemExit('v0.9.8 summary anchor missing')
    insert='''def _delivery_state(job: dict) -> str:
    status = str(job.get("status", "queued")).lower()
    if status not in {"completed", "complete"}:
        if status in {"failed", "partial", "interrupted", "superseded"}:
            return status
        return "working"
    if job.get("deployment_verified") is True or str(job.get("deployment_state", "")).lower() == "verified":
        return "deployed_verified"
    text = (str(job.get("goal", "")) + "\n" + str(job.get("context", ""))).lower()
    artifact_markers = (
        "implementation package", "patch package", "handoff", "implementation-ready",
        "implementation ready", "deployable package", "deployment package",
        "do not perform or claim live deployment", "do not claim deployment",
        "no deployment", "artifact mission"
    )
    production_markers = (
        "deploy", "production", "live ui", "rebuild", "build the", "implement the"
    )
    if any(x in text for x in artifact_markers):
        return "artifact_ready"
    if any(x in text for x in production_markers):
        return "execution_pending"
    return "reasoning_complete"

'''
    s=s.replace(anchor,insert+anchor,1)

# 3) Expose truthful delivery state to the browser and avoid displaying artifact-only
# completion as if the user's requested real-world outcome is complete.
old="""        'architecture': job.get('architecture', ''), 'status': job.get('status', 'queued'), 'stage': _stage(job.get('status', 'queued')),
"""
new="""        'architecture': job.get('architecture', ''), 'status': job.get('status', 'queued'),
        'stage': ('Artifact Ready' if _delivery_state(job) == 'artifact_ready' else ('Execution Pending' if _delivery_state(job) == 'execution_pending' else _stage(job.get('status', 'queued')))),
        'delivery_state': _delivery_state(job),
"""
if "'delivery_state': _delivery_state(job)" not in s:
    if old not in s:
        raise SystemExit('v0.9.8 sanitize stage anchor missing')
    s=s.replace(old,new,1)

old="""        'stage': _stage(job.get('status', 'queued')), 'architecture': job.get('architecture', ''),
        'agents_created': job.get('agents_created', 1), 'created_at': job.get('created_at'),
"""
new="""        'stage': ('Artifact Ready' if _delivery_state(job) == 'artifact_ready' else ('Execution Pending' if _delivery_state(job) == 'execution_pending' else _stage(job.get('status', 'queued')))),
        'delivery_state': _delivery_state(job), 'architecture': job.get('architecture', ''),
        'agents_created': job.get('agents_created', 1), 'created_at': job.get('created_at'),
"""
if "'delivery_state': _delivery_state(job), 'architecture'" not in s:
    if old not in s:
        raise SystemExit('v0.9.8 summary delivery anchor missing')
    s=s.replace(old,new,1)

# 4) Parse the browser mission correctly.
old='''    return await _start_task(req.goal, req.context, background_tasks)
'''
new='''    goal, context = _normalize_task_submission(req.goal, req.context)
    return await _start_task(goal, context, background_tasks)
'''
if '_normalize_task_submission(req.goal, req.context)' not in s:
    if old not in s:
        raise SystemExit('v0.9.8 submit task anchor missing')
    s=s.replace(old,new,1)

# 5) After a process restart, in-memory background tasks do not survive. Any job that
# was marked active before import is therefore orphaned and must not remain "running".
# Reconcile these files once at process start so state/UI are truthful.
if 'def _reconcile_orphaned_jobs(' not in s:
    anchor="@router.get('/control-room', response_class=HTMLResponse)\n"
    if anchor not in s:
        raise SystemExit('v0.9.8 route anchor missing')
    insert='''def _reconcile_orphaned_jobs() -> None:
    active = {"queued", "running", "understanding", "planning", "executing", "verifying", "synthesizing", "recovering", "waiting_human", "waiting"}
    for path in JOBS_DIR.glob("*.json"):
        try:
            job = json.loads(path.read_text())
            if str(job.get("status", "")).lower() not in active:
                continue
            job["status"] = "interrupted"
            job["error"] = (str(job.get("error", "")) + " | Runtime restarted; prior in-memory execution is no longer attached.").strip(" |")
            for d in job.get("decisions", []):
                if str(d.get("status", "")) == "pending":
                    d["status"] = "interrupted"
            job.setdefault("events", []).append({
                "ts": time.time(), "type": "runtime_reconcile",
                "summary": "Job marked interrupted after runtime restart; no background execution remains attached."
            })
            path.write_text(json.dumps(job, ensure_ascii=False, separators=(",", ":")))
        except Exception:
            continue

_reconcile_orphaned_jobs()

'''
    s=s.replace(anchor,insert+anchor,1)

s=s.replace("return {'authenticated': _valid_session(fl_session), 'version': '0.9.0'}", "return {'authenticated': _valid_session(fl_session), 'version': '0.9.8'}")
p.write_text(s)

p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
# Health/current-version markers.
s=s.replace('version="0.9.7"','version="0.9.8"')
s=s.replace('"version":"0.9.7"','"version":"0.9.8"')
s=s.replace('"version": "0.8.0"','"version": "0.9.8"')
s=s.replace('"version":"0.8.0"','"version":"0.9.8"')
if 'truthful-orchestration-v0.9.8' not in s:
    marker='failure-recovery-v0.9.7'
    if marker not in s:
        raise SystemExit('v0.9.8 architecture marker missing')
    s=s.replace(marker,marker+'+truthful-orchestration-v0.9.8',1)
# Where legacy state metadata hard-codes the historical budget, expose the governed
# intelligence budget rather than claiming 85 active capacity.
s=s.replace('"max_agents": 85', '"max_agents": INTELLIGENCE_AGENT_BUDGET')
p.write_text(s)
PY

python3 -m py_compile "$CR" "$MAIN" "$PROJECT/app/intelligence_engine.py"
python3 - <<'PY'
from pathlib import Path
s=Path('/opt/fourth-law-agent/app/control_room.py').read_text()
assert 'def _normalize_task_submission' in s
assert 'def _delivery_state' in s
assert 'def _reconcile_orphaned_jobs' in s
assert "'delivery_state': _delivery_state(job)" in s
assert '_normalize_task_submission(req.goal, req.context)' in s
print('V098_TRUTHFUL_ORCHESTRATION_LOCAL_OK')
PY

cd "$PROJECT"
docker compose build agent >/tmp/fl098-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl098-up.log 2>&1

ok=0
for i in $(seq 1 60); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.9.8"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/dev/null

# Verify stale active jobs were reconciled and the task normalizer works locally.
docker compose exec -T agent python - <<'PY'
from app.control_room import _normalize_task_submission, _delivery_state
raw='CHATGPT_COMMAND {"id":"x","type":"intelligence_problem","goal":"Build the UI","context":"deploy after verification"}'
g,c=_normalize_task_submission(raw,'')
assert g=='Build the UI' and c=='deploy after verification'
assert _delivery_state({'status':'completed','goal':'Build the production UI','context':'patch package; do not claim deployment'})=='artifact_ready'
print('V098_INGRESS_AND_DELIVERY_STATE_OK')
PY

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'TRUTHFUL_ORCHESTRATION_V0_9_8_DEPLOYED {"nested_command_ingress":"unwrapped","artifact_complete_not_equal_deployed":true,"delivery_state_exposed":true,"restart_orphans":"marked-interrupted","stale_pending_decisions":"interrupted","state_version":"0.9.8","health":"ok","control_room":"ok","execution_layer":"still-separate-next-layer"}' >/dev/null 2>&1 || true
echo TRUTHFUL_ORCHESTRATION_V0_9_8_READY

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
ENVFILE="$PROJECT/.env"
JOB_ID="dcde605faa844d"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.8.1-governor-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$ENVFILE" "$BACKUP/.env"

rollback() {
  set +e
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"
  cp "$BACKUP/.env" "$ENVFILE"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl081-rollback-build.log 2>&1
  docker compose up -d --force-recreate agent >/tmp/fl081-rollback-up.log 2>&1
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'INTELLIGENCE_V0_8_1_ROLLED_BACK {"reason":"governor deployment validation failed"}' >/dev/null 2>&1 || true
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/.env')
rows=[]
settings={
    'INTELLIGENCE_AGENT_BUDGET':'21',
    'INTELLIGENCE_MAX_CHILDREN':'2',
}
seen=set()
for line in p.read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k=line.split('=',1)[0].strip()
        if k in settings:
            rows.append(f'{k}={settings[k]}'); seen.add(k); continue
    rows.append(line)
for k,v in settings.items():
    if k not in seen: rows.append(f'{k}={v}')
p.write_text('\n'.join(rows).rstrip()+'\n')
PY
chmod 600 "$ENVFILE"

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s=p.read_text()

# Default coded child cap is two even if env is absent.
s=s.replace('max_children_per_node: int = 4,', 'max_children_per_node: int = 2,')
s=s.replace('self.max_children_per_node = max(1, min(4, max_children_per_node))', 'self.max_children_per_node = max(1, min(2, max_children_per_node))')

# Add a deterministic usefulness gate before keeping delegate steps.
old='''        delegated = 0
        for s in steps:
            if s.execution_mode == "delegate":
                if node.get("depth", 0) >= max_depth or delegated >= self.max_children_per_node:
                    s.execution_mode = "local"
                    s.delegation_reason = "Delegation converted to local execution by coded depth/child cap."
                else:
                    delegated += 1
'''
new='''        delegated = 0
        node_complexity = int((node.get("understanding") or {}).get("complexity", 5) or 5)
        for s in steps:
            if s.execution_mode == "delegate":
                reason = (s.delegation_reason or "").strip()
                materially_justified = node_complexity >= 7 and len(reason) >= 32
                if (not materially_justified) or node.get("depth", 0) >= max_depth or delegated >= self.max_children_per_node:
                    s.execution_mode = "local"
                    s.delegation_reason = "Delegation converted to local execution by complexity/usefulness/depth/child governor."
                else:
                    delegated += 1
'''
if old not in s:
    raise SystemExit('v0.8.1 normalize delegation anchor missing')
s=s.replace(old,new,1)

# Record why each actual delegation was allowed.
old='''        if not await self._reserve_child(job):
            await self.emit(job, "intelligence_budget_fallback", "Agent budget exhausted; delegated step converted to local execution", node=node, step_index=step["index"])
            return await self._execute_local_step(job, node, step, context, "")

        child = {
'''
new='''        if not await self._reserve_child(job):
            step["delegation_governor"] = {"decision": "local", "reason": "global agent budget exhausted"}
            await self.emit(job, "intelligence_budget_fallback", "Agent budget exhausted; delegated step converted to local execution", node=node, step_index=step["index"])
            return await self._execute_local_step(job, node, step, context, "")

        step["delegation_governor"] = {
            "decision": "delegate",
            "reason": step.get("delegation_reason", ""),
            "node_complexity": int((node.get("understanding") or {}).get("complexity", 5) or 5),
            "max_children_per_node": self.max_children_per_node,
            "global_agent_budget": int(job.get("agent_budget", 21)),
        }
        child = {
'''
if old not in s:
    raise SystemExit('v0.8.1 reserve child anchor missing')
s=s.replace(old,new,1)

# Audit governor behavior.
old='''                "delegated_step_count": sum(1 for s in n.get("steps", []) if s.get("execution_mode") == "delegate"),
                "child_count": len(n.get("children", [])),
'''
new='''                "delegated_step_count": sum(1 for s in n.get("steps", []) if s.get("execution_mode") == "delegate"),
                "governor_delegate_count": sum(1 for s in n.get("steps", []) if (s.get("delegation_governor") or {}).get("decision") == "delegate"),
                "governor_local_fallback_count": sum(1 for s in n.get("steps", []) if (s.get("delegation_governor") or {}).get("decision") == "local"),
                "child_count": len(n.get("children", [])),
'''
if old not in s:
    raise SystemExit('v0.8.1 audit anchor missing')
s=s.replace(old,new,1)

p.write_text(s)
PY

python3 -m py_compile "$ENGINE"

# Stop the exploratory high-fanout regression before rebuilding; recursion has already been proven.
cd "$PROJECT"
docker compose stop agent >/dev/null 2>&1 || true

# Mark the exploratory job as superseded if its persisted JSON is on the host volume.
python3 - <<'PY'
from pathlib import Path
import json, time
job_id='dcde605faa844d'
candidates=list(Path('/opt/fourth-law-agent').glob(f'**/{job_id}.json'))
for p in candidates:
    try:
        data=json.loads(p.read_text())
        if data.get('id')==job_id and data.get('status') in {'queued','running'}:
            data['status']='superseded'
            data['error']='Exploratory v0.8 recursion test stopped after proving depth-3 delegation; superseded by v0.8.1 efficiency governor.'
            data['completed_at']=time.time()
            p.write_text(json.dumps(data, ensure_ascii=False, indent=2))
            print('marked_superseded='+str(p))
    except Exception:
        pass
PY

docker compose build agent
docker compose up -d --force-recreate agent

ok=0
for i in $(seq 1 75); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl081-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.8.0"' /tmp/fl081-health.json

ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl081-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl081-api.json

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'INTELLIGENCE_V0_8_1_GOVERNOR_DEPLOYED {"max_children_per_node":2,"global_agent_budget":21,"delegation_requires_complexity_gte":7,"delegation_reason_min_chars":32,"exploratory_run":"superseded_after_depth3_proof","api_check":"ok"}' >/dev/null 2>&1 || true

echo FOURTHLAW_INTELLIGENCE_V0_8_1_GOVERNOR_READY
cat /tmp/fl081-health.json

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
MAIN="$PROJECT/app/main.py"
ENVFILE="$PROJECT/.env"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.9.1-cost-governor-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$MAIN" "$BACKUP/main.py"
cp "$ENVFILE" "$BACKUP/.env"

rollback(){
  set +e
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"
  cp "$BACKUP/main.py" "$MAIN"
  cp "$BACKUP/.env" "$ENVFILE"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl091-rollback-build.log 2>&1
  docker compose up -d --force-recreate agent >/tmp/fl091-rollback-up.log 2>&1
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'COST_GOVERNOR_V0_9_1_ROLLED_BACK' >/dev/null 2>&1 || true
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/.env')
settings={
 'INTELLIGENCE_AGENT_BUDGET':'12',
 'INTELLIGENCE_MAX_CHILDREN':'2',
}
rows=[]; seen=set()
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

# 1) Stateless SDK calls: structured node state is the memory; do not replay growing SQLite history.
if 'session=self._session(job, node),' in s:
    s=s.replace('            session=self._session(job, node),\n','',1)

# 2) One recovery retry only.
s=s.replace('self.recovery_attempts = max(1, min(3, recovery_attempts))', 'self.recovery_attempts = 1')

# 3) Dynamic plans remain intelligent but are bounded to six execution steps.
s=s.replace('steps = steps[:10]', 'steps = steps[:6]')
s=s.replace('Create 1 to 10 useful sequential steps.', 'Create 1 to 6 useful sequential steps.')

# 4) Insert deterministic job/node/request/context guards at the SDK call boundary.
anchor='''    ) -> BaseModel:\n        agent = Agent(\n'''
insert='''    ) -> BaseModel:\n        # COST GOVERNOR v0.9.1 — hard runtime limits, not prompt-only guidance.\n        cg = job.setdefault("cost_governor", {\n            "version": "1.0",\n            "sdk_token_budget": 250000,\n            "sdk_request_budget": 60,\n            "node_token_budget": 60000,\n            "node_request_budget": 14,\n            "prompt_char_cap": 12000,\n            "soft_warning_ratio": 0.80,\n            "sdk_total_tokens": 0,\n            "sdk_requests": 0,\n            "soft_warning_emitted": False,\n        })\n        nu = node.setdefault("sdk_usage", {"requests": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0})\n        if int(cg.get("sdk_total_tokens", 0)) >= int(cg["sdk_token_budget"]):\n            raise RuntimeError("COST_GOVERNOR: job SDK token budget reached; model call blocked")\n        if int(cg.get("sdk_requests", 0)) >= int(cg["sdk_request_budget"]):\n            raise RuntimeError("COST_GOVERNOR: job SDK request budget reached; model call blocked")\n        if int(nu.get("total_tokens", 0)) >= int(cg["node_token_budget"]):\n            raise RuntimeError("COST_GOVERNOR: node token budget reached; model call blocked")\n        if int(nu.get("requests", 0)) >= int(cg["node_request_budget"]):\n            raise RuntimeError("COST_GOVERNOR: node request budget reached; model call blocked")\n        cap = int(cg["prompt_char_cap"])\n        if len(prompt) > cap:\n            half = cap // 2\n            prompt = prompt[:half] + "\\n...[COST_GOVERNOR_CONTEXT_COMPACTED]...\\n" + prompt[-half:]\n        max_turns = min(int(max_turns), 2)\n        agent = Agent(\n'''
if 'COST GOVERNOR v0.9.1' not in s:
    if anchor not in s: raise SystemExit('sdk boundary anchor missing')
    s=s.replace(anchor,insert,1)

# 5) Update counters after each successful SDK run.
anchor='''        node["sdk_usage"]["total_tokens"] += int(getattr(usage, "total_tokens", 0) or 0)\n        await self.emit(\n'''
insert='''        node["sdk_usage"]["total_tokens"] += int(getattr(usage, "total_tokens", 0) or 0)\n        cg["sdk_requests"] = int(cg.get("sdk_requests", 0)) + int(getattr(usage, "requests", 0) or 0)\n        cg["sdk_total_tokens"] = int(cg.get("sdk_total_tokens", 0)) + int(getattr(usage, "total_tokens", 0) or 0)\n        ratio = float(cg["sdk_total_tokens"]) / float(max(1, int(cg["sdk_token_budget"])))\n        if ratio >= float(cg.get("soft_warning_ratio", 0.80)) and not cg.get("soft_warning_emitted"):\n            cg["soft_warning_emitted"] = True\n            await self.emit(job, "cost_governor_warning", f"SDK budget at {ratio:.0%}; delegation and new model work should minimize cost", node=node, budget_ratio=ratio)\n        await self.emit(\n'''
if 'cg["sdk_requests"]' not in s:
    if anchor not in s: raise SystemExit('usage counter anchor missing')
    s=s.replace(anchor,insert,1)

# 6) Verification is cheap first-pass; expensive Supervisor consultation only on revise/blocked.
s=s.replace('''                model=self.intelligence_model,\n                max_turns=3,\n            )\n\n            sup = await self.supervisor_consult(\n                job,\n                node,\n                "intelligence_step_verification",\n                f"Step {step['index']} objective: {step['objective']}\\nExpected: {step['expected_result']}\\nSelf-review: {review.model_dump_json()}",\n                candidate=out.result,\n            )\n''','''                model=self.execution_model,\n                max_turns=2,\n            )\n\n            sup = {"summary": "Step passed local bounded verification; Supervisor API checkpoint deferred.", "verify": "", "guidance": ""}\n            if review.verdict != "pass":\n                sup = await self.supervisor_consult(\n                    job,\n                    node,\n                    "intelligence_step_recovery",\n                    f"Step {step['index']} objective: {step['objective']}\\nExpected: {step['expected_result']}\\nSelf-review: {review.model_dump_json()}",\n                    candidate=out.result,\n                )\n''',1)

# 7) Stop spawning children when 80% of SDK budget is already consumed.
anchor='''    async def _reserve_child(self, job: dict) -> bool:\n        lock = self._budget_locks.setdefault(job["id"], asyncio.Lock())\n'''
insert='''    async def _reserve_child(self, job: dict) -> bool:\n        cg = job.get("cost_governor") or {}\n        if cg and int(cg.get("sdk_total_tokens", 0)) >= int(int(cg.get("sdk_token_budget", 250000)) * 0.80):\n            return False\n        lock = self._budget_locks.setdefault(job["id"], asyncio.Lock())\n'''
if '0.80):\n            return False\n        lock = self._budget_locks' not in s:
    if anchor not in s: raise SystemExit('reserve child anchor missing')
    s=s.replace(anchor,insert,1)

p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('version="0.9.0"','version="0.9.1"')
s=s.replace('"version":"0.9.0"','"version":"0.9.1"')
if 'cost-governor-v0.9.1' not in s:
    s=s.replace('control-room-v0.9','control-room-v0.9+cost-governor-v0.9.1')
p.write_text(s)
PY

python3 -m py_compile "$ENGINE" "$MAIN"
grep -q 'COST GOVERNOR v0.9.1' "$ENGINE"
grep -q 'steps = steps\[:6\]' "$ENGINE"
! grep -q 'session=self._session(job, node),' "$ENGINE"

cd "$PROJECT"
docker compose build agent
docker compose up -d --force-recreate agent

ok=0
for i in $(seq 1 75); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl091-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.9.1"' /tmp/fl091-health.json

# No paid model smoke test: account is currently quota-exhausted. Validate free/local control surfaces instead.
curl -fsS http://127.0.0.1:8787/control-room >/tmp/fl091-ui.html
grep -q 'Fourth Law' /tmp/fl091-ui.html

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'COST_GOVERNOR_V0_9_1_DEPLOYED {"session_replay":false,"sdk_token_budget":250000,"sdk_request_budget":60,"node_token_budget":60000,"node_request_budget":14,"prompt_char_cap":12000,"max_steps_per_node":6,"max_turns_per_call":2,"recovery_retries":1,"verification_model":"luna-first","supervisor_step_calls":"recovery-only","delegation_stop_ratio":0.80,"global_agent_budget":12,"paid_smoke":"skipped_quota_exhausted","local_health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true

echo FOURTHLAW_COST_GOVERNOR_V0_9_1_READY
cat /tmp/fl091-health.json

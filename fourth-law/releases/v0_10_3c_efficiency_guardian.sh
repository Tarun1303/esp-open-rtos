#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
MAIN="$PROJECT/app/main.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.10.3c-efficiency-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$MAIN" "$BACKUP/main.py"
rollback(){
  set +e
  echo 'V0103C_FAILURE_CONTEXT' >/tmp/fl0103c-failure.txt
  python3 -m py_compile "$ENGINE" "$MAIN" >>/tmp/fl0103c-failure.txt 2>&1 || true
  cd "$PROJECT"; docker compose logs --tail=80 agent >>/tmp/fl0103c-failure.txt 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file /tmp/fl0103c-failure.txt >/dev/null 2>&1 || true
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"; cp "$BACKUP/main.py" "$MAIN"
  docker compose build agent >/tmp/fl0103c-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl0103c-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'EFFICIENCY_GUARDIAN_V0_10_3C_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s=p.read_text()

# 1) Reserve root slot 04 for Efficiency while forcing first three modules to cover the productive mission.
old='''            root_context = self.memory.root_planning_context(str(job.get("context", "") or ""))
            plan = await self.problem_engine.plan_problem(job, root, root_context)
            self.memory.bootstrap(job, plan, root_context)
'''
new='''            root_context = self.memory.root_planning_context(str(job.get("context", "") or ""))
            efficiency_directive = """\nFOURTH LAW ROOT ARCHITECTURE INVARIANT:\n- Exactly four primary root slots must exist.\n- Slots 01-03 are productive work agents and MUST collectively cover 100% of the requested mission outcome.\n- Slot 04 is permanently reserved for the Efficiency Guardian. It is governance, not a quarter of the productive task.\n- Therefore plan the first three modules as complete complementary coverage of the actual work. Name module 04 'Efficiency Guardian'; its work packages may describe token/context/request/delegation monitoring only.\n"""
            planning_context = root_context + efficiency_directive
            plan = await self.problem_engine.plan_problem(job, root, planning_context)
            if len(plan.get("modules", [])) != 4:
                raise RuntimeError("Root plan must contain exactly four modules")
            plan["modules"][3] = {
                "name": "Efficiency Guardian",
                "role": "Token / Context / Request / Delegation Efficiency Guardian",
                "objective": "Continuously enforce coded efficiency boundaries while the three productive agents execute the complete mission.",
                "expected_module_outcome": "No agent exceeds configured request/token/context limits; prompt/output communication stays compact; synthesis and recovery headroom is preserved.",
                "balance_rationale": "Permanent governance slot; productive task coverage belongs entirely to slots 01-03.",
                "work_packages": [
                    {"title":"Input efficiency","task":"Watch prompt/context size and compaction.","expected_outcome":"Inputs remain within coded caps."},
                    {"title":"Output efficiency","task":"Watch output ceilings and recovery headroom.","expected_outcome":"Outputs remain bounded and useful."},
                    {"title":"Delegation efficiency","task":"Stop unnecessary child creation before budget pressure.","expected_outcome":"Delegation remains materially justified and bounded."},
                    {"title":"Mission budget telemetry","task":"Track requests/tokens and preserve synthesis reserve.","expected_outcome":"Mission finishes without preventable budget exhaustion."},
                ],
            }
            job["efficiency_guardian"] = {
                "version":"1.0","mode":"deterministic-local","request_reserve_ratio":0.30,
                "token_reserve_ratio":0.30,"prompt_compactions":0,"blocked_delegations":0,
                "sdk_requests":0,"sdk_total_tokens":0,"last_stage":"root_planning"
            }
            self.memory.bootstrap(job, plan, planning_context)
'''
if 'efficiency_directive = """' not in s:
    if old not in s: raise SystemExit('root planner anchor missing')
    s=s.replace(old,new,1)

# 2) Turn the already-reserved fourth root node into a coded guardian and run models only for 01-03.
old='''            root["children"] = modules
            await self.persist(job)

            results = await asyncio.gather(*[self.run_node(job, module, "") for module in modules], return_exceptions=True)

            failed = []
            module_results = []
            for module, result in zip(modules, results):
'''
new='''            if len(modules) != 4:
                raise RuntimeError(f"Expected four root nodes, got {len(modules)}")
            guardian = modules[3]
            guardian.update({
                "name":"Efficiency Guardian",
                "role":"Token / Context / Request / Delegation Efficiency Guardian",
                "goal":"Continuously enforce coded efficiency boundaries for this mission.",
                "expected_module_outcome":"Mission remains within hard cost/context limits with recovery and synthesis headroom.",
                "status":"monitoring",
                "mode":"efficiency_guardian",
                "steps":[],"children":[],"error":"",
                "result":"Efficiency monitoring active; this root slot consumes no model calls.",
                "understanding":{
                    "normalized_goal":"Enforce mission efficiency boundaries.",
                    "deliverables":["budget telemetry","context compaction","delegation control","synthesis reserve"],
                    "constraints":["no LLM calls","no children","never relax safety/cost limits"],
                    "success_criteria":["hard limits respected","reserve preserved","no ceremonial fan-out"],
                    "uncertainties":[],"complexity":1,"recommended_strategy":"direct"
                },
                "intelligence_plan":{"strategy":"direct","synthesis_goal":"Keep the mission efficient.","rationale":"Coded governance does not need a model call.","steps":[]}
            })
            root["children"] = modules
            await self.emit(job,"efficiency_guardian_start","Root slot 04 is monitoring request/token/context/delegation efficiency",node=guardian)
            await self.persist(job)

            work_modules = modules[:3]
            results = await asyncio.gather(*[self.run_node(job, module, "") for module in work_modules], return_exceptions=True)

            failed = []
            module_results = []
            for module, result in zip(work_modules, results):
'''
if 'work_modules = modules[:3]' not in s:
    if old not in s: raise SystemExit('root execution anchor missing')
    s=s.replace(old,new,1)

# Add guardian evidence to Supervisor synthesis, with no model-generated claim.
anchor='''                    module_results.append({"name": module["name"], "result_ref": f"local://job/{job['id']}/memory/{module['id']}"})

            if failed:
'''
insert='''                    module_results.append({"name": module["name"], "result_ref": f"local://job/{job['id']}/memory/{module['id']}"})
            eg = job.get("efficiency_guardian", {})
            guardian["result"] = f"Requests {eg.get('sdk_requests',0)} · SDK tokens {eg.get('sdk_total_tokens',0)} · prompt compactions {eg.get('prompt_compactions',0)} · blocked delegations {eg.get('blocked_delegations',0)}"
            module_results.append({"name":"Efficiency Guardian","result_ref":f"local://job/{job['id']}/efficiency_guardian"})

            if failed:
'''
if 'local://job/{job[\'id\']}/efficiency_guardian' not in s:
    if anchor not in s: raise SystemExit('module result anchor missing')
    s=s.replace(anchor,insert,1)

# 3) Sync efficiency telemetry at the SDK boundary and reserve 30% request+token headroom for synthesis/recovery.
anchor='''        max_turns = min(int(max_turns), 2)
        agent = Agent(
'''
insert='''        eg = job.get("efficiency_guardian")
        if isinstance(eg, dict):
            eg["last_stage"] = str(stage)[:120]
            eg["sdk_requests"] = int(cg.get("sdk_requests",0))
            eg["sdk_total_tokens"] = int(cg.get("sdk_total_tokens",0))
            eg["prompt_char_cap"] = int(cg.get("prompt_char_cap",9000))
            eg["estimated_input_token_cap"] = int(cg.get("estimated_input_token_cap",3200))
            eg["max_prompt_chars_seen"] = max(int(eg.get("max_prompt_chars_seen",0)), len(prompt))

        max_turns = min(int(max_turns), 2)
        agent = Agent(
'''
if 'eg["last_stage"] = str(stage)' not in s:
    if anchor not in s: raise SystemExit('sdk agent anchor missing')
    s=s.replace(anchor,insert,1)

# Update telemetry after successful calls.
anchor='''        cg["sdk_total_tokens"] = int(cg.get("sdk_total_tokens", 0)) + int(getattr(usage, "total_tokens", 0) or 0)
'''
insert='''        cg["sdk_total_tokens"] = int(cg.get("sdk_total_tokens", 0)) + int(getattr(usage, "total_tokens", 0) or 0)
        eg = job.get("efficiency_guardian")
        if isinstance(eg, dict):
            eg["sdk_requests"] = int(cg.get("sdk_requests",0))
            eg["sdk_total_tokens"] = int(cg.get("sdk_total_tokens",0))
'''
if 'eg["sdk_total_tokens"] = int(cg.get("sdk_total_tokens",0))' not in s:
    if anchor not in s: raise SystemExit('sdk usage anchor missing')
    s=s.replace(anchor,insert,1)

# Existing child governor keeps hard budgets; make delegation stop earlier at 70% of BOTH dimensions.
old='''    async def _reserve_child(self, job: dict) -> bool:
        cg = job.get("cost_governor") or {}
'''
new='''    async def _reserve_child(self, job: dict) -> bool:
        cg = job.get("cost_governor") or {}
        if cg:
            token_cut = int(int(cg.get("sdk_token_budget",250000)) * 0.70)
            request_cut = int(int(cg.get("sdk_request_budget",60)) * 0.70)
            if int(cg.get("sdk_total_tokens",0)) >= token_cut or int(cg.get("sdk_requests",0)) >= request_cut:
                eg = job.get("efficiency_guardian")
                if isinstance(eg, dict): eg["blocked_delegations"] = int(eg.get("blocked_delegations",0)) + 1
                return False
'''
if 'request_cut = int(int(cg.get("sdk_request_budget",60)) * 0.70)' not in s:
    if old not in s: raise SystemExit('reserve child anchor missing')
    s=s.replace(old,new,1)

# Close guardian status on all ordinary successful completions.
old='''            root["status"] = "completed"
            job["status"] = "completed"
'''
new='''            guardian["status"] = "completed"
            root["status"] = "completed"
            job["status"] = "completed"
'''
if 'guardian["status"] = "completed"' not in s:
    if old not in s: raise SystemExit('root complete anchor missing')
    s=s.replace(old,new,1)

p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('"version":"0.10.2"','"version":"0.10.3"')
s=s.replace('"version": "0.10.2"','"version": "0.10.3"')
s=s.replace('version="0.10.2"','version="0.10.3"')
if 'efficiency-guardian-v0.10.3c' not in s:
    marker='human-intervention-v0.10.2'
    if marker not in s: raise SystemExit('architecture marker missing')
    s=s.replace(marker,marker+'+efficiency-guardian-v0.10.3c',1)
p.write_text(s)
PY

python3 -m py_compile "$ENGINE" "$MAIN"
grep -q 'work_modules = modules\[:3\]' "$ENGINE"
grep -q 'request_cut = int' "$ENGINE"
grep -q 'efficiency-guardian-v0.10.3c' "$MAIN"

# Free structural regression using source assertions; no model calls.
python3 - <<'PY'
from pathlib import Path
s=Path('/opt/fourth-law-agent/app/intelligence_engine.py').read_text()
assert 'planning_context = root_context + efficiency_directive' in s
assert 'plan["modules"][3] = {' in s
assert 'work_modules = modules[:3]' in s
assert '"mode":"efficiency_guardian"' in s
assert 'request_cut = int(int(cg.get("sdk_request_budget",60)) * 0.70)' in s
print('V0103C_STRUCTURAL_REGRESSION_OK')
PY

cd "$PROJECT"
docker compose build agent >/tmp/fl0103c-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl0103c-up.log 2>&1
ok=0
for i in $(seq 1 90); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.10.3"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/tmp/fl0103c-ui.html
grep -q 'Fourth Law' /tmp/fl0103c-ui.html

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'EFFICIENCY_GUARDIAN_V0_10_3C_DEPLOYED {"root_slots":4,"productive_agents":3,"efficiency_slot":4,"guardian_model_calls":0,"request_reserve":0.30,"token_reserve":0.30,"hard_budgets_unchanged":true,"health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true
echo EFFICIENCY_GUARDIAN_V0_10_3C_READY

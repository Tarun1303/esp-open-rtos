#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
PROBLEM="$PROJECT/app/problem_engine.py"
MAIN="$PROJECT/app/main.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.10.3-efficiency-governor-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$PROBLEM" "$BACKUP/problem_engine.py"
cp "$MAIN" "$BACKUP/main.py"
rollback(){
  set +e
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"
  cp "$BACKUP/problem_engine.py" "$PROBLEM"
  cp "$BACKUP/main.py" "$MAIN"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl0103-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl0103-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'EFFICIENCY_GOVERNOR_V0_10_3_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/problem_engine.py')
s=p.read_text()
if 'async def plan_intelligence_problem(' not in s:
    anchor='''    async def plan_problem(self, job: dict, root: dict, context: str) -> dict[str, Any]:\n'''
    method=r'''    async def plan_intelligence_problem(self, job: dict, root: dict, context: str) -> dict[str, Any]:
        """Plan only the three productive root domains; slot four is a coded Efficiency Governor."""
        pre = await self.supervisor_consult(job, root, "intelligence_problem_decomposition_precheck", context)
        last_error = ""
        for attempt in range(1, 3):
            prompt = f"""You are the Fourth Law Problem Supervisor.
Problem statement: {root['goal']}
Context: {context[-18000:]}
Supervisor precheck guidance: {json.dumps(pre, ensure_ascii=False)}
Previous planning error: {last_error}

The root runtime has FOUR primary agent slots by invariant. Slot 4 is permanently reserved for a deterministic Efficiency Governor and MUST NOT be planned as domain work.
Divide the COMPLETE productive problem into EXACTLY THREE balanced, complementary, non-overlapping WORK modules. Collectively those three work modules must cover 100% of the requested outcome; do not leave a quarter of the problem for the Efficiency Governor.
For EACH work module, predefine EXACTLY FOUR major work packages with a concrete task and an ideal expected outcome. Do not create execution micro-steps yet.
Keep module boundaries compact enough to reduce repeated context and cross-agent communication.

Return ONLY JSON:
{{
  "problem_summary":"...",
  "success_definition":"observable definition of overall success",
  "modules":[
    {{
      "name":"...",
      "role":"...",
      "objective":"...",
      "expected_module_outcome":"...",
      "balance_rationale":"why this is roughly one third of the productive work",
      "work_packages":[
        {{"title":"...","task":"...","expected_outcome":"..."}},
        {{"title":"...","task":"...","expected_outcome":"..."}},
        {{"title":"...","task":"...","expected_outcome":"..."}},
        {{"title":"...","task":"...","expected_outcome":"..."}}
      ]
    }}
  ]
}}
There MUST be exactly 3 work modules and exactly 4 work_packages in each module. Never create an Efficiency module; runtime owns it."""
            try:
                txt = await self.raw_response(
                    self.supervisor_model,
                    "Produce three balanced work modules. A coded Efficiency Governor occupies the fourth root slot. Operational summary only; no hidden chain-of-thought.",
                    prompt,
                    4300,
                )
                raw = self.parse_json_object(txt)
                modules = raw.get("modules")
                if not isinstance(modules, list) or len(modules) != 3:
                    raise ValueError("Intelligence Supervisor plan must contain exactly three work modules")
                # Reuse the battle-tested 4-module normalizer by adding a private fixed sentinel,
                # then discard the sentinel before any model-visible/runtime work.
                padded = dict(raw)
                padded["modules"] = list(modules) + [{
                    "name": "__EFFICIENCY_SENTINEL__",
                    "role": "runtime-only",
                    "objective": "runtime-only",
                    "expected_module_outcome": "runtime-only",
                    "balance_rationale": "runtime-only",
                    "work_packages": [
                        {"title": f"Runtime {i}", "task": "runtime-only", "expected_outcome": "runtime-only"}
                        for i in range(1, 5)
                    ],
                }]
                normalized = self._normalize_problem_plan(padded)
                normalized["modules"] = normalized["modules"][:3]
                job["problem_plan"] = normalized
                await self.emit(
                    job, "problem_plan",
                    "Supervisor created 3 productive modules; root slot 4 reserved for Efficiency Governor",
                    node=root, module_count=3, efficiency_governor=True,
                )
                return normalized
            except Exception as exc:
                last_error = str(exc)
                await self.emit(job, "problem_plan_recovery", f"Three-work-module planning attempt {attempt} rejected: {last_error}", node=root)
        raise RuntimeError(f"Problem Supervisor could not produce a valid 3-work-module plan: {last_error}")

'''
    if anchor not in s: raise SystemExit('plan_problem anchor missing')
    s=s.replace(anchor,method+anchor,1)
p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s=p.read_text()

# Intelligence planning uses the new three-work-module planner only; legacy /problem remains unchanged.
old='plan = await self.problem_engine.plan_problem(job, root, root_context)'
new='plan = await self.problem_engine.plan_intelligence_problem(job, root, root_context)'
if new not in s:
    if old not in s: raise SystemExit('intelligence planning call anchor missing')
    s=s.replace(old,new,1)

# Deterministic Efficiency Governor: no LLM, no delegation, safe telemetry only.
if 'def _efficiency_make_node(' not in s:
    anchor='''    async def _reserve_child(self, job: dict) -> bool:\n'''
    methods=r'''    def _efficiency_make_node(self, job: dict, root: dict) -> dict:
        eg = job.setdefault("efficiency_governor", {
            "version": "1.0",
            "mode": "deterministic-local",
            "request_reserve_ratio": 0.30,
            "token_reserve_ratio": 0.30,
            "prompt_compactions": 0,
            "preflight_calls": 0,
            "blocked_delegations": 0,
            "max_prompt_chars_seen": 0,
            "last_stage": "root_planning",
        })
        return {
            "id": uuid.uuid4().hex[:12],
            "parent_id": root["id"],
            "name": "Efficiency Governor",
            "role": "Token / Context / Delegation Efficiency Governor",
            "goal": "Continuously enforce bounded prompts, outputs, requests, delegation headroom, and concise inter-agent communication.",
            "expected_module_outcome": "All work remains inside coded token/request/context boundaries with synthesis and recovery headroom preserved.",
            "depth": 1,
            "status": "monitoring",
            "mode": "efficiency_governor",
            "supervisor_tasks": [],
            "children": [],
            "steps": [],
            "result": "Deterministic efficiency monitoring active; no model calls allocated to this governor.",
            "error": "",
            "sdk_usage": {"requests": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
            "understanding": {
                "normalized_goal": "Enforce token, request, context, output and delegation efficiency for this mission.",
                "deliverables": ["bounded context", "reserved synthesis headroom", "delegation control", "efficiency telemetry"],
                "constraints": ["no LLM calls", "no child agents", "no safety-boundary relaxation"],
                "success_criteria": ["budgets remain bounded", "prompt caps enforced", "delegation stops before exhaustion"],
                "uncertainties": [], "complexity": 1, "recommended_strategy": "direct",
            },
            "intelligence_plan": {
                "strategy": "direct",
                "synthesis_goal": "Keep execution efficient without consuming an agent model budget.",
                "rationale": "Efficiency enforcement is coded runtime governance, not a reasoning workload.",
                "steps": [],
            },
        }

    def _efficiency_sync(self, job: dict, *, stage: str = "", original_prompt_chars: int = 0, prompt_chars: int = 0, estimated_input: int = 0) -> dict:
        eg = job.setdefault("efficiency_governor", {
            "version": "1.0", "mode": "deterministic-local", "request_reserve_ratio": 0.30,
            "token_reserve_ratio": 0.30, "prompt_compactions": 0, "preflight_calls": 0,
            "blocked_delegations": 0, "max_prompt_chars_seen": 0, "last_stage": "",
        })
        cg = job.get("cost_governor") or {}
        eg["sdk_requests"] = int(cg.get("sdk_requests", 0))
        eg["sdk_request_budget"] = int(cg.get("sdk_request_budget", 60))
        eg["sdk_total_tokens"] = int(cg.get("sdk_total_tokens", 0))
        eg["sdk_token_budget"] = int(cg.get("sdk_token_budget", 250000))
        eg["prompt_char_cap"] = int(cg.get("prompt_char_cap", 9000))
        eg["estimated_input_token_cap"] = int(cg.get("estimated_input_token_cap", 3200))
        if stage:
            eg["last_stage"] = str(stage)[:120]
            eg["preflight_calls"] = int(eg.get("preflight_calls", 0)) + 1
        if original_prompt_chars:
            eg["max_prompt_chars_seen"] = max(int(eg.get("max_prompt_chars_seen", 0)), int(original_prompt_chars))
            if prompt_chars and int(prompt_chars) < int(original_prompt_chars):
                eg["prompt_compactions"] = int(eg.get("prompt_compactions", 0)) + 1
        if estimated_input:
            eg["last_estimated_input_tokens"] = int(estimated_input)
        req_budget=max(1,int(eg.get("sdk_request_budget",60)))
        tok_budget=max(1,int(eg.get("sdk_token_budget",250000)))
        eg["request_ratio"] = round(int(eg.get("sdk_requests",0))/req_budget,4)
        eg["token_ratio"] = round(int(eg.get("sdk_total_tokens",0))/tok_budget,4)
        summary=(
            f"Requests {eg['sdk_requests']}/{req_budget} · SDK tokens {eg['sdk_total_tokens']}/{tok_budget} · "
            f"prompt compactions {eg.get('prompt_compactions',0)} · delegation reserve 30%"
        )
        for n in (job.get("root") or {}).get("children", []):
            if n.get("mode") == "efficiency_governor":
                if str(job.get("status", "")) in {"completed","partial","failed","rolled_back"}:
                    n["status"] = "completed"
                else:
                    n["status"] = "monitoring"
                n["result"] = summary
                break
        return eg

'''
    if anchor not in s: raise SystemExit('reserve child anchor missing')
    s=s.replace(anchor,methods+anchor,1)

# Track prompt compaction and estimated input at every SDK call boundary.
if 'original_prompt_chars = len(prompt)' not in s:
    anchor='''        cap = int(cg["prompt_char_cap"])\n'''
    if anchor not in s: raise SystemExit('prompt cap anchor missing')
    s=s.replace(anchor,'        original_prompt_chars = len(prompt)\n'+anchor,1)

if 'self._efficiency_sync(job, stage=stage' not in s:
    anchor='''        stage_u = stage.upper()\n'''
    insert='''        self._efficiency_sync(job, stage=stage, original_prompt_chars=original_prompt_chars, prompt_chars=len(prompt), estimated_input=estimated_input)\n\n'''
    if anchor not in s: raise SystemExit('stage_u anchor missing')
    s=s.replace(anchor,insert+anchor,1)

# Preserve 30% of both request and token budgets before creating deeper agents.
s=s.replace('int(int(cg.get("sdk_token_budget", 250000)) * 0.80)', 'int(int(cg.get("sdk_token_budget", 250000)) * 0.70)', 1)
if 'blocked_delegations' in s:
    old='''            if int(cg.get("sdk_requests", 0)) >= int(int(cg.get("sdk_request_budget", 60)) * 0.70):\n                return False\n'''
    new='''            if int(cg.get("sdk_requests", 0)) >= int(int(cg.get("sdk_request_budget", 60)) * 0.70):\n                eg = self._efficiency_sync(job)\n                eg["blocked_delegations"] = int(eg.get("blocked_delegations", 0)) + 1\n                return False\n'''
    if old in s: s=s.replace(old,new,1)

# Root invariant: 3 work agents + fixed Efficiency Governor = exactly four primary children.
if 'governor = self._efficiency_make_node(job, root)' not in s:
    anchor='''            root["children"] = modules\n            await self.persist(job)\n\n            results = await asyncio.gather(*[self.run_node(job, module, "") for module in modules], return_exceptions=True)\n'''
    replacement='''            if len(modules) != 3:\n                raise RuntimeError(f"Efficiency architecture requires exactly 3 work modules; got {len(modules)}")\n            if not await self._reserve_child(job):\n                raise RuntimeError("Agent budget exhausted before Efficiency Governor could be created")\n            governor = self._efficiency_make_node(job, root)\n            root["children"] = modules + [governor]\n            self._efficiency_sync(job)\n            await self.emit(job, "efficiency_governor_start", "Fourth root slot assigned to deterministic Efficiency Governor", node=governor)\n            await self.persist(job)\n\n            results = await asyncio.gather(*[self.run_node(job, module, "") for module in modules], return_exceptions=True)\n'''
    if anchor not in s: raise SystemExit('root children block anchor missing')
    s=s.replace(anchor,replacement,1)

# Final Supervisor semantics describe the actual architecture, not four productive agents.
s=s.replace('Four major agents completed. Success definition:', 'Three work agents completed under the Efficiency Governor. Success definition:', 1)

# Close governor cleanly at terminal successful completion.
anchor='''            root["status"] = "completed"\n            job["status"] = "completed"\n'''
if 'governor["status"] = "completed"' not in s:
    replacement='''            governor["status"] = "completed"\n            self._efficiency_sync(job)\n            root["status"] = "completed"\n            job["status"] = "completed"\n'''
    if anchor not in s: raise SystemExit('completion anchor missing')
    s=s.replace(anchor,replacement,1)

p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('"version":"0.10.2"','"version":"0.10.3"')
s=s.replace('"version": "0.10.2"','"version": "0.10.3"')
s=s.replace('version="0.10.2"','version="0.10.3"')
marker='human-intervention-v0.10.2'
if 'efficiency-governor-v0.10.3' not in s:
    if marker not in s: raise SystemExit('v0.10.2 architecture marker missing')
    s=s.replace(marker,marker+'+efficiency-governor-v0.10.3',1)
# live state metadata: four primary slots, one is governor; deeper cap remains two.
s=s.replace('"problem_mode":"4 major agents; 4 supervisor work packages each; 2-10 sequential execution steps"',
            '"problem_mode":"4 primary slots: 3 productive agents + 1 deterministic Efficiency Governor; 4 supervisor work packages per productive agent; deeper max 2 children"')
p.write_text(s)
PY

python3 -m py_compile "$ENGINE" "$PROBLEM" "$MAIN"
grep -q 'plan_intelligence_problem' "$PROBLEM"
grep -q 'Efficiency Governor' "$ENGINE"
grep -q 'modules + \[governor\]' "$ENGINE"

# Local zero-model regression of governor structure and request/delegation boundary.
cd "$PROJECT"
python3 - <<'PY'
import asyncio
from app.intelligence_engine import IntelligenceEngine

e=object.__new__(IntelligenceEngine)
e._budget_locks={}
root={'id':'root','children':[]}
job={'id':'test','status':'running','root':root,'agents_created':5,'agent_budget':12,
     'cost_governor':{'sdk_requests':42,'sdk_request_budget':60,'sdk_total_tokens':1000,'sdk_token_budget':250000,
                      'prompt_char_cap':9000,'estimated_input_token_cap':3200}}
g=e._efficiency_make_node(job,root)
root['children']=[g]
assert g['mode']=='efficiency_governor' and g['children']==[] and g['sdk_usage']['requests']==0
e._efficiency_sync(job,stage='TEST',original_prompt_chars=12000,prompt_chars=8000,estimated_input=2000)
assert job['efficiency_governor']['prompt_compactions']==1
assert asyncio.run(e._reserve_child(job)) is False, 'delegation must stop at 70% request budget'
assert job['efficiency_governor']['blocked_delegations']>=1
print('EFFICIENCY_GOVERNOR_LOCAL_TEST_OK')
PY

cd "$PROJECT"
docker compose build agent >/tmp/fl0103-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl0103-up.log 2>&1
ok=0
for i in $(seq 1 75); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.10.3"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/tmp/fl0103-ui.html
grep -q 'fl-human-intervention-v0102' /tmp/fl0103-ui.html

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'EFFICIENCY_GOVERNOR_V0_10_3_DEPLOYED {"root_primary_slots":4,"productive_agents":3,"efficiency_governor":1,"governor_model_calls":0,"governor_children":0,"request_delegation_stop_ratio":0.70,"token_delegation_stop_ratio":0.70,"prompt_compaction_tracking":true,"estimated_input_cap_enforced":true,"stage_output_ceiling_preserved":true,"agent_budget":12,"deeper_child_cap":2,"full_history_replay":false,"local_regression":"ok","health":"ok","human_intervention_preserved":true}' >/dev/null 2>&1 || true
echo EFFICIENCY_GOVERNOR_V0_10_3_READY

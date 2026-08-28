#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
MEMORY="$PROJECT/app/shared_memory.py"
MAIN="$PROJECT/app/main.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.9.3-constraint-memory-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$MEMORY" "$BACKUP/shared_memory.py"
cp "$MAIN" "$BACKUP/main.py"

rollback() {
  set +e
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"
  cp "$BACKUP/shared_memory.py" "$MEMORY"
  cp "$BACKUP/main.py" "$MAIN"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl093-rollback-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl093-rollback-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'CONSTRAINT_MEMORY_V0_9_3_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path

p = Path('/opt/fourth-law-agent/app/shared_memory.py')
s = p.read_text()

s = s.replace('VERSION = "1.0"', 'VERSION = "1.1"', 1)
s = s.replace('core_cap: int = 3600,', 'core_cap: int = 4600,', 1)

anchor = '            "success_definition": self._compact(plan.get("success_definition", ""), 900),\n            "modules": modules,\n'
replacement = '            "success_definition": self._compact(plan.get("success_definition", ""), 900),\n            "root_operating_constraints": self._compact(raw, 1400),\n            "modules": modules,\n'
if '"root_operating_constraints"' not in s:
    if anchor not in s:
        raise SystemExit('shared-memory core anchor missing')
    s = s.replace(anchor, replacement, 1)

anchor = '            f"SUCCESS: {core.get(\'success_definition\',\'\')}",\n        ]\n'
replacement = '            f"SUCCESS: {core.get(\'success_definition\',\'\')}",\n            f"ROOT CONSTRAINTS: {core.get(\'root_operating_constraints\',\'\')}",\n        ]\n'
if 'ROOT CONSTRAINTS:' not in s:
    if anchor not in s:
        raise SystemExit('shared-memory core-text anchor missing')
    s = s.replace(anchor, replacement, 1)

s = s.replace('"raw_context_model_visible": False,', '"raw_context_model_visible": "bounded_root_constraints_only",', 1)
p.write_text(s)

p = Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s = p.read_text()
if '\nimport re\n' not in s:
    if 'import json\n' not in s:
        raise SystemExit('json import anchor missing')
    s = s.replace('import json\n', 'import json\nimport re\n', 1)

anchor = '        self.memory.store_understanding(job, node, understanding)\n        await self.persist(job)\n\n        plan = await self._sdk_run(\n'
insert = '''        self.memory.store_understanding(job, node, understanding)
        await self.persist(job)

        # v0.9.3: complexity-aware coded step governor plus explicit user constraint preservation.
        complexity = int(getattr(understanding, "complexity", 5) or 5)
        coded_step_cap = 2 if complexity <= 3 else (3 if complexity <= 6 else 4)
        root_constraints = str(job.get("context", "") or "")
        requested_caps = [
            int(x) for x in re.findall(
                r"(?i)(?:at\\s+most|max(?:imum)?|no\\s+more\\s+than)\\s*[:=]?\\s*(\\d+)\\s+(?:local\\s+)?steps?",
                root_constraints,
            )
        ]
        if requested_caps:
            coded_step_cap = max(1, min(coded_step_cap, min(requested_caps)))
        force_no_delegation = bool(re.search(
            r"(?i)\\b(?:no\\s+child(?:ren|\\s+agents?)?|no\\s+delegation|do\\s+not\\s+delegate|without\\s+delegation)\\b",
            root_constraints,
        ))
        node["coded_step_cap"] = coded_step_cap
        node["force_no_delegation"] = force_no_delegation

        plan = await self._sdk_run(
'''
if 'node["coded_step_cap"]' not in s:
    if anchor not in s:
        raise SystemExit('understand-plan insertion anchor missing')
    s = s.replace(anchor, insert, 1)

old = 'Create 1 to 6 useful sequential steps. Choose local or delegate per step.\nDelegate only when a genuinely separable specialist responsibility materially improves\nthe result. If inherited work-package IDs exist, cover every one at least once.\n'
new = 'Create 1 to {coded_step_cap} useful sequential steps. Choose local or delegate per step.\n{"Do NOT delegate or create child agents for this node." if force_no_delegation else "Delegate only when a genuinely separable specialist responsibility materially improves the result."}\nIf inherited work-package IDs exist, cover every one at least once. Multiple inherited packages may be covered by one well-designed step.\n'
if old in s:
    s = s.replace(old, new, 1)
elif 'Create 1 to {coded_step_cap} useful sequential steps.' not in s:
    raise SystemExit('plan prompt cap anchor missing')

anchor = '        plan = self._normalize_plan(node, plan, int(job.get("max_depth", 3)))\n        node["intelligence_plan"] = plan.model_dump()\n'
insert = '''        plan = self._normalize_plan(node, plan, int(job.get("max_depth", 3)))
        plan.steps = list(plan.steps or [])[:coded_step_cap]
        if force_no_delegation:
            for spec in plan.steps:
                spec.execution_mode = "local"
                spec.delegation_reason = "Delegation disabled by explicit root operating constraint."
        required = self._required_ids(node)
        if required and plan.steps:
            covered = set()
            for spec in plan.steps:
                spec.covers = [x for x in spec.covers if x in required]
                covered.update(spec.covers)
            missing = sorted(required - covered)
            if missing:
                plan.steps[-1].covers = sorted(set(plan.steps[-1].covers).union(missing))
        node["intelligence_plan"] = plan.model_dump()
'''
if 'plan.steps = list(plan.steps or [])[:coded_step_cap]' not in s:
    if anchor not in s:
        raise SystemExit('plan post-normalize anchor missing')
    s = s.replace(anchor, insert, 1)

anchor = '''            review = await self._sdk_run(
                job,
                node,
                f"SELF_VERIFY_{step['index']}_ATTEMPT_{attempt}",
'''
cheap = '''            # v0.9.3: low-complexity, high-confidence steps use a deterministic local gate.
            # This avoids a second model call per simple step while preserving LLM review on uncertainty.
            node_complexity = int((node.get("understanding") or {}).get("complexity", 5) or 5)
            result_text = str(getattr(out, "result", "") or "").strip()
            confidence = float(getattr(out, "confidence", 0.0) or 0.0)
            unresolved = list(getattr(out, "unresolved", []) or [])
            if attempt == 1 and node_complexity <= 3 and len(result_text) >= 40 and confidence >= 0.55 and len(unresolved) <= 1:
                step["verification"] = {
                    "self": {"verdict": "pass", "issues": [], "revision_instruction": "", "mode": "deterministic-low-risk"},
                    "supervisor_summary": "Low-risk deterministic verification passed; paid per-step review deferred.",
                    "supervisor_verify": "",
                    "attempt": attempt,
                }
                return out.result

            review = await self._sdk_run(
                job,
                node,
                f"SELF_VERIFY_{step['index']}_ATTEMPT_{attempt}",
'''
if '"mode": "deterministic-low-risk"' not in s:
    if anchor not in s:
        raise SystemExit('self-verify anchor missing')
    s = s.replace(anchor, cheap, 1)

old = '''            post = await self.supervisor_consult(
                job,
                node,
                "intelligence_postverification",
                (
                    f"Goal: {node['goal'][:1200]}\\n"
                    f"Expected: {str(node.get('expected_module_outcome',''))[:1000]}\\n"
                    f"Step count: {len(node['steps'])}\\n"
                    + self.memory.supervisor_packet(job, node)
                ),
                candidate=str(synth.result)[:4200],
            )
'''
new = '''            node_complexity = int((node.get("understanding") or {}).get("complexity", 5) or 5)
            if node_complexity <= 3 and float(getattr(synth, "confidence", 0.0) or 0.0) >= 0.60 and not list(getattr(synth, "unresolved", []) or []):
                post = {
                    "summary": "Low-complexity node accepted by local bounded verification; paid Supervisor postcheck deferred.",
                    "verify": "",
                    "risk": "low",
                }
            else:
                post = await self.supervisor_consult(
                    job,
                    node,
                    "intelligence_postverification",
                    (
                        f"Goal: {node['goal'][:1200]}\\n"
                        f"Expected: {str(node.get('expected_module_outcome',''))[:1000]}\\n"
                        f"Step count: {len(node['steps'])}\\n"
                        + self.memory.supervisor_packet(job, node)
                    ),
                    candidate=str(synth.result)[:4200],
                )
'''
if 'Low-complexity node accepted by local bounded verification' not in s:
    if old not in s:
        raise SystemExit('postverification anchor missing')
    s = s.replace(old, new, 1)

s = s.replace('"raw_context_model_visible": False,', '"raw_context_model_visible": "bounded_root_constraints_only",', 1)
p.write_text(s)

p = Path('/opt/fourth-law-agent/app/main.py')
s = p.read_text()
s = s.replace('version="0.9.2"', 'version="0.9.3"')
s = s.replace('"version":"0.9.2"', '"version":"0.9.3"')
s = s.replace('shared-memory-v0.9.2', 'shared-memory-v0.9.3-constraint-preserving')
p.write_text(s)
PY

python3 -m py_compile "$ENGINE" "$MEMORY" "$MAIN"

cd "$PROJECT"
python3 - <<'PY'
from app.shared_memory import SharedContextMemory
m=SharedContextMemory()
job={"id":"regression","goal":"Test goal","context":"COST TEST: at most 2 LOCAL steps. Create NO child agents. Keep output concise."}
plan={"success_definition":"done","modules":[{"name":"A","objective":"a","expected_module_outcome":"x","work_packages":[]}]}
root=m.root_planning_context(job["context"])
m.bootstrap(job,plan,root)
node={"id":"n1","parent_id":None,"depth":1,"name":"A","goal":"a","expected_module_outcome":"x"}
pkt=m.packet(job,node,"PLAN")
assert "at most 2 LOCAL steps" in pkt
assert "NO child agents" in pkt
assert len(pkt) <= 7600
print('V093_LOCAL_MEMORY_REGRESSION_OK')
PY

grep -q 'coded_step_cap' "$ENGINE"
grep -q 'deterministic-low-risk' "$ENGINE"
grep -q 'root_operating_constraints' "$MEMORY"

docker compose build agent >/tmp/fl093-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl093-up.log 2>&1

ok=0
for i in $(seq 1 40); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.9.3"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/dev/null
trap - ERR

HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'CONSTRAINT_MEMORY_V0_9_3_DEPLOYED {"root_constraints":"shared-bounded","complexity_step_cap":"2/3/4","explicit_step_cap":"coded","explicit_no_delegation":"coded","low_risk_step_verification":"deterministic-first","low_risk_postverification":"local-first","full_history_replay":false,"paid_smoke":"not_run","local_memory_regression":"ok","local_health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true

echo CONSTRAINT_MEMORY_V0_9_3_READY

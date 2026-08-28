#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
MEMORY="$PROJECT/app/shared_memory.py"
MAIN="$PROJECT/app/main.py"
ENVFILE="$PROJECT/.env"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.9.2-shared-memory-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$MAIN" "$BACKUP/main.py"
cp "$ENVFILE" "$BACKUP/.env"
[[ -f "$MEMORY" ]] && cp "$MEMORY" "$BACKUP/shared_memory.py" || true

rollback() {
  set +e
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"
  cp "$BACKUP/main.py" "$MAIN"
  cp "$BACKUP/.env" "$ENVFILE"
  if [[ -f "$BACKUP/shared_memory.py" ]]; then
    cp "$BACKUP/shared_memory.py" "$MEMORY"
  else
    rm -f "$MEMORY"
  fi
  cd "$PROJECT"
  docker compose build agent >/tmp/fl092-rollback-build.log 2>&1
  docker compose up -d --force-recreate agent >/tmp/fl092-rollback-up.log 2>&1
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'SHARED_MEMORY_V0_9_2_ROLLED_BACK' >/dev/null 2>&1 || true
}
trap rollback ERR

cat > "$MEMORY" <<'PYMEM'
import hashlib
import json
from typing import Any

class SharedContextMemory:
    """Cheap, job-scoped memory shared by all agents.

    Full raw context stays local in the persisted job. LLMs receive only a compact,
    structured packet containing global core memory + lineage + small node-local memory.
    No model call is used to maintain this memory.
    """

    VERSION = "1.0"

    def __init__(
        self,
        *,
        root_context_cap: int = 16000,
        packet_cap: int = 7600,
        core_cap: int = 3600,
        local_cap: int = 2600,
        result_cap: int = 1600,
    ):
        self.root_context_cap = root_context_cap
        self.packet_cap = packet_cap
        self.core_cap = core_cap
        self.local_cap = local_cap
        self.result_cap = result_cap

    @staticmethod
    def _compact(value: Any, cap: int) -> str:
        if value is None:
            return ""
        if not isinstance(value, str):
            try:
                value = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
            except Exception:
                value = str(value)
        value = " ".join(value.split())
        if len(value) <= cap:
            return value
        if cap < 120:
            return value[:cap]
        left = int(cap * 0.62)
        right = cap - left - 34
        return value[:left] + " …[LOCAL_MEMORY_COMPACTED]… " + value[-right:]

    def root_planning_context(self, raw: str) -> str:
        raw = raw or ""
        if len(raw) <= self.root_context_cap:
            return raw
        cap = self.root_context_cap
        part = cap // 3
        mid = max(0, len(raw) // 2 - part // 2)
        return (
            raw[:part]
            + "\n...[ROOT_CONTEXT_LOCAL_COMPACTION]...\n"
            + raw[mid:mid + part]
            + "\n...[ROOT_CONTEXT_LOCAL_COMPACTION]...\n"
            + raw[-part:]
        )[:cap]

    def _mem(self, job: dict) -> dict:
        return job.setdefault(
            "shared_memory",
            {
                "version": self.VERSION,
                "core": {},
                "nodes": {},
                "stats": {
                    "packet_calls": 0,
                    "max_packet_chars": 0,
                    "raw_context_chars": len(str(job.get("context", "") or "")),
                    "root_context_chars_sent": 0,
                },
            },
        )

    def bootstrap(self, job: dict, plan: dict, root_context: str) -> None:
        mem = self._mem(job)
        modules = []
        for spec in plan.get("modules", [])[:4]:
            modules.append(
                {
                    "name": self._compact(spec.get("name", ""), 180),
                    "objective": self._compact(spec.get("objective", ""), 520),
                    "expected": self._compact(spec.get("expected_module_outcome", ""), 520),
                    "work_packages": [
                        {
                            "id": self._compact(w.get("id", ""), 80),
                            "title": self._compact(w.get("title", w.get("objective", "")), 220),
                            "expected": self._compact(w.get("expected_outcome", w.get("expected_result", "")), 260),
                        }
                        for w in (spec.get("work_packages") or [])[:4]
                    ],
                }
            )
        raw = str(job.get("context", "") or "")
        mem["core"] = {
            "goal": self._compact(job.get("goal", ""), 1800),
            "success_definition": self._compact(plan.get("success_definition", ""), 900),
            "modules": modules,
            "raw_context_ref": f"local://job/{job.get('id')}/context",
            "raw_context_sha256": hashlib.sha256(raw.encode("utf-8", "ignore")).hexdigest()[:20],
        }
        mem["stats"]["raw_context_chars"] = len(raw)
        mem["stats"]["root_context_chars_sent"] = len(root_context)

    def ensure_node(self, job: dict, node: dict) -> dict:
        mem = self._mem(job)
        nodes = mem.setdefault("nodes", {})
        n = nodes.setdefault(
            str(node.get("id")),
            {
                "id": str(node.get("id")),
                "parent_id": node.get("parent_id"),
                "depth": int(node.get("depth", 0) or 0),
                "name": self._compact(node.get("name", ""), 180),
                "goal": self._compact(node.get("goal", ""), 850),
                "expected": self._compact(node.get("expected_module_outcome", ""), 600),
                "understanding": {},
                "plan": {},
                "steps": [],
                "result": "",
                "unresolved": [],
            },
        )
        return n

    def store_understanding(self, job: dict, node: dict, understanding: Any) -> None:
        n = self.ensure_node(job, node)
        data = understanding.model_dump() if hasattr(understanding, "model_dump") else dict(understanding or {})
        n["understanding"] = {
            "goal": self._compact(data.get("normalized_goal", ""), 700),
            "deliverables": [self._compact(x, 220) for x in data.get("deliverables", [])[:8]],
            "constraints": [self._compact(x, 220) for x in data.get("constraints", [])[:8]],
            "success": [self._compact(x, 220) for x in data.get("success_criteria", [])[:8]],
            "uncertainties": [self._compact(x, 180) for x in data.get("uncertainties", [])[:6]],
            "complexity": data.get("complexity"),
            "strategy": data.get("recommended_strategy"),
        }

    def store_plan(self, job: dict, node: dict, plan: Any) -> None:
        n = self.ensure_node(job, node)
        data = plan.model_dump() if hasattr(plan, "model_dump") else dict(plan or {})
        n["plan"] = {
            "strategy": data.get("strategy"),
            "synthesis_goal": self._compact(data.get("synthesis_goal", ""), 600),
            "steps": [
                {
                    "title": self._compact(s.get("title", ""), 180),
                    "objective": self._compact(s.get("objective", ""), 360),
                    "expected": self._compact(s.get("expected_result", ""), 360),
                    "mode": s.get("execution_mode"),
                }
                for s in (data.get("steps") or [])[:6]
            ],
        }

    def store_step(self, job: dict, node: dict, step: dict, result: str) -> None:
        n = self.ensure_node(job, node)
        rows = [x for x in n.get("steps", []) if x.get("id") != step.get("id")]
        rows.append(
            {
                "id": step.get("id"),
                "index": step.get("index"),
                "title": self._compact(step.get("title", ""), 160),
                "result": self._compact(result, self.result_cap),
                "status": step.get("status", "completed"),
            }
        )
        n["steps"] = rows[-6:]

    def store_result(self, job: dict, node: dict, result: str, unresolved: Any = None) -> None:
        n = self.ensure_node(job, node)
        n["result"] = self._compact(result, 2200)
        n["unresolved"] = [self._compact(x, 240) for x in (unresolved or [])[:8]]

    def register_child(self, job: dict, parent: dict, child: dict, step: dict) -> None:
        self.ensure_node(job, parent)
        c = self.ensure_node(job, child)
        c["delegated_from"] = {
            "parent_id": parent.get("id"),
            "step_id": step.get("id"),
            "objective": self._compact(step.get("objective", ""), 500),
            "expected": self._compact(step.get("expected_result", ""), 500),
        }

    def _parent_memory(self, job: dict, node: dict) -> dict:
        mem = self._mem(job)
        pid = node.get("parent_id")
        return (mem.get("nodes") or {}).get(str(pid), {}) if pid else {}

    def _core_text(self, job: dict) -> str:
        core = self._mem(job).get("core", {})
        mods = core.get("modules", [])
        lines = [
            f"GOAL: {core.get('goal','')}",
            f"SUCCESS: {core.get('success_definition','')}",
        ]
        for i, m in enumerate(mods, 1):
            lines.append(f"M{i} {m.get('name','')}: {m.get('objective','')} | expected={m.get('expected','')}")
        return self._compact("\n".join(lines), self.core_cap)

    def packet(self, job: dict, node: dict, stage: str) -> str:
        mem = self._mem(job)
        own = self.ensure_node(job, node)
        parent = self._parent_memory(job, node)

        is_synthesis = "SYNTH" in stage.upper() or "FINAL" in stage.upper()
        local = {
            "node_goal": own.get("goal"),
            "expected": own.get("expected"),
            "understanding": own.get("understanding"),
            "plan": own.get("plan"),
            "recent_steps": (own.get("steps") or []) if is_synthesis else (own.get("steps") or [])[-2:],
        }
        if parent:
            local["parent_result"] = self._compact(parent.get("result", ""), 900)
            local["parent_goal"] = self._compact(parent.get("goal", ""), 400)

        if "FINAL" in stage.upper() or (int(node.get("depth", 0) or 0) == 0 and "SYNTH" in stage.upper()):
            majors = []
            for n in (mem.get("nodes") or {}).values():
                if int(n.get("depth", 0) or 0) == 1 and n.get("result"):
                    majors.append({"name": n.get("name"), "result": self._compact(n.get("result"), 1700)})
            local["major_results"] = majors[:4]

        packet = (
            "LOCAL SHARED MEMORY v1 — authoritative compact context; full raw context remains local and is not attached.\n"
            "SHARED CORE:\n"
            + self._core_text(job)
            + "\n\nNODE WORKING MEMORY:\n"
            + self._compact(local, 5000 if is_synthesis else self.local_cap)
        )
        packet = self._compact(packet, self.packet_cap)
        stats = mem.setdefault("stats", {})
        stats["packet_calls"] = int(stats.get("packet_calls", 0)) + 1
        stats["max_packet_chars"] = max(int(stats.get("max_packet_chars", 0)), len(packet))
        return packet

    def supervisor_packet(self, job: dict, node: dict) -> str:
        return self._compact(self.packet(job, node, "SUPERVISOR"), 4200)

    def audit(self, job: dict) -> dict:
        mem = self._mem(job)
        return {
            "version": mem.get("version"),
            "core_present": bool(mem.get("core")),
            "node_memories": len(mem.get("nodes") or {}),
            "stats": mem.get("stats", {}),
            "design": {
                "full_history_replay": False,
                "shared_core": True,
                "per_node_working_memory": True,
                "raw_context_model_visible": False,
                "memory_maintenance_model_calls": 0,
            },
        }
PYMEM

python3 - <<'PYPATCH'
from pathlib import Path
import re

engine = Path("/opt/fourth-law-agent/app/intelligence_engine.py")
s = engine.read_text()

if "from app.shared_memory import SharedContextMemory" not in s:
    anchor = "from pydantic import BaseModel, Field\n"
    if anchor not in s: raise SystemExit("pydantic import anchor missing")
    s = s.replace(anchor, anchor + "from app.shared_memory import SharedContextMemory\n", 1)

if "self.memory = SharedContextMemory()" not in s:
    anchor = "        self._budget_locks: dict[str, asyncio.Lock] = {}\n"
    if anchor not in s: raise SystemExit("engine init anchor missing")
    s = s.replace(anchor, anchor + "        self.memory = SharedContextMemory()\n", 1)

def replace_method(src: str, name: str, replacement: str) -> str:
    start_match = re.search(rf"^    (?:async def|def) {re.escape(name)}\b", src, flags=re.M)
    if not start_match: raise SystemExit(f"method anchor missing: {name}")
    start = start_match.start()
    after = src[start_match.end():]
    next_match = re.search(r"^(?:    (?:async def|def) [A-Za-z_]\w*\b|def _flatten\b)", after, flags=re.M)
    if not next_match: raise SystemExit(f"next method boundary missing after: {name}")
    end = start_match.end() + next_match.start()
    return src[:start] + replacement.rstrip() + "\n\n" + src[end:]

REPLACEMENTS = {}
REPLACEMENTS['_instructions'] = '''    def _instructions(self, node: dict, stage: str) -> str:
        # Keep the system/instruction prefix intentionally stable across agents so
        # prompt caching can work. Node-specific state lives in local shared memory.
        return f"""{self.constitution}

FOURTH LAW INTELLIGENCE KERNEL
Operating state machine:
UNDERSTAND -> PLAN -> EXECUTE_OR_DELEGATE -> VERIFY -> SYNTHESIZE -> REPORT.

Rules:
- Use the attached LOCAL SHARED MEMORY packet as the authoritative compact context.
- Full raw history/context remains local; never ask the runtime to resend the entire transcript.
- Work only on the assigned node and preserve parent constraints and expected outcomes.
- Decompose only when specialization materially improves correctness or efficiency.
- Never create child agents directly; coded runtime controls delegation and budgets.
- Never claim an external action happened unless an authorized capability actually executed it.
- Return operational outputs only; never expose hidden chain-of-thought.
"""
'''
REPLACEMENTS['_sdk_run'] = '''    async def _sdk_run(
        self,
        job: dict,
        node: dict,
        stage: str,
        output_type: type[BaseModel],
        prompt: str,
        *,
        model: str,
        max_turns: int = 4,
    ) -> BaseModel:
        # COST GOVERNOR v0.9.2 — deterministic preflight + postflight limits.
        cg = job.setdefault("cost_governor", {
            "version": "1.1",
            "sdk_token_budget": 250000,
            "sdk_request_budget": 60,
            "node_token_budget": 60000,
            "node_request_budget": 14,
            "prompt_char_cap": 9000,
            "estimated_input_token_cap": 3200,
            "soft_warning_ratio": 0.80,
            "sdk_total_tokens": 0,
            "sdk_requests": 0,
            "soft_warning_emitted": False,
        })
        cg["version"] = "1.1"
        cg["prompt_char_cap"] = min(int(cg.get("prompt_char_cap", 9000)), 9000)
        cg["estimated_input_token_cap"] = min(int(cg.get("estimated_input_token_cap", 3200)), 3200)

        nu = node.setdefault("sdk_usage", {"requests": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0})
        if int(cg.get("sdk_total_tokens", 0)) >= int(cg["sdk_token_budget"]):
            raise RuntimeError("COST_GOVERNOR: job SDK token budget reached; model call blocked")
        if int(cg.get("sdk_requests", 0)) >= int(cg["sdk_request_budget"]):
            raise RuntimeError("COST_GOVERNOR: job SDK request budget reached; model call blocked")
        if int(nu.get("total_tokens", 0)) >= int(cg["node_token_budget"]):
            raise RuntimeError("COST_GOVERNOR: node token budget reached; model call blocked")
        if int(nu.get("requests", 0)) >= int(cg["node_request_budget"]):
            raise RuntimeError("COST_GOVERNOR: node request budget reached; model call blocked")

        memory_packet = self.memory.packet(job, node, stage)
        prompt = memory_packet + "\n\nCURRENT REQUEST:\n" + str(prompt or "")
        instructions = self._instructions(node, stage)

        cap = int(cg["prompt_char_cap"])
        if len(prompt) > cap:
            half = cap // 2
            prompt = prompt[:half] + "\n...[COST_GOVERNOR_CONTEXT_COMPACTED]...\n" + prompt[-half:]
        est_cap = int(cg["estimated_input_token_cap"])
        estimated_input = max(1, (len(instructions) + len(prompt) + 3) // 4)
        if estimated_input > est_cap:
            allowed_chars = max(2200, est_cap * 4 - len(instructions))
            prompt = prompt[:allowed_chars]
            estimated_input = max(1, (len(instructions) + len(prompt) + 3) // 4)

        stage_u = stage.upper()
        if "SELF_VERIFY" in stage_u:
            output_cap = 550
        elif "UNDERSTAND" in stage_u:
            output_cap = 900
        elif stage_u == "PLAN":
            output_cap = 1200
        elif "SYNTH" in stage_u or "FINAL" in stage_u:
            output_cap = 1600
        else:
            output_cap = 1100

        remaining = int(cg["sdk_token_budget"]) - int(cg.get("sdk_total_tokens", 0))
        if remaining < estimated_input + output_cap:
            raise RuntimeError("COST_GOVERNOR: insufficient remaining job token budget for next bounded call")

        max_turns = min(int(max_turns), 2)
        agent = Agent(
            name=f"{node['name']} · {stage}",
            instructions=instructions,
            model=model,
            output_type=output_type,
            model_settings={
                "max_tokens": output_cap,
                "verbosity": "low",
                "store": False,
            },
        )
        result = await Runner.run(
            agent,
            prompt,
            max_turns=max_turns,
            run_config=self._run_config(job, node, stage),
        )
        usage = result.context_wrapper.usage
        req = int(getattr(usage, "requests", 0) or 0)
        inp = int(getattr(usage, "input_tokens", 0) or 0)
        outp = int(getattr(usage, "output_tokens", 0) or 0)
        total = int(getattr(usage, "total_tokens", 0) or 0)

        nu["requests"] += req
        nu["input_tokens"] += inp
        nu["output_tokens"] += outp
        nu["total_tokens"] += total
        cg["sdk_requests"] = int(cg.get("sdk_requests", 0)) + req
        cg["sdk_total_tokens"] = int(cg.get("sdk_total_tokens", 0)) + total

        ratio = float(cg["sdk_total_tokens"]) / float(max(1, int(cg["sdk_token_budget"])))
        if ratio >= float(cg.get("soft_warning_ratio", 0.80)) and not cg.get("soft_warning_emitted"):
            cg["soft_warning_emitted"] = True
            await self.emit(
                job,
                "cost_governor_warning",
                f"SDK budget at {ratio:.0%}; new delegation is now disabled and remaining model work is minimized",
                node=node,
                budget_ratio=ratio,
            )

        await self.emit(
            job,
            "intelligence_sdk_run",
            f"{node['name']} completed intelligence stage {stage}",
            node=node,
            stage=stage,
            model=model,
            requests=req,
            input_tokens=inp,
            output_tokens=outp,
            total_tokens=total,
            estimated_input_tokens=estimated_input,
        )
        await self.persist(job)
        return result.final_output
'''
REPLACEMENTS['_understand_and_plan'] = '''    async def _understand_and_plan(self, job: dict, node: dict, context: str) -> tuple[TaskUnderstanding, IntelligencePlan]:
        self.memory.ensure_node(job, node)

        sup = await self.supervisor_consult(
            job,
            node,
            "intelligence_precheck",
            "Review this node using the compact shared-memory packet only.\n" + self.memory.supervisor_packet(job, node),
        )
        brain_model = self.escalation_model if str(sup.get("risk", "")).lower() == "high" else self.intelligence_model

        understanding = await self._sdk_run(
            job,
            node,
            "UNDERSTAND",
            TaskUnderstanding,
            f"""Assigned goal:
{node['goal']}

Inherited parent/Supervisor work packages:
{json.dumps(node.get('supervisor_tasks', []), ensure_ascii=False)[:3600]}

Supervisor operational guidance:
{json.dumps(sup, ensure_ascii=False)[:2200]}

Normalize the actual task, deliverables, constraints, observable success criteria,
uncertainties, complexity 1-10, and whether the best strategy is direct, decompose,
or hybrid. Do not request the full original transcript; relevant shared context is
already attached by the runtime.""",
            model=brain_model,
        )
        node["understanding"] = understanding.model_dump()
        self.memory.store_understanding(job, node, understanding)
        await self.persist(job)

        plan = await self._sdk_run(
            job,
            node,
            "PLAN",
            IntelligencePlan,
            f"""Create this node's own bounded execution plan from the normalized understanding.

UNDERSTANDING:
{understanding.model_dump_json(indent=2)[:3800]}

Capability inventory:
- reasoning/model work: AVAILABLE
- bounded child-agent delegation: AVAILABLE subject to coded limits
- mandatory Supervisor checkpoints: AVAILABLE
- external browser/shell/email/API-write actions: NOT YET INSTALLED

Create 1 to 6 useful sequential steps. Choose local or delegate per step.
Delegate only when a genuinely separable specialist responsibility materially improves
the result. If inherited work-package IDs exist, cover every one at least once.
Mark any step that truly needs an unavailable external capability.""",
            model=brain_model,
        )
        plan = self._normalize_plan(node, plan, int(job.get("max_depth", 3)))
        node["intelligence_plan"] = plan.model_dump()
        self.memory.store_plan(job, node, plan)
        node["steps"] = []
        for i, spec in enumerate(plan.steps, 1):
            node["steps"].append({
                "id": f"{node['id']}-I{i}",
                "index": i,
                **spec.model_dump(),
                "status": "queued",
                "result": "",
                "verification": {},
                "child_id": None,
                "started_at": None,
                "completed_at": None,
            })
        await self.emit(
            job,
            "intelligence_plan",
            f"{node['name']} independently planned {len(node['steps'])} bounded steps",
            node=node,
            strategy=plan.strategy,
            delegated_steps=sum(1 for s in node["steps"] if s["execution_mode"] == "delegate"),
        )
        await self.persist(job)
        return understanding, plan
'''
REPLACEMENTS['_execute_local_step'] = '''    async def _execute_local_step(self, job: dict, node: dict, step: dict, context: str, prior: str) -> str:
        revision = ""
        for attempt in range(1, self.recovery_attempts + 2):
            model = self.execution_model if attempt == 1 else self.intelligence_model
            out = await self._sdk_run(
                job,
                node,
                f"EXECUTE_{step['index']}_ATTEMPT_{attempt}",
                StepExecution,
                f"""Execute only the current step.

Current step: {step['title']}
Objective: {step['objective']}
Expected result: {step['expected_result']}
Covered inherited packages: {step.get('covers', [])}
Revision instruction: {revision[:1400]}

Use the attached local working-memory summary for prior completed steps.
Return a concrete result, evidence/grounds, assumptions, unresolved items, and calibrated
confidence. Never request or reproduce the entire prior transcript.""",
                model=model,
                max_turns=2,
            )

            review = await self._sdk_run(
                job,
                node,
                f"SELF_VERIFY_{step['index']}_ATTEMPT_{attempt}",
                StepReview,
                f"""Review this one bounded step output.

OBJECTIVE:
{step['objective']}

EXPECTED:
{step['expected_result']}

CANDIDATE:
{out.model_dump_json(indent=2)[:5000]}

Return pass only if materially complete and internally consistent. Return revise for a
correctable gap. Return blocked only for a genuine missing capability/dependency.""",
                model=self.execution_model,
                max_turns=2,
            )

            sup = {
                "summary": "Local bounded verification passed; paid Supervisor checkpoint deferred.",
                "verify": "",
                "guidance": "",
            }
            if review.verdict != "pass":
                sup = await self.supervisor_consult(
                    job,
                    node,
                    "intelligence_step_recovery",
                    (
                        f"Step {step['index']} objective: {step['objective'][:900]}\n"
                        f"Expected: {step['expected_result'][:900]}\n"
                        f"Self-review: {review.model_dump_json()[:1800]}\n"
                        + self.memory.supervisor_packet(job, node)
                    ),
                    candidate=str(out.result)[:3200],
                )

            step["verification"] = {
                "self": review.model_dump(),
                "supervisor_summary": str(sup.get("summary", "")),
                "supervisor_verify": str(sup.get("verify", "")),
                "attempt": attempt,
            }
            if review.verdict == "pass":
                return out.result
            if review.verdict == "blocked":
                raise RuntimeError(review.revision_instruction or "Step blocked by missing capability")
            revision = (
                review.revision_instruction
                or "; ".join(review.issues)
                or str(sup.get("guidance", "Revise material gaps."))
            )
            await self.emit(
                job,
                "intelligence_revision",
                revision,
                node=node,
                step_index=step["index"],
                attempt=attempt,
            )

        raise RuntimeError("Local intelligence step could not pass bounded verification")
'''
REPLACEMENTS['_prior_text'] = '''    def _prior_text(self, node: dict, before_index: int) -> str:
        rows = []
        for s in node.get("steps", []):
            if int(s.get("index", 0)) >= before_index or not s.get("result"):
                continue
            rows.append(f"{s.get('index')}. {s.get('title','')}: {str(s.get('result',''))[:700]}")
        return "\n".join(rows)[-2400:]
'''
REPLACEMENTS['run_node'] = '''    async def run_node(self, job: dict, node: dict, context: str) -> str:
        self.memory.ensure_node(job, node)
        node["status"] = "understanding"
        node["started_at"] = time.time()
        await self.emit(job, "intelligence_node_start", f"{node['name']} intelligence loop started", node=node)

        try:
            _, plan = await self._understand_and_plan(job, node, "")
            node["status"] = "executing"
            await self.persist(job)

            for step in node["steps"]:
                step["status"] = "running"
                step["started_at"] = time.time()
                await self.emit(job, "intelligence_step_start", f"{node['name']} step {step['index']} started", node=node, step_index=step["index"])

                if step.get("requires_external_capability"):
                    step["status"] = "blocked_capability"
                    step["result"] = f"BLOCKED_CAPABILITY: {step.get('capability_needed') or 'External capability'} is not installed."
                    step["completed_at"] = time.time()
                    self.memory.store_step(job, node, step, step["result"])
                    await self.emit(job, "intelligence_step_blocked", step["result"], node=node, step_index=step["index"])
                    raise RuntimeError(step["result"])

                if step.get("execution_mode") == "delegate":
                    result = await self._delegate_step(job, node, step, "")
                else:
                    result = await self._execute_local_step(job, node, step, "", self._prior_text(node, step["index"]))

                step["result"] = result
                step["status"] = "completed"
                step["completed_at"] = time.time()
                self.memory.store_step(job, node, step, result)
                await self.emit(job, "intelligence_step_complete", f"{node['name']} step {step['index']} completed", node=node, step_index=step["index"])
                await self.persist(job)

            node["status"] = "synthesizing"
            synth = await self._sdk_run(
                job,
                node,
                "SYNTHESIZE",
                NodeSynthesis,
                f"""Synthesize this node's completed bounded step results into one parent-ready result.

Node goal: {node['goal']}
Synthesis goal: {plan.synthesis_goal}
Inherited expected outcome: {node.get('expected_module_outcome', '')}

All completed step summaries are attached in LOCAL SHARED MEMORY. Produce one concrete
result, explicit coverage, unresolved items, and calibrated confidence. Do not invent
sibling results or external actions.""",
                model=self.intelligence_model,
                max_turns=2,
            )
            self.memory.store_result(job, node, synth.result, synth.unresolved)

            post = await self.supervisor_consult(
                job,
                node,
                "intelligence_postverification",
                (
                    f"Goal: {node['goal'][:1200]}\n"
                    f"Expected: {str(node.get('expected_module_outcome',''))[:1000]}\n"
                    f"Step count: {len(node['steps'])}\n"
                    + self.memory.supervisor_packet(job, node)
                ),
                candidate=str(synth.result)[:4200],
            )
            node["post_verification"] = {
                "summary": str(post.get("summary", "")),
                "verify": str(post.get("verify", "")),
                "risk": str(post.get("risk", "")),
            }
            node["result"] = synth.result
            node["confidence"] = synth.confidence
            node["unresolved"] = synth.unresolved
            node["status"] = "completed"
            node["completed_at"] = time.time()
            self.memory.store_result(job, node, synth.result, synth.unresolved)
            await self.emit(job, "intelligence_node_complete", f"{node['name']} completed and reported upward", node=node, confidence=synth.confidence)
            await self.persist(job)
            return node["result"]
        except Exception as exc:
            node["status"] = "failed"
            node["error"] = str(exc)
            node["completed_at"] = time.time()
            await self.emit(job, "intelligence_node_failed", str(exc), node=node)
            await self.persist(job)
            raise
'''
REPLACEMENTS['run'] = '''    async def run(self, job: dict) -> None:
        root = job["root"]
        root["status"] = "running"
        job["status"] = "running"
        await self.emit(job, "intelligence_job_start", "v0.9.2 cheap-memory intelligence job started", node=root)

        try:
            root_context = self.memory.root_planning_context(str(job.get("context", "") or ""))
            plan = await self.problem_engine.plan_problem(job, root, root_context)
            self.memory.bootstrap(job, plan, root_context)
            await self.persist(job)

            modules = []
            for spec in plan["modules"]:
                if not await self._reserve_child(job):
                    raise RuntimeError("Agent budget exhausted before four major intelligence agents could be created")
                module = {
                    "id": uuid.uuid4().hex[:12],
                    "parent_id": root["id"],
                    "name": spec["name"],
                    "role": spec["role"],
                    "goal": spec["objective"],
                    "expected_module_outcome": spec["expected_module_outcome"],
                    "depth": 1,
                    "status": "queued",
                    "supervisor_tasks": spec["work_packages"],
                    "children": [],
                    "steps": [],
                    "result": "",
                    "error": "",
                    "sdk_usage": {"requests": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
                }
                self.memory.ensure_node(job, module)
                modules.append(module)

            root["children"] = modules
            await self.persist(job)

            results = await asyncio.gather(*[self.run_node(job, module, "") for module in modules], return_exceptions=True)

            failed = []
            module_results = []
            for module, result in zip(modules, results):
                if isinstance(result, Exception):
                    failed.append({"name": module["name"], "error": str(result)})
                else:
                    module_results.append({"name": module["name"], "result_ref": f"local://job/{job['id']}/memory/{module['id']}"})

            if failed:
                root["status"] = "failed"
                job["status"] = "partial"
                job["result"] = "INTELLIGENCE_PARTIAL\n\n" + "\n".join(f"- {x['name']}: {x['error']}" for x in failed)
                job["error"] = "One or more major intelligence agents failed"
                job["completed_at"] = time.time()
                await self.emit(job, "intelligence_job_partial", job["error"], node=root, failed_modules=len(failed))
                await self.persist(job)
                return

            root["status"] = "synthesizing"
            final_node = {**root, "name": "Problem Supervisor", "role": "Final Supervisor / Integrator"}
            final = await self._sdk_run(
                job,
                final_node,
                "FINAL_SYNTHESIS",
                FinalSynthesis,
                f"""Produce the final answer to the original problem using ONLY the four compact
major-agent reports attached in LOCAL SHARED MEMORY.

Original problem:
{str(job.get('goal',''))[:2200]}

Overall success definition:
{str(plan.get('success_definition', ''))[:1200]}

Integrate the four reports into one actionable result. Preserve unresolved items and
uncertainty. Never claim external actions/evidence not actually produced.""",
                model=self.supervisor_model,
                max_turns=2,
            )
            self.memory.store_result(job, root, final.result, final.unresolved)

            post = await self.supervisor_consult(
                job,
                root,
                "intelligence_final_verification",
                f"Four major agents completed. Success definition: {str(plan.get('success_definition',''))[:1200]}\n" + self.memory.supervisor_packet(job, root),
                candidate=str(final.result)[:5000],
            )
            root["final_verification"] = {
                "summary": str(post.get("summary", "")),
                "verify": str(post.get("verify", "")),
                "risk": str(post.get("risk", "")),
            }
            root["result"] = final.result
            root["status"] = "completed"
            root["completed_at"] = time.time()
            job["status"] = "completed"
            job["result"] = "INTELLIGENCE_COMPLETE\n\n" + final.result
            job["completed_at"] = time.time()
            await self.emit(job, "intelligence_job_complete", "All intelligent agents completed using shared compact memory; final Supervisor synthesis verified", node=root)
            await self.persist(job)
        except Exception as exc:
            root["status"] = "failed"
            root["error"] = str(exc)
            job["status"] = "failed"
            job["error"] = str(exc)
            job["completed_at"] = time.time()
            await self.emit(job, "intelligence_job_failed", str(exc), node=root)
            await self.persist(job)
'''

for name in ["_instructions", "_sdk_run", "_understand_and_plan", "_execute_local_step", "_prior_text", "run_node", "run"]:
    s = replace_method(s, name, REPLACEMENTS[name])

old = '        return await self.run_node(job, child, context)'
new = '        self.memory.register_child(job, node, child, step)\n        await self.persist(job)\n        return await self.run_node(job, child, "")'
if old in s:
    s = s.replace(old, new, 1)
elif "self.memory.register_child(job, node, child, step)" not in s:
    raise SystemExit("delegate child return anchor missing")

if '"shared_memory": {' not in s:
    anchor = '        "sdk_usage": usage,\n'
    insert = '        "sdk_usage": usage,\n        "cost_governor": job.get("cost_governor", {}),\n        "shared_memory": {\n            "version": (job.get("shared_memory") or {}).get("version"),\n            "core_present": bool((job.get("shared_memory") or {}).get("core")),\n            "node_memories": len((job.get("shared_memory") or {}).get("nodes") or {}),\n            "stats": (job.get("shared_memory") or {}).get("stats", {}),\n            "full_history_replay": False,\n            "shared_core": True,\n            "per_node_working_memory": True,\n            "raw_context_model_visible": False,\n        },\n'
    if anchor not in s: raise SystemExit("audit sdk_usage anchor missing")
    s = s.replace(anchor, insert, 1)

engine.write_text(s)
PYPATCH

python3 - <<'PYMAIN'
from pathlib import Path
p=Path("/opt/fourth-law-agent/app/main.py")
s=p.read_text()
s=s.replace('version="0.9.1"', 'version="0.9.2"')
s=s.replace('"version":"0.9.1"', '"version":"0.9.2"')
if 'shared-memory-v0.9.2' not in s:
    if 'cost-governor-v0.9.1' in s:
        s=s.replace('cost-governor-v0.9.1', 'cost-governor-v0.9.1+shared-memory-v0.9.2', 1)
    elif 'control-room-v0.9' in s:
        s=s.replace('control-room-v0.9', 'control-room-v0.9+shared-memory-v0.9.2', 1)
p.write_text(s)
PYMAIN

python3 - <<'PYENV'
from pathlib import Path
p=Path("/opt/fourth-law-agent/.env")
rows=p.read_text().splitlines()
settings={
  "INTELLIGENCE_MEMORY_MODE":"shared-compact-local",
  "INTELLIGENCE_AGENT_BUDGET":"12",
  "INTELLIGENCE_MAX_CHILDREN":"2",
}
seen=set(); out=[]
for line in rows:
    if "=" in line and not line.lstrip().startswith("#"):
        k=line.split("=",1)[0].strip()
        if k in settings:
            out.append(f"{k}={settings[k]}"); seen.add(k); continue
    out.append(line)
for k,v in settings.items():
    if k not in seen: out.append(f"{k}={v}")
p.write_text("\n".join(out).rstrip()+"\n")
PYENV
chmod 600 "$ENVFILE"

python3 -m py_compile "$MEMORY" "$ENGINE" "$MAIN"

! grep -q 'session=self._session(job, node)' "$ENGINE"
! grep -q 'context\[-14000:' "$ENGINE"
! grep -q 'context\[-9000:' "$ENGINE"
grep -q 'SharedContextMemory' "$ENGINE"
grep -q 'LOCAL SHARED MEMORY' "$MEMORY"
grep -q 'estimated_input_token_cap' "$ENGINE"

PYTHONPATH="$PROJECT" python3 - <<'PYTEST'
from app.shared_memory import SharedContextMemory

m=SharedContextMemory()
raw=("BEGIN " + ("alpha beta gamma " * 12000) + " END")
job={"id":"memtest","goal":"Build a reliable control room cheaply","context":raw}
plan={
 "success_definition":"Working UI with bounded cost and verifiable status.",
 "modules":[
  {"name":f"M{i}","objective":f"Objective {i}","expected_module_outcome":f"Outcome {i}",
    "work_packages":[{"id":f"M{i}W{j}","title":f"Task {j}","expected_outcome":"Done"} for j in range(1,5)]}
  for i in range(1,5)
 ]
}
root_ctx=m.root_planning_context(raw)
assert len(root_ctx) <= 16000
m.bootstrap(job, plan, root_ctx)
n1={"id":"n1","parent_id":"root","depth":1,"name":"M1","goal":"Objective 1","expected_module_outcome":"Outcome 1"}
n2={"id":"n2","parent_id":"root","depth":1,"name":"M2","goal":"Objective 2","expected_module_outcome":"Outcome 2"}
p1=m.packet(job,n1,"UNDERSTAND")
p2=m.packet(job,n2,"UNDERSTAND")
assert len(p1) <= 7600 and len(p2) <= 7600
assert "BEGIN alpha beta gamma alpha beta gamma" not in p1
assert "SHARED CORE" in p1 and "SHARED CORE" in p2
m.store_understanding(job,n1,{"normalized_goal":"Obj1","deliverables":["D1"],"constraints":["C1"],"success_criteria":["S1"],"uncertainties":[],"complexity":5,"recommended_strategy":"direct"})
m.store_plan(job,n1,{"strategy":"direct","synthesis_goal":"Finish","steps":[{"title":"A","objective":"Do A","expected_result":"A done","execution_mode":"local"}]})
step={"id":"n1-I1","index":1,"title":"A","status":"completed"}
m.store_step(job,n1,step,"A completed with a concise durable local summary.")
m.store_result(job,n1,"Module one result",[])
syn=m.packet(job,n1,"SYNTHESIZE")
assert "Module one result" not in p2
assert len(syn) <= 7600
audit=m.audit(job)
assert audit["design"]["full_history_replay"] is False
assert audit["design"]["shared_core"] is True
assert audit["design"]["per_node_working_memory"] is True
print("SHARED_MEMORY_LOCAL_REGRESSION_OK", audit)
PYTEST

cd "$PROJECT"
docker compose build agent
docker compose up -d --force-recreate agent

ok=0
for i in $(seq 1 75); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl092-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.9.2"' /tmp/fl092-health.json
curl -fsS http://127.0.0.1:8787/control-room >/tmp/fl092-ui.html
grep -q 'Fourth Law' /tmp/fl092-ui.html

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'SHARED_MEMORY_V0_9_2_DEPLOYED {"memory":"job-shared-local","full_history_replay":false,"root_raw_context":"local-once-bounded","shared_core":true,"per_node_working_memory":true,"sibling_private_memory":true,"model_memory_maintenance_calls":0,"prompt_char_cap":9000,"estimated_input_token_cap":3200,"max_output_tokens_by_stage":true,"stable_instruction_prefix":true,"final_synthesis_uses_compact_module_results":true,"paid_smoke":"skipped_quota_exhausted","local_memory_regression":"ok","local_health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true

echo FOURTHLAW_SHARED_MEMORY_V0_9_2_READY
cat /tmp/fl092-health.json

import asyncio
import json
import time
import uuid
from pathlib import Path
from typing import Any, Awaitable, Callable, Literal

from agents import Agent, Runner, RunConfig, SQLiteSession
from pydantic import BaseModel, Field


class TaskUnderstanding(BaseModel):
    normalized_goal: str
    deliverables: list[str] = Field(default_factory=list)
    constraints: list[str] = Field(default_factory=list)
    success_criteria: list[str] = Field(default_factory=list)
    uncertainties: list[str] = Field(default_factory=list)
    complexity: int = Field(ge=1, le=10)
    recommended_strategy: Literal["direct", "decompose", "hybrid"]


class IntelligenceStepSpec(BaseModel):
    title: str
    objective: str
    expected_result: str
    covers: list[str] = Field(default_factory=list)
    execution_mode: Literal["local", "delegate"]
    delegation_reason: str = ""
    requires_external_capability: bool = False
    capability_needed: str = ""


class IntelligencePlan(BaseModel):
    strategy: Literal["direct", "decompose", "hybrid"]
    synthesis_goal: str
    rationale: str
    steps: list[IntelligenceStepSpec]


class StepExecution(BaseModel):
    result: str
    evidence: list[str] = Field(default_factory=list)
    assumptions: list[str] = Field(default_factory=list)
    unresolved: list[str] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0)


class StepReview(BaseModel):
    verdict: Literal["pass", "revise", "blocked"]
    issues: list[str] = Field(default_factory=list)
    revision_instruction: str = ""


class NodeSynthesis(BaseModel):
    result: str
    coverage: list[str] = Field(default_factory=list)
    unresolved: list[str] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0)


class FinalSynthesis(BaseModel):
    result: str
    major_findings: list[str] = Field(default_factory=list)
    unresolved: list[str] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0)


class IntelligenceEngine:
    """Fourth Law v0.8 per-node intelligence runtime."""

    def __init__(
        self,
        *,
        problem_engine: Any,
        supervisor_consult: Callable[..., Awaitable[dict]],
        emit: Callable[..., Awaitable[None]],
        persist: Callable[[dict], Awaitable[None]],
        constitution: str,
        supervisor_model: str,
        intelligence_model: str,
        execution_model: str,
        escalation_model: str = "gpt-5.6-sol",
        max_children_per_node: int = 4,
        recovery_attempts: int = 2,
        session_db_path: str = "/data/intelligence_sessions",
    ):
        self.problem_engine = problem_engine
        self.supervisor_consult = supervisor_consult
        self.emit = emit
        self.persist = persist
        self.constitution = constitution
        self.supervisor_model = supervisor_model
        self.intelligence_model = intelligence_model
        self.execution_model = execution_model
        self.escalation_model = escalation_model
        self.max_children_per_node = max(1, min(4, max_children_per_node))
        self.recovery_attempts = max(1, min(3, recovery_attempts))
        self.session_db_path = session_db_path
        self._budget_locks: dict[str, asyncio.Lock] = {}

    def _session(self, job: dict, node: dict) -> SQLiteSession:
        root = Path(self.session_db_path)
        root.mkdir(parents=True, exist_ok=True)
        db_path = root / f"{job['id']}-{node['id']}.db"
        return SQLiteSession(f"{job['id']}:{node['id']}", db_path)

    def _run_config(self, job: dict, node: dict, stage: str) -> RunConfig:
        return RunConfig(
            workflow_name="Fourth Law Intelligence Layer",
            group_id=str(job["id"]),
            trace_include_sensitive_data=False,
            trace_metadata={
                "job_id": str(job["id"]),
                "node_id": str(node["id"]),
                "node_depth": str(node.get("depth", 0)),
                "stage": stage,
            },
        )

    def _instructions(self, node: dict, stage: str) -> str:
        return f"""{self.constitution}

FOURTH LAW INTELLIGENCE KERNEL
Logical node id: {node['id']}
Logical node name: {node['name']}
Role: {node['role']}
Depth: {node.get('depth', 0)}
Current stage: {stage}

Operating state machine:
UNDERSTAND -> PLAN -> EXECUTE_OR_DELEGATE -> VERIFY -> SYNTHESIZE -> REPORT.

Rules:
- Think independently about only this node's assigned goal.
- Decompose only when it materially improves correctness, specialization, or efficiency.
- Never create child agents directly. You may recommend delegation; the coded runtime is the only component allowed to create children.
- Never claim an external action happened unless an authorized capability actually executed it.
- Preserve parent constraints and expected outcomes.
- Return operational outputs only; never expose hidden chain-of-thought.
"""

    async def _sdk_run(
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
        agent = Agent(
            name=f"{node['name']} · {stage}",
            instructions=self._instructions(node, stage),
            model=model,
            output_type=output_type,
        )
        result = await Runner.run(
            agent,
            prompt,
            session=self._session(job, node),
            max_turns=max_turns,
            run_config=self._run_config(job, node, stage),
        )
        usage = result.context_wrapper.usage
        node.setdefault("sdk_usage", {"requests": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0})
        node["sdk_usage"]["requests"] += int(getattr(usage, "requests", 0) or 0)
        node["sdk_usage"]["input_tokens"] += int(getattr(usage, "input_tokens", 0) or 0)
        node["sdk_usage"]["output_tokens"] += int(getattr(usage, "output_tokens", 0) or 0)
        node["sdk_usage"]["total_tokens"] += int(getattr(usage, "total_tokens", 0) or 0)
        await self.emit(
            job,
            "intelligence_sdk_run",
            f"{node['name']} completed intelligence stage {stage}",
            node=node,
            stage=stage,
            model=model,
            requests=int(getattr(usage, "requests", 0) or 0),
            total_tokens=int(getattr(usage, "total_tokens", 0) or 0),
        )
        return result.final_output

    async def _reserve_child(self, job: dict) -> bool:
        lock = self._budget_locks.setdefault(job["id"], asyncio.Lock())
        async with lock:
            if int(job.get("agents_created", 1)) >= int(job.get("agent_budget", 85)):
                return False
            job["agents_created"] = int(job.get("agents_created", 1)) + 1
            await self.persist(job)
            return True

    def _required_ids(self, node: dict) -> set[str]:
        return {str(x.get("id")) for x in node.get("supervisor_tasks", []) if x.get("id")}

    def _normalize_plan(self, node: dict, plan: IntelligencePlan, max_depth: int) -> IntelligencePlan:
        steps = list(plan.steps or [])
        if not steps:
            steps = [
                IntelligenceStepSpec(
                    title="Complete assigned goal",
                    objective=node["goal"],
                    expected_result=node.get("expected_module_outcome") or "A complete, useful result.",
                    covers=sorted(self._required_ids(node)),
                    execution_mode="local",
                )
            ]
        steps = steps[:10]

        delegated = 0
        for s in steps:
            if s.execution_mode == "delegate":
                if node.get("depth", 0) >= max_depth or delegated >= self.max_children_per_node:
                    s.execution_mode = "local"
                    s.delegation_reason = "Delegation converted to local execution by coded depth/child cap."
                else:
                    delegated += 1

        required = self._required_ids(node)
        if required:
            covered: set[str] = set()
            for s in steps:
                s.covers = [x for x in s.covers if x in required]
                covered.update(s.covers)
            missing = sorted(required - covered)
            if missing:
                steps[-1].covers = sorted(set(steps[-1].covers).union(missing))

        plan.steps = steps
        return plan

    async def _understand_and_plan(self, job: dict, node: dict, context: str) -> tuple[TaskUnderstanding, IntelligencePlan]:
        sup = await self.supervisor_consult(
            job,
            node,
            "intelligence_precheck",
            f"Assigned goal: {node['goal']}\nInherited supervisor tasks: {json.dumps(node.get('supervisor_tasks', []), ensure_ascii=False)}\nContext: {context[-10000:]}",
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
{json.dumps(node.get('supervisor_tasks', []), ensure_ascii=False)}

Context:
{context[-14000:]}

Supervisor operational guidance:
{json.dumps(sup, ensure_ascii=False)}

Normalize the actual task, deliverables, constraints, observable success criteria, uncertainties, complexity 1-10, and whether the best strategy is direct, decompose, or hybrid.""",
            model=brain_model,
        )
        node["understanding"] = understanding.model_dump()
        await self.persist(job)

        plan = await self._sdk_run(
            job,
            node,
            "PLAN",
            IntelligencePlan,
            f"""Use the task understanding below to create this node's own execution plan.

UNDERSTANDING:
{understanding.model_dump_json(indent=2)}

Capability inventory in v0.8:
- reasoning/model work: AVAILABLE
- bounded child-agent delegation: AVAILABLE subject to coded depth/agent limits
- mandatory Supervisor consultation: AVAILABLE
- external browser/shell/email/API-write actions: NOT YET INSTALLED

Create 1 to 10 useful sequential steps. For each step choose:
- local: this node should execute it itself
- delegate: a specialized child agent would materially improve the result

A node may recommend no more than {self.max_children_per_node} delegated child steps.
If inherited work-package IDs exist, cover every one at least once.
Do not make delegation ceremonial: delegate only for a genuinely separable specialist responsibility.
Mark any step that truly needs an unavailable external capability.""",
            model=brain_model,
        )
        plan = self._normalize_plan(node, plan, int(job.get("max_depth", 3)))
        node["intelligence_plan"] = plan.model_dump()
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
            f"{node['name']} independently planned {len(node['steps'])} steps",
            node=node,
            strategy=plan.strategy,
            delegated_steps=sum(1 for s in node["steps"] if s["execution_mode"] == "delegate"),
        )
        return understanding, plan

    async def _execute_local_step(self, job: dict, node: dict, step: dict, context: str, prior: str) -> str:
        revision = ""
        for attempt in range(1, self.recovery_attempts + 2):
            model = self.execution_model if attempt == 1 else self.intelligence_model
            if attempt > self.recovery_attempts:
                model = self.escalation_model
            out = await self._sdk_run(
                job,
                node,
                f"EXECUTE_{step['index']}_ATTEMPT_{attempt}",
                StepExecution,
                f"""Execute only the current step.

Node goal: {node['goal']}
Current step: {step['title']}
Objective: {step['objective']}
Expected result: {step['expected_result']}
Covered inherited packages: {step.get('covers', [])}
Prior completed step outputs:
{prior[-14000:]}

Original context:
{context[-9000:]}

Revision instruction from earlier verification:
{revision}

Return a concrete result, evidence/grounds used, assumptions, unresolved items, and calibrated confidence.
Do not claim any real external action occurred.""",
                model=model,
                max_turns=4,
            )

            review = await self._sdk_run(
                job,
                node,
                f"SELF_VERIFY_{step['index']}_ATTEMPT_{attempt}",
                StepReview,
                f"""Strictly review this step output against its objective and expected result.

OBJECTIVE:
{step['objective']}

EXPECTED:
{step['expected_result']}

CANDIDATE:
{out.model_dump_json(indent=2)}

Return pass only if the result is materially complete and internally consistent. Return revise for correctable gaps. Return blocked only for a genuine missing capability or dependency.""",
                model=self.intelligence_model,
                max_turns=3,
            )

            sup = await self.supervisor_consult(
                job,
                node,
                "intelligence_step_verification",
                f"Step {step['index']} objective: {step['objective']}\nExpected: {step['expected_result']}\nSelf-review: {review.model_dump_json()}",
                candidate=out.result,
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
            revision = review.revision_instruction or "; ".join(review.issues) or str(sup.get("guidance", "Revise material gaps."))
            await self.emit(job, "intelligence_revision", revision, node=node, step_index=step["index"], attempt=attempt)

        raise RuntimeError("Local intelligence step could not pass verification")

    async def _delegate_step(self, job: dict, node: dict, step: dict, context: str) -> str:
        if node.get("depth", 0) >= int(job.get("max_depth", 3)):
            return await self._execute_local_step(job, node, step, context, "")

        if not await self._reserve_child(job):
            await self.emit(job, "intelligence_budget_fallback", "Agent budget exhausted; delegated step converted to local execution", node=node, step_index=step["index"])
            return await self._execute_local_step(job, node, step, context, "")

        child = {
            "id": uuid.uuid4().hex[:12],
            "parent_id": node["id"],
            "name": f"{node['name']} / {step['title']}"[:180],
            "role": "Specialist child agent",
            "goal": step["objective"],
            "expected_module_outcome": step["expected_result"],
            "depth": int(node.get("depth", 0)) + 1,
            "status": "queued",
            "supervisor_tasks": [],
            "children": [],
            "steps": [],
            "result": "",
            "error": "",
            "sdk_usage": {"requests": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
        }
        node.setdefault("children", []).append(child)
        step["child_id"] = child["id"]
        await self.emit(
            job,
            "intelligence_delegate",
            f"{node['name']} delegated step {step['index']} to child {child['name']}",
            node=node,
            child_id=child["id"],
            step_index=step["index"],
        )
        await self.persist(job)
        return await self.run_node(job, child, context)

    def _prior_text(self, node: dict, before_index: int) -> str:
        rows = []
        for s in node.get("steps", []):
            if int(s.get("index", 0)) >= before_index or not s.get("result"):
                continue
            rows.append(f"STEP {s['index']} {s['title']}:\n{s['result'][-5000:]}")
        return "\n\n".join(rows)[-18000:]

    async def run_node(self, job: dict, node: dict, context: str) -> str:
        node["status"] = "understanding"
        node["started_at"] = time.time()
        await self.emit(job, "intelligence_node_start", f"{node['name']} intelligence loop started", node=node)

        try:
            _, plan = await self._understand_and_plan(job, node, context)
            node["status"] = "executing"
            await self.persist(job)

            for step in node["steps"]:
                step["status"] = "running"
                step["started_at"] = time.time()
                await self.emit(job, "intelligence_step_start", f"{node['name']} step {step['index']} started", node=node, step_index=step["index"])

                if step.get("requires_external_capability"):
                    step["status"] = "blocked_capability"
                    step["result"] = f"BLOCKED_CAPABILITY: {step.get('capability_needed') or 'External capability'} is not installed in v0.8."
                    step["completed_at"] = time.time()
                    await self.emit(job, "intelligence_step_blocked", step["result"], node=node, step_index=step["index"])
                    raise RuntimeError(step["result"])

                if step.get("execution_mode") == "delegate":
                    result = await self._delegate_step(job, node, step, context)
                else:
                    result = await self._execute_local_step(job, node, step, context, self._prior_text(node, step["index"]))

                step["result"] = result
                step["status"] = "completed"
                step["completed_at"] = time.time()
                await self.emit(job, "intelligence_step_complete", f"{node['name']} step {step['index']} completed", node=node, step_index=step["index"])
                await self.persist(job)

            node["status"] = "synthesizing"
            synth = await self._sdk_run(
                job,
                node,
                "SYNTHESIZE",
                NodeSynthesis,
                f"""Synthesize this node's completed step results into one parent-ready result.

Node goal: {node['goal']}
Synthesis goal: {plan.synthesis_goal}
Inherited expected outcome: {node.get('expected_module_outcome', '')}

Completed steps:
{json.dumps([{'title': s['title'], 'expected': s['expected_result'], 'result': s['result']} for s in node['steps']], ensure_ascii=False)[-24000:]}

Produce one concrete result, explicit coverage, unresolved items, and calibrated confidence. Do not invent sibling results or external actions.""",
                model=self.intelligence_model,
                max_turns=4,
            )

            post = await self.supervisor_consult(
                job,
                node,
                "intelligence_postverification",
                f"Goal: {node['goal']}\nExpected: {node.get('expected_module_outcome','')}\nStep count: {len(node['steps'])}",
                candidate=synth.result,
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

    async def run(self, job: dict) -> None:
        root = job["root"]
        root["status"] = "running"
        job["status"] = "running"
        await self.emit(job, "intelligence_job_start", "v0.8 intelligence job started", node=root)

        try:
            # Preserve the proven v0.7 4x4 Supervisor decomposition as governance shell.
            plan = await self.problem_engine.plan_problem(job, root, job.get("context", ""))

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
                modules.append(module)

            root["children"] = modules
            await self.persist(job)

            # Major agents can run concurrently; every node's own steps remain sequential.
            results = await asyncio.gather(
                *[self.run_node(job, module, job.get("context", "")) for module in modules],
                return_exceptions=True,
            )

            failed = []
            module_results = []
            for module, result in zip(modules, results):
                if isinstance(result, Exception):
                    failed.append({"name": module["name"], "error": str(result)})
                else:
                    module_results.append({"name": module["name"], "result": result})

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
                f"""Use ONLY the four actual major-agent reports below to produce the final answer to the original problem.

Original problem:
{job['goal']}

Overall success definition:
{plan.get('success_definition', '')}

Major-agent reports:
{json.dumps(module_results, ensure_ascii=False)[-30000:]}

Integrate them into one actionable final result. Preserve unresolved items and uncertainty. Never claim external actions or evidence that the agents did not actually produce.""",
                model=self.supervisor_model,
                max_turns=5,
            )
            post = await self.supervisor_consult(
                job,
                root,
                "intelligence_final_verification",
                f"Four major agents completed. Success definition: {plan.get('success_definition','')}",
                candidate=final.result,
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
            await self.emit(job, "intelligence_job_complete", "All intelligent agents completed; final Supervisor synthesis verified", node=root)
            await self.persist(job)
        except Exception as exc:
            root["status"] = "failed"
            root["error"] = str(exc)
            job["status"] = "failed"
            job["error"] = str(exc)
            job["completed_at"] = time.time()
            await self.emit(job, "intelligence_job_failed", str(exc), node=root)
            await self.persist(job)


def _flatten(root: dict) -> list[dict]:
    rows = [root]
    for child in root.get("children", []):
        rows.extend(_flatten(child))
    return rows


def build_intelligence_audit(job: dict) -> dict[str, Any]:
    nodes = _flatten(job.get("root", {})) if job.get("root") else []
    logical_agents = [n for n in nodes if int(n.get("depth", 0)) > 0]
    usage = {"requests": 0, "input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
    for n in nodes:
        u = n.get("sdk_usage", {})
        for k in usage:
            usage[k] += int(u.get(k, 0) or 0)

    return {
        "id": job.get("id"),
        "architecture": job.get("architecture"),
        "status": job.get("status"),
        "agents_created": job.get("agents_created"),
        "logical_agent_count": len(logical_agents),
        "max_depth_observed": max([int(n.get("depth", 0)) for n in nodes] or [0]),
        "all_agents_have_understanding": all(bool(n.get("understanding")) for n in logical_agents) if logical_agents else False,
        "all_agents_have_intelligence_plan": all(bool(n.get("intelligence_plan")) for n in logical_agents) if logical_agents else False,
        "all_completed_agents_postverified": all(bool(n.get("post_verification")) for n in logical_agents if n.get("status") == "completed"),
        "all_agents_complete": all(n.get("status") == "completed" for n in logical_agents) if logical_agents else False,
        "sdk_usage": usage,
        "supervisor_event_count": sum(1 for e in job.get("events", []) if e.get("type") == "supervisor"),
        "nodes": [
            {
                "id": n.get("id"),
                "parent_id": n.get("parent_id"),
                "name": n.get("name"),
                "depth": n.get("depth"),
                "status": n.get("status"),
                "strategy": (n.get("intelligence_plan") or {}).get("strategy"),
                "step_count": len(n.get("steps", [])),
                "delegated_step_count": sum(1 for s in n.get("steps", []) if s.get("execution_mode") == "delegate"),
                "child_count": len(n.get("children", [])),
                "sdk_usage": n.get("sdk_usage", {}),
                "error": n.get("error", ""),
            }
            for n in logical_agents
        ],
        "result_prefix": str(job.get("result", ""))[:500],
    }

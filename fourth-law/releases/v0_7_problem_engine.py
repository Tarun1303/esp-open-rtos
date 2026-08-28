import json
import time
import uuid
from typing import Any, Callable, Awaitable


class ProblemEngine:
    """Supervisor-led 4x4 problem decomposition with dynamic 2-10 sequential steps per module."""

    def __init__(
        self,
        *,
        raw_response: Callable[..., Awaitable[str]],
        parse_json_object: Callable[[str], dict[str, Any]],
        supervisor_consult: Callable[..., Awaitable[dict]],
        emit: Callable[..., Awaitable[None]],
        persist: Callable[[dict], Awaitable[None]],
        supervisor_model: str,
        master_model: str,
        worker_model: str,
        recovery_attempts: int = 2,
    ):
        self.raw_response = raw_response
        self.parse_json_object = parse_json_object
        self.supervisor_consult = supervisor_consult
        self.emit = emit
        self.persist = persist
        self.supervisor_model = supervisor_model
        self.master_model = master_model
        self.worker_model = worker_model
        self.recovery_attempts = max(1, min(3, recovery_attempts))

    def _normalize_problem_plan(self, data: dict[str, Any]) -> dict[str, Any]:
        modules = data.get("modules")
        if not isinstance(modules, list) or len(modules) != 4:
            raise ValueError("Supervisor plan must contain exactly four major modules")
        normalized = []
        for mi, raw in enumerate(modules, 1):
            if not isinstance(raw, dict):
                raise ValueError(f"Module {mi} is not an object")
            packages = raw.get("work_packages")
            if not isinstance(packages, list) or len(packages) != 4:
                raise ValueError(f"Module {mi} must contain exactly four supervisor work packages")
            n_packages = []
            for ti, wp in enumerate(packages, 1):
                if not isinstance(wp, dict):
                    raise ValueError(f"Module {mi} work package {ti} is not an object")
                n_packages.append({
                    "id": f"M{mi}-T{ti}",
                    "title": str(wp.get("title") or f"Work Package {ti}")[:180],
                    "task": str(wp.get("task") or "")[:8000],
                    "expected_outcome": str(wp.get("expected_outcome") or "")[:8000],
                })
            normalized.append({
                "index": mi,
                "name": str(raw.get("name") or f"Module {mi}")[:180],
                "role": str(raw.get("role") or f"Major Module Agent {mi}")[:240],
                "objective": str(raw.get("objective") or "")[:12000],
                "expected_module_outcome": str(raw.get("expected_module_outcome") or "")[:12000],
                "balance_rationale": str(raw.get("balance_rationale") or "")[:4000],
                "work_packages": n_packages,
            })
        return {
            "problem_summary": str(data.get("problem_summary") or "")[:12000],
            "success_definition": str(data.get("success_definition") or "")[:12000],
            "modules": normalized,
        }

    async def plan_problem(self, job: dict, root: dict, context: str) -> dict[str, Any]:
        pre = await self.supervisor_consult(job, root, "problem_decomposition_precheck", context)
        last_error = ""
        for attempt in range(1, 4):
            prompt = f"""You are the Fourth Law Problem Supervisor.
Problem statement: {root['goal']}
Context: {context[-22000:]}
Supervisor precheck guidance: {json.dumps(pre, ensure_ascii=False)}
Previous planning error: {last_error}

Create a TWO-LAYER problem architecture before any module agent starts work.
Layer 1: divide the full problem into EXACTLY FOUR balanced, complementary, non-overlapping major modules. They should be approximately equal in responsibility/effort and collectively sufficient to solve the problem.
Layer 2: for EACH major module, predefine EXACTLY FOUR major work packages. Each work package needs a concrete task and an IDEAL EXPECTED OUTCOME so the module agent can later prove completion.
Do not create execution micro-steps yet; each module agent will do that itself.

Return ONLY JSON in this shape:
{{
  "problem_summary":"...",
  "success_definition":"observable definition of overall success",
  "modules":[
    {{
      "name":"...",
      "role":"...",
      "objective":"...",
      "expected_module_outcome":"...",
      "balance_rationale":"why this is roughly one quarter of the problem",
      "work_packages":[
        {{"title":"...","task":"...","expected_outcome":"..."}},
        {{"title":"...","task":"...","expected_outcome":"..."}},
        {{"title":"...","task":"...","expected_outcome":"..."}},
        {{"title":"...","task":"...","expected_outcome":"..."}}
      ]
    }}
  ]
}}
There MUST be exactly 4 modules and exactly 4 work_packages in each module."""
            try:
                txt = await self.raw_response(
                    self.supervisor_model,
                    "Produce a balanced 4-by-4 supervisor problem plan. Operational summary only; no hidden chain-of-thought.",
                    prompt,
                    5200,
                )
                plan = self._normalize_problem_plan(self.parse_json_object(txt))
                job["problem_plan"] = plan
                await self.emit(job, "problem_plan", "Supervisor created 4 major modules with 4 work packages each", node=root,
                                module_count=4, work_packages_per_module=4)
                return plan
            except Exception as exc:
                last_error = str(exc)
                await self.emit(job, "problem_plan_recovery", f"Planning attempt {attempt} rejected: {last_error}", node=root)
        raise RuntimeError(f"Problem Supervisor could not produce a valid 4x4 plan: {last_error}")

    def _normalize_step_plan(self, module: dict, data: dict[str, Any]) -> dict[str, Any]:
        steps = data.get("steps")
        if not isinstance(steps, list) or not 2 <= len(steps) <= 10:
            raise ValueError("Module execution plan must have between 2 and 10 steps")
        valid_ids = {x["id"] for x in module["supervisor_tasks"]}
        covered: set[str] = set()
        n_steps = []
        for si, raw in enumerate(steps, 1):
            if not isinstance(raw, dict):
                raise ValueError(f"Execution step {si} is not an object")
            covers = raw.get("covers") if isinstance(raw.get("covers"), list) else []
            covers = [str(x) for x in covers if str(x) in valid_ids]
            covered.update(covers)
            n_steps.append({
                "id": f"{module['id']}-S{si}",
                "index": si,
                "title": str(raw.get("title") or f"Execution Step {si}")[:180],
                "objective": str(raw.get("objective") or "")[:8000],
                "expected_result": str(raw.get("expected_result") or "")[:8000],
                "covers": covers,
                "execution_class": str(raw.get("execution_class") or "reasoning")[:80],
                "status": "queued",
                "result": "",
                "error": "",
                "started_at": None,
                "completed_at": None,
                "attempts": 0,
            })
        missing = sorted(valid_ids - covered)
        if missing:
            raise ValueError("Dynamic steps do not cover supervisor work packages: " + ", ".join(missing))
        result_mode = str(data.get("result_mode") or "combined_synthesis")
        if result_mode not in {"single_outcome", "multi_output", "combined_synthesis"}:
            result_mode = "combined_synthesis"
        return {
            "result_mode": result_mode,
            "completion_definition": str(data.get("completion_definition") or module.get("expected_module_outcome") or "")[:12000],
            "steps": n_steps,
        }

    def _fallback_step_plan(self, module: dict) -> dict[str, Any]:
        steps = []
        for i, wp in enumerate(module["supervisor_tasks"], 1):
            steps.append({
                "id": f"{module['id']}-S{i}", "index": i,
                "title": wp["title"], "objective": wp["task"], "expected_result": wp["expected_outcome"],
                "covers": [wp["id"]], "execution_class": "reasoning", "status": "queued", "result": "", "error": "",
                "started_at": None, "completed_at": None, "attempts": 0,
            })
        return {"result_mode": "combined_synthesis", "completion_definition": module["expected_module_outcome"], "steps": steps}

    async def plan_module_steps(self, job: dict, module: dict, context: str) -> dict[str, Any]:
        sup = await self.supervisor_consult(job, module, "module_dynamic_planning", context)
        tasks_text = json.dumps(module["supervisor_tasks"], ensure_ascii=False)
        last_error = ""
        for attempt in range(1, 3):
            prompt = f"""You are the major module agent responsible for one quarter of a larger problem.
Module: {module['name']}
Objective: {module['goal']}
Ideal module outcome: {module['expected_module_outcome']}
The Problem Supervisor already assigned these EXACTLY FOUR work packages:
{tasks_text}
Supervisor guidance: {json.dumps(sup, ensure_ascii=False)}
Previous plan error: {last_error}

Now decide the best execution granularity YOURSELF. Expand the assigned work into between 2 and 10 sequential executable steps. Use only as many steps as genuinely useful: a simple module may need 2; a complex one may need all 10.
Every supervisor work-package ID must be covered by at least one step. A step may cover multiple work packages.
Choose how results should resolve at module level:
- single_outcome: many steps lead to one concrete final outcome/action,
- multi_output: the steps legitimately produce multiple distinct deliverables,
- combined_synthesis: step results should be integrated into one solid module report.
If a step would require a real external tool/action (browser submission, authenticated API write, email send, shell, etc.), label execution_class="external_action". Do not assume such a capability exists.

Return ONLY JSON:
{{"result_mode":"single_outcome|multi_output|combined_synthesis","completion_definition":"...","steps":[
{{"title":"...","objective":"...","expected_result":"...","covers":["M1-T1"],"execution_class":"reasoning|external_action"}}
]}}
2 <= number of steps <= 10."""
            try:
                txt = await self.raw_response(self.master_model, "Plan a bounded sequential execution path for your assigned module.", prompt, 4000)
                plan = self._normalize_step_plan(module, self.parse_json_object(txt))
                module["result_mode"] = plan["result_mode"]
                module["completion_definition"] = plan["completion_definition"]
                module["steps"] = plan["steps"]
                await self.emit(job, "module_step_plan", f"{module['name']} created {len(plan['steps'])} sequential execution steps", node=module,
                                step_count=len(plan["steps"]), result_mode=plan["result_mode"])
                return plan
            except Exception as exc:
                last_error = str(exc)
                await self.emit(job, "module_plan_recovery", f"Dynamic plan attempt {attempt} rejected: {last_error}", node=module)
        plan = self._fallback_step_plan(module)
        module["result_mode"] = plan["result_mode"]
        module["completion_definition"] = plan["completion_definition"]
        module["steps"] = plan["steps"]
        await self.emit(job, "module_step_plan", "Dynamic planning fallback: one sequential step per supervisor work package", node=module,
                        step_count=4, result_mode=plan["result_mode"])
        return plan

    def _prior_results(self, module: dict, before_index: int) -> str:
        rows = []
        for s in module.get("steps", []):
            if s["index"] >= before_index or not s.get("result"):
                continue
            rows.append(f"STEP {s['index']} {s['title']}:\n{s['result'][-5000:]}")
        return "\n\n".join(rows)[-18000:]

    async def execute_step(self, job: dict, module: dict, step: dict, context: str) -> str:
        step_node = {
            "id": step["id"], "name": step["title"], "role": "Sequential Execution Step",
            "depth": 2, "goal": step["objective"], "status": "running",
        }
        step["status"] = "running"
        step["started_at"] = time.time()
        await self.emit(job, "problem_step_start", f"{module['name']} step {step['index']} started", node=step_node,
                        module_id=module["id"], step_index=step["index"])

        if step.get("execution_class") == "external_action":
            step["status"] = "blocked_capability"
            step["error"] = "External action capability is not installed in the current Problem Handling engine"
            step["result"] = "BLOCKED_CAPABILITY: This step requires an external action/tool that is not currently installed. No success was claimed."
            step["completed_at"] = time.time()
            await self.emit(job, "problem_step_blocked", step["error"], node=step_node, module_id=module["id"], step_index=step["index"])
            await self.persist(job)
            raise RuntimeError(step["error"])

        recovery = ""
        for attempt in range(1, self.recovery_attempts + 2):
            step["attempts"] = attempt
            prior = self._prior_results(module, step["index"])
            try:
                prompt = f"""You are executing ONE step inside a major module. Work sequentially; do not skip ahead.
Overall problem: {job['goal']}
Module objective: {module['goal']}
Supervisor's four work packages: {json.dumps(module['supervisor_tasks'], ensure_ascii=False)}
Current step {step['index']}: {step['title']}
Step objective: {step['objective']}
Expected result: {step['expected_result']}
This step covers: {step['covers']}
Original context: {context[-10000:]}
Prior completed step results (authoritative): {prior}
Recovery instruction: {recovery}

Complete only this step. Return a concrete useful TEXT result. Never claim that an external action occurred unless an authorized tool actually performed it. If a missing external capability is discovered, begin the answer with BLOCKED_CAPABILITY: and explain exactly what capability is missing."""
                result = await self.raw_response(self.worker_model, "Execute one bounded sequential problem-solving step.", prompt, 3600)
                if result.lstrip().startswith("BLOCKED_CAPABILITY:"):
                    step["status"] = "blocked_capability"
                    step["result"] = result
                    step["error"] = "Worker discovered a missing external capability"
                    step["completed_at"] = time.time()
                    await self.emit(job, "problem_step_blocked", step["error"], node=step_node, module_id=module["id"], step_index=step["index"])
                    await self.persist(job)
                    raise RuntimeError(step["error"])

                verify_context = f"Module objective: {module['goal']}\nStep expected result: {step['expected_result']}\nCovered packages: {step['covers']}\nPrior results:\n{prior}"
                sup = await self.supervisor_consult(job, step_node, "problem_step_verification", verify_context, candidate=result)
                check = f"""Step objective: {step['objective']}
Expected result: {step['expected_result']}
Candidate result: {result[-16000:]}
Supervisor verification criterion: {sup.get('verify','')}
Return ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction if needed"}}"""
                chk = self.parse_json_object(await self.raw_response(self.supervisor_model, "Strictly verify this one execution step.", check, 900))
                if chk.get("verdict") == "pass":
                    step["result"] = result
                    step["status"] = "completed"
                    step["completed_at"] = time.time()
                    await self.emit(job, "problem_step_complete", f"{module['name']} step {step['index']} verified", node=step_node,
                                    module_id=module["id"], step_index=step["index"], attempts=attempt)
                    await self.persist(job)
                    return result
                recovery = str(chk.get("revision") or "Correct the result so it meets the expected outcome.")
                await self.emit(job, "problem_step_recovery", recovery, node=step_node, module_id=module["id"], step_index=step["index"])
            except RuntimeError:
                raise
            except Exception as exc:
                recovery = str(exc)
                await self.emit(job, "problem_step_error", f"Attempt {attempt}: {exc}", node=step_node,
                                module_id=module["id"], step_index=step["index"])
        step["status"] = "failed"
        step["error"] = "Step failed strict verification after bounded recovery attempts"
        step["completed_at"] = time.time()
        await self.persist(job)
        raise RuntimeError(step["error"])

    async def synthesize_module(self, job: dict, module: dict, context: str) -> str:
        reports = "\n\n".join(
            f"--- STEP {s['index']}: {s['title']} ---\n{s.get('result','')[-7000:]}" for s in module.get("steps", [])
        )[-42000:]
        recovery = ""
        candidate = ""
        for attempt in range(1, 3):
            prompt = f"""You are the major module agent. All your sequential execution steps have completed.
Module objective: {module['goal']}
Ideal module outcome: {module['expected_module_outcome']}
Supervisor work packages and expected outcomes: {json.dumps(module['supervisor_tasks'], ensure_ascii=False)}
Chosen result mode: {module.get('result_mode')}
Completion definition: {module.get('completion_definition')}
Actual verified step results:
{reports}
Revision instruction: {recovery}

Produce the module-level result. If result_mode=single_outcome, state the one final outcome and the evidence from the steps. If multi_output, preserve the distinct outputs clearly. If combined_synthesis, integrate the step results into one solid report. Do not invent completion that is not supported by actual step results."""
            candidate = await self.raw_response(self.master_model, "Synthesize verified sequential work into the assigned module outcome.", prompt, 4600)
            sup_context = f"Expected module outcome: {module['expected_module_outcome']}\nCompletion definition: {module.get('completion_definition')}\nActual step reports:\n{reports}"
            sup = await self.supervisor_consult(job, module, "module_completion_verification", sup_context, candidate=candidate)
            verify_prompt = f"""Module objective: {module['goal']}
Expected module outcome: {module['expected_module_outcome']}
Supervisor work packages: {json.dumps(module['supervisor_tasks'], ensure_ascii=False)}
Actual verified step reports: {reports}
Candidate module result: {candidate[-18000:]}
Supervisor verification criterion: {sup.get('verify','')}
Return ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction"}}"""
            chk = self.parse_json_object(await self.raw_response(self.supervisor_model, "Verify whether the module end goal is actually complete.", verify_prompt, 1000))
            if chk.get("verdict") == "pass":
                return candidate
            recovery = str(chk.get("revision") or "Revise the module result to match actual evidence and expected outcomes.")
            await self.emit(job, "module_result_recovery", recovery, node=module)
        raise RuntimeError("Module result failed completion verification")

    async def run_module(self, job: dict, module: dict, context: str) -> str:
        module["status"] = "running"
        module["started_at"] = time.time()
        await self.emit(job, "problem_module_start", f"{module['name']} agent started", node=module)
        try:
            await self.supervisor_consult(job, module, "module_pre_execution", context,
                                          candidate=json.dumps(module["supervisor_tasks"], ensure_ascii=False))
            await self.plan_module_steps(job, module, context)
            # Strictly sequential within each major module agent.
            for step in module["steps"]:
                await self.execute_step(job, module, step, context)
            result = await self.synthesize_module(job, module, context)
            module["result"] = result
            module["status"] = "completed"
            module["completed_at"] = time.time()
            await self.emit(job, "problem_module_complete", f"{module['name']} end goal verified complete", node=module,
                            step_count=len(module.get("steps", [])), result_mode=module.get("result_mode"))
            await self.persist(job)
            return result
        except Exception as exc:
            module["status"] = "blocked" if any(s.get("status") == "blocked_capability" for s in module.get("steps", [])) else "failed"
            module["error"] = str(exc)
            module["completed_at"] = time.time()
            await self.emit(job, "problem_module_failed", f"{module['name']}: {exc}", node=module)
            await self.persist(job)
            return f"[{module['status'].upper()} MODULE] {module['name']}: {exc}"

    async def final_supervisor_result(self, job: dict, root: dict, context: str, module_results: list[str]) -> str:
        module_reports = "\n\n".join(
            f"--- MODULE {i+1}: {m['name']} | status={m['status']} | expected={m['expected_module_outcome']} ---\n{module_results[i][-12000:]}"
            for i, m in enumerate(root["children"])
        )[-50000:]
        statuses = [m["status"] for m in root["children"]]
        all_complete = all(x == "completed" for x in statuses)
        pre = await self.supervisor_consult(job, root, "problem_final_pre_synthesis", context, candidate=module_reports)
        prompt = f"""You are the Problem Supervisor receiving the FOUR actual major-agent reports.
Original problem: {job['goal']}
Overall success definition: {job['problem_plan']['success_definition']}
Module statuses: {statuses}
Supervisor guidance: {json.dumps(pre, ensure_ascii=False)}
Actual module reports:
{module_reports}

Create the final problem result using ONLY supported module evidence. If all four modules are genuinely completed, begin with PROBLEM_COMPLETE. Otherwise begin with PROBLEM_PARTIAL and clearly name unfinished/blocked modules and what is required next. Integrate the four module results into the strongest useful final answer; do not merely concatenate them."""
        result = await self.raw_response(self.supervisor_model, "Produce the evidence-grounded final Problem Supervisor result.", prompt, 6000)
        post_context = f"Success definition: {job['problem_plan']['success_definition']}\nModule statuses: {statuses}\nACTUAL FOUR MODULE REPORTS:\n{module_reports}"
        post = await self.supervisor_consult(job, root, "problem_final_post_verification", post_context, candidate=result)
        check_prompt = f"""Overall success definition: {job['problem_plan']['success_definition']}
Module statuses: {statuses}
Actual module reports: {module_reports}
Candidate final result: {result[-22000:]}
Supervisor verification criterion: {post.get('verify','')}
Return ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction"}}"""
        chk = self.parse_json_object(await self.raw_response(self.supervisor_model, "Verify final result against all four actual module reports.", check_prompt, 1200))
        if chk.get("verdict") != "pass":
            revision = str(chk.get("revision") or "Correct final result to match actual module evidence.")
            revise_prompt = f"""Revise this Problem Supervisor result using the correction below.
Correction: {revision}
Module statuses: {statuses}
Actual module reports: {module_reports}
Current result: {result}
Begin with {'PROBLEM_COMPLETE' if all_complete else 'PROBLEM_PARTIAL'} and do not invent success."""
            result = await self.raw_response(self.supervisor_model, "Correct the final Problem Supervisor result.", revise_prompt, 6000)
        return result

    async def run(self, job: dict) -> None:
        root = job["root"]
        context = job.get("context", "")
        try:
            job["status"] = "running"
            root["status"] = "running"
            root["started_at"] = time.time()
            await self.persist(job)
            await self.emit(job, "problem_start", "Problem Handling Architecture started", node=root)
            plan = await self.plan_problem(job, root, context)
            root["children"] = []
            for spec in plan["modules"]:
                module = {
                    "id": uuid.uuid4().hex[:12],
                    "name": spec["name"],
                    "role": spec["role"],
                    "goal": spec["objective"],
                    "depth": 1,
                    "status": "queued",
                    "mode": "problem_module_agent",
                    "children": [],
                    "result": "",
                    "error": "",
                    "expected_module_outcome": spec["expected_module_outcome"],
                    "balance_rationale": spec["balance_rationale"],
                    "supervisor_tasks": spec["work_packages"],
                    "steps": [],
                    "result_mode": "",
                    "completion_definition": "",
                    "started_at": None,
                    "completed_at": None,
                }
                root["children"].append(module)
                job["agents_created"] += 1
            await self.emit(job, "problem_spawn", "Problem Supervisor deployed exactly 4 major module agents", node=root, agents_created=job["agents_created"])
            await self.persist(job)

            module_context = f"{context}\n\nORIGINAL PROBLEM: {job['goal']}\nOVERALL SUCCESS DEFINITION: {plan['success_definition']}"
            # Major module agents may work concurrently. Each agent's own steps are strictly sequential.
            import asyncio
            results = await asyncio.gather(*(self.run_module(job, m, module_context) for m in root["children"]))
            result = await self.final_supervisor_result(job, root, context, list(results))
            root["result"] = result
            root["completed_at"] = time.time()
            all_complete = all(m.get("status") == "completed" for m in root["children"])
            root["status"] = "completed" if all_complete else "partial"
            job["result"] = result
            job["status"] = root["status"]
            job["completed_at"] = time.time()
            await self.emit(job, "problem_complete", "Problem Supervisor finalized four module reports", node=root,
                            all_modules_complete=all_complete)
            await self.persist(job)
        except Exception as exc:
            root["status"] = "failed"
            root["error"] = str(exc)
            job["status"] = "failed"
            job["error"] = str(exc)
            job["completed_at"] = time.time()
            await self.emit(job, "problem_failed", str(exc), node=root)
            await self.persist(job)


def build_problem_audit(job: dict[str, Any]) -> dict[str, Any]:
    root = job.get("root") or {}
    modules = root.get("children") or []
    per_module = []
    sequential_ok = True
    for m in modules:
        steps = m.get("steps") or []
        local_seq = True
        for prev, curr in zip(steps, steps[1:]):
            if prev.get("completed_at") is None or curr.get("started_at") is None or curr["started_at"] < prev["completed_at"]:
                local_seq = False
        sequential_ok = sequential_ok and local_seq
        per_module.append({
            "id": m.get("id"),
            "name": m.get("name"),
            "status": m.get("status"),
            "supervisor_task_count": len(m.get("supervisor_tasks") or []),
            "dynamic_step_count": len(steps),
            "result_mode": m.get("result_mode"),
            "sequential_verified": local_seq,
            "step_statuses": [s.get("status") for s in steps],
        })
    sup_events = [e for e in job.get("events", []) if e.get("type") == "supervisor"]
    return {
        "id": job.get("id"),
        "architecture": job.get("architecture"),
        "status": job.get("status"),
        "agents_created": job.get("agents_created"),
        "major_module_count": len(modules),
        "supervisor_work_package_counts": [len(m.get("supervisor_tasks") or []) for m in modules],
        "dynamic_step_counts": [len(m.get("steps") or []) for m in modules],
        "all_step_counts_within_2_to_10": all(2 <= len(m.get("steps") or []) <= 10 for m in modules) if modules else False,
        "strict_sequential_execution_verified": sequential_ok if modules else False,
        "all_modules_complete": bool(modules) and all(m.get("status") == "completed" for m in modules),
        "supervisor_event_count": len(sup_events),
        "post_verification_seen": any(e.get("summary", "").startswith("problem_final_post_verification:") for e in sup_events),
        "modules": per_module,
        "result_prefix": (job.get("result") or "")[:120],
    }

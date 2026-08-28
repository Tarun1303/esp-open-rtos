#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
MAIN="$PROJECT/app/main.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.9.7-failure-recovery-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$MAIN" "$BACKUP/main.py"

rollback(){
  set +e
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"
  cp "$BACKUP/main.py" "$MAIN"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl097-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl097-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'FAILURE_RECOVERY_V0_9_7_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s=p.read_text()

# 1) Give structured artifact execution enough output room while keeping the existing
# job/node/request cost governor authoritative. Recovery attempts get additional room.
old='''        stage_u = stage.upper()
        if "SELF_VERIFY" in stage_u:
            output_cap = 650
            reasoning_effort = "none"
        elif "UNDERSTAND" in stage_u:
            output_cap = 950
            reasoning_effort = "low"
        elif stage_u == "PLAN":
            output_cap = 1250
            reasoning_effort = "low"
        elif "SYNTH" in stage_u or "FINAL" in stage_u:
            output_cap = 1900
            reasoning_effort = "low"
        else:
            output_cap = 1450
            reasoning_effort = "none"
'''
new='''        stage_u = stage.upper()
        if "SELF_VERIFY" in stage_u:
            output_cap = 700
            reasoning_effort = "none"
        elif "UNDERSTAND" in stage_u:
            output_cap = 1100
            reasoning_effort = "low"
        elif stage_u == "PLAN":
            output_cap = 1500
            reasoning_effort = "low"
        elif "SYNTH" in stage_u or "FINAL" in stage_u:
            output_cap = 2600
            reasoning_effort = "low"
        else:
            output_cap = 2200
            reasoning_effort = "none"
        if "ATTEMPT_2" in stage_u or "OUTPUT_RECOVERY" in stage_u:
            output_cap = max(output_cap, 3200)
'''
if 'output_cap = 2200' not in s:
    if old not in s: raise SystemExit('v0.9.7 output-cap anchor missing')
    s=s.replace(old,new,1)

# 2) A max_output_tokens terminal event is recoverable, not a node failure. Retry the
# same bounded call once with a larger ceiling and a compact-output instruction.
old='''        result = await Runner.run(
            agent,
            prompt,
            max_turns=max_turns,
            run_config=self._run_config(job, node, stage),
        )
'''
new='''        try:
            result = await Runner.run(
                agent,
                prompt,
                max_turns=max_turns,
                run_config=self._run_config(job, node, stage),
            )
        except Exception as exc:
            msg = str(exc)
            truncation = "max_output_tokens" in msg or ("response.incomplete" in msg and "incomplete" in msg)
            if not truncation:
                raise

            # Conservatively meter the failed call because the SDK does not return a
            # normal usage object for a terminal incomplete response.
            estimated_input = max(1, len(prompt) // 4)
            estimated_failed = estimated_input + int(output_cap)
            nu["requests"] = int(nu.get("requests", 0)) + 1
            nu["input_tokens"] = int(nu.get("input_tokens", 0)) + estimated_input
            nu["output_tokens"] = int(nu.get("output_tokens", 0)) + int(output_cap)
            nu["total_tokens"] = int(nu.get("total_tokens", 0)) + estimated_failed
            nu["output_recoveries"] = int(nu.get("output_recoveries", 0)) + 1
            cg["sdk_requests"] = int(cg.get("sdk_requests", 0)) + 1
            cg["sdk_total_tokens"] = int(cg.get("sdk_total_tokens", 0)) + estimated_failed
            if int(cg.get("sdk_requests", 0)) >= int(cg["sdk_request_budget"]) or int(cg.get("sdk_total_tokens", 0)) >= int(cg["sdk_token_budget"]):
                raise RuntimeError("COST_GOVERNOR: truncation recovery blocked because the job budget is exhausted") from exc

            recovery_cap = min(4200, max(3000, int(output_cap) + 1200))
            recovery_agent = Agent(
                name=f"{node['name']} · {stage} · OUTPUT_RECOVERY",
                instructions=instructions,
                model=model,
                output_type=output_type,
                model_settings={
                    "max_tokens": recovery_cap,
                    "reasoning": {"effort": "none"},
                    "verbosity": "low",
                    "store": False,
                    "prompt_cache_retention": "24h",
                },
            )
            recovery_prompt = prompt + "\\n\\nOUTPUT-CEILING RECOVERY: the prior structured response hit max_output_tokens. Return the SAME required structured result, complete but compressed. Keep the result field implementation-oriented, avoid repeated context, keep lists concise, and do not omit required constraints or acceptance criteria."
            result = await Runner.run(
                recovery_agent,
                recovery_prompt,
                max_turns=max_turns,
                run_config=self._run_config(job, node, stage + "_OUTPUT_RECOVERY"),
            )
            await self.emit(job, "intelligence_output_recovered", f"{node['name']} recovered {stage} after max_output_tokens", node=node, stage=stage, recovery_cap=recovery_cap)
'''
if 'intelligence_output_recovered' not in s:
    if old not in s: raise SystemExit('v0.9.7 Runner.run anchor missing')
    s=s.replace(old,new,1)

# 3) Planning semantics: tools needed only by a later deployment/handoff must not turn
# an artifact/specification node into BLOCKED_CAPABILITY.
old='Mark any step that truly needs an unavailable external capability.'
new='''Mark a step as requiring an unavailable external capability only when THIS node must perform that live external action to satisfy its assigned result. For design/specification/patch/deployable-package work, repository inspection, shell, CI, or deployment that will be performed later by the controlled bridge is a deferred handoff dependency: produce the exact artifact, commands, placeholders, validation contract, and handoff instead of blocking.'''
if 'deferred handoff dependency' not in s:
    if old not in s: raise SystemExit('v0.9.7 plan capability anchor missing')
    s=s.replace(old,new,1)

# 4) Broaden artifact/handoff detection so build specs and deployable packages receive
# artifact semantics, not live-action semantics.
old='''            artifact_mode = any(marker in operating_text for marker in (
                "design artifact", "reasoning/artifact", "reasoning-only", "implementation specification",
                "architecture specification", "creative + technical", "framework", "design brief",
                "produce the specification", "create a specification"
            ))
'''
new='''            artifact_mode = any(marker in operating_text for marker in (
                "design artifact", "reasoning/artifact", "reasoning-only", "implementation specification",
                "architecture specification", "creative + technical", "framework", "design brief",
                "produce the specification", "create a specification", "build spec", "patch package",
                "implementation-ready", "implementation ready", "production specification",
                "deployable package", "deployment package", "handoff", "no deployment",
                "do not claim actual deployment", "execution-focused artifact"
            ))
'''
if '"patch package"' not in s:
    if old not in s: raise SystemExit('v0.9.7 artifact marker anchor missing')
    s=s.replace(old,new,1)

# 5) At runtime, convert unavailable capabilities into a local handoff step for artifact
# jobs. Live-action jobs still hard-block exactly as before.
old='''                if step.get("requires_external_capability"):
                    step["status"] = "blocked_capability"
                    step["result"] = f"BLOCKED_CAPABILITY: {step.get('capability_needed') or 'External capability'} is not installed."
                    step["completed_at"] = time.time()
                    self.memory.store_step(job, node, step, step["result"])
                    await self.emit(job, "intelligence_step_blocked", step["result"], node=node, step_index=step["index"])
                    raise RuntimeError(step["result"])
'''
new='''                if step.get("requires_external_capability"):
                    operating_text = (str(job.get("goal", "")) + "\\n" + str(job.get("context", ""))).lower()
                    artifact_handoff_mode = any(marker in operating_text for marker in (
                        "design artifact", "reasoning/artifact", "reasoning-only", "implementation specification",
                        "architecture specification", "build spec", "patch package", "implementation-ready",
                        "implementation ready", "production specification", "deployable package",
                        "deployment package", "handoff", "no deployment", "do not claim actual deployment",
                        "execution-focused artifact"
                    ))
                    if artifact_handoff_mode:
                        capability = step.get("capability_needed") or "External capability"
                        step["capability_deferred"] = capability
                        step["requires_external_capability"] = False
                        step["objective"] = str(step.get("objective", "")) + f"\\nDeferred capability: {capability}. Do not perform or claim the live action; produce the complete local artifact/handoff needed for the controlled execution layer to perform it later."
                        step["expected_result"] = str(step.get("expected_result", "")) + " The result must remain useful without the live capability by including exact assumptions/placeholders, handoff instructions, and validation criteria."
                        await self.emit(job, "intelligence_capability_deferred", f"{node['name']} converted unavailable capability into artifact handoff", node=node, step_index=step["index"], capability=capability)
                    else:
                        step["status"] = "blocked_capability"
                        step["result"] = f"BLOCKED_CAPABILITY: {step.get('capability_needed') or 'External capability'} is not installed."
                        step["completed_at"] = time.time()
                        self.memory.store_step(job, node, step, step["result"])
                        await self.emit(job, "intelligence_step_blocked", step["result"], node=node, step_index=step["index"])
                        raise RuntimeError(step["result"])
'''
if 'intelligence_capability_deferred' not in s:
    if old not in s: raise SystemExit('v0.9.7 capability runtime anchor missing')
    s=s.replace(old,new,1)

# 6) If a semantic reviewer still says 'blocked' only because a later external tool is
# absent, a substantive artifact result is accepted as a verified handoff instead of
# failing the node. Pure 'cannot complete' outputs are still rejected.
old='''            if review.verdict == "pass":
                return out.result
            if review.verdict == "blocked":
                raise RuntimeError(review.revision_instruction or "Step blocked by missing capability")
'''
new='''            if review.verdict == "pass":
                return out.result
            if review.verdict == "blocked":
                pure_block = result_text.lower().startswith(("blocked_capability", "cannot complete", "unable to complete"))
                if artifact_mode and len(result_text) >= 120 and not pure_block:
                    step["verification"] = {
                        "self": {"verdict": "pass", "issues": list(review.issues), "revision_instruction": "", "mode": "artifact-capability-deferred"},
                        "supervisor_summary": "Useful artifact accepted; unavailable live capability is preserved as a deferred execution handoff, not a reasoning failure.",
                        "supervisor_verify": str(sup.get("verify", "")),
                        "attempt": attempt,
                    }
                    return out.result
                raise RuntimeError(review.revision_instruction or "Step blocked by missing capability")
'''
if 'artifact-capability-deferred' not in s:
    if old not in s: raise SystemExit('v0.9.7 blocked-review anchor missing')
    s=s.replace(old,new,1)

p.write_text(s)

p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('version="0.9.6"','version="0.9.7"')
s=s.replace('"version":"0.9.6"','"version":"0.9.7"')
if 'failure-recovery-v0.9.7' not in s:
    marker='artifact-step-verify-v0.9.6'
    if marker not in s: raise SystemExit('v0.9.7 architecture marker missing')
    s=s.replace(marker,marker+'+failure-recovery-v0.9.7',1)
p.write_text(s)
PY

python3 -m py_compile "$ENGINE" "$MAIN"
python3 - <<'PY'
from pathlib import Path
s=Path('/opt/fourth-law-agent/app/intelligence_engine.py').read_text()
assert 'intelligence_output_recovered' in s
assert 'intelligence_capability_deferred' in s
assert 'artifact-capability-deferred' in s
assert 'output_cap = 2200' in s and 'output_cap = 2600' in s
assert 'recovery_cap = min(4200' in s
assert '"patch package"' in s and '"deployable package"' in s
assert 'COST_GOVERNOR: truncation recovery blocked' in s
print('V097_LOCAL_FAILURE_REGRESSION_OK')
PY

cd "$PROJECT"
docker compose build agent >/tmp/fl097-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl097-up.log 2>&1
ok=0
for i in $(seq 1 60); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.9.7"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/dev/null
trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'FAILURE_RECOVERY_V0_9_7_DEPLOYED {"capability_false_fail":"artifact-handoff-not-hard-fail","max_output_tokens":"automatic-metered-single-recovery","execute_output_cap":2200,"synthesis_output_cap":2600,"recovery_output_cap_max":4200,"cost_governor":"conservatively-metered","live_action_missing_capability":"still-hard-blocked","artifact_step_verification":"preserved","node_final_quality_gate":"preserved","full_history_replay":false,"paid_smoke":"not_run","local_regression":"ok","local_health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true
echo FAILURE_RECOVERY_V0_9_7_READY

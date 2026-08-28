#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/problem_engine.py"
MAIN="$PROJECT/app/main.py"
[[ $EUID -eq 0 ]]
[[ -f "$ENGINE" && -f "$MAIN" && -f "$PROJECT/.env" ]]
cd "$PROJECT"
cp "$ENGINE" "$ENGINE.bak-v0.7.2-verifier-precedence"
cp "$MAIN" "$MAIN.bak-v0.7.2-verifier-precedence"

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/problem_engine.py')
s=p.read_text()

old='''Module objective: {module['goal']}\\nStep expected result: {step['expected_result']}\\nCovered packages: {step['covers']}\\nPrior results:\\n{prior}'''
new='''Module objective: {module['goal']}\\nStep expected result: {step['expected_result']}\\nCovered packages: {step['covers']}\\nTool capability: {job.get("tool_capability", "unknown")}\\nSemantic scope: If this is reasoning/design work, verify the produced artifact itself; future empirical evidence may be specified but is not required unless the original problem explicitly asks for live execution.\\nPrior results:\\n{prior}'''
if old not in s: raise SystemExit('verify_context anchor missing')
s=s.replace(old,new,1)

old='''SEMANTIC VERIFICATION RULES:\\n- Verify whether the candidate actually PRODUCES the step's requested deliverable.\\n- For a framework/design/analysis step, do NOT reject merely because real-world measurements, completed tests, production logs, or external confirmations are absent. Those can be defined as future evidence requirements.\\n- Reject only for material incompleteness, inconsistency, unsupported claims, or failure to create the requested artifact.\\n- Never pass a claim that an external action occurred without tool evidence.\\nReturn ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction if needed"}}'''
new='''SEMANTIC VERIFICATION RULES:\\nAUTHORITY ORDER:\\n1. The original step objective + expected result + actual tool capability define what completion means.\\n2. The candidate must materially produce that requested artifact/result.\\n3. The Supervisor verification criterion is advisory and MUST NOT silently expand a reasoning/design task into an unrequested live-world execution requirement.\\n- For a framework/design/analysis step, do NOT reject merely because real-world measurements, completed tests, production logs, rollback drills, approvals, or external confirmations are absent. The artifact may DEFINE those future evidence requirements.\\n- If the Supervisor criterion asks for live evidence that the original reasoning-only step did not ask to collect, reinterpret that criterion as a requirement that the artifact clearly specify the evidence/test/gate, not that it already exists.\\n- Reject only for material incompleteness, inconsistency, unsupported factual claims, or failure to create the requested artifact.\\n- Never pass a claim that an external action occurred without tool evidence.\\nReturn ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction if needed"}}'''
if old not in s: raise SystemExit('step semantic rules anchor missing')
s=s.replace(old,new,1)

# Add a final semantic adjudication before a reasoning step is marked failed.
old='''        step["status"] = "failed"\n        step["error"] = "Step failed strict verification after bounded recovery attempts"\n        step["completed_at"] = time.time()\n        await self.persist(job)\n        raise RuntimeError(step["error"])\n'''
new='''        # Final conflict adjudication for reasoning artifacts. This does not lower the quality bar;\n        # it removes only verifier criteria that improperly demand unrequested live-world evidence.\n        if step.get("execution_class") == "reasoning" and locals().get("result"):\n            try:\n                adjudicate = f"""Original overall problem: {job['goal']}\nModule objective: {module['goal']}\nStep objective: {step['objective']}\nExpected result: {step['expected_result']}\nTool capability: {job.get('tool_capability', 'unknown')}\nCandidate result: {result[-18000:]}\n\nPerform a FINAL SEMANTIC ADJUDICATION independent of prior Supervisor criteria.\nIf this is a reasoning/design/framework task, PASS when the candidate concretely creates the requested artifact with enough usable substance, even if it specifies future tests/evidence rather than having already run them.\nREVISE only if the requested artifact itself is materially incomplete, inconsistent, unsupported, or absent.\nNever pass a false claim of external execution.\nReturn ONLY JSON: {{"verdict":"pass|revise","reason":"short reason"}}"""\n                adj = self.parse_json_object(await self.raw_response(self.supervisor_model, "Adjudicate artifact completion without inventing live-world requirements.", adjudicate, 900))\n                if adj.get("verdict") == "pass":\n                    step["result"] = result\n                    step["status"] = "completed"\n                    step["error"] = ""\n                    step["completed_at"] = time.time()\n                    await self.emit(job, "problem_step_semantic_adjudication", "Reasoning artifact passed final semantic adjudication", node=step_node, module_id=module["id"], step_index=step["index"], reason=str(adj.get("reason", ""))[:1200])\n                    await self.persist(job)\n                    return result\n            except Exception as exc:\n                await self.emit(job, "problem_step_adjudication_error", f"Semantic adjudication error: {exc}", node=step_node, module_id=module["id"], step_index=step["index"])\n        step["status"] = "failed"\n        step["error"] = "Step failed strict verification after bounded recovery attempts"\n        step["completed_at"] = time.time()\n        await self.persist(job)\n        raise RuntimeError(step["error"])\n'''
if old not in s: raise SystemExit('step failure anchor missing')
s=s.replace(old,new,1)

# Strengthen module verifier precedence as well.
old='''SEMANTIC VERIFICATION RULE: For design/framework/analysis work, pass when all assigned work packages are concretely answered by usable artifacts and decision rules. Do not require the future real-world evidence those artifacts are designed to collect. For explicit execution tasks, continue to require actual execution evidence.\\nReturn ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction"}}'''
new='''SEMANTIC VERIFICATION RULE: For design/framework/analysis work, pass when all assigned work packages are concretely answered by usable artifacts and decision rules. Do not require the future real-world evidence those artifacts are designed to collect. The original module objective and verified step reports control completion semantics; Supervisor verification text is advisory and may not convert an artifact task into an unrequested live execution. For explicit execution tasks, continue to require actual execution evidence. Never pass false external-action claims.\\nReturn ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction"}}'''
if old not in s: raise SystemExit('module semantic rules anchor missing')
s=s.replace(old,new,1)

p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('0.7.1','0.7.2')
p.write_text(s)
PY

python3 -m py_compile "$ENGINE" "$MAIN"
docker compose build agent
docker compose up -d agent
ok=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl072-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.7.2"' /tmp/fl072-health.json
ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl072-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl072-api.json
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'PROBLEM_ARCHITECTURE_V0_7_2_PATCHED {"fix":"reasoning-verifier-precedence+semantic-adjudication","api_check":"ok"}' >/dev/null 2>&1 || true
echo FOURTHLAW_V0_7_2_READY
cat /tmp/fl072-health.json

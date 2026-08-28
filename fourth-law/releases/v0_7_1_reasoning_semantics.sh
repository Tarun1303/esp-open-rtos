#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/problem_engine.py"
MAIN="$PROJECT/app/main.py"
BRIDGE=/usr/local/lib/fourthlaw-bridge/bridge.py
[[ $EUID -eq 0 ]]
[[ -f "$ENGINE" && -f "$MAIN" && -f "$PROJECT/.env" ]]
cd "$PROJECT"
cp "$ENGINE" "$ENGINE.bak-v0.7.1-reasoning-semantics"
cp "$MAIN" "$MAIN.bak-v0.7.1-reasoning-semantics"

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/problem_engine.py')
s=p.read_text()

# 1) Root Supervisor: distinguish requested artifact/design work from live-world execution.
old='''Previous planning error: {last_error}\n\nCreate a TWO-LAYER problem architecture before any module agent starts work.\n'''
new='''Previous planning error: {last_error}\nTool capability: {job.get("tool_capability", "unknown")}\n\nCOMPLETION SEMANTICS:\n- First determine what the user actually asked to produce.\n- If the problem asks to design, define, analyze, plan, create a framework, checklist, protocol, matrix, model, strategy, or other reasoning artifact, completion means PRODUCING that usable artifact. Do NOT require nonexistent empirical observations or completed external tests. You may specify what evidence a future real execution must collect.\n- If the problem explicitly asks to perform a real external action or verify a real-world state, only then may completion depend on actual external evidence/tool results.\n- In reasoning-only mode, every expected outcome must itself be producible through reasoning: criteria, templates, methods, decision rules, risk registers, evidence requirements, or other requested artifacts. Never phrase the expected outcome as though live evidence was already gathered.\n\nCreate a TWO-LAYER problem architecture before any module agent starts work.\n'''
if old not in s: raise SystemExit('root semantics anchor missing')
s=s.replace(old,new,1)

# 2) Dynamic module planning: prevent invented external evidence requirements in reasoning-only work.
old='''Previous plan error: {last_error}\n\nNow decide the best execution granularity YOURSELF. Expand the assigned work into between 2 and 10 sequential executable steps.'''
new='''Previous plan error: {last_error}\nTool capability: {job.get("tool_capability", "unknown")}\n\nSEMANTIC RULE: If the assigned module is a design/framework/analysis task, your steps must CREATE the requested artifacts. Do not turn "define a test/evidence framework" into "run the test and collect evidence". In reasoning-only mode, transform any would-be live action into a concrete specification, checklist, scenario set, evidence schema, acceptance rule, or decision artifact unless the original user explicitly asked for the live action.\n\nNow decide the best execution granularity YOURSELF. Expand the assigned work into between 2 and 10 sequential executable steps.'''
if old not in s: raise SystemExit('module planning semantics anchor missing')
s=s.replace(old,new,1)

# 3) Step worker: make artifact-completion semantics explicit.
old='''Recovery instruction: {recovery}\n\nComplete only this step. Return a concrete useful TEXT result. Never claim that an external action occurred unless an authorized tool actually performed it.'''
new='''Recovery instruction: {recovery}\nTool capability: {job.get("tool_capability", "unknown")}\n\nCOMPLETION RULE: Judge the step by the requested deliverable, not by evidence that the user never asked you to collect. For reasoning/design work, produce the actual matrix/checklist/framework/rubric/protocol/template/method requested, with concrete fields, thresholds, examples, and evidence requirements where useful. It is valid to define what future evidence must show; it is NOT necessary to pretend that evidence has already been collected.\n\nComplete only this step. Return a concrete useful TEXT result. Never claim that an external action occurred unless an authorized tool actually performed it.'''
if old not in s: raise SystemExit('worker semantics anchor missing')
s=s.replace(old,new,1)

# 4) Strict step verifier: verify artifact quality, not nonexistent empirical proof.
old='''Candidate result: {result[-16000:]}\nSupervisor verification criterion: {sup.get('verify','')}\nReturn ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction if needed"}}'''
new='''Candidate result: {result[-16000:]}\nSupervisor verification criterion: {sup.get('verify','')}\nTool capability: {job.get("tool_capability", "unknown")}\nSEMANTIC VERIFICATION RULES:\n- Verify whether the candidate actually PRODUCES the step's requested deliverable.\n- For a framework/design/analysis step, do NOT reject merely because real-world measurements, completed tests, production logs, or external confirmations are absent. Those can be defined as future evidence requirements.\n- Reject only for material incompleteness, inconsistency, unsupported claims, or failure to create the requested artifact.\n- Never pass a claim that an external action occurred without tool evidence.\nReturn ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction if needed"}}'''
if old not in s: raise SystemExit('step verifier semantics anchor missing')
s=s.replace(old,new,1)

# 5) Module synthesis semantics.
old='''Actual verified step results:\n{reports}\nRevision instruction: {recovery}\n\nProduce the module-level result.'''
new='''Actual verified step results:\n{reports}\nRevision instruction: {recovery}\nTool capability: {job.get("tool_capability", "unknown")}\n\nFor design/framework/analysis problems, the module can be complete when the requested operational artifact is complete even though the real system has not yet been tested with future empirical evidence. Clearly separate "framework produced" from "future evidence still to be collected during real execution."\n\nProduce the module-level result.'''
if old not in s: raise SystemExit('module synthesis semantics anchor missing')
s=s.replace(old,new,1)

# 6) Module completion verifier semantics.
old='''Candidate module result: {candidate[-18000:]}\nSupervisor verification criterion: {sup.get('verify','')}\nReturn ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction"}}'''
new='''Candidate module result: {candidate[-18000:]}\nSupervisor verification criterion: {sup.get('verify','')}\nTool capability: {job.get("tool_capability", "unknown")}\nSEMANTIC VERIFICATION RULE: For design/framework/analysis work, pass when all assigned work packages are concretely answered by usable artifacts and decision rules. Do not require the future real-world evidence those artifacts are designed to collect. For explicit execution tasks, continue to require actual execution evidence.\nReturn ONLY JSON: {{"verdict":"pass|revise","revision":"specific correction"}}'''
if old not in s: raise SystemExit('module verifier semantics anchor missing')
s=s.replace(old,new,1)

# 7) Final Supervisor semantics: distinguish framework completion from real-world go/no-go evidence.
old='''Create the final problem result using ONLY supported module evidence. If all four modules are genuinely completed, begin with PROBLEM_COMPLETE. Otherwise begin with PROBLEM_PARTIAL and clearly name unfinished/blocked modules and what is required next.'''
new='''Create the final problem result using ONLY supported module evidence. Interpret success according to what the user asked: if the user asked to CREATE a decision framework, then the problem is complete when that framework and its required evidence schema/gates are complete; do not falsely downgrade it because the fictional/real product has not yet generated that future evidence. If the user asked to actually perform or verify a live-world outcome, require real execution evidence. If all four requested modules are genuinely completed under those semantics, begin with PROBLEM_COMPLETE. Otherwise begin with PROBLEM_PARTIAL and clearly name unfinished/blocked modules and what is required next.'''
if old not in s: raise SystemExit('final semantics anchor missing')
s=s.replace(old,new,1)

# 8) More useful audit debugging without dumping full job data.
old='''            "result_mode": m.get("result_mode"),\n            "sequential_verified": local_seq,\n            "step_statuses": [s.get("status") for s in steps],\n        })'''
new='''            "result_mode": m.get("result_mode"),\n            "sequential_verified": local_seq,\n            "error": m.get("error", ""),\n            "failed_steps": [\n                {"index": s.get("index"), "title": s.get("title"), "status": s.get("status"), "error": s.get("error", ""), "attempts": s.get("attempts", 0)}\n                for s in steps if s.get("status") in {"failed", "blocked_capability"}\n            ],\n            "step_statuses": [s.get("status") for s in steps],\n        })'''
if old not in s: raise SystemExit('audit anchor missing')
s=s.replace(old,new,1)

p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('0.7.0','0.7.1')
p.write_text(s)
PY

# Cosmetic bridge version fix only; command set was already active.
if [[ -f "$BRIDGE" ]]; then
python3 - <<'PY'
from pathlib import Path
p=Path('/usr/local/lib/fourthlaw-bridge/bridge.py')
s=p.read_text()
s=s.replace("{'version':'1.1'", "{'version':'1.4'")
s=s.replace('"version":"1.1"', '"version":"1.4"')
p.write_text(s)
PY
fi

python3 -m py_compile "$ENGINE" "$MAIN" "$BRIDGE"
docker compose build agent
docker compose up -d agent
ok=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl071-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.7.1"' /tmp/fl071-health.json
ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl071-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl071-api.json
systemctl restart fourthlaw-command-bridge.service
sleep 2
systemctl is-active --quiet fourthlaw-command-bridge.service
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'PROBLEM_ARCHITECTURE_V0_7_1_PATCHED {"fix":"artifact-vs-live-execution-semantics","audit_errors":true,"api_check":"ok"}' >/dev/null 2>&1 || true
echo FOURTHLAW_V0_7_1_READY
cat /tmp/fl071-health.json

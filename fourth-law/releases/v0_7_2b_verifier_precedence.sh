#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/problem_engine.py"
MAIN="$PROJECT/app/main.py"
[[ $EUID -eq 0 ]]
[[ -f "$ENGINE" && -f "$MAIN" && -f "$PROJECT/.env" ]]
cd "$PROJECT"
cp "$ENGINE" "$ENGINE.bak-v0.7.2b-verifier-precedence"
cp "$MAIN" "$MAIN.bak-v0.7.2b-verifier-precedence"

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/problem_engine.py')
s=p.read_text()

needle="Supervisor verification criterion: {sup.get('verify','')}"
if s.count(needle) < 2:
    raise SystemExit(f'expected at least two supervisor criterion anchors, found {s.count(needle)}')

step_repl="""Supervisor verification criterion (ADVISORY only): {sup.get('verify','')}\nVERIFIER AUTHORITY: The original step objective, expected result, and actual tool capability define completion. For reasoning/design/framework work, a Supervisor criterion may require the artifact to SPECIFY future tests/evidence/gates, but may not require those future live-world actions to have already happened unless the original problem explicitly requested execution. Never pass a false claim of external execution."""
s=s.replace(needle, step_repl, 1)

module_repl="""Supervisor verification criterion (ADVISORY only): {sup.get('verify','')}\nMODULE VERIFIER AUTHORITY: The module objective plus actual verified step reports define completion. For reasoning/design/framework work, do not convert a completed artifact into a failure merely because future empirical evidence, approvals, drills, telemetry, or external confirmations have not yet occurred. Explicit live-execution tasks still require real tool evidence."""
s=s.replace(needle, module_repl, 1)

failure_anchor='''        step["status"] = "failed"\n        step["error"] = "Step failed strict verification after bounded recovery attempts"\n        step["completed_at"] = time.time()\n        await self.persist(job)\n        raise RuntimeError(step["error"])\n'''
if failure_anchor not in s:
    raise SystemExit('step failure boundary missing')

adjudication='''        # Final semantic conflict adjudication for reasoning artifacts only.\n        # This keeps factual/external-action verification strict while preventing advisory\n        # criteria from silently expanding an artifact task into live-world execution.\n        if step.get("execution_class") == "reasoning" and locals().get("result"):\n            try:\n                adjudicate = f"""Overall problem: {job['goal']}\nModule objective: {module['goal']}\nStep objective: {step['objective']}\nExpected result: {step['expected_result']}\nTool capability: {job.get('tool_capability', 'unknown')}\nCandidate result: {result[-18000:]}\n\nFINAL SEMANTIC ADJUDICATION:\n- Judge only whether the requested reasoning/design/framework artifact itself is concretely and usefully produced.\n- It is valid for an artifact to define future tests, evidence fields, acceptance gates, rollback drills, approvals, or telemetry requirements without pretending they already occurred.\n- REVISE if the artifact itself is materially incomplete, inconsistent, unsupported, or absent.\n- Never PASS a claim that an external action occurred without actual tool evidence.\nReturn ONLY JSON: {{"verdict":"pass|revise","reason":"short reason"}}"""\n                adj = self.parse_json_object(await self.raw_response(self.supervisor_model, "Final semantic adjudication for one reasoning artifact.", adjudicate, 900))\n                if adj.get("verdict") == "pass":\n                    step["result"] = result\n                    step["status"] = "completed"\n                    step["error"] = ""\n                    step["completed_at"] = time.time()\n                    await self.emit(job, "problem_step_semantic_adjudication", "Reasoning artifact passed final semantic adjudication", node=step_node, module_id=module["id"], step_index=step["index"], reason=str(adj.get("reason", ""))[:1200])\n                    await self.persist(job)\n                    return result\n            except Exception as exc:\n                await self.emit(job, "problem_step_adjudication_error", f"Semantic adjudication error: {exc}", node=step_node, module_id=module["id"], step_index=step["index"])\n\n'''
s=s.replace(failure_anchor, adjudication+failure_anchor, 1)
p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
if '0.7.1' not in s:
    raise SystemExit('main version 0.7.1 anchor missing')
s=s.replace('0.7.1','0.7.2',1)
p.write_text(s)
PY

python3 -m py_compile "$ENGINE" "$MAIN"
docker compose build agent
docker compose up -d agent
ok=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl072b-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.7.2"' /tmp/fl072b-health.json
ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl072b-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl072b-api.json
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'PROBLEM_ARCHITECTURE_V0_7_2_PATCHED {"fix":"robust-verifier-precedence+semantic-adjudication","api_check":"ok"}' >/dev/null 2>&1 || true
echo FOURTHLAW_V0_7_2_READY
cat /tmp/fl072b-health.json

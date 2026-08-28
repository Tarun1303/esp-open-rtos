#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
MAIN="$PROJECT/app/main.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.9.5b-artifact-reliability-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$MAIN" "$BACKUP/main.py"
rollback(){
  set +e
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"
  cp "$BACKUP/main.py" "$MAIN"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl095b-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl095b-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'ARTIFACT_RELIABILITY_V0_9_5B_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s=p.read_text()

old='''        stage_u = stage.upper()
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
'''
new='''        stage_u = stage.upper()
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
if 'reasoning_effort = "none"' not in s:
    if old not in s: raise SystemExit('v0.9.5b output-cap anchor missing')
    s=s.replace(old,new,1)

# Current v0.9.3 includes prompt_cache_retention. Patch only the stable max_tokens line.
needle='                "max_tokens": output_cap,\n'
if '"reasoning": {"effort": reasoning_effort}' not in s:
    if needle not in s: raise SystemExit('v0.9.5b max_tokens line missing')
    s=s.replace(needle, needle+'                "reasoning": {"effort": reasoning_effort},\n',1)

anchor='''            node_complexity = int((node.get("understanding") or {}).get("complexity", 5) or 5)
            result_text = str(getattr(out, "result", "") or "").strip()
            confidence = float(getattr(out, "confidence", 0.0) or 0.0)
            unresolved = list(getattr(out, "unresolved", []) or [])
            if attempt == 1 and node_complexity <= 3 and len(result_text) >= 40 and confidence >= 0.55 and len(unresolved) <= 1:
'''
replacement='''            node_complexity = int((node.get("understanding") or {}).get("complexity", 5) or 5)
            result_text = str(getattr(out, "result", "") or "").strip()
            confidence = float(getattr(out, "confidence", 0.0) or 0.0)
            unresolved = list(getattr(out, "unresolved", []) or [])
            operating_text = (str(job.get("goal", "")) + "\\n" + str(job.get("context", ""))).lower()
            artifact_mode = any(marker in operating_text for marker in (
                "design artifact", "reasoning/artifact", "reasoning-only", "implementation specification",
                "architecture specification", "creative + technical", "framework", "design brief",
                "produce the specification", "create a specification"
            ))
            artifact_blocked = any(x in result_text.lower() for x in (
                "cannot complete", "unable to complete", "blocked by missing", "requires unavailable"
            ))
            if (attempt == 1 and artifact_mode and len(result_text) >= 90 and confidence >= 0.45
                    and len(unresolved) <= 1 and not artifact_blocked):
                step["verification"] = {
                    "self": {"verdict": "pass", "issues": [], "revision_instruction": "", "mode": "deterministic-artifact"},
                    "supervisor_summary": "Artifact step passed local completeness gate; semantic quality is checked at node/final synthesis.",
                    "supervisor_verify": "",
                    "attempt": attempt,
                }
                return out.result
            if attempt == 1 and node_complexity <= 3 and len(result_text) >= 40 and confidence >= 0.55 and len(unresolved) <= 1:
'''
if '"mode": "deterministic-artifact"' not in s:
    if anchor not in s: raise SystemExit('v0.9.5b artifact gate anchor missing')
    s=s.replace(anchor,replacement,1)

old='''Return a concrete result, evidence/grounds used, assumptions, unresolved items, and calibrated confidence.
Do not claim any real external action occurred.'''
new='''Return a concrete result, evidence/grounds used, assumptions, unresolved items, and calibrated confidence.
For design/specification/artifact work, keep the result concise and implementation-oriented; do not narrate your reasoning process.
Do not claim any real external action occurred.'''
if 'keep the result concise and implementation-oriented' not in s:
    if old not in s: raise SystemExit('v0.9.5b execute prompt anchor missing')
    s=s.replace(old,new,1)

p.write_text(s)

p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('version="0.9.3"','version="0.9.5"')
s=s.replace('"version":"0.9.3"','"version":"0.9.5"')
if 'artifact-reliability-v0.9.5' not in s:
    marker='shared-memory-v0.9.3-constraint-preserving'
    if marker not in s: raise SystemExit('v0.9.5b architecture marker missing')
    s=s.replace(marker,marker+'+artifact-reliability-v0.9.5',1)
p.write_text(s)
PY

python3 -m py_compile "$ENGINE" "$MAIN"
grep -q 'deterministic-artifact' "$ENGINE"
grep -q 'reasoning_effort = "none"' "$ENGINE"
grep -q '"reasoning": {"effort": reasoning_effort}' "$ENGINE"
grep -q 'prompt_cache_retention' "$ENGINE"
grep -q 'output_cap = 1900' "$ENGINE"

cd "$PROJECT"
docker compose build agent >/tmp/fl095b-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl095b-up.log 2>&1
ok=0
for i in $(seq 1 60); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.9.5"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/dev/null
trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'ARTIFACT_RELIABILITY_V0_9_5_DEPLOYED {"artifact_step_verification":"deterministic-first","node_final_quality_gate":"preserved","execute_reasoning":"none","understand_plan_synth_reasoning":"low","execute_output_cap":1450,"synthesis_output_cap":1900,"prompt_cache_retention":"preserved","cost_governor":"unchanged","step_governor":"unchanged","delegation_governor":"unchanged","full_history_replay":false,"paid_smoke":"not_run","local_health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true
echo ARTIFACT_RELIABILITY_V0_9_5_READY

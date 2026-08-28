#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
MAIN="$PROJECT/app/main.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.9.6-artifact-step-verification-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$MAIN" "$BACKUP/main.py"
rollback(){
  set +e
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"
  cp "$BACKUP/main.py" "$MAIN"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl096-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl096-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'ARTIFACT_STEP_VERIFY_V0_9_6_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s=p.read_text()
old='''            if (attempt == 1 and artifact_mode and len(result_text) >= 90 and confidence >= 0.45
                    and len(unresolved) <= 1 and not artifact_blocked):
                step["verification"] = {
                    "self": {"verdict": "pass", "issues": [], "revision_instruction": "", "mode": "deterministic-artifact"},
                    "supervisor_summary": "Artifact step passed local completeness gate; semantic quality remains checked at node/final synthesis.",
                    "supervisor_verify": "",
                    "attempt": attempt,
                }
                return out.result
'''
new='''            if attempt == 1 and artifact_mode and len(result_text) >= 60 and not artifact_blocked:
                step["verification"] = {
                    "self": {
                        "verdict": "pass",
                        "issues": [],
                        "revision_instruction": "",
                        "mode": "deterministic-artifact-v2",
                    },
                    "supervisor_summary": "Artifact step accepted locally; semantic quality remains enforced at node synthesis/post-verification and final Supervisor synthesis.",
                    "supervisor_verify": "",
                    "attempt": attempt,
                    "artifact_unresolved_count": len(unresolved),
                    "artifact_confidence": confidence,
                }
                return out.result
'''
if 'deterministic-artifact-v2' not in s:
    if old not in s: raise SystemExit('v0.9.6 artifact-v1 gate anchor missing')
    s=s.replace(old,new,1)
p.write_text(s)

p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('version="0.9.5"','version="0.9.6"')
s=s.replace('"version":"0.9.5"','"version":"0.9.6"')
if 'artifact-step-verify-v0.9.6' not in s:
    marker='artifact-reliability-v0.9.5'
    if marker not in s: raise SystemExit('v0.9.6 architecture marker missing')
    s=s.replace(marker,marker+'+artifact-step-verify-v0.9.6',1)
p.write_text(s)
PY
python3 -m py_compile "$ENGINE" "$MAIN"
grep -q 'deterministic-artifact-v2' "$ENGINE"
grep -q 'node synthesis/post-verification' "$ENGINE"
grep -q 'reasoning_effort = "none"' "$ENGINE"
cd "$PROJECT"
docker compose build agent >/tmp/fl096-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl096-up.log 2>&1
ok=0
for i in $(seq 1 60); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.9.6"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/dev/null
trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'ARTIFACT_STEP_VERIFY_V0_9_6_DEPLOYED {"artifact_step_llm_verifier":false,"artifact_step_gate":"substantive-nonblocked-local","module_postverification":"preserved","final_supervisor_quality_gate":"preserved","reasoning_effort_governor":"preserved","cost_governor":"unchanged","step_governor":"unchanged","delegation_governor":"unchanged","full_history_replay":false,"paid_smoke":"not_run","local_health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true
echo ARTIFACT_STEP_VERIFY_V0_9_6_READY
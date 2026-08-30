#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
ENG="$PROJECT/app/intelligence_engine.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.9.9-agent-failure-repair-$STAMP"
mkdir -p "$BACKUP"
cp "$ENG" "$BACKUP/intelligence_engine.py"
rollback(){
  set +e
  cp "$BACKUP/intelligence_engine.py" "$ENG"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl099-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl099-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'AGENT_FAILURE_REPAIR_V0_9_9_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s=p.read_text()
old='''            artifact_blocked = any(x in result_text.lower() for x in (
                "cannot complete", "unable to complete", "blocked by missing", "requires unavailable"
            ))
'''
new='''            artifact_prefix = result_text.lower().lstrip()[:240]
            artifact_blocked = artifact_prefix.startswith((
                "cannot complete", "unable to complete", "blocked_capability", "blocked by missing",
                "requires unavailable capability", "unable to proceed"
            ))
'''
if 'artifact_prefix = result_text.lower().lstrip()[:240]' not in s:
    if old not in s: raise SystemExit('artifact block anchor missing')
    s=s.replace(old,new,1)
old='''                "do not claim actual deployment", "execution-focused artifact"
'''
new='''                "do not claim actual deployment", "execution-focused artifact", "artifact mission",
                "system-repair artifact", "system repair artifact", "artifact-only", "artifact only"
'''
if '"system-repair artifact"' not in s:
    if old not in s: raise SystemExit('artifact mode anchor missing')
    s=s.replace(old,new,1)
old='''        cg = job.get("cost_governor") or {}
        if cg and int(cg.get("sdk_total_tokens", 0)) >= int(int(cg.get("sdk_token_budget", 250000)) * 0.80):
            return False
        lock = self._budget_locks.setdefault(job["id"], asyncio.Lock())
'''
new='''        cg = job.get("cost_governor") or {}
        if cg:
            if int(cg.get("sdk_total_tokens", 0)) >= int(int(cg.get("sdk_token_budget", 250000)) * 0.80):
                return False
            # Preserve request headroom for already-created nodes and final synthesis.
            if int(cg.get("sdk_requests", 0)) >= int(int(cg.get("sdk_request_budget", 60)) * 0.70):
                return False
        lock = self._budget_locks.setdefault(job["id"], asyncio.Lock())
'''
if 'sdk_request_budget", 60)) * 0.70' not in s:
    if old not in s: raise SystemExit('reserve child anchor missing')
    s=s.replace(old,new,1)
p.write_text(s)
PY
python3 -m py_compile "$ENG"
python3 - <<'PY'
from pathlib import Path
s=Path('/opt/fourth-law-agent/app/intelligence_engine.py').read_text()
assert 'artifact_prefix = result_text.lower().lstrip()[:240]' in s
assert '"system-repair artifact"' in s
assert 'sdk_request_budget", 60)) * 0.70' in s
print('AGENT_FAILURE_REPAIR_V099_LOCAL_OK')
PY
cd "$PROJECT"
docker compose build agent >/tmp/fl099-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl099-up.log 2>&1
ok=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl099-health.json 2>/dev/null; then ok=1; break; fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/dev/null
trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'AGENT_FAILURE_REPAIR_V0_9_9_DEPLOYED {"artifact_false_block":"fixed","artifact_mission_markers":"expanded","request_headroom_child_stop":0.70,"request_budget":60,"request_budget_raised":false,"health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true
echo AGENT_FAILURE_REPAIR_V0_9_9_READY

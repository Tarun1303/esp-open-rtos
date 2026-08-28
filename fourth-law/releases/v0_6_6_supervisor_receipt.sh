#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
[[ $EUID -eq 0 ]]
[[ -f "$MAIN" && -f "$PROJECT/.env" ]]
cd "$PROJECT"
cp "$MAIN" "$MAIN.bak-v0.6.2-supervisor-receipt"

python3 - <<'PY'
from pathlib import Path
p=Path("/opt/fourth-law-agent/app/main.py")
s=p.read_text()

# 1) Attach a machine-generated local receipt to every Supervisor consultation.
old = '''    await emit(job, "supervisor", f"{stage}: {result.get('summary','')}", node=node)\n'''
new = '''    receipt = {\n        "consulted": True,\n        "stage": stage,\n        "node_id": node["id"],\n        "ts": time.time(),\n        "summary": str(result.get("summary", ""))[:2000],\n        "risk": str(result.get("risk", "")),\n    }\n    result["_receipt"] = receipt\n    await emit(job, "supervisor", f"{stage}: {result.get('summary','')}", node=node, supervisor_receipt=receipt)\n'''
if old not in s:
    raise SystemExit("supervisor emit anchor not found")
s=s.replace(old,new,1)

# 2) Give an atomic leaf proof of its own pre-plan Supervisor consultation.
a=s.find('async def execute_leaf(')
b=s.find('async def synthesize_parent(', a)
if a < 0 or b < 0:
    raise SystemExit("execute_leaf boundaries not found")
chunk=s[a:b]
needle='Supervisor guidance: {json.dumps(guidance, ensure_ascii=False)}\nRecovery instruction: {recovery}'
replacement='Supervisor guidance: {json.dumps(guidance, ensure_ascii=False)}\nSupervisor consultation receipt: {json.dumps(guidance.get("_receipt", {}), ensure_ascii=False)}\nRecovery instruction: {recovery}'
if needle not in chunk:
    raise SystemExit("leaf prompt supervisor anchor not found")
chunk=chunk.replace(needle,replacement,1)

# 3) Give the strict leaf verifier both the pre-plan and verification receipts.
needle2="Supervisor verification criteria: {verification.get('verify','')}\n\nSTRICT SCOPE RULES:"
replacement2="Supervisor verification criteria: {verification.get('verify','')}\nSupervisor pre-plan receipt: {json.dumps(guidance.get('_receipt', {}), ensure_ascii=False)}\nSupervisor verification receipt: {json.dumps(verification.get('_receipt', {}), ensure_ascii=False)}\n\nSTRICT SCOPE RULES:"
if needle2 not in chunk:
    raise SystemExit("leaf verifier receipt anchor not found")
chunk=chunk.replace(needle2,replacement2,1)
s=s[:a]+chunk+s[b:]

# 4) Version bump.
s=s.replace('0.6.1','0.6.2')
p.write_text(s)
PY

python3 -m py_compile "$MAIN"
docker compose build agent
docker compose up -d agent

ok=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health > /tmp/fl062-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.6.2"' /tmp/fl062-health.json

ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl062-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl062-api.json

HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'CONTROL_ROOM_V0_6_2_PATCHED {"fix":"supervisor-local-receipt","api_check":"ok"}' >/dev/null 2>&1 || true
echo FOURTHLAW_V0_6_2_READY
cat /tmp/fl062-health.json

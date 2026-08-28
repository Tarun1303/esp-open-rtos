#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
[[ $EUID -eq 0 ]]
[[ -f "$MAIN" && -f "$PROJECT/.env" ]]
cd "$PROJECT"
cp "$MAIN" "$MAIN.bak-v0.6.1-leaf-scope"

python3 - <<'PY'
from pathlib import Path
p=Path("/opt/fourth-law-agent/app/main.py")
s=p.read_text()
s=s.replace('version="0.6.0"', 'version="0.6.1"')
s=s.replace('"version":"0.6.0"', '"version":"0.6.1"')
old='            check_prompt = f"""Goal: {node[\'goal\']}\nResult: {result[-18000:]}\nVerification criteria: {verification.get(\'verify\',\'\')}\nReturn ONLY JSON: {{\\"verdict\\":\\"pass|revise\\",\\"revision\\":\\"specific correction\\"}}"""'
new='            check_prompt = f"""You are verifying ONE ATOMIC LEAF only.\nLeaf role: {node[\'role\']}\nLeaf goal: {node[\'goal\']}\nLeaf result: {result[-18000:]}\nSupervisor verification criteria: {verification.get(\'verify\',\'\')}\n\nSTRICT SCOPE RULES:\n- Judge ONLY whether this leaf result satisfies this leaf\'s assigned goal.\n- This leaf does NOT have sibling outputs and must NEVER be required to provide them.\n- Do NOT require parent synthesis, sibling statuses, sibling evidence, or the overall mission outcome.\n- Do NOT ask this leaf to prove what other agents did.\n- If the result adequately completes its own bounded goal, verdict MUST be \\"pass\\".\n- Request revision only for a concrete deficiency within this leaf\'s own assigned goal.\n\nReturn ONLY JSON: {{\\"verdict\\":\\"pass|revise\\",\\"revision\\":\\"specific in-scope correction or empty string\\"}}"""'
if old not in s:
    raise SystemExit("execute_leaf verifier anchor not found")
s=s.replace(old,new,1)
old2="Synthesize them into one coherent TEXT result that answers the parent goal.\nResolve conflicts explicitly, preserve important evidence and uncertainty, and do not invent missing facts."
new2="Synthesize them into one coherent TEXT result that answers the parent goal.\nEach child report is authoritative only about THAT CHILD'S own assigned work.\nIgnore unsupported claims a child makes about sibling outcomes or parent-wide completion unless those claims are independently supported by the actual sibling reports supplied here.\nUse the four actual child reports as the source of truth for cross-child status.\nResolve conflicts explicitly, preserve important evidence and uncertainty, and do not invent missing facts."
if old2 not in s:
    raise SystemExit("parent synthesis anchor not found")
s=s.replace(old2,new2,1)
p.write_text(s)
PY

python3 -m py_compile "$MAIN"
docker compose build agent
docker compose up -d agent

ok=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health > /tmp/fl061-health.json 2>/dev/null; then
    ok=1
    break
  fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.6.1"' /tmp/fl061-health.json

ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl061-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl061-api.json

if command -v gh >/dev/null 2>&1 && HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth status >/dev/null 2>&1; then
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'CONTROL_ROOM_V0_6_1_PATCHED {"fix":"leaf-verifier-scope","api_check":"ok"}' >/dev/null 2>&1 || true
fi

echo FOURTHLAW_V0_6_1_READY
cat /tmp/fl061-health.json

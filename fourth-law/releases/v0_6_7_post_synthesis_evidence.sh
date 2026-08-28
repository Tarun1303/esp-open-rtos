#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
[[ $EUID -eq 0 ]]
[[ -f "$MAIN" && -f "$PROJECT/.env" ]]
cd "$PROJECT"
cp "$MAIN" "$MAIN.bak-v0.6.3-post-synthesis-evidence"

python3 - <<'PY'
from pathlib import Path
p=Path("/opt/fourth-law-agent/app/main.py")
s=p.read_text()
old='''    await supervisor_consult(job, node, "post_synthesis_verification", context, candidate=result)\n    return result\n'''
new='''    post_context = (context[-10000:] + "\\n\\nACTUAL FOUR CHILD REPORTS USED FOR SYNTHESIS:\\n" + reports[-36000:])\n    await supervisor_consult(job, node, "post_synthesis_verification", post_context, candidate=result)\n    return result\n'''
if old not in s:
    raise SystemExit("post-synthesis verification anchor not found")
s=s.replace(old,new,1)
s=s.replace('0.6.2','0.6.3')
p.write_text(s)
PY

python3 -m py_compile "$MAIN"
docker compose build agent
docker compose up -d agent

ok=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health > /tmp/fl063-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.6.3"' /tmp/fl063-health.json

ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl063-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl063-api.json

HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'CONTROL_ROOM_V0_6_3_PATCHED {"fix":"post-synthesis-evidence-context","api_check":"ok"}' >/dev/null 2>&1 || true
echo FOURTHLAW_V0_6_3_READY
cat /tmp/fl063-health.json

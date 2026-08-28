#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/fourth-law-agent
MAIN=app/main.py
ENGINE=app/problem_engine.py
[[ -f "$MAIN" && -f "$ENGINE" && -f .env ]]
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
needle='"version":"0.7.1"'
count=s.count(needle)
if count != 2:
    raise SystemExit(f'expected exactly 2 stale version markers, found {count}')
s=s.replace(needle,'"version":"0.7.2"')
p.write_text(s)
PY
python3 -m py_compile "$MAIN" "$ENGINE"
grep -q 'FINAL SEMANTIC ADJUDICATION' "$ENGINE"
[[ "$(grep -c 'ADVISORY only' "$ENGINE")" -ge 2 ]]
docker compose build agent
docker compose up -d agent
ok=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/fl072c-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '"version":"0.7.2"' /tmp/fl072c-health.json
ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | cut -d= -f2-)"
code="$(curl -sS -o /tmp/fl072c-api.json -w '%{http_code}' -H "X-Admin-Token: $ADMIN_TOKEN" http://127.0.0.1:8787/api-check)"
[[ "$code" = "200" ]]
grep -q 'FOURTHLAW_API_OK' /tmp/fl072c-api.json
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'PROBLEM_ARCHITECTURE_V0_7_2_PATCHED {"fix":"verifier-precedence+semantic-adjudication+version-finalized","api_check":"ok"}' >/dev/null 2>&1 || true
echo FOURTHLAW_V0_7_2_READY
cat /tmp/fl072c-health.json

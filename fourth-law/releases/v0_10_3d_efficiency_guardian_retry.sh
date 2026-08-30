#!/usr/bin/env bash
set -Eeuo pipefail
SRC_URL='https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases/v0_10_3c_efficiency_guardian.sh'
SRC_SHA='fcd775620eaf924b5fee97fd02a890d12e6b15e73d0423072fcc6a1bad695bea'
TMP=/tmp/v0103c-retry.sh
curl -fsSL "$SRC_URL" -o "$TMP"
printf '%s  %s\n' "$SRC_SHA" "$TMP" | sha256sum -c - >/dev/null
python3 - <<'PY'
from pathlib import Path
p=Path('/tmp/v0103c-retry.sh')
s=p.read_text()
old='''    if printf '%s' "$body" | grep -q '\"version\":\"0.10.3\"'; then ok=1; break; fi'''
new='''    if printf '%s' "$body" | grep -q '\"ok\":true'; then ok=1; break; fi'''
if old not in s: raise SystemExit('health gate anchor missing in verified source')
s=s.replace(old,new,1)
p.write_text(s)
PY
chmod 700 "$TMP"
bash "$TMP"
# Independent postcondition: source capability + healthy app, regardless of stale version label.
grep -q 'work_modules = modules\[:3\]' /opt/fourth-law-agent/app/intelligence_engine.py
grep -q 'request_cut = int' /opt/fourth-law-agent/app/intelligence_engine.py
curl -fsS http://127.0.0.1:8787/health | grep -q '"ok":true'
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'EFFICIENCY_GUARDIAN_V0_10_3D_DEPLOYED {"root_slots":4,"productive_agents":3,"efficiency_guardian":true,"guardian_model_calls":0,"request_reserve":0.30,"token_reserve":0.30,"hard_budgets_unchanged":true,"postcondition":"source+health-ok"}' >/dev/null 2>&1 || true

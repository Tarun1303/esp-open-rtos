#!/usr/bin/env bash
set -Eeuo pipefail
BRIDGE=/usr/local/lib/fourthlaw-bridge/bridge.py
[[ $EUID -eq 0 ]]
[[ -f "$BRIDGE" ]]
python3 - <<'PY'
from pathlib import Path
p=Path("/usr/local/lib/fourthlaw-bridge/bridge.py")
s=p.read_text()
anchor='    if typ=="mission":\n'
insert='    if typ=="api_check":\n        s,b=req("GET","/api-check");return cid,s==200,{"http":s,"body":b[:6000]}\n    if typ=="job_result":\n        jid=str(c.get("job_id",""));s,b=req("GET",f"/task/{jid}/result");return cid,s==200,{"http":s,"body":b[:20000]}\n    if typ=="job":\n        jid=str(c.get("job_id",""));s,b=req("GET",f"/task/{jid}");return cid,s==200,{"http":s,"body":b[:24000]}\n'
if 'if typ=="job_result":' not in s:
    if anchor not in s:
        raise SystemExit("bridge patch anchor missing")
    s=s.replace(anchor,insert+anchor,1)
s=s.replace('["health","state","mission","continue","decision","restart_agent","apply_release"]',
            '["health","state","api_check","job","job_result","mission","continue","decision","restart_agent","apply_release"]')
p.write_text(s)
PY
python3 -m py_compile "$BRIDGE"
systemctl restart fourthlaw-command-bridge.service
sleep 2
systemctl is-active --quiet fourthlaw-command-bridge.service
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh issue comment 7 --repo Tarun1303/factory --body 'BRIDGE_UPGRADED {"version":"1.2","features":["api_check","job","job_result"]}' >/dev/null 2>&1 || true
fi
echo FOURTHLAW_BRIDGE_V1_2_READY

#!/usr/bin/env bash
set -Eeuo pipefail

BRIDGE=/usr/local/lib/fourthlaw-bridge/bridge.py
SERVICE=fourthlaw-command-bridge.service
[[ $EUID -eq 0 ]]
[[ -f "$BRIDGE" ]]

cp "$BRIDGE" "$BRIDGE.bak-v0.7.2-pagination"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('/usr/local/lib/fourthlaw-bridge/bridge.py')
s = p.read_text()

replacement = '''def fetch_comments():
    # Always fetch the newest 100 comments, then process them oldest-to-newest.
    # This avoids the old first-page-only deadlock once an issue exceeds 100 comments.
    rows=json.loads(gh("api",f"repos/{REPO}/issues/{ISSUE}/comments?per_page=100&sort=created&direction=desc"))
    return sorted(rows,key=lambda r:int(r.get("id",0)))
'''

# Handle the original compact one-line function or any prior multiline version.
pattern = r'def fetch_comments\(\):(?:return[^\n]*|\n(?:[ \t]+[^\n]*\n)+)(?=def main\(\):)'
m = re.search(pattern, s)
if not m:
    # Fallback specifically for the known compact production function.
    old = 'def fetch_comments():return json.loads(gh("api",f"repos/{REPO}/issues/{ISSUE}/comments?per_page=100"))\n'
    if old not in s:
        raise SystemExit('fetch_comments anchor not found; refusing blind edit')
    s = s.replace(old, replacement, 1)
else:
    s = s[:m.start()] + replacement + s[m.end():]

# Keep bridge identity explicit after repair.
s = s.replace('"version":"1.1"', '"version":"1.4"')
s = s.replace("'version':'1.1'", "'version':'1.4'")

p.write_text(s)
PY

python3 -m py_compile "$BRIDGE"
systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE"

# Marker is informational; bridge itself will now pick up the commands that were stranded beyond comment #100.
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'BRIDGE_PAGINATION_FIXED {"strategy":"newest-100-sorted-ascending","version":"1.4"}' >/dev/null 2>&1 || true

echo BRIDGE_PAGINATION_FIXED

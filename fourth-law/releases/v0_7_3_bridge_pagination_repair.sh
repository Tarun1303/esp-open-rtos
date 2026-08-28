#!/usr/bin/env bash
set -Eeuo pipefail

BRIDGE=/usr/local/lib/fourthlaw-bridge/bridge.py
SERVICE=fourthlaw-command-bridge.service
[[ $EUID -eq 0 ]]
[[ -f "$BRIDGE" ]]

cp "$BRIDGE" "$BRIDGE.bak-v0.7.3-pagination"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('/usr/local/lib/fourthlaw-bridge/bridge.py')
s = p.read_text()

replacement = '''def fetch_comments():
    # Fetch all pages safely. GitHub's issue-specific comments endpoint is ordered
    # by ascending ID, so the bridge can resume from its stored last_comment_id.
    pages=json.loads(gh("api","--paginate","--slurp",f"repos/{REPO}/issues/{ISSUE}/comments?per_page=100"))
    rows=[]
    for page in pages:
        if isinstance(page,list): rows.extend(page)
    return rows
'''

pattern = r'def fetch_comments\(\):(?:return[^\n]*|\n(?:[ \t]+[^\n]*\n)+)(?=def main\(\):)'
m = re.search(pattern, s)
if not m:
    raise SystemExit('fetch_comments anchor not found; refusing blind edit')
s = s[:m.start()] + replacement + s[m.end():]
s = s.replace('"version":"1.1"', '"version":"1.4"')
s = s.replace("'version':'1.1'", "'version':'1.4'")
p.write_text(s)
PY

python3 -m py_compile "$BRIDGE"
systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE"

# Verify the exact gh pagination form locally before declaring success.
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api --paginate --slurp 'repos/Tarun1303/factory/issues/7/comments?per_page=100' >/tmp/fourthlaw-comments-pages.json
python3 - <<'PY'
import json
p='/tmp/fourthlaw-comments-pages.json'
pages=json.load(open(p))
assert isinstance(pages,list) and pages, 'no pages returned'
assert all(isinstance(x,list) for x in pages), 'unexpected pagination shape'
print('BRIDGE_PAGINATION_FIXED_V073')
PY
rm -f /tmp/fourthlaw-comments-pages.json

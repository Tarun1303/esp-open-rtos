#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
APP='/var/lib/fourthlaw-dev/projects/eight-neuron-connection'
ROOT="$APP/validation/v0.3-consolidation-reignition"
REPO='Tarun1303/esp-open-rtos'
BRANCH='fourth-law-bootstrap'
ISSUE_REPO='Tarun1303/factory'
ISSUE=7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LATEST="$(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2- || true)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$LATEST" "$TMP/status.json" <<'PY'
import json, os, pathlib, subprocess, sys, time
latest=pathlib.Path(sys.argv[1]) if sys.argv[1] else None
out=pathlib.Path(sys.argv[2])
def run(cmd):
    p=subprocess.run(cmd,shell=True,text=True,capture_output=True)
    return {'rc':p.returncode,'stdout':p.stdout[-12000:],'stderr':p.stderr[-4000:]}
status={
 'timestamp_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
 'latest_workspace':str(latest) if latest else None,
 'processes':run("pgrep -af 'codex|run_exact_closed_loop|run_v03_consolidation_reignition|final_v03' || true"),
 'release_units':run("systemctl list-units --all --no-pager 'fourthlaw-release-*' | tail -n 20 || true"),
 'live_service':run("systemctl show eight-neuron-connection.service -p ActiveState -p SubState -p MainPID -p ExecMainStatus || true"),
 'live_health':run("curl -fsS --max-time 5 http://127.0.0.1:8788/api/health || true"),
}
if latest and latest.exists():
    for name in ['bridge-report.txt','validation.log','codex-implement.log','codex-review.log','results.json','review.json','REPORT.md']:
        p=latest/name
        if p.exists():
            text=p.read_text(errors='replace')
            if name.endswith('.json'):
                try: status[name]=json.loads(text)
                except Exception: status[name]=text[-30000:]
            else:
                status[name]=text[-30000:]
    status['files']=[{'name':str(p.relative_to(latest)),'bytes':p.stat().st_size,'mtime':p.stat().st_mtime} for p in latest.rglob('*') if p.is_file()]
out.write_text(json.dumps(status,indent=2))
PY
DEST="fourth-law/results/v03-consolidation-reignition/status-${STAMP}.json"
B64="$(base64 -w0 "$TMP/status.json")"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api --method PUT "/repos/$REPO/contents/$DEST" -f message="Publish v0.3 consolidation/reignition status $STAMP" -f content="$B64" -f branch="$BRANCH" >/dev/null
{
 echo "## 8 Neuron Connection — v0.3 status snapshot"
 echo
 echo "Published: \`$DEST\`"
 echo
 echo '```text'
 python3 - "$TMP/status.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); print('timestamp='+s['timestamp_utc']); print('latest_workspace='+str(s.get('latest_workspace')))
for name in ('results.json','review.json'):
 v=s.get(name)
 if isinstance(v,dict):
  print(name+'='+json.dumps(v,separators=(',',':'))[:10000])
print('processes='+s['processes']['stdout'][-5000:])
print('live_service='+s['live_service']['stdout'].strip())
PY
 echo '```'
} > "$TMP/body.md"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$ISSUE_REPO" --body-file "$TMP/body.md" >/dev/null
cat "$TMP/status.json"

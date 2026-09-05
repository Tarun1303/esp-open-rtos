#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
APP='/var/lib/fourthlaw-dev/projects/eight-neuron-connection'
ROOT="$APP/validation/v0.3-consolidation-reignition"
REPO='Tarun1303/esp-open-rtos'
BRANCH='fourth-law-bootstrap'
DEST='fourth-law/results/v03-consolidation-reignition/latest-20260905.json'
ISSUE_REPO='Tarun1303/factory'
ISSUE=7
LATEST="$(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2- || true)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 - "$LATEST" "$TMP/status.json" <<'PY'
import json,pathlib,subprocess,sys,time
latest=pathlib.Path(sys.argv[1]) if sys.argv[1] else None
out=pathlib.Path(sys.argv[2])
def sh(c):
 p=subprocess.run(c,shell=True,text=True,capture_output=True); return {'rc':p.returncode,'stdout':p.stdout[-30000:],'stderr':p.stderr[-10000:]}
s={'timestamp_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'latest_workspace':str(latest) if latest else None,'processes':sh("pgrep -af 'codex|run_exact_closed_loop|run_v03_consolidation_reignition|final_v03' || true"),'live_service':sh("systemctl show eight-neuron-connection.service -p ActiveState -p SubState -p MainPID -p ExecMainStatus || true"),'live_health':sh("curl -fsS --max-time 5 http://127.0.0.1:8788/api/health || true")}
if latest and latest.exists():
 for name in ['bridge-report.txt','validation.log','codex-implement.log','codex-review.log','results.json','review.json','REPORT.md']:
  p=latest/name
  if p.exists():
   text=p.read_text(errors='replace')
   if name.endswith('.json'):
    try:s[name]=json.loads(text)
    except:s[name]=text[-50000:]
   else:s[name]=text[-50000:]
 s['files']=[{'name':str(p.relative_to(latest)),'bytes':p.stat().st_size,'mtime':p.stat().st_mtime} for p in latest.rglob('*') if p.is_file()]
out.write_text(json.dumps(s,indent=2))
PY
B64="$(base64 -w0 "$TMP/status.json")"
sha="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$REPO/contents/$DEST?ref=$BRANCH" --jq .sha 2>/dev/null || true)"
args=(--method PUT "/repos/$REPO/contents/$DEST" -f message='Update v0.3 consolidation/reignition status' -f content="$B64" -f branch="$BRANCH")
[[ -n "$sha" ]] && args+=(-f sha="$sha")
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "${args[@]}" >/dev/null
python3 - "$TMP/status.json" > "$TMP/summary.txt" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); print('timestamp='+s['timestamp_utc']); print('latest_workspace='+str(s.get('latest_workspace')))
r=s.get('results.json'); v=s.get('review.json')
if isinstance(r,dict):
 print('decision='+str(r.get('decision'))); print('gates='+json.dumps(r.get('gates',{}),separators=(',',':'))); print('two_pattern='+json.dumps(r.get('two_pattern',{}),separators=(',',':'))); print('four_pattern_strict='+json.dumps(r.get('four_pattern_strict',{}),separators=(',',':'))); print('four_pattern_rehearsal='+json.dumps(r.get('four_pattern_rehearsal',{}),separators=(',',':'))); print('reignition='+json.dumps(r.get('reignition',{}),separators=(',',':'))); print('drift='+json.dumps(r.get('drift',{}),separators=(',',':'))[:12000]); print('scale='+json.dumps(r.get('scale',{}),separators=(',',':'))[:12000])
else: print('decision=PENDING')
if isinstance(v,dict): print('review='+json.dumps(v,separators=(',',':'))[:6000])
print('processes='+s['processes']['stdout'][-8000:])
print('live_service='+s['live_service']['stdout'].strip())
PY
{
 echo '## 8 Neuron Connection — v0.3 fixed status snapshot'; echo; echo "Repository status path: \`$DEST\`"; echo; echo '```text'; cat "$TMP/summary.txt"; echo '```';
} > "$TMP/body.md"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$ISSUE_REPO" --body-file "$TMP/body.md" >/dev/null
cat "$TMP/summary.txt"

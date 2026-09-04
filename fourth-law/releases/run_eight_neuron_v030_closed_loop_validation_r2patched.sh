#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

APP=/var/lib/fourthlaw-dev/projects/eight-neuron-connection
CURRENT="$APP/current"
SHARED="$APP/shared"
WORK="$APP/validation/v0.3-closed-loop/$(date -u +%Y%m%dT%H%M%SZ)"
SERVICE=eight-neuron-connection.service
REPO=Tarun1303/esp-open-rtos
REF=fourth-law-bootstrap
DIR=fourth-law/releases/eight-neuron-v030-validation-r2
ISSUE_REPO=Tarun1303/factory
ISSUE=7
STAMP="$(basename "$WORK")"
TMP="$(mktemp -d)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
OUT="$SHARED/final_v03_closedloop-vps-$STAMP.json"
LOG="$WORK/validation.log"

cleanup(){ rm -rf "$TMP" "$REPORT" "$BODY"; }
post(){ { echo '## 8 Neuron Connection — v0.3 closed-loop validation'; echo; echo '```text'; cat "$REPORT"; echo '```'; } > "$BODY"; HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$ISSUE_REPO" --body-file "$BODY" >/dev/null 2>&1 || true; }
fail(){ rc=$?; echo "execution=FAILED exit=$rc" >> "$REPORT"; [[ -f "$LOG" ]] && { echo '--- log tail ---' >> "$REPORT"; tail -n 60 "$LOG" >> "$REPORT"; }; post; exit "$rc"; }
trap fail ERR
trap cleanup EXIT

for c in python3 systemctl curl gh base64 sha256sum tar timeout runuser; do command -v "$c" >/dev/null; done
SOURCE="$(readlink -f "$CURRENT")"
[[ -f "$SOURCE/engine.py" ]]
install -d -m 0750 -o fourthlaw-dev -g fourthlaw-dev "$SHARED" "$WORK"
PID0="$(systemctl show "$SERVICE" -p MainPID --value)"
SHA0="$(sha256sum "$SOURCE/engine.py"|awk '{print $1}')"
HEALTH0="$(curl -fsS http://127.0.0.1:8788/api/health)"
{
 echo EIGHT_NEURON_V030_VALIDATION_BEGIN
 echo "timestamp=$STAMP"
 echo "contract=continuous_state+pre_cue_baseline+post_cue_only+no_label_injection+no_fast_reset"
 echo "live_release_before=$SOURCE"
 echo "live_pid_before=$PID0"
 echo "live_engine_sha_before=$SHA0"
 echo "live_health_before=$HEALTH0"
} > "$REPORT"

chunk_hashes=(
  686f606965f7146d458c22556b45840e1508139fd587c0ca9c31e64a0135d543
  3a25c244b435edfafa76e05a6812b11cd8f4ae43eec93375065664a7714c3a22
  fb43730a3c71433abf899938fdc0e3ee7b3a6f437b6776edfdbcb1829e1781e3
)
: > "$TMP/bundle.b64"
for i in 0 1 2; do
 p="$(printf '%02d' "$i")"
 HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$REPO/contents/$DIR/v03val_chunk_${p}.txt?ref=$REF" --jq .content | tr -d '\n' | base64 -d > "$TMP/$p"
 [[ "$(sha256sum "$TMP/$p"|awk '{print $1}')" == "${chunk_hashes[$i]}" ]]
 cat "$TMP/$p" >> "$TMP/bundle.b64"
done
[[ "$(wc -c < "$TMP/bundle.b64"|tr -d ' ')" == 15008 ]]
[[ "$(sha256sum "$TMP/bundle.b64"|awk '{print $1}')" == ba8bc53e672be779de3eab151657f6f2535474a3ddc307ffca5f236fe4ac2876 ]]
base64 -d "$TMP/bundle.b64" > "$TMP/bundle.tgz"
[[ "$(sha256sum "$TMP/bundle.tgz"|awk '{print $1}')" == a9f15d193ce84676a672a8db04c11ee6f6a7e4b5ba311ceb85626513d1df4f85 ]]
tar -xzf "$TMP/bundle.tgz" -C "$WORK"
chown -R fourthlaw-dev:fourthlaw-dev "$WORK"
find "$WORK" -type d -exec chmod 0750 {} +
find "$WORK" -type f -exec chmod 0640 {} +
# Make the R2 measurement helper portable: defer candidate-matrix loading unless run directly.
python3 - "$WORK/continuous_contrast_matrix.py" <<'PY_PATCH'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old="""SOURCE='/mnt/data/_v020src/eight-neuron-connection-v0.2.0'
rows=json.load(open('/mnt/data/candidate_live_matrix.json'));NAMES={'b18_i18','b20_i18','b20_context','b22_i18'};C=[{'name':x['name'],'params':x['params'],'measure':x['measure']} for x in rows if x['name'] in NAMES]
"""
new="""SOURCE=os.environ.get('ENC_SOURCE','/mnt/data/_v020src/eight-neuron-connection-v0.2.0')
NAMES={'b18_i18','b20_i18','b20_context','b22_i18'}
C=[]
if __name__=='__main__':
 candidate_path=Path(os.environ.get('ENC_CANDIDATE_MATRIX','/mnt/data/candidate_live_matrix.json'))
 rows=json.loads(candidate_path.read_text())
 C=[{'name':x['name'],'params':x['params'],'measure':x['measure']} for x in rows if x['name'] in NAMES]
"""
if old not in s:
    raise SystemExit('portable patch target missing')
p.write_text(s.replace(old,new))
PY_PATCH
python3 -m py_compile "$WORK"/*.py
[[ "$(sha256sum "$WORK/v03_response_closed_loop.py"|awk '{print $1}')" == 830e2092bd5f725d6e177c11f68b4ce6bff15c2f9297df04f08ed92c97712380 ]]
[[ "$(sha256sum "$WORK/continuous_contrast_matrix.py"|awk '{print $1}')" == 34e5d7cda2f5e7286dab21b09494b54c4770a70a36b209f7dec656d449c4a60e ]]
[[ "$(sha256sum "$WORK/final_v03_closedloop_vps.py"|awk '{print $1}')" == 574896cef3f06b091ce93d2e4c12b40a298cd083055c94d379727cb47361d8c4 ]]

echo "bundle_sha256=a9f15d193ce84676a672a8db04c11ee6f6a7e4b5ba311ceb85626513d1df4f85" >> "$REPORT"
set +e
timeout -k 30s 2400s runuser -u fourthlaw-dev -- env PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=1 ENC_SOURCE="$SOURCE" ENC_OUTPUT="$OUT" python3 -u "$WORK/final_v03_closedloop_vps.py" > "$LOG" 2>&1
RC=$?
set -e
echo "experiment_exit=$RC" >> "$REPORT"
[[ "$RC" == 0 && -s "$OUT" ]]
chown fourthlaw-dev:fourthlaw-dev "$OUT" "$LOG"
cp "$OUT" "$SHARED/final_v03_closedloop-vps-latest.json"
chown fourthlaw-dev:fourthlaw-dev "$SHARED/final_v03_closedloop-vps-latest.json"

python3 - "$OUT" >> "$REPORT" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); L=x['lawset']; t=x['two_pattern']; s=x['four_pattern_strict']; r=x['four_pattern_rehearsal']; d=x['drift']['checkpoints'][-1]
print('--- results ---')
for k,v in [
 ('lawset_status',L['status']),('two_accuracy',t['association_accuracy']),('two_all_correct',t['all_correct_rate']),('two_unknown_rejection',t['unknown_rejection']),
 ('strict_four_accuracy',s['association_accuracy']),('strict_four_all_correct',s['all_correct_rate']),('strict_max_forgetting',s['max_forgetting']),
 ('rehearsal_four_accuracy',r['association_accuracy']),('rehearsal_four_all_correct',r['all_correct_rate']),('rehearsal_unknown_rejection',r['unknown_rejection']),
 ('drift_1500s_accuracy',d['accuracy']),('drift_1500s_top1',d['top1_accuracy']),('drift_1500s_unknown_rejection',d['unknown_rejection']),('drift_persistent',d['persistent_rate']),('drift_spike_rate_hz',d['mean_spike_rate']),('energy_residual_abs',d['max_energy_residual_abs'])]: print(f'{k}={v}')
for q in x['scale']['sizes']:
 n=q['neurons']; print(f'scale_{n}=accuracy:{q["accuracy"]},top1:{q["top1_accuracy"]},all:{q["all_correct_rate"]},unknown:{q["unknown_rejection"]},persistent:{q["persistent_rate"]}')
print('gates='+json.dumps(L['gates'],separators=(',',':')))
PY

PID1="$(systemctl show "$SERVICE" -p MainPID --value)"
SOURCE1="$(readlink -f "$CURRENT")"
SHA1="$(sha256sum "$SOURCE1/engine.py"|awk '{print $1}')"
HEALTH1="$(curl -fsS http://127.0.0.1:8788/api/health)"
{
 echo "result_json=$OUT"
 echo "result_sha256=$(sha256sum "$OUT"|awk '{print $1}')"
 echo "log=$LOG"
 echo "live_release_after=$SOURCE1"
 echo "live_pid_after=$PID1"
 echo "live_engine_sha_after=$SHA1"
 echo "live_health_after=$HEALTH1"
 echo "live_app_modified=NO"
 echo "live_service_restarted_by_validation=NO"
 echo "v03_deployed=NO"
 echo "packages_installed=NO"
 echo "execution=SUCCESS"
 echo EIGHT_NEURON_V030_VALIDATION_END
} >> "$REPORT"
post
cat "$REPORT"

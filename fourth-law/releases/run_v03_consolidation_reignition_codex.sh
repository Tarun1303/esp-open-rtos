#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

TITLE="8 Neuron Connection"
DEV_USER="fourthlaw-dev"
APP="/var/lib/fourthlaw-dev/projects/eight-neuron-connection"
CURRENT="$APP/current"
VALID_ROOT="$APP/validation/v0.3-consolidation-reignition"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$VALID_ROOT/$STAMP"
REPORT="$WORK/bridge-report.txt"
BODY="$WORK/issue-body.md"
RESULT="$WORK/results.json"
REVIEW="$WORK/review.json"
ISSUE_REPO="Tarun1303/factory"
ISSUE=7
LIVE_SERVICE="eight-neuron-connection.service"

mkdir -p "$WORK"
chmod 0755 "$WORK"
touch "$REPORT"
post_report(){
  {
    echo "## ${TITLE} — consolidation and natural re-ignition closed loop"
    echo
    echo '```text'
    cat "$REPORT"
    echo '```'
    if [[ -f "$WORK/REPORT.md" ]]; then
      echo
      sed -n '1,260p' "$WORK/REPORT.md"
    fi
  } > "$BODY"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$ISSUE_REPO" --body-file "$BODY" >/dev/null 2>&1 || true
}
fail(){
  rc=$?
  echo "execution=FAILED" >> "$REPORT"
  echo "exit_code=$rc" >> "$REPORT"
  [[ -f "$WORK/codex-implement.log" ]] && { echo '--- implement log tail ---' >> "$REPORT"; tail -n 50 "$WORK/codex-implement.log" >> "$REPORT"; }
  [[ -f "$WORK/validation.log" ]] && { echo '--- validation log tail ---' >> "$REPORT"; tail -n 80 "$WORK/validation.log" >> "$REPORT"; }
  post_report
  exit "$rc"
}
trap fail ERR

for c in python3 codex systemctl curl sha256sum find cp timeout runuser gh git; do command -v "$c" >/dev/null; done
SOURCE="$(readlink -f "$CURRENT")"
[[ -f "$SOURCE/engine.py" ]]
LIVE_PID_BEFORE="$(systemctl show "$LIVE_SERVICE" -p MainPID --value)"
LIVE_SHA_BEFORE="$(sha256sum "$SOURCE/engine.py" | awk '{print $1}')"
LIVE_HEALTH_BEFORE="$(curl -fsS --max-time 5 http://127.0.0.1:8788/api/health)"
PREV_HARNESS="$(find "$APP/validation/v0.3-closed-loop" -type f -name final_v03_closedloop_vps.py -printf '%T@ %h\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-)"
[[ -n "$PREV_HARNESS" && -d "$PREV_HARNESS" ]]

{
  echo EIGHT_NEURON_V03_CONSOLIDATION_REIGNITION_BEGIN
  echo "timestamp_utc=$STAMP"
  echo "live_release_before=$SOURCE"
  echo "live_pid_before=$LIVE_PID_BEFORE"
  echo "live_engine_sha_before=$LIVE_SHA_BEFORE"
  echo "previous_gate_harness=$PREV_HARNESS"
  echo "live_health_before=$LIVE_HEALTH_BEFORE"
  echo "contract=no_live_change+no_label_injection+no_force_fire+continuous_state+post_cue_only"
} > "$REPORT"

mkdir -p "$WORK/baseline" "$WORK/candidate" "$WORK/harness"
cp -a "$SOURCE/." "$WORK/baseline/"
cp -a "$SOURCE/." "$WORK/candidate/"
cp -a "$PREV_HARNESS/." "$WORK/harness/"
chown -R "$DEV_USER:$DEV_USER" "$WORK"
BASELINE_ENGINE_SHA="$(sha256sum "$WORK/baseline/engine.py" | awk '{print $1}')"
HARNESS_SHA_BEFORE="$(find "$WORK/harness" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"

cat > "$WORK/IMPLEMENTATION_PROMPT.md" <<'PROMPT'
You are implementing a research candidate, not a demo. Work only inside the supplied candidate and work directories. Do not touch the running service, current symlink, shared state, Caddy, or systemd.

Project: 8 Neuron Connection. Baseline source is in ./baseline and an editable copy is in ./candidate. The previous authoritative closed-loop validation harness is in ./harness. Read all source and the prior result/report files before editing.

Implement exactly two missing physical mechanisms in ./candidate/engine.py while preserving public APIs used by the harness and UI:

1. FAST-TO-SLOW LOCAL CONSOLIDATION
- Every directed path must expose a labile fast component and a durable slow structural component.
- Fast state rises only from local causal flux and decays on a short timescale.
- A local recurrence/metaplastic trace integrates repeated causal use.
- Slow state grows only when repeated causal use crosses a local consolidation condition; one accidental traversal must not create permanent memory.
- Slow state decays far more slowly.
- Effective conductance must be derived from geometry/base conductance plus fast and slow state; do not set a recognition weight from labels.
- Slow growth must consume finite local structural resource. The resource can replenish slowly from an explicitly finite environmental/material supply. Do not unconditionally renormalize all old paths every time a new one learns; that previously caused erasure.
- Keep conductance/path state bounded and auditable.

2. NATURAL ENERGY-DRIVEN RE-IGNITION
- No global silence detector, no `if silent: fire`, no forced spike, no pacemaker neuron, and no hidden periodic trigger.
- Every neuron follows the same local law.
- Continued finite environmental energy must accumulate locally.
- Allow a physically interpretable local barrier instability or thermal/shot-noise activation hazard whose probability rises as stored energy approaches the firing barrier.
- Any spike triggered this way must discharge only energy already stored at that neuron. Do not create energy.
- A quiet but powered network should re-ignite with high probability across random seeds.

NON-NEGOTIABLE EXPERIMENT CONTRACT
- Labels never enter or alter the physical engine.
- The decoder may see only measured temporal firing fingerprints, never the expression string or input identity.
- No fast-state reset before a query.
- Measure a pre-cue baseline and read only post-cue response after a guard interval.
- Background dynamics remain active during learning and recall.
- Unknown inputs must be rejectable.
- Do not tune on final evaluation seeds.

VALIDATION
Reuse the prior gate definitions and methodology from ./harness. Create ./run_exact_closed_loop.py that imports the candidate engine and runs:
A) parameter sensitivity on training seeds, then fixed held-out seeds;
B) two-pattern memory;
C) strict sequential four-pattern continual learning;
D) balanced four-pattern rehearsal;
E) drift at 0, 100, 500, 1500 and 5000 simulated seconds;
F) explicit quiet-start natural re-ignition on at least 40 held-out seeds;
G) unchanged-law scaling at 16, 32 and 64 neurons;
H) energy and material ledgers;
I) static anti-gaming audit.

Freeze gates:
- two-pattern thresholded accuracy >= 0.90
- two-pattern all-correct seed rate >= 0.70
- four-pattern rehearsal accuracy >= 0.90
- all-four-correct seed rate >= 0.70
- unknown rejection >= 0.90
- strict maximum forgetting <= 0.10
- 1500-second drift accuracy >= 0.85
- persistent activity >= 0.90
- natural re-ignition success >= 0.95, no forced spikes
- maximum absolute energy residual <= 1e-6

Output ./results.json and ./REPORT.md. `results.json` must include exact metrics, seeds, chosen physical constants, all gates, FROZEN or NOT_FROZEN, and scale results. Do not mark FROZEN unless every gate passes. Add unit tests for local consolidation, decay timescale separation, finite structural resource, no-energy-creation thermal activation, and re-ignition.

Run the unit tests and a short smoke validation yourself. Do not modify the authoritative harness files.
PROMPT
chown "$DEV_USER:$DEV_USER" "$WORK/IMPLEMENTATION_PROMPT.md"

# Use the authenticated Codex CLI in bounded workspace-write mode.
set +e
runuser -u "$DEV_USER" -- env HOME="$(getent passwd "$DEV_USER" | cut -d: -f6)" PYTHONUNBUFFERED=1 \
  timeout -k 30s 1500s codex exec --full-auto --sandbox workspace-write --skip-git-repo-check -C "$WORK" - \
  < "$WORK/IMPLEMENTATION_PROMPT.md" > "$WORK/codex-implement.log" 2>&1
CODEX_RC=$?
set -e
echo "codex_implementation_exit=$CODEX_RC" >> "$REPORT"
[[ "$CODEX_RC" -eq 0 ]]
[[ -s "$WORK/candidate/engine.py" ]]
[[ -s "$WORK/run_exact_closed_loop.py" ]]
python3 -m py_compile "$WORK/candidate/engine.py" "$WORK/run_exact_closed_loop.py"

# The authoritative copied harness must remain byte-identical.
HARNESS_SHA_AFTER="$(find "$WORK/harness" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
[[ "$HARNESS_SHA_AFTER" == "$HARNESS_SHA_BEFORE" ]]

echo "baseline_engine_sha=$BASELINE_ENGINE_SHA" >> "$REPORT"
echo "candidate_engine_sha=$(sha256sum "$WORK/candidate/engine.py" | awk '{print $1}')" >> "$REPORT"
echo "harness_sha_before=$HARNESS_SHA_BEFORE" >> "$REPORT"
echo "harness_sha_after=$HARNESS_SHA_AFTER" >> "$REPORT"

set +e
runuser -u "$DEV_USER" -- env PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=1 \
  timeout -k 45s 3000s python3 -u "$WORK/run_exact_closed_loop.py" \
  > "$WORK/validation.log" 2>&1
VALID_RC=$?
set -e
echo "validation_exit=$VALID_RC" >> "$REPORT"
[[ "$VALID_RC" -eq 0 ]]
[[ -s "$RESULT" && -s "$WORK/REPORT.md" ]]

# Independent deterministic schema and anti-gaming audit.
python3 - "$WORK" "$RESULT" >> "$REPORT" <<'PY'
import ast, json, pathlib, re, sys
work=pathlib.Path(sys.argv[1]); result=pathlib.Path(sys.argv[2])
r=json.loads(result.read_text())
required=['two_pattern','four_pattern_strict','four_pattern_rehearsal','drift','reignition','scale','gates','decision']
for k in required: assert k in r, k
assert r['decision'] in ('FROZEN','NOT_FROZEN')
assert isinstance(r['gates'],dict) and r['gates']
assert (r['decision']=='FROZEN') == all(bool(v) for v in r['gates'].values())
assert r['reignition'].get('forced_spikes',0)==0
assert r['reignition']['success_rate'] >= 0 and r['reignition']['success_rate'] <= 1
engine=(work/'candidate'/'engine.py').read_text()
tree=ast.parse(engine)
forbidden=[]
for node in ast.walk(tree):
    if isinstance(node,(ast.FunctionDef,ast.AsyncFunctionDef)) and node.name.lower() in {'force_fire','force_spike','ensure_activity','reignite_if_silent'}:
        forbidden.append(node.name)
    if isinstance(node,ast.Constant) and isinstance(node.value,str) and re.search(r'if\s+silent.*fire|force[-_ ]?spike',node.value,re.I):
        forbidden.append(str(node.value)[:80])
assert not forbidden, forbidden
# Labels must not be a physical engine argument/state.
for node in ast.walk(tree):
    if isinstance(node,(ast.FunctionDef,ast.AsyncFunctionDef)):
        args=[a.arg.lower() for a in node.args.args]
        if 'label' in args and any(x in node.name.lower() for x in ('step','fire','propagate','energy','conduct','plastic')):
            raise AssertionError((node.name,args))
print('schema_audit=PASS')
print('anti_gaming_audit=PASS')
print('decision='+r['decision'])
for k,v in r['gates'].items(): print(f'gate_{k}={"PASS" if v else "FAIL"}')
for section in ('two_pattern','four_pattern_strict','four_pattern_rehearsal','reignition'):
    print(section+'='+json.dumps(r[section],separators=(',',':'))[:1800])
print('scale='+json.dumps(r['scale'],separators=(',',':'))[:2400])
PY

# Independent Codex reviewer: inspect but do not edit candidate or results.
cat > "$WORK/REVIEW_PROMPT.md" <<'PROMPT'
Act as an adversarial scientific reviewer. Do not edit files. Inspect candidate/engine.py, run_exact_closed_loop.py, results.json, REPORT.md, validation.log and the unchanged harness. Check for: labels or expression identity leaking into physics/readout; forced re-ignition or global silence triggers; energy creation; training/evaluation seed overlap; thresholds selected from evaluation labels; skipped or weakened gates; result fabrication; harness modification; and claims unsupported by raw metrics. Re-run small spot checks. Write review.json with keys verdict (PASS/FAIL), findings, independent_checks, confidence. PASS only if the result is a genuine closed-loop test.
PROMPT
chown "$DEV_USER:$DEV_USER" "$WORK/REVIEW_PROMPT.md"
set +e
runuser -u "$DEV_USER" -- env HOME="$(getent passwd "$DEV_USER" | cut -d: -f6)" PYTHONUNBUFFERED=1 \
  timeout -k 30s 900s codex exec --full-auto --sandbox read-only --skip-git-repo-check -C "$WORK" - \
  < "$WORK/REVIEW_PROMPT.md" > "$WORK/codex-review.log" 2>&1
REVIEW_RC=$?
set -e
echo "codex_review_exit=$REVIEW_RC" >> "$REPORT"
[[ "$REVIEW_RC" -eq 0 && -s "$REVIEW" ]]
python3 - "$REVIEW" >> "$REPORT" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r.get('verdict') in ('PASS','FAIL'); print('review_verdict='+r['verdict']); print('review='+json.dumps(r,separators=(',',':'))[:2500])
PY

# Archive candidate and evidence, preserve on VPS, and optionally push to an isolated Git branch.
tar -C "$WORK" -czf "$WORK/v03-consolidation-reignition-evidence.tar.gz" candidate run_exact_closed_loop.py results.json REPORT.md review.json validation.log codex-implement.log codex-review.log
sha256sum "$WORK/v03-consolidation-reignition-evidence.tar.gz" > "$WORK/v03-consolidation-reignition-evidence.tar.gz.sha256"
chown -R "$DEV_USER:$DEV_USER" "$WORK"

LIVE_PID_AFTER="$(systemctl show "$LIVE_SERVICE" -p MainPID --value)"
LIVE_SOURCE_AFTER="$(readlink -f "$CURRENT")"
LIVE_SHA_AFTER="$(sha256sum "$LIVE_SOURCE_AFTER/engine.py" | awk '{print $1}')"
LIVE_HEALTH_AFTER="$(curl -fsS --max-time 5 http://127.0.0.1:8788/api/health)"
[[ "$LIVE_PID_AFTER" == "$LIVE_PID_BEFORE" ]]
[[ "$LIVE_SOURCE_AFTER" == "$SOURCE" ]]
[[ "$LIVE_SHA_AFTER" == "$LIVE_SHA_BEFORE" ]]

{
  echo "evidence_dir=$WORK"
  echo "evidence_archive=$WORK/v03-consolidation-reignition-evidence.tar.gz"
  echo "evidence_sha256=$(awk '{print $1}' "$WORK/v03-consolidation-reignition-evidence.tar.gz.sha256")"
  echo "live_release_after=$LIVE_SOURCE_AFTER"
  echo "live_pid_after=$LIVE_PID_AFTER"
  echo "live_engine_sha_after=$LIVE_SHA_AFTER"
  echo "live_health_after=$LIVE_HEALTH_AFTER"
  echo "live_modified=NO"
  echo "live_service_restarted=NO"
  echo "execution=SUCCESS"
  echo EIGHT_NEURON_V03_CONSOLIDATION_REIGNITION_END
} >> "$REPORT"
post_report
cat "$REPORT"

#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

OWNER="Tarun1303"
NAME="eight-neuron-connection"
REPO="${OWNER}/${NAME}"
DESCRIPTION="Physics-first recurrent temporal-memory laboratory with local energy accounting, consolidation, and natural re-ignition"
SOURCE_SHA256="2cbce61b3d6e127952fad788dafa5af02306d09dffc9c0a30a66acb916611727"
RESEARCH_BRANCH="research/v0.4-multipattern-scaling"
REPORT_REPO="Tarun1303/factory"
REPORT_ISSUE=7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$(mktemp -d)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
ISSUE_BODY="$(mktemp)"

cleanup(){ rm -rf "$TMP" "$REPORT" "$BODY" "$ISSUE_BODY"; }
trap cleanup EXIT

post_report(){
  {
    echo "## 8 Neuron Connection — dedicated repository bootstrap"
    echo
    echo '```text'
    cat "$REPORT"
    echo '```'
  } > "$BODY"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment "$REPORT_ISSUE" --repo "$REPORT_REPO" --body-file "$BODY" >/dev/null 2>&1 || true
}

fail(){
  rc=$?
  echo "bootstrap_result=FAILED" >> "$REPORT" 2>/dev/null || true
  echo "exit_code=$rc" >> "$REPORT" 2>/dev/null || true
  post_report
  exit "$rc"
}
trap fail ERR

for command in gh git base64 sha256sum tar python3; do command -v "$command" >/dev/null; done
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth status >/dev/null
LOGIN="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api user --jq .login)"
[[ "$LOGIN" == "$OWNER" ]]

{
  echo EIGHT_NEURON_DEDICATED_REPOSITORY_BOOTSTRAP_BEGIN
  echo "timestamp_utc=$STAMP"
  echo "authenticated_github_user=$LOGIN"
  echo "target_repository=$REPO"
  echo "visibility=private"
  echo "credentials_printed=NO"
} > "$REPORT"

cat > "$TMP/source.tar.gz.b64" <<'PAYLOAD'
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
PAYLOAD
base64 -d "$TMP/source.tar.gz.b64" > "$TMP/source.tar.gz"
ACTUAL_SOURCE_SHA="$(sha256sum "$TMP/source.tar.gz" | awk '{print $1}')"
echo "source_payload_sha256=$ACTUAL_SOURCE_SHA" >> "$REPORT"
[[ "$ACTUAL_SOURCE_SHA" == "$SOURCE_SHA256" ]]

mkdir -p "$TMP/work"
tar -xzf "$TMP/source.tar.gz" -C "$TMP/work"
for file in README.md MODEL.md engine.py app.py tests/test_engine.py validation/summary.json .github/workflows/test.yml; do
  [[ -s "$TMP/work/$file" ]]
done

# Validate the exact source before repository creation.
(
  cd "$TMP/work"
  python3 -m py_compile app.py engine.py tests/test_engine.py
  python3 -m unittest discover -s tests -v
  python3 - <<'PY'
import json
from pathlib import Path
s=json.loads(Path('validation/summary.json').read_text())
assert s['version']=='0.3.0'
assert s['lawset_status']=='FROZEN'
assert all(s['gates'].values())
print('validation_summary=PASS')
PY
) > "$TMP/prepush-tests.log" 2>&1
TESTS_RUN="$(grep -E '^Ran [0-9]+ tests' "$TMP/prepush-tests.log" | tail -n1 | awk '{print $2}')"
echo "prepush_tests=${TESTS_RUN:-unknown}" >> "$REPORT"
echo "prepush_result=PASS" >> "$REPORT"

if HOME=/root GH_CONFIG_DIR=/root/.config/gh gh repo view "$REPO" >/dev/null 2>&1; then
  # Refuse to overwrite an existing non-empty repository.
  DEFAULT_BRANCH="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // ""')"
  if [[ -n "$DEFAULT_BRANCH" ]]; then
    echo "repository_creation=REFUSED_EXISTING_NONEMPTY" >> "$REPORT"
    false
  fi
else
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh repo create "$REPO" --private --description "$DESCRIPTION" >/dev/null
  echo "repository_created=YES" >> "$REPORT"
fi

HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth setup-git >/dev/null
cd "$TMP/work"
git init -b main >/dev/null
git config user.name "Tarun1303"
git config user.email "tarunpurohit68@gmail.com"
git add -A
git commit -m "Establish validated v0.3.0 physics-first baseline" >/dev/null
git remote add origin "https://github.com/${REPO}.git"
git push -u origin main >/dev/null
MAIN_SHA="$(git rev-parse HEAD)"

git tag -a v0.3.0 -m "Frozen eight-neuron v0.3.0 law set"
git push origin v0.3.0 >/dev/null

git checkout -b "$RESEARCH_BRANCH" >/dev/null
cat > docs/V0.4_EXPERIMENT_PLAN.md <<'EOF'
# v0.4 experiment plan

The active research target is scale-normalized multi-pattern memory without weakening the frozen v0.3 physics contracts.

## Immediate experiments

1. Reproduce all v0.3 gates on held-out seeds.
2. Measure per-neuron and per-edge energy as network size grows.
3. Normalize environmental drive by network size and local degree.
4. Generate sparse spatial graphs with bounded degree.
5. Normalize sensory input density and energy.
6. Recalibrate readout from training-only distributions.
7. Test 8, 16, 32 and 64 neurons under one unchanged law set.
8. Preserve UNKNOWN rejection and natural re-ignition.

## Prohibited shortcuts

- no label injection into the physics;
- no decoder access to input identity;
- no global silence detector or forced spike;
- no tuning on final evaluation seeds;
- no energy or structural-resource creation.
EOF
git add docs/V0.4_EXPERIMENT_PLAN.md
git commit -m "Start v0.4 multi-pattern scaling research" >/dev/null
git push -u origin "$RESEARCH_BRANCH" >/dev/null
RESEARCH_SHA="$(git rev-parse HEAD)"

cat > "$ISSUE_BODY" <<'EOF'
## Objective

Extend the frozen eight-neuron v0.3.0 baseline toward scale-normalized multi-pattern memory at 16, 32 and 64 neurons.

## Acceptance gates

- Preserve all v0.3 eight-neuron regression gates.
- Four-pattern recognition at least 90% at 16 and 32 neurons.
- Unknown rejection at least 90% at 16 and 32 neurons.
- Four-pattern recognition at least 85% at 64 neurons.
- Natural re-ignition at least 95% across held-out seeds.
- Maximum absolute energy residual no greater than 1e-6.
- No label injection, forced spikes, global silence control, input-identity decoding, or evaluation-seed tuning.

## Working branch

`research/v0.4-multipattern-scaling`
EOF
ISSUE_URL="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue create --repo "$REPO" --title "v0.4: scale-normalized multi-pattern memory" --body-file "$ISSUE_BODY")"

# Publish the frozen baseline release with its validation evidence.
HOME=/root GH_CONFIG_DIR=/root/.config/gh \
  gh release create v0.3.0 \
  validation/summary.json \
  validation/closed_loop_evidence.json \
  --repo "$REPO" \
  --title "v0.3.0 — frozen eight-neuron law set" \
  --notes "Validated physics-first baseline with fast/slow consolidation, finite structural reserve, natural energy-driven re-ignition, emergent temporal pattern labels, UNKNOWN rejection, and a closed energy ledger. Scaling beyond eight neurons remains experimental." >/dev/null

# Verify repository state from the remote API.
REMOTE_PRIVATE="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh repo view "$REPO" --json isPrivate --jq .isPrivate)"
REMOTE_DEFAULT="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
REMOTE_MAIN="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$REPO/commits/main" --jq .sha)"
REMOTE_RESEARCH="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$REPO/commits/$RESEARCH_BRANCH" --jq .sha)"
[[ "$REMOTE_PRIVATE" == true ]]
[[ "$REMOTE_DEFAULT" == main ]]
[[ "$REMOTE_MAIN" == "$MAIN_SHA" ]]
[[ "$REMOTE_RESEARCH" == "$RESEARCH_SHA" ]]

{
  echo "repository_url=https://github.com/$REPO"
  echo "repository_private=$REMOTE_PRIVATE"
  echo "default_branch=$REMOTE_DEFAULT"
  echo "main_commit=$REMOTE_MAIN"
  echo "research_branch=$RESEARCH_BRANCH"
  echo "research_commit=$REMOTE_RESEARCH"
  echo "release_tag=v0.3.0"
  echo "work_issue=$ISSUE_URL"
  echo "source_files_pushed=YES"
  echo "validation_evidence_pushed=YES"
  echo "ci_workflow_pushed=YES"
  echo "password_requested=NO"
  echo "secrets_committed=NO"
  echo "bootstrap_result=SUCCESS"
  echo EIGHT_NEURON_DEDICATED_REPOSITORY_BOOTSTRAP_END
} >> "$REPORT"
post_report
cat "$REPORT"

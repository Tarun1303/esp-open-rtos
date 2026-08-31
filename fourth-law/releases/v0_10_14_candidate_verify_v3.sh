#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
REPO='/var/lib/fourthlaw-dev/agent-repos/supervisor'
RELEASE="$REPO/scripts/release_v0.10.14.sh"
MANIFEST="$REPO/docs/operations/INTEGRATION_MANIFEST_v0.10.14.sha256"
BUNDLE='/tmp/fourthlaw-v0.10.14-root-candidate.tar'
REPORT='/tmp/fl-v01014-candidate-verify.txt'
EXPECTED_RELEASE_SHA='fcc232419254773620113e43ef38c79191c6ee000cae8bdf5737ba7a0703e3e4'
EXPECTED_MANIFEST_SHA='d526c181a2b6b4deb8acbf9502a37b29e4277a8de05ef23c1487a44d82eb8635'
IMAGE='fourth-law-agent:v0.10.14-candidate-check'
TEMP_ROOT=''

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  if test -n "$TEMP_ROOT" && test -d "$TEMP_ROOT"; then
    rm -rf -- "$TEMP_ROOT"
  fi
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  {
    echo FOURTH_LAW_V0_10_14_CANDIDATE_VERIFY_FAILED
    echo "command=$failed_command"
    tail -160 "$REPORT" 2>/dev/null || true
    curl -fsS http://127.0.0.1:8787/health 2>/dev/null || true
  } | report_issue
  cleanup
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
trap cleanup EXIT

: >"$REPORT"
health="$(curl -fsS http://127.0.0.1:8787/health)"
printf '%s' "$health" | grep -q '"ok":true'
printf '%s' "$health" | grep -q '"version":"0.10.13"'
systemctl is-active --quiet fourthlaw-codex.service
test -d "$REPO/.git"
test -f "$RELEASE"
test -f "$MANIFEST"

printf '%s  %s\n' "$EXPECTED_RELEASE_SHA" "$RELEASE" | sha256sum -c - >>"$REPORT"
printf '%s  %s\n' "$EXPECTED_MANIFEST_SHA" "$MANIFEST" | sha256sum -c - >>"$REPORT"
bash -n "$RELEASE"

expected_paths="$(mktemp /tmp/fl-v01014-expected.XXXXXX)"
actual_paths="$(mktemp /tmp/fl-v01014-actual.XXXXXX)"
cat >"$expected_paths" <<'EOF'
app/codex_actions.py
app/codex_control.py
app/efficiency_memory.py
app/static/codex.html
docs/architecture/CONTROL_ROOM_V01014_CONTRACT.md
docs/operations/INTEGRATION_MANIFEST_v0.10.14.sha256
scripts/ROLLBACK_v0.10.14.md
scripts/release_v0.10.14.sh
tests/test_codex_actions.py
tests/test_codex_runtime_contract.py
tests/test_codex_workspace_ui.py
tests/test_efficiency_memory.py
tests/test_release_handoff.py
EOF

git -c safe.directory="$REPO" -C "$REPO" diff --name-only HEAD >"$actual_paths"
git -c safe.directory="$REPO" -C "$REPO" ls-files --others --exclude-standard >>"$actual_paths"
sort -u -o "$actual_paths" "$actual_paths"
diff -u "$expected_paths" "$actual_paths" >>"$REPORT"

if grep -E '(^|/)(\.env|\.ssh|\.aws|\.config|secrets?)(/|$)' "$actual_paths"; then
  echo forbidden_path_in_candidate >>"$REPORT"
  false
fi

(cd "$REPO" && sha256sum -c "$MANIFEST") >>"$REPORT" 2>&1
(cd "$REPO" && tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -cf "$BUNDLE" -T "$expected_paths")
root_bundle_sha="$(sha256sum "$BUNDLE" | cut -d' ' -f1)"
tar -tf "$BUNDLE" > /tmp/fl-v01014-bundle-paths.txt
if grep -E '(^/|(^|/)\.\.(/|$)|(^|/)(\.env|\.ssh|\.aws|secrets?)(/|$))' /tmp/fl-v01014-bundle-paths.txt; then
  echo unsafe_bundle_path >>"$REPORT"
  false
fi

python3 - "$REPO/app/codex_control.py" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
assert re.search(r'["\x27]personality["\x27]\s*:\s*["\x27]friendly["\x27]', text), 'friendly personality protocol missing'
PY
grep -q 'Last-Event-ID' "$REPO/app/codex_control.py"
grep -q 'prefers-reduced-motion' "$REPO/app/static/codex.html"
grep -q 'data-theme' "$REPO/app/static/codex.html"

TEMP_ROOT="$(mktemp -d /tmp/fl-v01014-candidate.XXXXXX)"
CANDIDATE="$TEMP_ROOT/project"
mkdir -p "$CANDIDATE"
cp -a "$PROJECT/." "$CANDIDATE/"
while IFS= read -r path; do
  (cd "$REPO" && cp -a --parents "$path" "$CANDIDATE")
done <"$expected_paths"

python3 -m py_compile \
  "$CANDIDATE/app/codex_control.py" \
  "$CANDIDATE/app/codex_actions.py" \
  "$CANDIDATE/app/efficiency_memory.py"

docker build -t "$IMAGE" "$CANDIDATE" >>"$REPORT" 2>&1
docker run --rm --network none \
  -v "$CANDIDATE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest \
    tests.test_codex_actions \
    tests.test_codex_runtime_contract \
    tests.test_codex_workspace_ui \
    tests.test_efficiency_memory \
    tests.test_release_handoff \
    tests.test_codex_control -v >>"$REPORT" 2>&1

docker run --rm --network none \
  -v "$CANDIDATE:/workspace:ro" -w /workspace "$IMAGE" \
  python -m unittest discover -s tests -v >>"$REPORT" 2>&1

rm -f "$expected_paths" "$actual_paths" /tmp/fl-v01014-bundle-paths.txt

{
  echo FOURTH_LAW_V0_10_14_CANDIDATE_VERIFIED
  echo source_repository=Tarun1303/fourth-law
  echo source_branch=agent/supervisor
  echo changed_paths=13
  echo "release_sha256=$EXPECTED_RELEASE_SHA"
  echo "manifest_sha256=$EXPECTED_MANIFEST_SHA"
  echo supervisor_sandbox_candidate_sha256=688af6496ee701e69da19159b9f9d08a609f77885291ca316471488393aea46e
  echo "root_candidate_sha256=$root_bundle_sha"
  echo dependency_complete_image_build=passed
  echo focused_container_tests=passed
  echo full_container_discovery=passed
  echo personality_protocol=friendly
  echo command_network=false
  echo secrets_in_candidate=false
  echo production_changed=false
  echo "health=$health"
  tail -80 "$REPORT"
} | report_issue

trap - ERR
echo FOURTH_LAW_V0_10_14_CANDIDATE_VERIFY_READY

#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
export HOME=/root GH_CONFIG_DIR=/root/.config/gh GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0
APP=/var/lib/fourthlaw-dev/projects/eight-neuron-connection
REPO=Tarun1303/eight-neuron-connection
BRANCH=repair/verified-source-20260905
EXPECTED=6b8a61cad15796e70936e20b673bc3ff1e7630325e398c4d6aeb2c923ff54d78
TMP=$(mktemp -d)
REPORT=$TMP/report.txt
SRC=''
finish(){
 rc=$?
 trap - EXIT
 printf '\nexit_code=%s\nlive_service_modified=NO\n' "$rc" >> "$REPORT"
 { printf '## GitHub source-import repair 2026-09-05\n\n```text\n'; cat "$REPORT"; printf '\n```\n'; } > "$TMP/body.md"
 gh issue comment 1 --repo "$REPO" --body-file "$TMP/body.md" >/dev/null 2>&1 || true
 gh issue comment 7 --repo Tarun1303/factory --body-file "$TMP/body.md" >/dev/null 2>&1 || true
 cat "$REPORT"
 rm -rf "$TMP"
 exit "$rc"
}
trap finish EXIT
printf 'operation=source-import\nrepository=%s\n' "$REPO" > "$REPORT"
[ "$(gh api "repos/$REPO" --jq .private)" = true ]
printf 'private_verified=true\n' >> "$REPORT"
while IFS= read -r -d '' file; do
 sha=$(sha256sum "$file" | cut -d' ' -f1)
 printf 'candidate_engine=%s sha256=%s\n' "$file" "$sha" >> "$REPORT"
 if [ "$sha" = "$EXPECTED" ]; then SRC=$(dirname "$file"); break; fi
done < <(find "$APP" -maxdepth 9 -type f -name engine.py -print0)
if [ -z "$SRC" ]; then printf 'result=EXACT_SOURCE_NOT_ON_VPS\n' >> "$REPORT"; exit 4; fi
printf 'source=%s\n' "$SRC" >> "$REPORT"
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' clone -q "https://github.com/$REPO.git" "$TMP/repo"
cd "$TMP/repo"
git switch -c "$BRANCH"
# Only copy an explicit source allowlist; never copy credentials, state or runtime logs.
for file in engine.py app.py MODEL.md README.md run.sh package.json static/index.html static/app.js static/styles.css tests/test_engine.py validation/summary.json validation/closed_loop_evidence.json; do
 [ -s "$SRC/$file" ] || { echo "missing=$file" >> "$REPORT"; exit 5; }
 mkdir -p "$(dirname "$file")"
 cp "$SRC/$file" "$file"
done
printf '__pycache__/\n*.py[cod]\n.venv/\nruntime/\nshared/\n.env\n.env.*\n*.pem\n*.key\nnode_modules/\n' > .gitignore
mkdir -p docs .github/workflows
cat > AGENTS.md <<'EOF'
# Development contract
Keep the display title 8 Neuron Connection. Labels are external metadata, never injected targets. Preserve continuous-state, post-cue-only measurement and UNKNOWN rejection. Do not change physical laws or acceptance gates to make tests pass. Unit tests are not proof of the entire scientific benchmark. Never modify the live VPS service as a consequence of a source commit. Use pull requests, commit-pinned artifacts and checksums. Never commit credentials or runtime state.
EOF
cat > .github/workflows/tests.yml <<'EOF'
name: Unit and source integrity tests
on: [push, pull_request, workflow_dispatch]
permissions:
  contents: read
jobs:
  tests:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - run: python -m compileall -q app.py engine.py tests
      - run: python -m unittest discover -s tests -v
      - run: node --check static/app.js
EOF
# The broken bootstrap remains in history; it must never overwrite working source.
git rm -q .github/workflows/bootstrap-source.yml
printf '# Source provenance\n\nImported from a VPS file matching the supplied v0.3.0 engine SHA-256: `%s`.\n\nEarlier benchmark JSON is historical evidence, not rerun by this import. No production deployment is performed.\n' "$EXPECTED" > docs/SOURCE_PROVENANCE.md
chmod 0755 "$TMP" "$TMP/repo"
chmod -R a+rX "$TMP/repo"
set +e
runuser -u fourthlaw-dev -- env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v > "$TMP/tests.log" 2>&1
rc=$?
set -e
tail -n 5 "$TMP/tests.log" >> "$REPORT"
[ "$rc" = 0 ]
git config user.name 'Neural Repository Setup'
git config user.email 'automation@users.noreply.github.com'
git add engine.py app.py MODEL.md README.md run.sh package.json static tests validation .gitignore AGENTS.md docs .github/workflows
git commit -q -m 'Recover checksum-verified v0.3 source and add CI; no live deployment'
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q origin "HEAD:refs/heads/$BRANCH"
printf 'result=SOURCE_PUSHED\nbranch=%s\ncommit=%s\n' "$BRANCH" "$(git rev-parse HEAD)" >> "$REPORT"

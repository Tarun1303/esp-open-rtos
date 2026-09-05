#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

REPO="Tarun1303/esp-open-rtos"
REF="fourth-law-bootstrap"
PAYLOAD="fourth-law/releases/eight-neuron-connection-v0.3.0-closed-loop/payload.tar.gz"
REPORT_REPO="Tarun1303/factory"
ISSUE=7
TMP="$(mktemp -d)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
cleanup(){ rm -rf "$TMP" "$REPORT" "$BODY"; }
trap cleanup EXIT

for c in gh base64 sha256sum tar python3 grep find; do command -v "$c" >/dev/null; done
HOME=/root GH_CONFIG_DIR=/root/.config/gh \
  gh api "/repos/$REPO/contents/$PAYLOAD?ref=$REF" --jq .content \
  | tr -d '\n' | base64 -d > "$TMP/payload.tar.gz"
{
  echo EIGHT_NEURON_V030_PAYLOAD_INSPECTION_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "payload_bytes=$(wc -c < "$TMP/payload.tar.gz" | tr -d ' ')"
  echo "payload_sha256=$(sha256sum "$TMP/payload.tar.gz" | awk '{print $1}')"
  echo '=== archive list ==='
  tar -tzf "$TMP/payload.tar.gz"
} > "$REPORT" 2>&1
mkdir -p "$TMP/unpacked"
tar -xzf "$TMP/payload.tar.gz" -C "$TMP/unpacked"
{
  echo '=== required files ==='
  for f in app.py engine.py tests/test_engine.py experiments/closed_loop_benchmark.py static/index.html static/app.js static/styles.css; do
    if [ -s "$TMP/unpacked/$f" ]; then echo "$f=OK bytes=$(wc -c < "$TMP/unpacked/$f" | tr -d ' ') sha256=$(sha256sum "$TMP/unpacked/$f" | awk '{print $1}')"; else echo "$f=MISSING"; fi
  done
  echo '=== version markers ==='
  grep -nE 'VERSION|fast|slow|consolid|reservoir|re.?ignit|closed.loop' "$TMP/unpacked/engine.py" | head -n 120 || true
  echo '=== unit tests ==='
} >> "$REPORT"
set +e
(cd "$TMP/unpacked" && python3 -m unittest discover -s tests -v) >> "$REPORT" 2>&1
UNIT_RC=$?
set -e
echo "unit_test_exit=$UNIT_RC" >> "$REPORT"
if [ "$UNIT_RC" -eq 0 ] && [ -s "$TMP/unpacked/experiments/closed_loop_benchmark.py" ]; then
  echo '=== benchmark smoke (4 seeds) ===' >> "$REPORT"
  set +e
  (cd "$TMP/unpacked" && python3 experiments/closed_loop_benchmark.py --seeds 4 --workers 2 --max-cycles 100) >> "$REPORT" 2>&1
  BENCH_RC=$?
  set -e
  echo "benchmark_smoke_exit=$BENCH_RC" >> "$REPORT"
else
  echo "benchmark_smoke_exit=SKIPPED" >> "$REPORT"
fi
echo EIGHT_NEURON_V030_PAYLOAD_INSPECTION_END >> "$REPORT"
{
  echo '## 8 Neuron Connection — v0.3 payload inspection'
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPORT_REPO" --body-file "$BODY" >/dev/null
cat "$REPORT"

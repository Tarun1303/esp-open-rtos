#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

TITLE="8 Neuron Connection"
UI_VERSION="0.1.2"
APP_ROOT="/var/lib/fourthlaw-dev/projects/eight-neuron-connection"
CURRENT="${APP_ROOT}/current"
STATIC="${CURRENT}/static"
SERVICE="eight-neuron-connection.service"
PORT=8788
DEV_USER="fourthlaw-dev"
DEV_GROUP="fourthlaw-dev"
SOURCE_REPO="Tarun1303/esp-open-rtos"
SOURCE_REF="fourth-law-bootstrap"
PAYLOAD_DIR="fourth-law/releases/eight-neuron-connection-v0.1.2-python-static/payload"
ARCHIVE_SHA256="eb770e5755a498b631d0fa0687e0c7741eba162d5972002dfdb8d31c8f970a83"
REPORT_REPO="Tarun1303/factory"
REPORT_ISSUE=7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$(mktemp -d)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
BACKUP_DIR="/var/lib/fourthlaw-dev/backups/eight-neuron-connection"
BACKUP="${BACKUP_DIR}/static-before-v012-${STAMP}.tar.gz"
COPIED=0

cleanup() {
  rm -rf "$TMP" "$REPORT" "$BODY"
}

post_report() {
  {
    echo "## ${TITLE} — learned-pattern UI deployment ${UI_VERSION}"
    echo
    echo '```text'
    cat "$REPORT"
    echo '```'
  } > "$BODY"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment "$REPORT_ISSUE" --repo "$REPORT_REPO" --body-file "$BODY" >/dev/null 2>&1 || true
}

rollback() {
  if [[ "$COPIED" -eq 1 && -f "$BACKUP" ]]; then
    rm -rf "$STATIC"
    mkdir -p "$STATIC"
    tar -xzf "$BACKUP" -C "$STATIC"
    chown -R "$DEV_USER:$DEV_GROUP" "$STATIC"
    find "$STATIC" -type d -exec chmod 0750 {} +
    find "$STATIC" -type f -exec chmod 0644 {} +
  fi
}

fail() {
  rc=$?
  echo "deployment_result=FAILED" >> "$REPORT" 2>/dev/null || true
  echo "exit_code=$rc" >> "$REPORT" 2>/dev/null || true
  rollback || true
  post_report
  exit "$rc"
}

trap fail ERR
trap cleanup EXIT

{
  echo EIGHT_NEURON_CONNECTION_PATTERN_UI_DEPLOY_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "title=$TITLE"
  echo "ui_version=$UI_VERSION"
  echo "host=$(hostname)"
  echo "execution_identity=$(id -un)"
  echo "service_before=$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  echo "current_release=$(readlink -f "$CURRENT" 2>/dev/null || true)"
} > "$REPORT"

for command in node python3 curl systemctl sha256sum base64 tar gh; do
  command -v "$command" >/dev/null
done
id "$DEV_USER" >/dev/null
[[ -L "$CURRENT" ]]
[[ -f "$CURRENT/app.py" ]]
[[ -f "$CURRENT/engine.py" ]]
[[ -d "$STATIC" ]]
systemctl is-active --quiet "$SERVICE"

EXPECTED_B64_SHA256="b296cf31052325ba4b4e1014ee87f221986bc9887c0af51adfd118b39cb0b219"
EXPECTED_B64_BYTES=16668

: > "$TMP/payload.b64"
for index in 0 1; do
  part="$(printf '%02d' "$index")"
  source_path="${PAYLOAD_DIR}/chunk_${part}.txt"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh api "/repos/${SOURCE_REPO}/contents/${source_path}?ref=${SOURCE_REF}" --jq .content \
    | tr -d '\n' | base64 -d > "$TMP/chunk_${part}.txt"
  cat "$TMP/chunk_${part}.txt" >> "$TMP/payload.b64"
done

actual_b64_bytes="$(wc -c < "$TMP/payload.b64" | tr -d ' ')"
actual_b64_sha="$(sha256sum "$TMP/payload.b64" | awk '{print $1}')"
echo "payload_b64_bytes=$actual_b64_bytes" >> "$REPORT"
echo "payload_b64_sha256=$actual_b64_sha" >> "$REPORT"
[[ "$actual_b64_bytes" = "$EXPECTED_B64_BYTES" ]]
[[ "$actual_b64_sha" = "$EXPECTED_B64_SHA256" ]]

base64 -d "$TMP/payload.b64" > "$TMP/static.tar.gz"
actual_archive="$(sha256sum "$TMP/static.tar.gz" | awk '{print $1}')"
echo "archive_sha256=$actual_archive" >> "$REPORT"
[[ "$actual_archive" = "$ARCHIVE_SHA256" ]]

mkdir -p "$TMP/unpacked"
tar -xzf "$TMP/static.tar.gz" -C "$TMP/unpacked"
for file in index.html app.js pattern.js styles.css; do
  [[ -s "$TMP/unpacked/$file" ]]
done

node --check "$TMP/unpacked/pattern.js"
node --check "$TMP/unpacked/app.js"

node - "$TMP/unpacked/pattern.js" <<'JS_TEST'
const patternPath = process.argv[2];
const P = require(patternPath);
const samples = [
  [3.0, 1.0, 0, 0, 2.0, 0, 0, 0],
  [2.8, 1.1, 0, 0, 2.1, 0, 0, 0],
  [3.1, 0.9, 0, 0, 1.9, 0, 0, 0],
];
const centre = P.centroid(samples);
const stable = P.stability(samples, centre);
if (!(stable > 0.99)) throw new Error(`stability=${stable}`);
const known = [{label: "2", vector: centre, stability: stable}];
const positive = P.classify([3.05, 1, 0, 0, 2, 0, 0, 0], known);
if (!positive.recognised || positive.label !== "2") throw new Error(JSON.stringify(positive));
const negative = P.classify([0, 0, 0, 3, 0, 0, 0, 2], known);
if (negative.recognised) throw new Error(`false-positive=${JSON.stringify(negative)}`);
console.log(`pattern_math=PASS stability=${stable.toFixed(6)} positive=${positive.score.toFixed(6)} negative=${negative.score.toFixed(6)}`);
JS_TEST

python3 - "$TMP/unpacked/index.html" "$TMP/unpacked/app.js" <<'PY_TEST'
import re
import sys
from pathlib import Path

html = Path(sys.argv[1]).read_text(encoding="utf-8")
js = Path(sys.argv[2]).read_text(encoding="utf-8")
ids = set(re.findall(r'id="([^"]+)"', html))
refs = set(re.findall(r'\$\("([^"]+)"\)', js))
missing = sorted(refs - ids)
assert not missing, missing
for marker in (
    "Start training",
    "Stop &amp; capture pattern",
    "Get output",
    "the network does not need a predefined binary code",
):
    assert marker in html, marker
assert 'response && response.result && response.result.readout' in js
print(f"dom_contract=PASS html_ids={len(ids)} js_refs={len(refs)}")
PY_TEST

install -d -m 0750 -o "$DEV_USER" -g "$DEV_GROUP" "$BACKUP_DIR"
tar -czf "$BACKUP" -C "$STATIC" .
chown "$DEV_USER:$DEV_GROUP" "$BACKUP"
echo "rollback_snapshot=$BACKUP" >> "$REPORT"

rm -rf "$TMP/new-static"
mkdir -p "$TMP/new-static"
cp "$TMP/unpacked/index.html" "$TMP/unpacked/app.js" "$TMP/unpacked/pattern.js" "$TMP/unpacked/styles.css" "$TMP/new-static/"
chown -R "$DEV_USER:$DEV_GROUP" "$TMP/new-static"
find "$TMP/new-static" -type d -exec chmod 0750 {} +
find "$TMP/new-static" -type f -exec chmod 0644 {} +

rm -rf "$STATIC.new"
mv "$TMP/new-static" "$STATIC.new"
chown -R "$DEV_USER:$DEV_GROUP" "$STATIC.new"
COPIED=1
mv "$STATIC" "$STATIC.old-v012-$STAMP"
mv "$STATIC.new" "$STATIC"

health="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/health")"
printf '%s' "$health" | grep -q '"ok":true'
printf '%s' "$health" | grep -q '"version":"0.1.1"'

state="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/state")"
printf '%s' "$state" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["nodes"]) == 8; assert len(d["edges"]) == 12; print("state_api=PASS nodes=8 edges=12")' >> "$REPORT"

probe="$(curl -fsS --max-time 15 -X POST "http://127.0.0.1:${PORT}/api/recall" \
  -H 'Content-Type: application/json' \
  --data '{"expression":"1+1","trials":1,"controlled":true}')"
printf '%s' "$probe" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d["result"]["readout"]; assert len(v)==8; assert all(isinstance(x,(int,float)) for x in v); print("recall_api=PASS readout_length=8")' >> "$REPORT"

html="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/")"
printf '%s' "$html" | grep -q 'Stop &amp; capture pattern'
printf '%s' "$html" | grep -q 'Get output'
printf '%s' "$html" | grep -q 'the network does not need a predefined binary code'
js_live="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/app.js?v=012")"
printf '%s' "$js_live" | grep -q 'collectSamples'
printf '%s' "$js_live" | grep -q 'Pattern.classify'
pattern_live="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/pattern.js?v=012")"
printf '%s' "$pattern_live" | grep -q 'function classify'

public_html="$(curl -kfsS --max-time 10 --resolve eight-neuron-94-136-189-216.sslip.io:443:127.0.0.1 \
  "https://eight-neuron-94-136-189-216.sslip.io/")"
printf '%s' "$public_html" | grep -q 'Stop &amp; capture pattern'
printf '%s' "$public_html" | grep -q 'Get output'

systemctl is-active --quiet "$SERVICE"
rm -rf "$STATIC.old-v012-$STAMP"
COPIED=0

{
  echo "service_after=$(systemctl is-active "$SERVICE")"
  echo "health=$health"
  echo "pattern_math_test=PASS"
  echo "dom_contract_test=PASS"
  echo "local_ui_check=PASS"
  echo "public_ui_check=PASS"
  echo "recall_readout_check=PASS"
  echo "physics_engine_changed=NO"
  echo "structural_memory_changed=NO"
  echo "service_restarted=NO"
  echo "fourth_law_stack_changed=NO"
  echo "public_url=https://eight-neuron-94-136-189-216.sslip.io/"
  echo "deployment_result=SUCCESS"
  echo EIGHT_NEURON_CONNECTION_PATTERN_UI_DEPLOY_END
} >> "$REPORT"

post_report
cat "$REPORT"

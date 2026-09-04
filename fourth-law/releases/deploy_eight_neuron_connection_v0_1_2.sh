#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

TITLE="8 Neuron Connection"
VERSION="0.1.2"
APP="/var/lib/fourthlaw-dev/projects/eight-neuron-connection"
SERVICE="eight-neuron-connection.service"
DEV_USER="fourthlaw-dev"
DEV_GROUP="fourthlaw-dev"
PORT=8788
SOURCE_REPO="Tarun1303/esp-open-rtos"
SOURCE_REF="fourth-law-bootstrap"
PAYLOAD_PATH="fourth-law/releases/eight-neuron-connection-v0.1.2.payload.b64"
PAYLOAD_TEXT_SHA256="6671f3264a25bfeb08f0a3e5dcfcfa913369637a75fb0fdff57f00e454be9aa3"
PAYLOAD_TAR_SHA256="44e268517164a74bf9ca36092f143f96b0c854e5db5e019ce019de4cc8b29f24"
REPORT_REPO="Tarun1303/factory"
REPORT_ISSUE=7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$(mktemp -d)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
BACKUP="/var/lib/fourthlaw-dev/backups/eight-neuron-connection/ui-v012-${STAMP}.tar.gz"
DEPLOYED=0

cleanup(){ rm -rf "$TMP" "$REPORT" "$BODY"; }
post_report(){
  {
    echo "## ${TITLE} — UI/signature deployment ${VERSION}"
    echo
    echo '```text'
    cat "$REPORT"
    echo '```'
  } > "$BODY"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$REPORT_ISSUE" --repo "$REPORT_REPO" --body-file "$BODY" >/dev/null 2>&1 || true
}
rollback(){
  if [ "$DEPLOYED" -eq 1 ] && [ -f "$BACKUP" ]; then
    systemctl stop "$SERVICE" 2>/dev/null || true
    rm -rf "$APP/public"
    rm -f "$APP/server.mjs" "$APP/package.json" "$APP/tests/signature.test.mjs"
    tar -xzf "$BACKUP" -C "$APP"
    chown -R "$DEV_USER:$DEV_GROUP" "$APP"
    systemctl restart "$SERVICE" 2>/dev/null || true
  fi
}
fail(){
  rc=$?
  echo "deployment_result=FAILED" >> "$REPORT" 2>/dev/null || true
  echo "exit_code=$rc" >> "$REPORT" 2>/dev/null || true
  rollback
  post_report
  exit "$rc"
}
trap fail ERR
trap cleanup EXIT

{
  echo EIGHT_NEURON_CONNECTION_V012_DEPLOY_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "title=$TITLE"
  echo "version=$VERSION"
  echo "host=$(hostname)"
  echo "execution_identity=$(id -un)"
  echo "existing_service=$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
} > "$REPORT"

for command in node npm curl systemctl sha256sum base64 tar gh; do command -v "$command" >/dev/null; done
id "$DEV_USER" >/dev/null
[ -d "$APP" ]
[ -f "$APP/src/model.mjs" ]
[ -f "$APP/tests/model.test.mjs" ]
install -d -m 0750 -o "$DEV_USER" -g "$DEV_GROUP" "$(dirname "$BACKUP")"

HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$SOURCE_REPO/contents/$PAYLOAD_PATH?ref=$SOURCE_REF" --jq .content \
  | tr -d '\n' | base64 -d > "$TMP/payload.b64"
TEXT_SHA="$(sha256sum "$TMP/payload.b64" | awk '{print $1}')"
echo "payload_text_sha256=$TEXT_SHA" >> "$REPORT"
[ "$TEXT_SHA" = "$PAYLOAD_TEXT_SHA256" ]
base64 -d "$TMP/payload.b64" > "$TMP/payload.tar.gz"
TAR_SHA="$(sha256sum "$TMP/payload.tar.gz" | awk '{print $1}')"
echo "payload_tar_sha256=$TAR_SHA" >> "$REPORT"
[ "$TAR_SHA" = "$PAYLOAD_TAR_SHA256" ]
mkdir -p "$TMP/unpacked"
tar -xzf "$TMP/payload.tar.gz" -C "$TMP/unpacked"

node --check "$TMP/unpacked/server.mjs"
node --check "$TMP/unpacked/public/app.js"
node --check "$TMP/unpacked/public/signature.js"
node --test "$TMP/unpacked/tests/signature.test.mjs" > "$TMP/signature-tests.log" 2>&1
SIG_PASS="$(awk '/# pass / {print $3}' "$TMP/signature-tests.log" | tail -n1)"
SIG_FAIL="$(awk '/# fail / {print $3}' "$TMP/signature-tests.log" | tail -n1)"
echo "standalone_signature_tests_passed=${SIG_PASS:-unknown}" >> "$REPORT"
echo "standalone_signature_tests_failed=${SIG_FAIL:-unknown}" >> "$REPORT"
[ "${SIG_FAIL:-1}" = 0 ]

tar -czf "$BACKUP" -C "$APP" package.json server.mjs public tests 2>/dev/null
chown "$DEV_USER:$DEV_GROUP" "$BACKUP"
echo "rollback_snapshot=$BACKUP" >> "$REPORT"
DEPLOYED=1

systemctl stop "$SERVICE"
rm -rf "$APP/public"
cp -a "$TMP/unpacked/public" "$APP/public"
cp "$TMP/unpacked/server.mjs" "$APP/server.mjs"
cp "$TMP/unpacked/package.json" "$APP/package.json"
cp "$TMP/unpacked/tests/signature.test.mjs" "$APP/tests/signature.test.mjs"
chown -R "$DEV_USER:$DEV_GROUP" "$APP/public" "$APP/server.mjs" "$APP/package.json" "$APP/tests/signature.test.mjs"
find "$APP/public" -type d -exec chmod 0750 {} +
find "$APP/public" -type f -exec chmod 0640 {} +
chmod 0640 "$APP/server.mjs" "$APP/package.json" "$APP/tests/signature.test.mjs"

FULL_TESTS="$(runuser -u "$DEV_USER" -- bash -lc "cd '$APP' && npm test" 2>&1)"
printf '%s\n' "$FULL_TESTS" > "$APP/logs/deploy-test-${VERSION}-${STAMP}.log"
chown "$DEV_USER:$DEV_GROUP" "$APP/logs/deploy-test-${VERSION}-${STAMP}.log"
TEST_PASS="$(printf '%s\n' "$FULL_TESTS" | awk '/# pass / {print $3}' | tail -n1)"
TEST_FAIL="$(printf '%s\n' "$FULL_TESTS" | awk '/# fail / {print $3}' | tail -n1)"
echo "complete_tests_passed=${TEST_PASS:-unknown}" >> "$REPORT"
echo "complete_tests_failed=${TEST_FAIL:-unknown}" >> "$REPORT"
[ "${TEST_FAIL:-1}" = 0 ]

systemctl start "$SERVICE"
HEALTH=""
for _ in $(seq 1 40); do
  HEALTH="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || true)"
  printf '%s' "$HEALTH" | grep -q '"version":"0.1.2"' && break
  sleep .25
done
printf '%s' "$HEALTH" | grep -q '"version":"0.1.2"'
HTML="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/")"
printf '%s' "$HTML" | grep -q 'Stop & capture pattern'
printf '%s' "$HTML" | grep -q 'Get output'
printf '%s' "$HTML" | grep -q 'No fixed binary answer is required'

SMOKE_LABEL="__deployment_smoke_${STAMP}"
SAVE_RESPONSE="$(curl -fsS --max-time 5 -X POST "http://127.0.0.1:${PORT}/api/signatures" -H 'content-type: application/json' --data "{\"label\":\"${SMOKE_LABEL}\",\"cue\":\"smoke\",\"vector\":[1,0,0,0,0,0,0,0],\"bits\":[1,0,0,0,0,0,0,0],\"stability\":1,\"samples\":1,\"trainingEpisodes\":0}")"
printf '%s' "$SAVE_RESPONSE" | grep -q "$SMOKE_LABEL"
LIST_RESPONSE="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/signatures")"
printf '%s' "$LIST_RESPONSE" | grep -q "$SMOKE_LABEL"
DELETE_RESPONSE="$(curl -fsS --max-time 5 -X POST "http://127.0.0.1:${PORT}/api/signatures/delete" -H 'content-type: application/json' --data "{\"label\":\"${SMOKE_LABEL}\"}")"
printf '%s' "$DELETE_RESPONSE" | grep -q '"ok":true'

SERVICE_STATE="$(systemctl is-active "$SERVICE")"
[ "$SERVICE_STATE" = active ]
echo "service_active=$SERVICE_STATE" >> "$REPORT"
echo "health=$HEALTH" >> "$REPORT"
echo "ui_flow_check=PASS" >> "$REPORT"
echo "signature_api_check=PASS" >> "$REPORT"
echo "public_url=https://eight-neuron-94-136-189-216.sslip.io/" >> "$REPORT"
echo "physics_engine_changed=NO" >> "$REPORT"
echo "checkpoint_preserved=YES" >> "$REPORT"
echo "reverse_proxy_modified=NO" >> "$REPORT"
echo "fourth_law_services_modified=NO" >> "$REPORT"
echo "deployment_result=SUCCESS" >> "$REPORT"
echo EIGHT_NEURON_CONNECTION_V012_DEPLOY_END >> "$REPORT"
post_report
cat "$REPORT"
DEPLOYED=0

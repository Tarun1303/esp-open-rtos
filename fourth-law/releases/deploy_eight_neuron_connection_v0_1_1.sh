#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

TITLE="8 Neuron Connection"
VERSION="0.1.1"
APP_SLUG="eight-neuron-connection"
DEV_USER="fourthlaw-dev"
PORT="8788"
APP_ROOT="/var/lib/fourthlaw-dev/projects/${APP_SLUG}"
RELEASE_ID="v0.1.1-1515a5c4facd"
RELEASE_DIR="${APP_ROOT}/releases/${RELEASE_ID}"
CURRENT_LINK="${APP_ROOT}/current"
SHARED_DIR="${APP_ROOT}/shared"
STATE_FILE="${SHARED_DIR}/state.json"
UNIT_NAME="eight-neuron-connection.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
ARCHIVE_SHA="1515a5c4facd01af56b5ac056a2f4febe85dc700df5d21c8507aef9176f83c37"
REPORT="$(mktemp)"
ARCHIVE="$(mktemp)"
STATE_BACKUP="$(mktemp)"
OLD_TARGET=""
STATE_EXISTED=0
DEPLOY_OK=0

cleanup() {
  local status=$?
  if [[ ${DEPLOY_OK} -ne 1 ]]; then
    echo "ROLLBACK_BEGIN status=${status}" | tee -a "${REPORT}" >&2 || true
    if [[ -n "${OLD_TARGET}" && -d "${OLD_TARGET}" ]]; then
      ln -sfn "${OLD_TARGET}" "${CURRENT_LINK}.rollback" || true
      mv -Tf "${CURRENT_LINK}.rollback" "${CURRENT_LINK}" || true
    fi
    if [[ ${STATE_EXISTED} -eq 1 ]]; then
      install -m 0640 -o "${DEV_USER}" -g "${DEV_USER}" "${STATE_BACKUP}" "${STATE_FILE}" || true
    else
      rm -f "${STATE_FILE}" || true
    fi
    if systemctl list-unit-files "${UNIT_NAME}" >/dev/null 2>&1; then
      systemctl restart "${UNIT_NAME}" >/dev/null 2>&1 || true
    fi
    echo "ROLLBACK_END" | tee -a "${REPORT}" >&2 || true
  fi
  rm -f "${ARCHIVE}" "${STATE_BACKUP}" "${B64_PAYLOAD:-}" /tmp/enc-health.json /tmp/enc-state.json /tmp/enc-pre.json /tmp/enc-post.json /tmp/enc-bg.json /tmp/enc-report.md
  exit "${status}"
}
trap cleanup EXIT

fail() { echo "DEPLOYMENT_FAILED: $*" | tee -a "${REPORT}" >&2; exit 1; }
api_get() { curl -fsS --max-time 8 "http://127.0.0.1:${PORT}$1"; }
api_post() { local path="$1" body="$2"; curl -fsS --max-time 15 -H 'Content-Type: application/json' -X POST -d "${body}" "http://127.0.0.1:${PORT}${path}"; }

[[ $(id -u) -eq 0 ]] || fail "release broker must run as root"
id "${DEV_USER}" >/dev/null 2>&1 || fail "development user ${DEV_USER} does not exist"
for cmd in python3 systemctl curl ss sha256sum tar base64 runuser gh; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is missing"
done
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth status >/dev/null 2>&1 || fail "root GitHub authentication is unavailable"

if [[ -L "${CURRENT_LINK}" ]]; then
  OLD_TARGET="$(readlink -f "${CURRENT_LINK}" || true)"
fi
install -d -m 0750 -o "${DEV_USER}" -g "${DEV_USER}" "${APP_ROOT}" "${APP_ROOT}/releases" "${SHARED_DIR}"
if [[ -f "${STATE_FILE}" ]]; then
  cp "${STATE_FILE}" "${STATE_BACKUP}"
  STATE_EXISTED=1
fi

if ss -ltnH "sport = :${PORT}" 2>/dev/null | grep -q .; then
  systemctl is-active --quiet "${UNIT_NAME}" || fail "TCP port ${PORT} is occupied by another service"
fi

B64_PAYLOAD="$(mktemp)"
: >"${B64_PAYLOAD}"
for chunk in chunk_00.txt chunk_01.txt chunk_02.txt chunk_03.txt chunk_04.txt chunk_05.txt chunk_06.txt chunk_07.txt chunk_08.txt; do
  encoded="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api \
    "repos/Tarun1303/esp-open-rtos/contents/fourth-law/releases/eight-neuron-connection-v0.1.1/payload/${chunk}?ref=fourth-law-bootstrap" \
    --jq .content)" || fail "could not fetch payload chunk ${chunk}"
  printf '%s' "${encoded}" | tr -d '\n' | base64 -d >>"${B64_PAYLOAD}" || fail "could not decode GitHub content for ${chunk}"
done
base64 -d "${B64_PAYLOAD}" >"${ARCHIVE}" || fail "could not decode release payload"
rm -f "${B64_PAYLOAD}"

ACTUAL_SHA="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
[[ "${ACTUAL_SHA}" == "${ARCHIVE_SHA}" ]] || fail "embedded payload checksum mismatch"

rm -rf "${RELEASE_DIR}"
install -d -m 0750 -o "${DEV_USER}" -g "${DEV_USER}" "${RELEASE_DIR}"
tar -xzf "${ARCHIVE}" -C "${RELEASE_DIR}"
chown -R "${DEV_USER}:${DEV_USER}" "${RELEASE_DIR}"
chmod 0750 "${RELEASE_DIR}/run.sh"
find "${RELEASE_DIR}" -type f -not -name run.sh -exec chmod 0640 {} +
find "${RELEASE_DIR}/static" -type f -exec chmod 0644 {} +

(
  cd "${RELEASE_DIR}"
  sha256sum -c SHA256SUMS
  runuser -u "${DEV_USER}" -- env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${RELEASE_DIR}"     python3 -m unittest discover -s tests -v
) >"${REPORT}" 2>&1 || { cat "${REPORT}" >&2; fail "source integrity or unit tests failed"; }

ln -sfn "${RELEASE_DIR}" "${CURRENT_LINK}.new"
mv -Tf "${CURRENT_LINK}.new" "${CURRENT_LINK}"
chown -h "${DEV_USER}:${DEV_USER}" "${CURRENT_LINK}"

cat >"${UNIT_FILE}" <<UNIT
[Unit]
Description=8 Neuron Connection physics-first simulator
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${DEV_USER}
Group=${DEV_USER}
WorkingDirectory=${CURRENT_LINK}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=STATE_FILE=${STATE_FILE}
ExecStart=/usr/bin/python3 ${CURRENT_LINK}/app.py --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=2
TimeoutStopSec=10
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${SHARED_DIR}
MemoryMax=512M
CPUQuota=100%

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "${UNIT_FILE}"
systemctl daemon-reload
systemctl enable --now "${UNIT_NAME}"
systemctl restart "${UNIT_NAME}"

healthy=0
for _ in $(seq 1 60); do
  if api_get /health >/tmp/enc-health.json 2>/dev/null; then healthy=1; break; fi
  sleep 0.25
done
[[ ${healthy} -eq 1 ]] || { journalctl -u "${UNIT_NAME}" -n 100 --no-pager >&2 || true; fail "service health check failed"; }

api_get /api/state >/tmp/enc-state.json
python3 - /tmp/enc-state.json <<'PY_CHECK_STATE'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
assert len(d['nodes']) == 8, len(d['nodes'])
assert len(d['edges']) == 12, len(d['edges'])
assert d['runtime']['running'] is True
assert d['runtime']['last_error'] is None
print('state_endpoint=PASS nodes=8 edges=12 runtime=running')
PY_CHECK_STATE

# Live end-to-end digital acceptance: untrained cue, train through HTTP, recall target.
api_post /api/reset/memory '{}' >/dev/null
api_post /api/runtime '{"speed":20,"background_rate":3}' >/dev/null
api_post /api/recall '{"expression":"1+1","trials":5,"controlled":true}' >/tmp/enc-pre.json
python3 - /tmp/enc-pre.json <<'PY_PRE'
import json,sys
d=json.load(open(sys.argv[1]))['result']
assert d['predicted'] != '2', d
print('pretraining_recall=PASS predicted=%r score2=%.6f' % (d['predicted'], d['scores']['2']))
PY_PRE

api_post /api/train/start '{"expression":"1+1","target":"2"}' >/dev/null
cycles=0
for _ in $(seq 1 240); do
  cycles="$(api_get /api/state | python3 -c 'import json,sys; print(json.load(sys.stdin)["runtime"]["training_cycles"])')"
  [[ "${cycles}" -ge 100 ]] && break
  sleep 0.25
done
api_post /api/train/stop '{}' >/dev/null
[[ "${cycles}" -ge 100 ]] || fail "live training did not reach 100 cycles (reached ${cycles})"

api_post /api/recall '{"expression":"1+1","trials":5,"controlled":true}' >/tmp/enc-post.json
python3 - /tmp/enc-post.json <<'PY_POST'
import json,sys
d=json.load(open(sys.argv[1]))['result']
votes=sum(x=='2' for x in d['trial_predictions'])
assert d['predicted']=='2', d
assert votes >= 4, d
assert d['scores']['2'] > d['scores']['1'], d
print('posttraining_recall=PASS predicted=2 votes=%d/5 score2=%.6f confidence=%.6f bits=%s' % (votes,d['scores']['2'],d['confidence'],''.join(map(str,d['bits']))))
PY_POST

# Verify continuing background-driven firing after teacher input is stopped.
api_post /api/reset/dynamic '{}' >/dev/null
sleep 2.5
api_get /api/state >/tmp/enc-bg.json
python3 - /tmp/enc-bg.json <<'PY_BG'
import json,sys
d=json.load(open(sys.argv[1]))
m=d['metrics']
assert m['spikes_in_window'] > 0, m
assert m['distinct_neurons_in_window'] >= 2, m
print('background_activity=PASS spikes=%d rate=%.3fHz distinct=%d entropy=%.6f persistent=%s' % (m['spikes_in_window'],m['spike_rate_hz'],m['distinct_neurons_in_window'],m['selection_entropy_bits'],m['persistent_activity']))
PY_BG
api_post /api/runtime '{"speed":10,"background_rate":3}' >/dev/null

SERVICE_STATE="$(systemctl is-active "${UNIT_NAME}")"
SERVICE_EXIT="$(systemctl show "${UNIT_NAME}" -p ExecMainStatus --value)"
PRE_SUMMARY="$(python3 -c 'import json; d=json.load(open("/tmp/enc-pre.json"))["result"]; print("predicted=%r score2=%.6f"%(d["predicted"],d["scores"]["2"]))')"
POST_SUMMARY="$(python3 -c 'import json; d=json.load(open("/tmp/enc-post.json"))["result"]; print("predicted=%s votes=%d/5 score2=%.6f confidence=%.6f bits=%s"%(d["predicted"],sum(x=="2" for x in d["trial_predictions"]),d["scores"]["2"],d["confidence"],"".join(map(str,d["bits"]))))')"
BG_SUMMARY="$(python3 -c 'import json; m=json.load(open("/tmp/enc-bg.json"))["metrics"]; print("spikes=%d rate=%.3fHz distinct=%d entropy=%.6f persistent=%s"%(m["spikes_in_window"],m["spike_rate_hz"],m["distinct_neurons_in_window"],m["selection_entropy_bits"],m["persistent_activity"]))')"

{
  echo "DEPLOYMENT_OK"
  echo "title=${TITLE}"
  echo "version=${VERSION}"
  echo "release=${RELEASE_ID}"
  echo "payload_sha256=${ARCHIVE_SHA}"
  echo "service=${UNIT_NAME} state=${SERVICE_STATE} exit=${SERVICE_EXIT}"
  echo "local_url=http://127.0.0.1:${PORT}/"
  echo "public_candidate_url=http://94.136.189.216:${PORT}/"
  echo "health=$(cat /tmp/enc-health.json)"
  echo "training_cycles=${cycles}"
  echo "pretraining=${PRE_SUMMARY}"
  echo "posttraining=${POST_SUMMARY}"
  echo "background=${BG_SUMMARY}"
  echo "workspace=${CURRENT_LINK}"
  echo "persistent_state=${STATE_FILE}"
  echo "production_fourth_law_modified=NO"
  echo "reverse_proxy_modified=NO"
  echo "firewall_modified=NO"
} | tee -a "${REPORT}"

DEPLOY_OK=1
if command -v gh >/dev/null 2>&1 && HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth status >/dev/null 2>&1; then
  {
    echo "## 8 Neuron Connection v${VERSION} deployed and digitally validated"
    echo
    echo '```text'
    cat "${REPORT}"
    echo '```'
  } >/tmp/enc-report.md
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file /tmp/enc-report.md >/dev/null 2>&1 || true
fi

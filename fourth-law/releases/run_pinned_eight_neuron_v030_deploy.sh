#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

REPO="Tarun1303/esp-open-rtos"
BLOB_SHA="17e1d0cdf1af4bea0ae4e244811bb3aebeba179c"
EXPECTED_NAME="deploy_eight_neuron_connection_v0_3_0_closed_loop.sh"
TMP="$(mktemp -d)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

for command in gh base64 sha256sum bash grep; do command -v "$command" >/dev/null; done
HOME=/root GH_CONFIG_DIR=/root/.config/gh \
  gh api "/repos/${REPO}/git/blobs/${BLOB_SHA}" --jq .content \
  | tr -d '\n' | base64 -d > "$TMP/$EXPECTED_NAME"

[ -s "$TMP/$EXPECTED_NAME" ]
grep -q 'VERSION="0.3.0"' "$TMP/$EXPECTED_NAME"
grep -q 'PAYLOAD_SHA256="6f6b780383f22cc5fea11ec136c1747edb6ea5290b1aeecabc71373b9202c331"' "$TMP/$EXPECTED_NAME"
printf 'PINNED_SCRIPT_BLOB=%s\n' "$BLOB_SHA"
printf 'PINNED_SCRIPT_SHA256=%s\n' "$(sha256sum "$TMP/$EXPECTED_NAME" | awk '{print $1}')"
exec /bin/bash "$TMP/$EXPECTED_NAME"

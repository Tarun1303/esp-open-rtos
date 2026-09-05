#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
REPO="Tarun1303/esp-open-rtos"
BLOB_SHA="f625d89863d3b0375432338875aa1c6ccaaebd81"
NAME="inspect_eight_neuron_v030_payload_robust.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME=/root GH_CONFIG_DIR=/root/.config/gh \
  gh api "/repos/${REPO}/git/blobs/${BLOB_SHA}" --jq .content \
  | tr -d '\n' | base64 -d > "$TMP/$NAME"
[ -s "$TMP/$NAME" ]
exec /bin/bash "$TMP/$NAME"

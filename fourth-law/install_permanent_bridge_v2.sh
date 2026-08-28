#!/usr/bin/env bash
set -Eeuo pipefail

REPO="Tarun1303/factory"
ISSUE="7"
BASE_PATH="repos/Tarun1303/esp-open-rtos/contents/fourth-law/install_permanent_bridge.sh?ref=fourth-law-bootstrap"
TMP="/tmp/fourthlaw-permanent-bridge.sh"

post() {
  gh issue comment "$ISSUE" --repo "$REPO" --body "$1" >/dev/null 2>&1 || true
}

on_err() {
  rc=$?
  post "BRIDGE_INSTALL_FAIL {\"rc\":$rc,\"line\":$1}"
  echo "BRIDGE_INSTALL_FAILED"
  exit "$rc"
}
trap 'on_err $LINENO' ERR

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi
command -v gh >/dev/null 2>&1 || { echo "GitHub CLI missing"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "GitHub CLI not authenticated"; exit 1; }

post "BRIDGE_INSTALL_STARTED"
gh api -H 'Accept: application/vnd.github.raw' "$BASE_PATH" > "$TMP"
chmod 700 "$TMP"
bash "$TMP"
systemctl is-active --quiet fourthlaw-command-bridge.service
post "BRIDGE_INSTALL_OK"
echo "FOURTHLAW_PERMANENT_BRIDGE_READY"

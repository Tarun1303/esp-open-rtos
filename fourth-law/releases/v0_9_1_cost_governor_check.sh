#!/usr/bin/env bash
set -Eeuo pipefail
BASE='https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases/v0_9_1_cost_governor.sh'
TMP=/tmp/v0_9_1_cost_governor.sh
curl -fsSL "$BASE" -o "$TMP"
sha256sum "$TMP" | awk '{print $1}'

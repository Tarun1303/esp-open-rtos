#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
REPO='Tarun1303/esp-open-rtos'
REF='fourth-law-bootstrap'
DIR='fourth-law/releases/eight-neuron-connection-v0.3.0-final/payload'
OUT_REPO='Tarun1303/factory'
ISSUE=7
TMP="$(mktemp -d)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
trap 'rm -rf "$TMP" "$REPORT" "$BODY"' EXIT
{
  echo EIGHT_NEURON_V030_FINAL_PAYLOAD_DIAG_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$REPO/contents/$DIR?ref=$REF" --jq '.[] | select(.name|startswith("chunk_")) | [.name,.size,.sha] | @tsv' | sort > "$TMP/list.tsv"
  cat "$TMP/list.tsv"
  : > "$TMP/payload.b64"
  while IFS=$'\t' read -r name size sha; do
    HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$REPO/contents/$DIR/$name?ref=$REF" --jq .content | tr -d '\n' | base64 -d >> "$TMP/payload.b64"
  done < "$TMP/list.tsv"
  echo "chunk_count=$(wc -l < "$TMP/list.tsv" | tr -d ' ')"
  echo "b64_bytes=$(wc -c < "$TMP/payload.b64" | tr -d ' ')"
  echo "b64_sha256=$(sha256sum "$TMP/payload.b64" | awk '{print $1}')"
  base64 -d "$TMP/payload.b64" > "$TMP/payload.tar.gz"
  echo "archive_bytes=$(wc -c < "$TMP/payload.tar.gz" | tr -d ' ')"
  echo "archive_sha256=$(sha256sum "$TMP/payload.tar.gz" | awk '{print $1}')"
  echo '=== archive listing ==='
  tar -tzf "$TMP/payload.tar.gz" | head -80
  mkdir "$TMP/x"; tar -xzf "$TMP/payload.tar.gz" -C "$TMP/x"
  root="$(find "$TMP/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
  echo "root=$root"
  echo '=== versions ==='
  grep -R -n -E 'VERSION|0\.3|consolid|re-ignition|reignition|fast_gate|slow_area' "$root"/engine.py "$root"/app.py "$root"/MODEL.md 2>/dev/null | head -80 || true
  echo '=== tests ==='
  (cd "$root" && python3 -m unittest discover -s tests -v) 2>&1 | tail -40
  echo EIGHT_NEURON_V030_FINAL_PAYLOAD_DIAG_END
} > "$REPORT" 2>&1
{
 echo '## 8 Neuron Connection — v0.3 final payload diagnostic'
 echo
 echo '```text'
 cat "$REPORT"
 echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$OUT_REPO" --body-file "$BODY" >/dev/null
cat "$REPORT"

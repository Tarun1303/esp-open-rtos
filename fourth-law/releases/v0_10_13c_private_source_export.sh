#!/usr/bin/env bash
set -Eeuo pipefail

DEV_USER=fourthlaw-dev
SOURCE=/var/lib/fourthlaw-dev/source
REPORT=/tmp/fl-v01013c-source-export.txt
STAGE="$(mktemp -d /tmp/fl-v01013c-export.XXXXXX)"
EXPECTED_HEAD=74358e413997255450b5dac69ce9a2308a2176c9

cleanup() {
  rm -rf -- "$STAGE"
}
trap cleanup EXIT

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

fail() {
  code="$1"
  failed_command="$2"
  trap - ERR
  {
    echo FOURTH_LAW_PRIVATE_SOURCE_EXPORT_FAILED
    echo "command=$failed_command"
    tail -100 "$REPORT"
  } | report_issue
  exit "$code"
}
trap 'fail "$?" "$BASH_COMMAND"' ERR
: >"$REPORT"

health="$(curl -fsS http://127.0.0.1:8787/health)"
echo "$health" | grep -q '"version":"0.10.12"'
test "$(runuser -u "$DEV_USER" -- git -C "$SOURCE" rev-parse HEAD)" = "$EXPECTED_HEAD"
test -z "$(runuser -u "$DEV_USER" -- git -C "$SOURCE" status --porcelain)"

tracked_env_count="$(runuser -u "$DEV_USER" -- git -C "$SOURCE" ls-files | awk '/(^|\/)\.env($|\.)/{n++} END{print n+0}')"
tracked_secret_name_count="$(runuser -u "$DEV_USER" -- git -C "$SOURCE" ls-files | awk 'BEGIN{IGNORECASE=1} /(^|\/)(credentials?|secrets?|id_[rd]sa|.*\.(pem|key|p12|pfx))$/{n++} END{print n+0}')"
test "$tracked_env_count" = 0
test "$tracked_secret_name_count" = 0

if runuser -u "$DEV_USER" -- git -C "$SOURCE" grep -I -E \
  '(sk-proj-[A-Za-z0-9_-]{32,}|github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{36,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY)' \
  >/dev/null 2>&1; then
  echo secret_value_pattern_detected=true >>"$REPORT"
  false
fi

archive="$STAGE/fourth-law-v0.10.12.tar.gz"
runuser -u "$DEV_USER" -- git -C "$SOURCE" archive --format=tar HEAD | gzip -9 >"$archive"
archive_size="$(stat -c '%s' "$archive")"
test "$archive_size" -gt 0
test "$archive_size" -le 3000000
archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"

mkdir -p "$STAGE/chunks"
base64 -w 0 "$archive" | split -b 48000 - "$STAGE/chunks/chunk-"
chunk_total="$(find "$STAGE/chunks" -type f | wc -l | tr -d ' ')"
test "$chunk_total" -gt 0
export_id="v01013c-${EXPECTED_HEAD:0:12}-$(date +%s)"

index=0
for chunk in "$STAGE"/chunks/chunk-*; do
  index=$((index + 1))
  body="$STAGE/body-$index.txt"
  {
    echo FOURTH_LAW_PRIVATE_SOURCE_EXPORT_CHUNK
    echo "export_id=$export_id"
    echo "source_head=$EXPECTED_HEAD"
    echo "archive_sha256=$archive_sha256"
    echo "chunk=$index/$chunk_total"
    echo encoding=base64+gzip+git-archive
    cat "$chunk"
  } >"$body"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file "$body" >>"$REPORT" 2>&1
done

{
  echo FOURTH_LAW_PRIVATE_SOURCE_EXPORT_READY
  echo "export_id=$export_id"
  echo "source_head=$EXPECTED_HEAD"
  echo "archive_sha256=$archive_sha256"
  echo "archive_size=$archive_size"
  echo "chunks=$chunk_total"
  echo "tracked_files=$(runuser -u "$DEV_USER" -- git -C "$SOURCE" ls-files | wc -l | tr -d ' ')"
  echo tracked_env_count=0
  echo tracked_secret_name_count=0
  echo destination=Tarun1303/fourth-law
} | report_issue

trap - ERR
echo FOURTH_LAW_PRIVATE_SOURCE_EXPORT_DISPATCHED

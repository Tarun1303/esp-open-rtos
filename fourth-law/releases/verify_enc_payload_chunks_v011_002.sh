#!/usr/bin/env bash
set -uo pipefail
umask 027
export HOME=/root
export GH_CONFIG_DIR=/root/.config/gh
OUT="$(mktemp)"
BODY="$(mktemp)"
B64="$(mktemp)"
ARCH="$(mktemp)"
cleanup(){ rm -f "$OUT" "$BODY" "$B64" "$ARCH" /tmp/enc-chunk-*; }
trap cleanup EXIT
expected=(
0c0c886f46ecddfb95863f08caf9695728e38ee6a63ea247daf18ff64d72b528
e5c9f48263f3b7b543d24fad9e63e33f6b6b6045bcbf8072af956f77e1b19f47
e845f511b8f73cfab80612a21c527d5d66ec723415c9c600b883081fd97c5f9f
f1acd0cb1ab2dcd3e4b0abf2daf54e8469c24d4179c65cf1eb3f4d1136081050
849121b78f263b23f5e2ed3d2c914f945ef980d2a8ee141bec023afc1fefb805
2222991127e9dc13bd5f02e6f01d5f0d65e4f82cc6696a7d0fff89be656da2a4
d4720f42c342a48e0e63d203b28e3c017e36264c41c0d48213282940217774eb
1fa62481f6c9359d1f54a1af4f35e4e884330a65d859592022a5dcc64cb36f39
3b6e968c175234258344819de34f8df3ee500dcb065ccdefdc2a0391dee4bd8e
)
{
 echo PAYLOAD_CHUNK_VERIFICATION_BEGIN
 echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
 : > "$B64"
 for n in $(seq 0 8); do
   printf -v i '%02d' "$n"
   path="repos/Tarun1303/esp-open-rtos/contents/fourth-law/releases/eight-neuron-connection-v0.1.1/payload/chunk_${i}.txt?ref=fourth-law-bootstrap"
   api="$(gh api "$path" --jq .content 2>&1)" || { echo "chunk_${i}=FETCH_FAILED $api"; continue; }
   f="/tmp/enc-chunk-${i}"
   printf '%s' "$api" | tr -d '\n' | base64 -d > "$f" 2>/dev/null || { echo "chunk_${i}=API_BASE64_DECODE_FAILED"; continue; }
   cat "$f" >> "$B64"
   idx=$((10#$i))
   size=$(wc -c < "$f" | tr -d ' ')
   sha=$(sha256sum "$f" | awk '{print $1}')
   status=MISMATCH
   [[ "$sha" == "${expected[$idx]}" ]] && status=OK
   echo "chunk_${i} size=${size} sha256=${sha} expected=${expected[$idx]} status=${status}"
 done
 echo "combined_base64_size=$(wc -c < "$B64" | tr -d ' ')"
 echo "combined_base64_sha256=$(sha256sum "$B64" | awk '{print $1}')"
 if base64 -d "$B64" > "$ARCH" 2>/dev/null; then
   echo "archive_size=$(wc -c < "$ARCH" | tr -d ' ')"
   echo "archive_sha256=$(sha256sum "$ARCH" | awk '{print $1}')"
   echo "expected_archive_sha256=1515a5c4facd01af56b5ac056a2f4febe85dc700df5d21c8507aef9176f83c37"
   echo 'archive_tar_test:'
   tar -tzf "$ARCH" >/dev/null 2>&1 && echo PASS || echo FAIL
 else
   echo archive_base64_decode=FAIL
 fi
 echo PAYLOAD_CHUNK_VERIFICATION_END
} > "$OUT"
cat "$OUT"
{
 echo '## 8 Neuron Connection v0.1.1 payload-chunk verification'
 echo
 echo '```text'
 cat "$OUT"
 echo '```'
} > "$BODY"
gh issue comment 7 --repo Tarun1303/factory --body-file "$BODY" >/dev/null 2>&1 || true
exit 0

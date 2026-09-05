#!/usr/bin/env bash
set -uo pipefail
umask 027

REPO="Tarun1303/esp-open-rtos"
REF="fourth-law-bootstrap"
PAYLOAD="fourth-law/releases/eight-neuron-connection-v0.3.0-closed-loop/payload.tar.gz"
REPORT_REPO="Tarun1303/factory"
ISSUE=7
TMP="$(mktemp -d)"
REPORT="$(mktemp)"
BODY="$(mktemp)"
cleanup(){ rm -rf "$TMP" "$REPORT" "$BODY"; }
trap cleanup EXIT

{
  echo EIGHT_NEURON_V030_PAYLOAD_ROBUST_INSPECTION_BEGIN
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo '=== fetch ==='
  set +e
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api "/repos/$REPO/contents/$PAYLOAD?ref=$REF" --jq .content \
    | tr -d '\n' | base64 -d > "$TMP/payload.bin"
  FETCH_RC=$?
  set -e
  echo "fetch_exit=$FETCH_RC"
  echo "payload_bytes=$(wc -c < "$TMP/payload.bin" 2>/dev/null | tr -d ' ')"
  echo "payload_sha256=$(sha256sum "$TMP/payload.bin" 2>/dev/null | awk '{print $1}')"
  echo "file_type=$(file -b "$TMP/payload.bin" 2>/dev/null || true)"
  echo -n 'first32_hex='; od -An -tx1 -N32 "$TMP/payload.bin" 2>/dev/null | tr -d ' \n'; echo

  echo '=== python archive inspection ==='
  mkdir -p "$TMP/unpacked"
  python3 - "$TMP/payload.bin" "$TMP/unpacked" <<'PY'
import gzip, hashlib, pathlib, sys, tarfile, traceback
source=pathlib.Path(sys.argv[1]); dest=pathlib.Path(sys.argv[2])
raw=source.read_bytes()
print('raw_len=',len(raw),sep='')
print('raw_sha=',hashlib.sha256(raw).hexdigest(),sep='')
print('gzip_magic=',raw[:2].hex(),sep='')
try:
    data=gzip.decompress(raw)
    print('gzip_ok=true')
    print('decompressed_len=',len(data),sep='')
    print('decompressed_first32=',data[:32].hex(),sep='')
except Exception as exc:
    print('gzip_ok=false')
    print('gzip_error=',type(exc).__name__,': ',exc,sep='')
try:
    with tarfile.open(source, mode='r:*') as tf:
        members=tf.getmembers()
        print('tar_ok=true')
        print('tar_members=',len(members),sep='')
        for member in members:
            print(f'MEMBER {member.name} {member.size}')
        tf.extractall(dest)
except Exception as exc:
    print('tar_ok=false')
    print('tar_error=',type(exc).__name__,': ',exc,sep='')
    traceback.print_exc()
PY
  ARCHIVE_RC=$?
  echo "archive_inspection_exit=$ARCHIVE_RC"

  echo '=== extracted tree ==='
  find "$TMP/unpacked" -maxdepth 4 -type f -printf '%P %s bytes\n' 2>/dev/null | sort || true
  echo '=== required files ==='
  REQUIRED=(app.py engine.py tests/test_engine.py experiments/closed_loop_benchmark.py static/index.html static/app.js static/styles.css)
  MISSING=0
  for f in "${REQUIRED[@]}"; do
    if [ -s "$TMP/unpacked/$f" ]; then
      echo "$f=OK sha256=$(sha256sum "$TMP/unpacked/$f" | awk '{print $1}')"
    else
      echo "$f=MISSING"
      MISSING=$((MISSING+1))
    fi
  done
  echo "required_missing=$MISSING"

  echo '=== engine markers ==='
  if [ -s "$TMP/unpacked/engine.py" ]; then
    grep -nEi 'VERSION|fast_area|slow_area|consolid|reservoir|re.?ignit|force.?fire|silence' "$TMP/unpacked/engine.py" | head -n 160 || true
  fi

  echo '=== unit tests ==='
  UNIT_RC=99
  if [ -s "$TMP/unpacked/tests/test_engine.py" ]; then
    set +e
    (cd "$TMP/unpacked" && python3 -m unittest discover -s tests -v)
    UNIT_RC=$?
    set -e
  fi
  echo "unit_test_exit=$UNIT_RC"

  echo '=== benchmark CLI/help ==='
  BENCH_HELP_RC=99
  if [ -s "$TMP/unpacked/experiments/closed_loop_benchmark.py" ]; then
    set +e
    (cd "$TMP/unpacked" && python3 experiments/closed_loop_benchmark.py --help)
    BENCH_HELP_RC=$?
    set -e
  fi
  echo "benchmark_help_exit=$BENCH_HELP_RC"

  echo '=== live service unchanged ==='
  echo "live_service=$(systemctl is-active eight-neuron-connection.service 2>/dev/null || true)"
  echo "live_current=$(readlink -f /var/lib/fourthlaw-dev/projects/eight-neuron-connection/current 2>/dev/null || true)"
  curl -fsS --max-time 5 http://127.0.0.1:8788/api/health 2>/dev/null || true
  echo
  echo EIGHT_NEURON_V030_PAYLOAD_ROBUST_INSPECTION_END
} > "$REPORT" 2>&1

{
  echo '## 8 Neuron Connection — robust v0.3 payload inspection'
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPORT_REPO" --body-file "$BODY" >/dev/null 2>&1 || true
cat "$REPORT"
exit 0

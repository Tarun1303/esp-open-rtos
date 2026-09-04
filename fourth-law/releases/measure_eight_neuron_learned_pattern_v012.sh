#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

REPO="Tarun1303/factory"
ISSUE=7
BASE="http://127.0.0.1:8788"
REPORT="$(mktemp)"
BODY="$(mktemp)"
trap 'rm -f "$REPORT" "$BODY"' EXIT

python3 - "$BASE" > "$REPORT" <<'PY'
import json
import math
import sys
import urllib.request
from datetime import datetime, timezone

BASE = sys.argv[1]

def get(path):
    with urllib.request.urlopen(BASE + path, timeout=10) as response:
        return json.load(response)

def post(path, payload):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        BASE + path,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)

def finite(vector):
    if not isinstance(vector, list) or len(vector) != 8:
        raise RuntimeError(f"invalid readout: {vector!r}")
    values = [max(0.0, float(value)) for value in vector]
    if not all(math.isfinite(value) for value in values):
        raise RuntimeError("non-finite readout")
    return values

def magnitude(vector):
    return math.sqrt(sum(value * value for value in vector))

def normalize(vector):
    vector = finite(vector)
    length = magnitude(vector)
    return [0.0] * 8 if length <= 1e-12 else [value / length for value in vector]

def cosine(left, right):
    a = normalize(left)
    b = normalize(right)
    return sum(x * y for x, y in zip(a, b))

def centroid(samples):
    normalized = [normalize(sample) for sample in samples]
    mean = [sum(sample[i] for sample in normalized) / len(normalized) for i in range(8)]
    return normalize(mean)

def stability(samples, centre):
    return sum(cosine(sample, centre) for sample in samples) / len(samples)

def collect(cue, count):
    samples = []
    retained = []
    for _ in range(count):
        response = post("/api/recall", {
            "expression": cue,
            "trials": 1,
            "controlled": True,
        })
        result = response["result"]
        samples.append(finite(result["readout"]))
        retained.append(bool(result.get("physical_memory_retained", False)))
    if not all(retained):
        raise RuntimeError(f"controlled recall did not preserve memory for cue {cue}")
    return samples

health = get("/health")
state = get("/api/state")
capture_samples = collect("1+1", 7)
signature = centroid(capture_samples)
captured_stability = stability(capture_samples, signature)
threshold = max(0.65, min(0.90, captured_stability - 0.12))

tests = {}
for cue in ("1+1", "2+1", "1+0", "0+0"):
    samples = collect(cue, 5)
    query = centroid(samples)
    score = cosine(query, signature)
    repeatability = stability(samples, query)
    tests[cue] = {
        "score_to_captured_signature": score,
        "query_repeatability": repeatability,
        "recognised_as_2": score >= threshold,
        "fingerprint": query,
    }

bits = [1 if value >= max(signature) * 0.55 else 0 for value in signature]
result = {
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    "health": health,
    "network": {
        "nodes": len(state.get("nodes", [])),
        "edges": len(state.get("edges", [])),
        "training_cycles": state.get("runtime", {}).get("training_cycles"),
        "training_active": state.get("runtime", {}).get("training_active"),
    },
    "measurement_contract": {
        "capture_cue": "1+1",
        "external_human_label": "2",
        "capture_samples": 7,
        "test_samples_per_cue": 5,
        "captured_stability": captured_stability,
        "acceptance_threshold": threshold,
        "captured_fingerprint": signature,
        "display_bits_only": bits,
        "fixed_binary_target_used_for_output": False,
    },
    "tests": tests,
    "same_cue_pass": tests["1+1"]["recognised_as_2"],
    "distractor_false_positives": [
        cue for cue in ("2+1", "1+0", "0+0")
        if tests[cue]["recognised_as_2"]
    ],
    "live_structural_memory_modified": False,
}
print("EIGHT_NEURON_LEARNED_PATTERN_MEASUREMENT_BEGIN")
print(json.dumps(result, indent=2, sort_keys=True))
print("EIGHT_NEURON_LEARNED_PATTERN_MEASUREMENT_END")
PY

{
  echo "## 8 Neuron Connection — learned-pattern measurement"
  echo
  echo '```json'
  cat "$REPORT"
  echo '```'
} > "$BODY"

HOME=/root GH_CONFIG_DIR=/root/.config/gh \
  gh issue comment "$ISSUE" --repo "$REPO" --body-file "$BODY" >/dev/null

cat "$REPORT"

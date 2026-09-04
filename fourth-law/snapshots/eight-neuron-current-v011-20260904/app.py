from __future__ import annotations

import argparse
import json
import mimetypes
import os
import signal
import threading
import time
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from engine import NetworkRuntime, PhysicsNetwork

ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
RUNTIME_DIR = ROOT / "runtime"
STATE_FILE = Path(os.environ.get("STATE_FILE", str(RUNTIME_DIR / "state.json"))).expanduser().resolve()
STATE_FILE.parent.mkdir(parents=True, exist_ok=True)


def load_runtime() -> tuple[NetworkRuntime, bool]:
    network = PhysicsNetwork(seed=7, background_rate=3.0)
    runtime = NetworkRuntime(network)
    resume_training = False
    if not STATE_FILE.is_file():
        return runtime, resume_training
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        areas = data.get("areas", [])
        if len(areas) == len(network.directed_edges):
            for edge, area in zip(network.directed_edges, areas):
                edge.area = max(network.area_min, min(float(area), network.area_max))
            network._normalise_outgoing_material()
        network.background_rate = max(0.0, min(float(data.get("background_rate", 3.0)), 12.0))
        runtime.speed = max(0.25, min(float(data.get("speed", 10.0)), 50.0))
        runtime.training_cycles = max(0, int(data.get("training_cycles", 0)))
        runtime.expression = str(data.get("expression", "1+1"))
        runtime.target = str(data.get("target", "2"))
        resume_training = bool(data.get("training", False))
    except Exception as exc:
        print(f"State load ignored: {type(exc).__name__}: {exc}", flush=True)
    return runtime, resume_training


RUNTIME, RESUME_TRAINING = load_runtime()


def persist_state() -> None:
    with RUNTIME.network.lock:
        value = {
            "version": 1,
            "saved_at_unix": time.time(),
            "areas": [edge.area for edge in RUNTIME.network.directed_edges],
            "background_rate": RUNTIME.network.background_rate,
            "speed": RUNTIME.speed,
            "training_cycles": RUNTIME.training_cycles,
            "expression": RUNTIME.expression,
            "target": RUNTIME.target,
            "training": RUNTIME.training,
        }
    temporary = STATE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
    os.replace(temporary, STATE_FILE)


def persistence_loop(stop_event: threading.Event) -> None:
    while not stop_event.wait(5.0):
        try:
            persist_state()
        except Exception as exc:
            print(f"State save failed: {type(exc).__name__}: {exc}", flush=True)


def body_json(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", "0"))
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    return json.loads(raw.decode("utf-8"))


class Handler(BaseHTTPRequestHandler):
    server_version = "EightNeuronConnection/0.1"

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.client_address[0]} - {fmt % args}", flush=True)

    def send_json(self, value: Any, status: int = 200) -> None:
        payload = json.dumps(value, separators=(",", ":"), allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def send_file(self, path: Path) -> None:
        try:
            path = path.resolve(strict=True)
        except FileNotFoundError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        if not path.is_file() or STATIC.resolve() not in path.parents:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        payload = path.read_bytes()
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/health":
            self.send_json({"ok": True, "title": PhysicsNetwork.TITLE, "version": "0.1.1"})
            return
        if parsed.path == "/api/state":
            self.send_json(RUNTIME.snapshot())
            return
        if parsed.path == "/api/model":
            self.send_json({
                "title": PhysicsNetwork.TITLE,
                "claim": "local energy-driven associative conditioning",
                "warning": "1+1→2 demonstrates learned association, not arithmetic generalisation",
                "equations": {
                    "resistance": "R_ij = rho L_ij / A_ij",
                    "conductance": "G_ij = A_ij / (rho L_ij)",
                    "energy_split": "Q_ij = Q_i G*_ij / sum_k G*_ik",
                    "arrival": "Q_arrival = exp(-kappa L/A) Q_sent",
                },
            })
            return
        if parsed.path in ("/", "/index.html"):
            self.send_file(STATIC / "index.html")
            return
        requested = STATIC / parsed.path.lstrip("/")
        self.send_file(requested)

    def do_POST(self) -> None:
        try:
            data = body_json(self)
            path = urllib.parse.urlparse(self.path).path
            if path == "/api/train/start":
                expression = str(data.get("expression", "1+1")).strip()
                target = str(data.get("target", "2")).strip()
                RUNTIME.start_training(expression, target)
                persist_state()
                self.send_json({"ok": True, "training": True, "expression": expression, "target": target})
                return
            if path == "/api/train/stop":
                RUNTIME.stop_training()
                persist_state()
                self.send_json({"ok": True, "training": False, "cycles": RUNTIME.training_cycles})
                return
            if path == "/api/recall":
                expression = str(data.get("expression", "1+1")).strip()
                trials = int(data.get("trials", 5))
                controlled = bool(data.get("controlled", True))
                RUNTIME._validate_expression(expression)
                result = RUNTIME.network.recall_probe(expression, trials, controlled=controlled)
                self.send_json({"ok": True, "result": result})
                return
            if path == "/api/inject":
                bits = data.get("bits")
                RUNTIME.network.inject_bits(bits)
                self.send_json({"ok": True, "bits": bits})
                return
            if path == "/api/reset/dynamic":
                RUNTIME.network.clear_dynamic_state()
                self.send_json({"ok": True, "reset": "dynamic"})
                return
            if path == "/api/reset/memory":
                RUNTIME.stop_training()
                RUNTIME.network.reset_memory()
                RUNTIME.training_cycles = 0
                persist_state()
                self.send_json({"ok": True, "reset": "memory"})
                return
            if path == "/api/runtime":
                if "speed" in data:
                    RUNTIME.speed = max(0.25, min(float(data["speed"]), 50.0))
                if "background_rate" in data:
                    RUNTIME.network.background_rate = max(0.0, min(float(data["background_rate"]), 12.0))
                persist_state()
                self.send_json({"ok": True, "speed": RUNTIME.speed, "background_rate": RUNTIME.network.background_rate})
                return
            self.send_error(HTTPStatus.NOT_FOUND)
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            self.send_json({"ok": False, "error": str(exc)}, status=400)
        except Exception as exc:  # pragma: no cover - HTTP safety path
            self.send_json({"ok": False, "error": f"{type(exc).__name__}: {exc}"}, status=500)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.environ.get("HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8788")))
    args = parser.parse_args()

    # Bind first.  A failed bind must not leave a background simulation thread.
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    RUNTIME.start()
    if RESUME_TRAINING:
        try:
            RUNTIME.start_training(RUNTIME.expression, RUNTIME.target)
        except ValueError as exc:
            print(f"Saved training state not resumed: {exc}", flush=True)

    stop_event = threading.Event()
    saver = threading.Thread(target=persistence_loop, args=(stop_event,), name="state-persistence", daemon=True)
    saver.start()

    def shutdown(*_: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    print(f"{PhysicsNetwork.TITLE} listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        stop_event.set()
        RUNTIME.stop()
        persist_state()
        server.server_close()


if __name__ == "__main__":
    main()

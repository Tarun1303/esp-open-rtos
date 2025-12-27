"""MQTT energy meter simulator.

This script publishes synthetic yet sensible three‑phase energy data to an MQTT
broker on multiple intervals. It is useful for testing dashboards and data
pipelines that expect an energy meter publishing JSON payloads.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, List

import paho.mqtt.client as mqtt


def clamp(value: float, low: float, high: float) -> float:
    """Clamp *value* to the inclusive range [low, high]."""

    return max(low, min(high, value))


@dataclass
class PhaseValues:
    voltage_v: float
    current_a: float
    power_kw: float
    power_factor: float


@dataclass
class EnergySnapshot:
    timestamp: str
    interval_seconds: int
    interval_label: str
    frequency_hz: float
    phases: Dict[str, PhaseValues]
    total_kw: float
    total_kvar: float
    total_pf: float
    total_energy_kwh: float
    average_demand_kw: float

    def to_payload(self) -> Dict[str, object]:
        """Convert the snapshot to a JSON‑serialisable payload."""

        return {
            "timestamp": self.timestamp,
            "interval_seconds": self.interval_seconds,
            "interval_label": self.interval_label,
            "frequency_hz": round(self.frequency_hz, 3),
            "power_factor": round(self.total_pf, 3),
            "average_demand_kw": round(self.average_demand_kw, 1),
            "totals": {
                "active_power_kw": round(self.total_kw, 2),
                "reactive_power_kvar": round(self.total_kvar, 2),
                "energy_kwh": round(self.total_energy_kwh, 3),
            },
            "phases": {
                phase: {
                    "voltage_v": round(values.voltage_v, 1),
                    "current_a": round(values.current_a, 1),
                    "active_power_kw": round(values.power_kw, 2),
                    "power_factor": round(values.power_factor, 3),
                }
                for phase, values in self.phases.items()
            },
        }


@dataclass
class EnergyMeterSimulator:
    host: str
    port: int
    topic: str
    username: str | None = None
    password: str | None = None
    base_kw: float = 1500.0
    base_pf: float = 0.94
    running: bool = field(default=False, init=False)
    energy_kwh: float = field(default=0.0, init=False)
    demand_kw: float = field(default=0.0, init=False)

    def __post_init__(self) -> None:
        self.client = mqtt.Client()
        if self.username:
            self.client.username_pw_set(self.username, password=self.password)

    def connect(self) -> None:
        """Connect to the MQTT broker and start the network loop."""

        self.client.connect(self.host, self.port)
        self.client.loop_start()

    def start(self) -> None:
        """Start publishing data on all configured intervals."""

        self.running = True
        threads: List[threading.Thread] = []
        interval_labels = {
            1: "realtime",
            60: "1min",
            300: "5min",
            900: "15min",
        }

        for seconds, label in interval_labels.items():
            thread = threading.Thread(
                target=self._publish_loop,
                args=(seconds, label),
                daemon=True,
            )
            thread.start()
            threads.append(thread)

        try:
            while self.running:
                time.sleep(0.5)
        except KeyboardInterrupt:
            self.running = False
        finally:
            self.client.loop_stop()

    def _publish_loop(self, interval_seconds: int, label: str) -> None:
        while self.running:
            snapshot = self._generate_snapshot(interval_seconds, label)
            payload = json.dumps(snapshot.to_payload())
            self.client.publish(self.topic, payload)
            time.sleep(interval_seconds)

    def _generate_snapshot(self, interval_seconds: int, label: str) -> EnergySnapshot:
        timestamp = datetime.now(timezone.utc).isoformat()
        frequency_hz = random.gauss(50.0, 0.05)

        total_kw = random.gauss(self.base_kw, self.base_kw * 0.05)
        total_kw = clamp(total_kw, self.base_kw * 0.85, self.base_kw * 1.05)

        total_pf = clamp(random.gauss(self.base_pf, 0.01), 0.85, 0.99)
        total_kva = total_kw / total_pf
        line_voltage = 415.0
        total_current = total_kva * 1000 / (math.sqrt(3) * line_voltage)

        weights = [random.uniform(0.95, 1.05) for _ in range(3)]
        total_weight = sum(weights)
        normalized = [w / total_weight for w in weights]

        phase_names = ["A", "B", "C"]
        phases: Dict[str, PhaseValues] = {}
        kvar_sign = -1.0 if random.random() > 0.5 else 1.0
        for name, weight in zip(phase_names, normalized):
            power_kw = total_kw * weight
            pf = clamp(random.gauss(total_pf, 0.01), 0.82, 0.99)
            kva = power_kw / pf
            current_a = kva * 1000 / (math.sqrt(3) * line_voltage)
            voltage_v = random.gauss(line_voltage, 2.0)
            phases[name] = PhaseValues(
                voltage_v=voltage_v,
                current_a=current_a,
                power_kw=power_kw,
                power_factor=pf,
            )

        total_kvar = math.sqrt(max(total_kva**2 - total_kw**2, 0.0)) * kvar_sign
        self._accumulate_energy(total_kw, interval_seconds)
        self._update_demand(total_kw, interval_seconds)

        return EnergySnapshot(
            timestamp=timestamp,
            interval_seconds=interval_seconds,
            interval_label=label,
            frequency_hz=frequency_hz,
            phases=phases,
            total_kw=total_kw,
            total_kvar=total_kvar,
            total_pf=total_pf,
            total_energy_kwh=self.energy_kwh,
            average_demand_kw=self.demand_kw,
        )

    def _accumulate_energy(self, kw: float, interval_seconds: int) -> None:
        """Accumulate delivered energy in kWh based on the interval."""

        self.energy_kwh += kw * interval_seconds / 3600.0

    def _update_demand(self, kw: float, interval_seconds: int) -> None:
        """Smooth average demand using exponential decay over ~15 minutes."""

        decay_constant = math.exp(-interval_seconds / 900.0)
        self.demand_kw = self.demand_kw * decay_constant + kw * (1 - decay_constant)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="localhost", help="MQTT broker host")
    parser.add_argument("--port", type=int, default=1883, help="MQTT broker port")
    parser.add_argument(
        "--topic",
        default="Limelightit/adr/device1/energydata",
        help="MQTT topic to publish to",
    )
    parser.add_argument("--username", help="MQTT username", default=None)
    parser.add_argument("--password", help="MQTT password", default=None)
    parser.add_argument(
        "--base-kw",
        type=float,
        default=1500.0,
        help="Approximate contracted demand to model",
    )
    parser.add_argument(
        "--base-pf",
        type=float,
        default=0.94,
        help="Nominal power factor to model",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    simulator = EnergyMeterSimulator(
        host=args.host,
        port=args.port,
        topic=args.topic,
        username=args.username,
        password=args.password,
        base_kw=args.base_kw,
        base_pf=args.base_pf,
    )
    simulator.connect()
    simulator.start()


if __name__ == "__main__":
    main()

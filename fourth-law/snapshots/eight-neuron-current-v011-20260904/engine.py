from __future__ import annotations

import copy
import heapq
import math
import random
import threading
import time
from collections import Counter, deque
from dataclasses import dataclass
from typing import Any, Iterable


@dataclass
class DirectedEdge:
    source: int
    target: int
    physical_edge: int
    length: float
    area: float
    availability: float = 1.0
    eligibility: float = 0.0
    flow_trace: float = 0.0
    last_flow: float = 0.0


class PhysicsNetwork:
    """Eight-node, energy-conserving recurrent excitable network.

    All values are dimensionless laboratory units.  The equations, not the
    visualisation, are authoritative.  The model contains no gradient descent,
    global route planner, or task-level reward signal.
    """

    TITLE = "8 Neuron Connection"

    POSITIONS = (
        (0.08, 0.25),
        (0.08, 0.75),
        (0.33, 0.18),
        (0.33, 0.82),
        (0.68, 0.25),
        (0.68, 0.75),
        (0.92, 0.18),
        (0.92, 0.82),
    )

    # Degree sequence: 4, 4, 3, 3, 2, 2, 3, 3.
    PHYSICAL_EDGES = (
        (0, 2), (0, 4), (0, 6), (0, 7),
        (1, 3), (1, 5), (1, 6), (1, 7),
        (2, 4), (2, 6),
        (3, 5), (3, 7),
    )

    # The first experiment deliberately uses separated sparse sensory codes.
    # Additional codes are available for later experiments, but only 1,+,2 are
    # part of the deterministic acceptance test in v0.1.
    SYMBOL_CODES = {
        "1": (1, 1, 0, 0, 0, 0, 0, 0),
        "+": (0, 0, 1, 1, 0, 0, 0, 0),
        "2": (0, 0, 0, 0, 1, 1, 0, 0),
        "0": (0, 0, 0, 0, 0, 0, 1, 1),
        "3": (1, 0, 1, 0, 0, 0, 0, 0),
        "4": (1, 0, 0, 1, 0, 0, 0, 0),
        "5": (1, 0, 0, 0, 1, 0, 0, 0),
        "6": (0, 1, 1, 0, 0, 0, 0, 0),
        "7": (0, 1, 0, 1, 0, 0, 0, 0),
        "8": (0, 1, 0, 0, 1, 0, 0, 0),
        "9": (0, 0, 1, 0, 0, 1, 0, 0),
    }

    def __init__(self, seed: int = 7, *, background_rate: float = 3.0) -> None:
        self.lock = threading.RLock()
        self.seed = seed
        self.rng = random.Random(seed)
        self.n = 8
        self.dt = 0.005
        self.sim_time = 0.0

        # Physical/material constants in normalized units.
        self.resistivity = 1.0
        self.area_baseline = 1.0
        self.area_min = 0.15
        self.area_max = 3.20
        self.energy_leak = 0.55
        self.background_rate = background_rate
        self.background_quantum = 0.14
        self.background_power = 0.028
        self.external_quantum = 1.20
        self.reset_energy = 0.05
        self.max_discharge = 1.40
        self.heat_per_spike = 0.22
        self.heat_decay_time = 0.55
        self.heat_threshold_gain = 0.55
        self.minimum_discharge_time = 0.05
        self.signal_velocity = 2.20
        self.loss_coefficient = 0.16
        self.availability_recovery_time = 0.35
        self.availability_depletion = 0.45
        self.eligibility_decay_time = 1.00
        self.flow_decay_time = 0.80
        self.flux_growth = 0.00030
        self.causal_growth = 0.20
        self.material_relaxation = 0.00020
        self.readout_decay_time = 0.28

        self.energy = [self.rng.random() * 0.15 for _ in range(self.n)]
        self.heat = [0.0] * self.n
        self.base_threshold = [1.0 + self.rng.uniform(-0.025, 0.025) for _ in range(self.n)]
        self.last_spike = [-1e9] * self.n
        self.readout = [0.0] * self.n
        self.is_spiking = [False] * self.n

        self.directed_edges: list[DirectedEdge] = []
        self.outgoing: list[list[int]] = [[] for _ in range(self.n)]
        self.incoming: list[list[int]] = [[] for _ in range(self.n)]
        self.reverse_edge: dict[int, int] = {}
        self.physical_to_directed: list[tuple[int, int]] = []
        for pidx, (a, b) in enumerate(self.PHYSICAL_EDGES):
            length = math.dist(self.POSITIONS[a], self.POSITIONS[b])
            ab = len(self.directed_edges)
            self.directed_edges.append(DirectedEdge(a, b, pidx, length, 1.0 + self.rng.uniform(-0.03, 0.03)))
            ba = len(self.directed_edges)
            self.directed_edges.append(DirectedEdge(b, a, pidx, length, 1.0 + self.rng.uniform(-0.03, 0.03)))
            self.reverse_edge[ab] = ba
            self.reverse_edge[ba] = ab
            self.physical_to_directed.append((ab, ba))
            self.outgoing[a].append(ab)
            self.incoming[b].append(ab)
            self.outgoing[b].append(ba)
            self.incoming[a].append(ba)

        self.material_budget = [len(self.outgoing[i]) * self.area_baseline for i in range(self.n)]
        self._normalise_outgoing_material()

        self.arrivals: list[tuple[float, int, float]] = []
        self.spike_history: deque[tuple[float, int]] = deque(maxlen=20_000)
        self.pulse_history: deque[dict[str, float | int]] = deque(maxlen=2_000)
        self.total_external_energy = 0.0
        self.total_background_energy = 0.0
        self.total_dissipated_energy = 0.0
        self.total_delivered_energy = 0.0
        self.learning_enabled = True
        self.last_output: dict[str, Any] = {
            "predicted": None,
            "confidence": 0.0,
            "bits": [0] * self.n,
            "scores": {},
            "measured_at": 0.0,
        }

    # ---------- Physical relationships ----------

    def resistance(self, edge: DirectedEdge) -> float:
        return self.resistivity * edge.length / max(edge.area, 1e-12)

    def conductance(self, edge: DirectedEdge) -> float:
        return 1.0 / self.resistance(edge)

    def effective_conductance(self, edge: DirectedEdge) -> float:
        return self.conductance(edge) * edge.availability

    def threshold(self, i: int) -> float:
        return self.base_threshold[i] * (1.0 + self.heat_threshold_gain * self.heat[i])

    # ---------- External environment ----------

    def inject_symbol(self, symbol: str, gain: float | None = None) -> None:
        if symbol not in self.SYMBOL_CODES:
            raise ValueError(f"Unsupported symbol: {symbol!r}")
        self.inject_bits(self.SYMBOL_CODES[symbol], gain=gain)

    def inject_bits(self, bits: Iterable[int], gain: float | None = None) -> None:
        bit_list = [int(v) for v in bits]
        if len(bit_list) != self.n or any(v not in (0, 1) for v in bit_list):
            raise ValueError("Input must be exactly eight binary values")
        quantum = self.external_quantum if gain is None else float(gain)
        with self.lock:
            for i, bit in enumerate(bit_list):
                if bit:
                    self.energy[i] += quantum
                    self.total_external_energy += quantum

    # ---------- Time integration ----------

    def step(self, count: int = 1) -> None:
        with self.lock:
            for _ in range(count):
                self._step_once()

    def run_for(self, duration: float) -> None:
        self.step(max(1, int(round(float(duration) / self.dt))))

    def _step_once(self) -> None:
        self.sim_time += self.dt

        while self.arrivals and self.arrivals[0][0] <= self.sim_time + 1e-12:
            _, edge_index, received = heapq.heappop(self.arrivals)
            edge = self.directed_edges[edge_index]
            self.energy[edge.target] += received
            edge.eligibility += received
            self.total_delivered_energy += received

        # Equal average supply, but granular arrival timing is independent for
        # each node.  This is physical stochasticity, not task-labelled noise.
        packet_probability = self.background_rate * self.dt
        for i in range(self.n):
            supplied = self.background_power * self.dt
            if self.rng.random() < packet_probability:
                supplied += self.background_quantum
            self.energy[i] += supplied
            self.total_background_energy += supplied

        energy_decay = math.exp(-self.energy_leak * self.dt)
        heat_decay = math.exp(-self.dt / self.heat_decay_time)
        readout_decay = math.exp(-self.dt / self.readout_decay_time)
        eligibility_decay = math.exp(-self.dt / self.eligibility_decay_time)
        flow_decay = math.exp(-self.dt / self.flow_decay_time)

        for i in range(self.n):
            self.energy[i] *= energy_decay
            self.heat[i] *= heat_decay
            self.readout[i] *= readout_decay
            self.is_spiking[i] = False

        for edge in self.directed_edges:
            edge.availability += (1.0 - edge.availability) * self.dt / self.availability_recovery_time
            edge.availability = min(1.0, max(0.08, edge.availability))
            edge.eligibility *= eligibility_decay
            edge.flow_trace *= flow_decay
            edge.last_flow *= math.exp(-self.dt / 0.16)
            if self.learning_enabled:
                growth = self.flux_growth * edge.flow_trace * (1.0 - edge.area / self.area_max)
                relaxation = self.material_relaxation * (edge.area - self.area_baseline)
                edge.area += self.dt * (growth - relaxation)
                edge.area = min(self.area_max, max(self.area_min, edge.area))

        if self.learning_enabled:
            self._normalise_outgoing_material()

        candidates = [
            i for i in range(self.n)
            if self.energy[i] >= self.threshold(i)
            and self.sim_time - self.last_spike[i] >= self.minimum_discharge_time
        ]
        self.rng.shuffle(candidates)
        for i in candidates:
            if (
                self.energy[i] >= self.threshold(i)
                and self.sim_time - self.last_spike[i] >= self.minimum_discharge_time
            ):
                self._fire(i)

        self._trim_histories()

    def _fire(self, i: int) -> None:
        available = self.energy[i]
        discharge = min(self.max_discharge, max(0.0, available - self.reset_energy))
        self.energy[i] = self.reset_energy
        self.heat[i] += self.heat_per_spike
        self.last_spike[i] = self.sim_time
        self.readout[i] += 1.0
        self.is_spiking[i] = True
        self.spike_history.append((self.sim_time, i))

        # Local causal consolidation: only traces that physically arrived at
        # this node can alter incoming paths when the node discharges.
        if self.learning_enabled:
            for edge_index in self.incoming[i]:
                edge = self.directed_edges[edge_index]
                if edge.eligibility > 1e-10:
                    edge.area += (
                        self.causal_growth
                        * edge.eligibility
                        * (1.0 - edge.area / self.area_max)
                    )
                    edge.area = min(self.area_max, max(self.area_min, edge.area))
            self._normalise_outgoing_material()

        outgoing = self.outgoing[i]
        if discharge <= 0.0 or not outgoing:
            return

        effective = [max(1e-12, self.effective_conductance(self.directed_edges[k])) for k in outgoing]
        total_effective = sum(effective)
        delivered_total = 0.0

        for edge_index, g_eff in zip(outgoing, effective):
            edge = self.directed_edges[edge_index]
            sent = discharge * g_eff / total_effective
            efficiency = math.exp(-self.loss_coefficient * edge.length / max(edge.area, 1e-12))
            received = sent * efficiency
            delay = edge.length / self.signal_velocity
            heapq.heappush(self.arrivals, (self.sim_time + delay, edge_index, received))
            edge.flow_trace += sent / self.dt
            edge.last_flow += sent
            edge.availability *= math.exp(-self.availability_depletion * sent)
            edge.availability = max(0.08, edge.availability)
            delivered_total += received
            self.pulse_history.append({
                "time": self.sim_time,
                "arrival_time": self.sim_time + delay,
                "source": edge.source,
                "target": edge.target,
                "edge": edge.physical_edge,
                "energy": received,
            })

        self.total_dissipated_energy += max(0.0, discharge - delivered_total)

    def _normalise_outgoing_material(self) -> None:
        # Each source node has a finite amount of path material.  Widening one
        # outgoing direction necessarily removes relative capacity elsewhere.
        for source, indices in enumerate(self.outgoing):
            if not indices:
                continue
            target_budget = self.material_budget[source]
            values = [min(self.area_max, max(self.area_min, self.directed_edges[k].area)) for k in indices]
            free = [v - self.area_min for v in values]
            free_budget = target_budget - len(indices) * self.area_min
            free_sum = sum(free)
            if free_sum <= 1e-12:
                values = [target_budget / len(indices)] * len(indices)
            else:
                values = [self.area_min + free_budget * f / free_sum for f in free]
            correction = target_budget / max(sum(values), 1e-12)
            for k, value in zip(indices, values):
                self.directed_edges[k].area = min(self.area_max, max(self.area_min, value * correction))

    def _trim_histories(self) -> None:
        cutoff = self.sim_time - 30.0
        while self.spike_history and self.spike_history[0][0] < cutoff:
            self.spike_history.popleft()
        pulse_cutoff = self.sim_time - 4.0
        while self.pulse_history and float(self.pulse_history[0]["arrival_time"]) < pulse_cutoff:
            self.pulse_history.popleft()

    # ---------- Training and recall ----------

    def clear_dynamic_state(self) -> None:
        """Clear only fast state.  Structural path areas remain as memory."""
        with self.lock:
            self.energy = [0.08] * self.n
            self.heat = [0.0] * self.n
            self.last_spike = [-1e9] * self.n
            self.readout = [0.0] * self.n
            self.is_spiking = [False] * self.n
            self.arrivals.clear()
            for edge in self.directed_edges:
                edge.availability = 1.0
                edge.eligibility = 0.0
                edge.flow_trace = 0.0
                edge.last_flow = 0.0

    def reset_memory(self) -> None:
        with self.lock:
            self.clear_dynamic_state()
            for edge in self.directed_edges:
                edge.area = self.area_baseline
            self._normalise_outgoing_material()
            self.spike_history.clear()
            self.pulse_history.clear()
            self.last_output = {
                "predicted": None,
                "confidence": 0.0,
                "bits": [0] * self.n,
                "scores": {},
                "measured_at": self.sim_time,
            }

    def conditioning_cycle(self, expression: str = "1+1", target: str = "2") -> None:
        """Timing used by the validated v0.1 experiment."""
        chars = list(expression)
        if not chars:
            raise ValueError("Expression cannot be empty")
        for idx, symbol in enumerate(chars):
            self.inject_symbol(symbol)
            self.run_for(0.04 if idx == len(chars) - 1 else 0.15)
        self.inject_symbol(target)
        self.run_for(0.20)

    def recall_once(
        self,
        expression: str = "1+1",
        *,
        blank_time: float = 0.05,
        measurement_window: float = 0.30,
    ) -> dict[str, Any]:
        """Recall on the current structural memory without changing it."""
        old_learning = self.learning_enabled
        self.learning_enabled = False
        try:
            self.clear_dynamic_state()
            chars = list(expression)
            for idx, symbol in enumerate(chars):
                self.inject_symbol(symbol)
                self.run_for(blank_time if idx == len(chars) - 1 else 0.15)
            # Clear the measuring instrument only; do not alter network energy,
            # heat, queued signals, availability, or path memory.
            self.readout = [0.0] * self.n
            self.run_for(measurement_window)
            result = self.decode(self.readout)
            self.last_output = result
            return result
        finally:
            self.learning_enabled = old_learning

    def recall_probe(self, expression: str = "1+1", trials: int = 5, *, controlled: bool = True) -> dict[str, Any]:
        """Average time-locked recall on cloned fast states.

        Repeated probes estimate a stochastic response while preserving the live
        system.  The structural areas are copied; no learning occurs in probes.
        """
        trials = max(1, min(int(trials), 25))
        with self.lock:
            structural = [edge.area for edge in self.directed_edges]
            seed_base = self.rng.randrange(1, 2**31 - 1)
            background_rate = 0.0 if controlled else self.background_rate
            background_power = self.background_power

        accumulated = [0.0] * self.n
        per_trial: list[dict[str, Any]] = []
        for trial in range(trials):
            probe = PhysicsNetwork(seed_base + trial, background_rate=background_rate)
            probe.background_power = background_power
            for edge, area in zip(probe.directed_edges, structural):
                edge.area = area
            probe._normalise_outgoing_material()
            probe.learning_enabled = False
            result = probe.recall_once(expression)
            for i, value in enumerate(probe.readout):
                accumulated[i] += value
            per_trial.append(result)

        averaged = [value / trials for value in accumulated]
        result = self.decode(averaged)
        result["trials"] = trials
        result["recall_mode"] = "controlled-evoked" if controlled else "live-background"
        result["trial_predictions"] = [item["predicted"] for item in per_trial]
        with self.lock:
            self.last_output = result
        return result

    # ---------- Readout and evidence ----------

    def decode(self, readout: Iterable[float] | None = None) -> dict[str, Any]:
        values = list(self.readout if readout is None else readout)
        norm = math.sqrt(sum(v * v for v in values))
        scores: dict[str, float] = {}
        for symbol, code in self.SYMBOL_CODES.items():
            code_norm = math.sqrt(sum(bit * bit for bit in code))
            score = sum(v * bit for v, bit in zip(values, code)) / max(norm * code_norm, 1e-12)
            scores[symbol] = score
        ranked = sorted(scores.items(), key=lambda item: item[1], reverse=True)
        predicted = ranked[0][0] if norm > 1e-9 else None
        confidence = max(0.0, ranked[0][1] - ranked[1][1]) if predicted is not None else 0.0
        max_value = max(values, default=0.0)
        bits = [1 if max_value > 0.0 and v >= 0.55 * max_value else 0 for v in values]
        return {
            "predicted": predicted,
            "confidence": confidence,
            "bits": bits,
            "readout": values,
            "scores": scores,
            "ranking": ranked,
            "measured_at": self.sim_time,
        }

    def metrics(self, window: float = 5.0) -> dict[str, Any]:
        with self.lock:
            cutoff = self.sim_time - window
            recent = [(t, i) for t, i in self.spike_history if t >= cutoff]
            counts = Counter(i for _, i in recent)
            total = len(recent)
            probabilities = [count / total for count in counts.values()] if total else []
            entropy = -sum(p * math.log(p, 2) for p in probabilities if p > 0.0)
            last_age = self.sim_time - self.spike_history[-1][0] if self.spike_history else None
            firing_nodes = sum(1 for active in self.is_spiking if active)
            return {
                "window_seconds": window,
                "spikes_in_window": total,
                "spike_rate_hz": total / window,
                "last_spike_age_s": last_age,
                "persistent_activity": last_age is not None and last_age < 2.5,
                "active_fraction": firing_nodes / self.n,
                "selection_entropy_bits": entropy,
                "distinct_neurons_in_window": len(counts),
                "stored_energy": sum(self.energy),
                "external_energy": self.total_external_energy,
                "background_energy": self.total_background_energy,
                "delivered_energy": self.total_delivered_energy,
                "dissipated_energy": self.total_dissipated_energy,
            }

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            nodes = []
            for i, (x, y) in enumerate(self.POSITIONS):
                nodes.append({
                    "id": i,
                    "x": x,
                    "y": y,
                    "energy": self.energy[i],
                    "threshold": self.threshold(i),
                    "heat": self.heat[i],
                    "spiking": self.is_spiking[i],
                    "last_spike_age": self.sim_time - self.last_spike[i] if self.last_spike[i] > -1e8 else None,
                    "readout": self.readout[i],
                })

            edges = []
            for pidx, (a, b) in enumerate(self.PHYSICAL_EDGES):
                ab_index, ba_index = self.physical_to_directed[pidx]
                ab = self.directed_edges[ab_index]
                ba = self.directed_edges[ba_index]
                edges.append({
                    "id": pidx,
                    "a": a,
                    "b": b,
                    "length": ab.length,
                    "area_ab": ab.area,
                    "area_ba": ba.area,
                    "area_mean": (ab.area + ba.area) / 2.0,
                    "resistance_ab": self.resistance(ab),
                    "resistance_ba": self.resistance(ba),
                    "conductance_ab": self.conductance(ab),
                    "conductance_ba": self.conductance(ba),
                    "availability_ab": ab.availability,
                    "availability_ba": ba.availability,
                    "flow_ab": ab.last_flow,
                    "flow_ba": ba.last_flow,
                })

            spikes = [
                {"time": t, "neuron": i}
                for t, i in list(self.spike_history)[-240:]
            ]
            pulses = [dict(item) for item in list(self.pulse_history)[-180:]]
            return {
                "title": self.TITLE,
                "sim_time": self.sim_time,
                "nodes": nodes,
                "edges": edges,
                "spikes": spikes,
                "pulses": pulses,
                "metrics": self.metrics(),
                "output": copy.deepcopy(self.last_output),
                "codes": {symbol: list(code) for symbol, code in self.SYMBOL_CODES.items()},
                "parameters": {
                    "dt": self.dt,
                    "background_rate": self.background_rate,
                    "background_quantum": self.background_quantum,
                    "background_power": self.background_power,
                    "energy_leak": self.energy_leak,
                    "external_quantum": self.external_quantum,
                    "learning_enabled": self.learning_enabled,
                },
            }

    def clone(self) -> "PhysicsNetwork":
        with self.lock:
            clone = PhysicsNetwork(self.seed, background_rate=self.background_rate)
            for dst, src in zip(clone.directed_edges, self.directed_edges):
                dst.area = src.area
            clone._normalise_outgoing_material()
            return clone


class NetworkRuntime:
    """Real-time wrapper that continuously advances the physical system."""

    def __init__(self, network: PhysicsNetwork | None = None) -> None:
        self.network = network or PhysicsNetwork()
        self.running = False
        self.speed = 10.0
        self.training = False
        self.expression = "1+1"
        self.target = "2"
        self.training_cycles = 0
        self._thread: threading.Thread | None = None
        self._next_event_wall = 0.0
        self._event_index = 0
        self._schedule: list[tuple[float, str]] = []
        self.last_error: str | None = None

    def start(self) -> None:
        if self.running:
            return
        self.running = True
        self._thread = threading.Thread(target=self._loop, name="physics-network", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self.running = False
        if self._thread:
            self._thread.join(timeout=2.0)

    def start_training(self, expression: str, target: str) -> None:
        self._validate_expression(expression)
        if target not in self.network.SYMBOL_CODES:
            raise ValueError(f"Unsupported target symbol: {target!r}")
        self.expression = expression
        self.target = target
        self.training = True
        self._schedule = []
        self._event_index = 0

    def stop_training(self) -> None:
        self.training = False
        self._schedule = []
        self._event_index = 0

    def _validate_expression(self, expression: str) -> None:
        if not expression or len(expression) > 12:
            raise ValueError("Expression must contain 1 to 12 symbols")
        unsupported = [c for c in expression if c not in self.network.SYMBOL_CODES]
        if unsupported:
            raise ValueError(f"Unsupported input symbol(s): {unsupported}")

    def _build_schedule(self) -> None:
        base = self.network.sim_time + 0.03
        schedule: list[tuple[float, str]] = []
        t = base
        for idx, symbol in enumerate(self.expression):
            schedule.append((t, symbol))
            t += 0.04 if idx == len(self.expression) - 1 else 0.15
        schedule.append((t, self.target))
        self._schedule = schedule
        self._event_index = 0
        self._cycle_end = t + 0.32

    def _training_tick(self) -> None:
        if not self.training:
            return
        if not self._schedule:
            self._build_schedule()
        while self._event_index < len(self._schedule) and self.network.sim_time >= self._schedule[self._event_index][0]:
            _, symbol = self._schedule[self._event_index]
            self.network.inject_symbol(symbol)
            self._event_index += 1
        if self._event_index >= len(self._schedule) and self.network.sim_time >= self._cycle_end:
            self.training_cycles += 1
            self._schedule = []
            self._event_index = 0

    def _loop(self) -> None:
        while self.running:
            started = time.perf_counter()
            try:
                self._training_tick()
                self.network.step(1)
                self.last_error = None
            except Exception as exc:  # pragma: no cover - runtime safety path
                self.last_error = f"{type(exc).__name__}: {exc}"
                self.training = False
            elapsed = time.perf_counter() - started
            delay = max(0.0005, self.network.dt / max(self.speed, 0.1) - elapsed)
            time.sleep(delay)

    def snapshot(self) -> dict[str, Any]:
        result = self.network.snapshot()
        result["runtime"] = {
            "running": self.running,
            "speed": self.speed,
            "training": self.training,
            "expression": self.expression,
            "target": self.target,
            "training_cycles": self.training_cycles,
            "last_error": self.last_error,
        }
        return result

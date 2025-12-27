# MQTT energy meter simulator

This utility publishes synthetic three-phase energy data to an MQTT broker at
1 second, 1 minute, 5 minute, and 15 minute intervals. Values are randomly
jittered around a nominal 1.5 MW load with realistic voltages, power factor,
and cumulative energy.

## Requirements

Install the single dependency before running the simulator:

```bash
pip install paho-mqtt
```

## Usage

```bash
python utils/mqtt_energy_simulator.py \
  --host limelightit.myvps4u.com \
  --port 1883 \
  --username limelight \
  --password '4P5X3bn0B6C' \
  --topic Limelightit/adr/device1/energydata
```

Arguments:

- `--host` / `--port`: MQTT broker address (default `localhost:1883`).
- `--topic`: Topic to publish JSON payloads to (default
  `Limelightit/adr/device1/energydata`).
- `--username` / `--password`: Optional MQTT credentials.
- `--base-kw`: Nominal contracted demand to simulate (default `1500`).
- `--base-pf`: Nominal power factor (default `0.94`).

The script stays running and emits JSON such as:

```json
{
  "timestamp": "2024-05-18T06:00:00.123456+00:00",
  "interval_seconds": 1,
  "interval_label": "realtime",
  "frequency_hz": 50.021,
  "power_factor": 0.947,
  "average_demand_kw": 1492.3,
  "totals": {
    "active_power_kw": 1487.12,
    "reactive_power_kvar": -190.45,
    "energy_kwh": 2345.678
  },
  "phases": {
    "A": {
      "voltage_v": 414.8,
      "current_a": 1195.7,
      "active_power_kw": 501.2,
      "power_factor": 0.945
    },
    "B": {
      "voltage_v": 415.9,
      "current_a": 1211.0,
      "active_power_kw": 503.7,
      "power_factor": 0.953
    },
    "C": {
      "voltage_v": 413.7,
      "current_a": 1208.1,
      "active_power_kw": 482.2,
      "power_factor": 0.944
    }
  }
}
```

Press `Ctrl+C` to stop publishing.

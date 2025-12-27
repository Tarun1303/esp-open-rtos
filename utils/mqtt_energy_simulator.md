# MQTT energy meter simulator

This utility publishes synthetic three-phase energy data to an MQTT broker at
1 second, 1 minute, 5 minute, and 15 minute intervals. Values are randomly
jittered around a nominal 1.5 MW load with realistic voltages, power factor,
and cumulative energy.

## Requirements

Install the dependencies before running the simulator:

```bash
pip install paho-mqtt
# Optional for the browser configuration UI
pip install flask
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
- `--intervals`: Comma-separated publish intervals in seconds (defaults to
  `1,60,300,900`).
- `--serve-ui`: Launch a small browser UI to configure broker/topic/intervals
  and start/stop publishing without the command line.

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

## Browser configuration UI

Launch the UI on port 5000 (default) and open it in your browser:

```bash
python utils/mqtt_energy_simulator.py --serve-ui --host localhost --port 1883
```

If you are working inside a container, keep the process running and browse to
`http://127.0.0.1:5000` (or the forwarded port) to preview the page. The UI
uses `/api/status` to load defaults and will stay on the status screen until
you click **Start simulator**.

From the UI you can:

- Set the broker host/port and MQTT credentials.
- Choose the publish topic and any combination of 1s/1m/5m/15m (or custom)
  intervals.
- Set the contracted demand (kW) and power factor used to generate data.
- Start or stop the simulator, with the current status shown on the page.

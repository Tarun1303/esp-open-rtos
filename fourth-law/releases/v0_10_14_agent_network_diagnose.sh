#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

{
  echo FOURTH_LAW_AGENT_NETWORK_DIAGNOSIS
  echo compose_agent_begin
  python3 - "$PROJECT/compose.yaml" <<'PY'
import json, subprocess, sys
path = sys.argv[1]
raw = subprocess.check_output(['docker', 'compose', '-f', path, 'config', '--format', 'json'], text=True)
config = json.loads(raw)
agent = config.get('services', {}).get('agent', {})
safe = {key: agent.get(key) for key in ('ports', 'network_mode', 'networks', 'depends_on', 'restart')}
print(json.dumps(safe, sort_keys=True))
PY
  echo compose_agent_end
  echo container_network_begin
  docker inspect fourth-law-agent --format 'restart_count={{.RestartCount}} network_mode={{.HostConfig.NetworkMode}} ports={{json .NetworkSettings.Ports}} networks={{json .NetworkSettings.Networks}}' 2>&1 || true
  docker inspect fourth-law-tunnel --format 'network_mode={{.HostConfig.NetworkMode}} networks={{json .NetworkSettings.Networks}}' 2>&1 || true
  docker network inspect fourth-law-agent_default --format '{{range $id, $cfg := .Containers}}{{$cfg.Name}}={{$cfg.IPv4Address}} {{end}}' 2>&1 || true
  echo container_network_end
  echo active_release_units_begin
  systemctl list-units 'fourthlaw-release-*' --all --no-legend --no-pager 2>&1 || true
  echo active_release_units_end
  echo docker_events_begin
  docker events --since 10m --until 0s --filter container=fourth-law-agent --filter event=start --filter event=die --filter event=connect --filter event=disconnect --format '{{.Time}}|{{.Action}}|{{json .Actor.Attributes}}' 2>&1 || true
  echo docker_events_end
  echo health_internal_begin
  docker exec fourth-law-agent python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8787/health", timeout=5).read().decode())' 2>&1 || true
  echo health_internal_end
} | report_issue

echo FOURTH_LAW_AGENT_NETWORK_DIAGNOSIS_READY

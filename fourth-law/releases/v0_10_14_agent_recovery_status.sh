#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

{
  echo FOURTH_LAW_AGENT_RECOVERY_STATUS
  echo health_begin
  curl -fsS --max-time 5 http://127.0.0.1:8787/health 2>&1 || true
  echo
  echo health_end
  echo docker_ps_begin
  docker ps -a --filter name=fourth-law-agent --format '{{.Names}}|{{.Status}}|{{.Image}}' || true
  echo docker_ps_end
  echo compose_ps_begin
  docker compose -f "$PROJECT/compose.yaml" ps -a 2>&1 || true
  echo compose_ps_end
  echo inspect_begin
  docker inspect fourth-law-agent --format 'status={{.State.Status}} running={{.State.Running}} restarting={{.State.Restarting}} exit={{.State.ExitCode}} error={{.State.Error}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' 2>&1 || true
  echo inspect_end
  echo logs_begin
  docker logs --tail 100 fourth-law-agent 2>&1 || true
  echo logs_end
  echo codex_service_begin
  systemctl is-active fourthlaw-codex.service 2>&1 || true
  echo codex_service_end
} | report_issue

echo FOURTH_LAW_AGENT_RECOVERY_STATUS_READY

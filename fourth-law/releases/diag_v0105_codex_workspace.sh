#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent

{
  echo 'V0105_CODEX_WORKSPACE_DIAGNOSTIC'
  echo '=== HEALTH ==='
  curl -fsS http://127.0.0.1:8787/health || true
  echo
  echo '=== HOST ==='
  id
  uname -a
  sed -n '1,12p' /etc/os-release 2>/dev/null || true
  echo '=== TOOLCHAIN ==='
  for tool in git node npm npx python3 pip3 docker codex gh; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '%s=' "$tool"
      command -v "$tool"
      "$tool" --version 2>/dev/null | head -1 || true
    else
      echo "$tool=MISSING"
    fi
  done
  echo '=== STORAGE ==='
  df -h /opt /var/lib 2>/dev/null || df -h /
  echo '=== PROJECT SAFETY MAP ==='
  test -d "$PROJECT" && echo 'project=present' || echo 'project=missing'
  test -f "$PROJECT/.env" && echo 'env=present-protected' || echo 'env=missing'
  test -d "$PROJECT/.git" && echo 'project_git=yes' || echo 'project_git=no'
  find "$PROJECT" -maxdepth 2 -type f \
    ! -name '.env' ! -path '*/backups/*' ! -path '*/data/*' \
    -printf '%P\t%s bytes\n' 2>/dev/null | sort | head -160
  echo '=== EXISTING DEV IDENTITY ==='
  getent passwd fourthlaw-dev || echo 'fourthlaw-dev=absent'
  test -d /var/lib/fourthlaw-dev && echo 'dev_home=present' || echo 'dev_home=absent'
  echo '=== DOCKER COMPOSE SERVICES ==='
  cd "$PROJECT"
  docker compose config --services 2>/dev/null || true
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true


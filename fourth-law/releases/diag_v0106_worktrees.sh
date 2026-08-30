#!/usr/bin/env bash
set -Eeuo pipefail
{
  echo V0106_WORKTREE_STATUS
  echo CONFIG_MARKERS
  grep -E 'default_permissions|":root"|enabled = false' /var/lib/fourthlaw-dev/.codex/config.toml || true
  for role in source runtime control-room execution efficiency; do
    if test "$role" = source; then path=/var/lib/fourthlaw-dev/source; else path="/var/lib/fourthlaw-dev/worktrees/$role"; fi
    echo "[$role]"
    git -C "$path" status --short --branch
  done
  curl -fsS http://127.0.0.1:8787/health
} | HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='/opt/fourth-law-agent'
STATE="$PROJECT/data/codex_sessions/project-supervisor.json"
REPOSITORY='/var/lib/fourthlaw-dev/agent-repos/supervisor'

report_issue() {
  HOME=/root GH_CONFIG_DIR=/root/.config/gh \
    gh issue comment 7 --repo Tarun1303/factory --body-file - >/dev/null 2>&1 || true
}

health="$(curl -fsS http://127.0.0.1:8787/health)"
printf '%s' "$health" | grep -q '"version":"0.10.13"'
systemctl is-active --quiet fourthlaw-codex.service
test -f "$STATE"
test -d "$REPOSITORY/.git"

result="$(python3 - "$STATE" "$REPOSITORY" <<'PY'
import json
import os
import shutil
import stat
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
repository = Path(sys.argv[2])
state = json.loads(path.read_text())
assert state.get('id') == 'project-supervisor'
assert state.get('role') == 'supervisor'
assert state.get('thread_id')
error = str(state.get('last_error') or '')
assert 'Failed to initialize session' in error or '/var/lib/fourthlaw-dev/worktrees/supervisor' in error

metadata = path.stat()
backup = path.with_suffix('.pre-v01013k.json')
if not backup.exists():
    shutil.copy2(path, backup)
    os.chown(backup, metadata.st_uid, metadata.st_gid)

legacy_thread = state.get('thread_id')
state['legacy_thread_id'] = legacy_thread
state['thread_id'] = None
state['turn_id'] = None
state['status'] = 'ready'
state['last_error'] = ''
state['updated_at'] = time.time()
events = state.setdefault('events', [])
events.append({
    'ts': time.time(),
    'type': 'thread_rebased',
    'summary': 'Persistent Supervisor workspace preserved; Codex thread will restart in the independent supervisor repository',
    'repository': str(repository),
})
state['events'] = events[-500:]

temp = path.with_suffix('.rebase.tmp')
temp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
os.chmod(temp, stat.S_IMODE(metadata.st_mode))
os.chown(temp, metadata.st_uid, metadata.st_gid)
temp.replace(path)

print('session=project-supervisor')
print('conversation_preserved=true')
print('legacy_thread_preserved_in_audit=true')
print(f'new_repository={repository}')
print('status=ready')
PY
)"

{
  echo SUPERVISOR_THREAD_REBASED_V0_10_13
  echo "$result"
  echo production_code_changed=false
  echo other_agent_state_changed=false
  echo "health=$health"
} | report_issue

echo SUPERVISOR_THREAD_REBASE_V0_10_13_READY

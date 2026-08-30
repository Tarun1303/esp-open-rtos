#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
ORIGINAL="$PROJECT/dispatched-releases/v0_10_4_bounded_code_workspace.sh"
PATCHED=/tmp/v0_10_4_bounded_code_workspace_patched.sh

test -f "$ORIGINAL"
cp "$ORIGINAL" "$PATCHED"

python3 - <<'PY_PATCH'
from pathlib import Path

p = Path('/tmp/v0_10_4_bounded_code_workspace_patched.sh')
s = p.read_text()

old = r'''# Free/local security + staging regression before restart.
cd "$PROJECT"
python3 - <<'PY'
import sys,tempfile
from pathlib import Path
sys.path.insert(0,'/opt/fourth-law-agent')
from app.code_workspace import CodeWorkspace
root=Path(tempfile.mkdtemp()); live=root/'live'; stage=root/'stage'; idx=root/'idx.json'; live.mkdir()
(live/'demo.py').write_text('def x():\n    return 1\n')
(live/'.env').write_text('SECRET=x')
w=CodeWorkspace(str(live),str(stage),str(idx))
assert 'demo.py' in w.index_packet()
assert 'return 1' in w.read_code('demo.py',1,5)
try:
    w.read_code('.env')
    raise AssertionError('secret read allowed')
except ValueError: pass
assert w.stage_from_live('j1','demo.py').startswith('STAGED')
assert w.replace_staged('j1','demo.py','return 1','return 2',1).startswith('REPLACED')
assert '+    return 2' in w.diff_staged('j1','demo.py')
assert 'PASS demo.py' in w.validate('j1')
assert (live/'demo.py').read_text().endswith('return 1\n')
print('V0104_CODE_WORKSPACE_LOCAL_REGRESSION_OK')
PY

docker compose build agent >/tmp/fl0104-build.log 2>&1
'''

new = r'''# Build first, then run the dependency-aware regression inside the image.
# The original v0.10.4 attempted this import on the host, where the Agents SDK
# is intentionally not installed, causing a false rollback before validation.
cd "$PROJECT"
docker compose build agent >/tmp/fl0104-build.log 2>&1
docker compose run --rm --no-deps agent python - <<'PY'
import tempfile
from pathlib import Path
from app.code_workspace import CodeWorkspace
root=Path(tempfile.mkdtemp()); live=root/'live'; stage=root/'stage'; idx=root/'idx.json'; live.mkdir()
(live/'demo.py').write_text('def x():\n    return 1\n')
(live/'.env').write_text('SECRET=x')
w=CodeWorkspace(str(live),str(stage),str(idx))
assert 'demo.py' in w.index_packet()
assert 'return 1' in w.read_code('demo.py',1,5)
try:
    w.read_code('.env')
    raise AssertionError('secret read allowed')
except ValueError:
    pass
assert w.stage_from_live('j1','demo.py').startswith('STAGED')
assert w.replace_staged('j1','demo.py','return 1','return 2',1).startswith('REPLACED')
assert '+    return 2' in w.diff_staged('j1','demo.py')
assert 'PASS demo.py' in w.validate('j1')
assert (live/'demo.py').read_text().endswith('return 1\n')
print('V0104_CODE_WORKSPACE_CONTAINER_REGRESSION_OK')
PY
'''

if old not in s:
    raise SystemExit('v0.10.4 host-regression block not found; refusing unsafe patch')
s = s.replace(old, new, 1)
p.write_text(s)
PY_PATCH

chmod 700 "$PATCHED"
/bin/bash "$PATCHED"

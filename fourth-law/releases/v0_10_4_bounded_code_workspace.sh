#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
ENGINE="$PROJECT/app/intelligence_engine.py"
MAIN="$PROJECT/app/main.py"
CW="$PROJECT/app/code_workspace.py"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.10.4-code-workspace-$STAMP"
mkdir -p "$BACKUP"
cp "$ENGINE" "$BACKUP/intelligence_engine.py"
cp "$MAIN" "$BACKUP/main.py"
[[ -f "$CW" ]] && cp "$CW" "$BACKUP/code_workspace.py" || true
rollback(){
  set +e
  echo 'V0104_FAILURE_CONTEXT' >/tmp/fl0104-failure.txt
  python3 -m py_compile "$ENGINE" "$MAIN" "$CW" >>/tmp/fl0104-failure.txt 2>&1 || true
  cd "$PROJECT"; docker compose logs --tail=100 agent >>/tmp/fl0104-failure.txt 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body-file /tmp/fl0104-failure.txt >/dev/null 2>&1 || true
  cp "$BACKUP/intelligence_engine.py" "$ENGINE"; cp "$BACKUP/main.py" "$MAIN"
  if [[ -f "$BACKUP/code_workspace.py" ]]; then cp "$BACKUP/code_workspace.py" "$CW"; else rm -f "$CW"; fi
  docker compose build agent >/tmp/fl0104-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl0104-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'BOUNDED_CODE_WORKSPACE_V0_10_4_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR

cat > "$CW" <<'PY'
from __future__ import annotations

import ast
import difflib
import hashlib
import json
import re
from pathlib import Path
from typing import Any

from agents import function_tool


class CodeWorkspace:
    """Secret-denying source reader + per-job staged writer. Never writes live source."""

    ALLOWED_EXT = {".py", ".html", ".css", ".js", ".json", ".md", ".txt", ".toml", ".yaml", ".yml"}
    DENY_PARTS = {".env", ".git", "secrets", "secret", "credentials", "credential", "__pycache__", "backups"}
    MAX_READ = 14000
    MAX_WRITE = 60000
    MAX_TOTAL_STAGE = 600000

    def __init__(self, live_root: str = "/app/app", stage_root: str = "/data/code-workspaces", index_path: str = "/data/code-index/index.json"):
        self.live_root = Path(live_root).resolve()
        self.stage_root = Path(stage_root).resolve()
        self.index_path = Path(index_path)
        self.stage_root.mkdir(parents=True, exist_ok=True)
        self.index_path.parent.mkdir(parents=True, exist_ok=True)

    def _clean_rel(self, raw: str, *, allow_dot: bool = False) -> Path:
        raw = str(raw or "").strip().replace("\\", "/")
        if allow_dot and raw in {"", "."}:
            return Path(".")
        p = Path(raw)
        if p.is_absolute() or ".." in p.parts or not p.parts:
            raise ValueError("Path must be a safe relative application path")
        if any(part.lower() in self.DENY_PARTS or part.lower().startswith(".env") for part in p.parts):
            raise ValueError("Path is denied by code-workspace policy")
        if p.suffix.lower() not in self.ALLOWED_EXT:
            raise ValueError("File type is not allowlisted")
        return p

    def _live(self, rel: Path) -> Path:
        p = (self.live_root / rel).resolve()
        if self.live_root not in p.parents and p != self.live_root:
            raise ValueError("Path escaped live source root")
        if p.is_symlink():
            raise ValueError("Symlinks are denied")
        return p

    def _stage(self, job_id: str, rel: Path) -> Path:
        root = (self.stage_root / re.sub(r"[^A-Za-z0-9_-]", "_", str(job_id))[:80]).resolve()
        root.mkdir(parents=True, exist_ok=True)
        p = (root / rel).resolve()
        if root not in p.parents and p != root:
            raise ValueError("Path escaped staging root")
        return p

    def _stage_total(self, job_id: str) -> int:
        root = self.stage_root / re.sub(r"[^A-Za-z0-9_-]", "_", str(job_id))[:80]
        if not root.exists(): return 0
        return sum(p.stat().st_size for p in root.rglob("*") if p.is_file())

    def refresh_index(self) -> dict[str, Any]:
        files=[]
        if not self.live_root.exists():
            return {"version":"1.0","files":[],"error":"live source unavailable"}
        for p in sorted(self.live_root.rglob("*")):
            if not p.is_file() or p.is_symlink() or p.suffix.lower() not in self.ALLOWED_EXT: continue
            rel=p.relative_to(self.live_root)
            if any(part.lower() in self.DENY_PARTS or part.lower().startswith(".env") for part in rel.parts): continue
            try: data=p.read_bytes()
            except Exception: continue
            item={"path":str(rel),"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()[:16],"language":p.suffix.lower().lstrip('.')}
            if p.suffix.lower()=='.py' and len(data)<=250000:
                try:
                    tree=ast.parse(data.decode('utf-8','replace'))
                    item["symbols"]=[n.name for n in tree.body if isinstance(n,(ast.ClassDef,ast.FunctionDef,ast.AsyncFunctionDef))][:30]
                except Exception: item["symbols"]=[]
            files.append(item)
            if len(files)>=240: break
        out={"version":"1.0","root":"application-source","files":files,"file_count":len(files)}
        self.index_path.write_text(json.dumps(out,ensure_ascii=False,indent=2))
        return out

    def index_packet(self, query: str = "", cap: int = 4500) -> str:
        idx=self.refresh_index()
        q=str(query or '').strip().lower()
        rows=[]
        for f in idx.get('files',[]):
            text=(f.get('path','')+' '+' '.join(f.get('symbols',[]))).lower()
            if q and q not in text: continue
            syms=','.join(f.get('symbols',[])[:8])
            rows.append(f"{f.get('path')} [{f.get('bytes')}B] {syms}")
            if len(rows)>=45: break
        payload="CODEBASE INDEX (compact; use tools for exact source):\n"+'\n'.join(rows)
        return payload[:cap]

    def list_code(self, path: str = ".") -> str:
        rel=self._clean_rel(path,allow_dot=True)
        base=self.live_root if rel==Path('.') else self._live(rel)
        if not base.exists(): return "NOT_FOUND"
        if base.is_file(): return str(rel)
        rows=[]
        for p in sorted(base.iterdir()):
            if p.name.startswith('.') or p.name.lower() in self.DENY_PARTS: continue
            if p.is_dir(): rows.append(p.name+'/')
            elif p.suffix.lower() in self.ALLOWED_EXT: rows.append(p.name)
            if len(rows)>=120: break
        return '\n'.join(rows)

    def read_code(self, path: str, start_line: int = 1, end_line: int = 160) -> str:
        rel=self._clean_rel(path); p=self._live(rel)
        if not p.is_file(): return "NOT_FOUND"
        text=p.read_text(errors='replace'); lines=text.splitlines()
        a=max(1,int(start_line)); b=min(len(lines),max(a,int(end_line)),a+260)
        out='\n'.join(f"{i+1}: {lines[i]}" for i in range(a-1,b))
        return out[:self.MAX_READ]

    def search_code(self, query: str, path: str = ".", max_hits: int = 25) -> str:
        q=str(query or '')[:300]
        if not q: return "QUERY_REQUIRED"
        rel=self._clean_rel(path,allow_dot=True); base=self.live_root if rel==Path('.') else self._live(rel)
        candidates=[base] if base.is_file() else list(base.rglob('*'))
        hits=[]
        for p in candidates:
            if not p.is_file() or p.is_symlink() or p.suffix.lower() not in self.ALLOWED_EXT: continue
            try: rp=p.relative_to(self.live_root)
            except Exception: continue
            if any(part.lower() in self.DENY_PARTS for part in rp.parts): continue
            try:
                for i,line in enumerate(p.read_text(errors='replace').splitlines(),1):
                    if q.lower() in line.lower():
                        hits.append(f"{rp}:{i}: {line[:240]}")
                        if len(hits)>=min(max(1,int(max_hits)),50): return '\n'.join(hits)
            except Exception: continue
        return '\n'.join(hits) if hits else "NO_MATCHES"

    def stage_from_live(self, job_id: str, path: str) -> str:
        rel=self._clean_rel(path); src=self._live(rel)
        if not src.is_file(): return "NOT_FOUND"
        data=src.read_text(errors='strict')
        if len(data)>self.MAX_WRITE: raise ValueError("File exceeds per-file staging limit")
        dst=self._stage(job_id,rel); dst.parent.mkdir(parents=True,exist_ok=True); dst.write_text(data)
        return f"STAGED {rel} sha={hashlib.sha256(data.encode()).hexdigest()[:16]}"

    def write_staged(self, job_id: str, path: str, content: str) -> str:
        rel=self._clean_rel(path); content=str(content)
        if len(content)>self.MAX_WRITE: raise ValueError("Content exceeds per-file staging limit")
        dst=self._stage(job_id,rel); old=dst.stat().st_size if dst.exists() else 0
        projected=self._stage_total(job_id)-old+len(content.encode())
        if projected>self.MAX_TOTAL_STAGE: raise ValueError("Job staging workspace exceeds total size limit")
        dst.parent.mkdir(parents=True,exist_ok=True); dst.write_text(content)
        return f"WROTE_STAGED {rel} bytes={len(content.encode())}"

    def replace_staged(self, job_id: str, path: str, old: str, new: str, count: int = 1) -> str:
        rel=self._clean_rel(path); dst=self._stage(job_id,rel)
        if not dst.exists(): self.stage_from_live(job_id,path)
        text=dst.read_text(); old=str(old); new=str(new)
        if not old: raise ValueError("old text is required")
        found=text.count(old)
        if found==0: return "OLD_TEXT_NOT_FOUND"
        n=max(1,min(int(count),found,20)); updated=text.replace(old,new,n)
        self.write_staged(job_id,path,updated)
        return f"REPLACED {rel} count={n} remaining_old={updated.count(old)}"

    def diff_staged(self, job_id: str, path: str) -> str:
        rel=self._clean_rel(path); live=self._live(rel); staged=self._stage(job_id,rel)
        if not staged.exists(): return "NOT_STAGED"
        a=live.read_text(errors='replace').splitlines() if live.exists() else []
        b=staged.read_text(errors='replace').splitlines()
        d='\n'.join(difflib.unified_diff(a,b,fromfile='live/'+str(rel),tofile='staged/'+str(rel),lineterm=''))
        return d[:30000] if d else "NO_DIFF"

    def validate(self, job_id: str) -> str:
        root=self._stage(job_id,Path('.')); rows=[]
        if not root.exists(): return "NO_STAGED_FILES"
        for p in sorted(root.rglob('*')):
            if not p.is_file(): continue
            rel=p.relative_to(root); ok=True; detail='ok'
            try:
                text=p.read_text()
                if p.suffix=='.py': compile(text,str(rel),'exec')
                elif p.suffix=='.json': json.loads(text)
                if len(text)>self.MAX_WRITE: raise ValueError('size limit')
            except Exception as exc: ok=False; detail=str(exc)[:300]
            rows.append(f"{'PASS' if ok else 'FAIL'} {rel}: {detail}")
        return '\n'.join(rows)[:16000]

    def tools(self, job: dict, node: dict) -> list[Any]:
        jid=str(job.get('id','unknown'))

        @function_tool(description_override="Show the compact application codebase index. Use this before guessing file locations.")
        async def codebase_map(query: str = "") -> str:
            return self.index_packet(query)

        @function_tool(description_override="List allowlisted application source files/directories. Secret paths are denied.")
        async def list_code(path: str = ".") -> str:
            return self.list_code(path)

        @function_tool(description_override="Read a bounded line range from real application source. Cannot read .env/secrets.")
        async def read_code(path: str, start_line: int = 1, end_line: int = 160) -> str:
            return self.read_code(path,start_line,end_line)

        @function_tool(description_override="Search real application source for an exact text/symbol. Returns bounded matches only.")
        async def search_code(query: str, path: str = ".", max_hits: int = 25) -> str:
            return self.search_code(query,path,max_hits)

        @function_tool(description_override="Copy one real source file into this mission's isolated staging workspace before editing it.")
        async def stage_from_live(path: str) -> str:
            return self.stage_from_live(jid,path)

        @function_tool(description_override="Write a complete UTF-8 source file only inside this mission's isolated staging workspace; never writes production directly.")
        async def write_staged_code(path: str, content: str) -> str:
            return self.write_staged(jid,path,content)

        @function_tool(description_override="Perform a bounded exact-text replacement in a staged source file. It automatically stages the live file first if necessary.")
        async def replace_staged_code(path: str, old: str, new: str, count: int = 1) -> str:
            return self.replace_staged(jid,path,old,new,count)

        @function_tool(description_override="Show a bounded unified diff between live source and this mission's staged version.")
        async def diff_staged_code(path: str) -> str:
            return self.diff_staged(jid,path)

        @function_tool(description_override="Validate all staged Python/JSON/source files with allowlisted local structural checks; no arbitrary command execution.")
        async def validate_staged_code() -> str:
            return self.validate(jid)

        return [codebase_map,list_code,read_code,search_code,stage_from_live,write_staged_code,replace_staged_code,diff_staged_code,validate_staged_code]
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/intelligence_engine.py')
s=p.read_text()
if 'from agents import Agent, Runner, RunConfig, SQLiteSession, function_tool' not in s:
    s=s.replace('from agents import Agent, Runner, RunConfig, SQLiteSession','from agents import Agent, Runner, RunConfig, SQLiteSession, function_tool',1)
if 'from app.code_workspace import CodeWorkspace' not in s:
    s=s.replace('from app.shared_memory import SharedContextMemory','from app.shared_memory import SharedContextMemory\nfrom app.code_workspace import CodeWorkspace',1)
if 'self.code_workspace = CodeWorkspace()' not in s:
    s=s.replace('        self.memory = SharedContextMemory()','        self.memory = SharedContextMemory()\n        self.code_workspace = CodeWorkspace()',1)

# Make bounded code tools part of every Agents-SDK node call.
anchor='''            output_type=output_type,
            model_settings={
'''
replacement='''            output_type=output_type,
            tools=self.code_workspace.tools(job, node),
            model_settings={
'''
if 'tools=self.code_workspace.tools(job, node),' not in s:
    if anchor not in s: raise SystemExit('primary Agent anchor missing')
    s=s.replace(anchor,replacement,1)

# Recovery Agent also retains the same bounded code tools.
anchor='''                output_type=output_type,
                model_settings={
'''
replacement='''                output_type=output_type,
                tools=self.code_workspace.tools(job, node),
                model_settings={
'''
if s.count('tools=self.code_workspace.tools(job, node),') < 2:
    if anchor not in s: raise SystemExit('recovery Agent anchor missing')
    s=s.replace(anchor,replacement,1)

# Give Supervisor a compact codebase map at root planning, while exact source stays on-demand through worker tools.
old='''            root_context = self.memory.root_planning_context(str(job.get("context", "") or ""))
'''
new='''            root_context = self.memory.root_planning_context(str(job.get("context", "") or ""))
            codebase_packet = self.code_workspace.index_packet()
            job["codebase_memory"] = {"version":"1.0","mode":"indexed-on-demand","packet":codebase_packet[:4500],"stage_root":f"/data/code-workspaces/{job['id']}"}
            root_context = (root_context + "\\n\\n" + codebase_packet)[:12000]
'''
if 'job["codebase_memory"] = {"version":"1.0"' not in s:
    if old not in s: raise SystemExit('root context anchor missing')
    s=s.replace(old,new,1)

# Tell every worker that real code tools exist and staging is the only writable boundary.
needle='''- Return operational outputs only; never expose hidden chain-of-thought.
'''
addition='''- Return operational outputs only; never expose hidden chain-of-thought.
- You have bounded codebase tools. For code/architecture tasks, inspect actual source before asserting file paths. You may write only to the per-job staging workspace via staged-code tools; never request or expose secrets and never claim staged edits are deployed.
'''
if 'You have bounded codebase tools.' not in s:
    if needle not in s: raise SystemExit('instruction anchor missing')
    s=s.replace(needle,addition,1)

p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('"version":"0.10.3"','"version":"0.10.4"')
s=s.replace('"version": "0.10.3"','"version": "0.10.4"')
s=s.replace('version="0.10.3"','version="0.10.4"')
# Also works if Efficiency patch rolled back and current source still says 0.10.2.
s=s.replace('"version":"0.10.2"','"version":"0.10.4"')
s=s.replace('"version": "0.10.2"','"version": "0.10.4"')
s=s.replace('version="0.10.2"','version="0.10.4"')
if 'bounded-code-workspace-v0.10.4' not in s:
    marker='efficiency-guardian-v0.10.3c' if 'efficiency-guardian-v0.10.3c' in s else 'human-intervention-v0.10.2'
    if marker not in s: raise SystemExit('architecture marker missing')
    s=s.replace(marker,marker+'+bounded-code-workspace-v0.10.4',1)
p.write_text(s)
PY

python3 -m py_compile "$CW" "$ENGINE" "$MAIN"
grep -q 'tools=self.code_workspace.tools(job, node)' "$ENGINE"
grep -q 'bounded-code-workspace-v0.10.4' "$MAIN"

# Free/local security + staging regression before restart.
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
docker compose up -d --force-recreate agent >/tmp/fl0104-up.log 2>&1
ok=0
for i in $(seq 1 90); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.10.4"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/tmp/fl0104-ui.html
grep -q 'Fourth Law' /tmp/fl0104-ui.html
# Confirm SDK constructs tools without calling a paid model.
docker compose exec -T agent python - <<'PY'
from app.code_workspace import CodeWorkspace
w=CodeWorkspace(); tools=w.tools({'id':'localtest'},{'id':'n1'})
assert len(tools)==9
print('V0104_TOOL_BINDING_OK', [t.name for t in tools])
PY

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'BOUNDED_CODE_WORKSPACE_V0_10_4_DEPLOYED {"real_source_read":true,"secret_deny":true,"per_job_staging":true,"direct_production_write":false,"arbitrary_shell":false,"code_index_memory":true,"agent_tools":9,"supervisor_compact_index":true,"health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true
echo BOUNDED_CODE_WORKSPACE_V0_10_4_READY

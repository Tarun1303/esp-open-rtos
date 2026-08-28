#!/usr/bin/env bash
set -Eeuo pipefail
MAINT=/opt/fourth-law-agent/bridge-v13-maintenance.sh
cat > "$MAINT" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
python3 - <<'PY'
from pathlib import Path
p=Path("/usr/local/lib/fourthlaw-bridge/bridge.py")
s=p.read_text()
start=s.find("def apply_release(")
end=s.find("\ndef execute(", start)
if start < 0 or end < 0:
    raise SystemExit("apply_release boundaries not found")
new_func = "def apply_release(name, sha256):\n    if not re.fullmatch(r'[A-Za-z0-9._-]+\\.sh', name or ''):\n        return False,'invalid release name'\n    if not re.fullmatch(r'[a-fA-F0-9]{64}', sha256 or ''):\n        return False,'invalid sha256'\n    url=RAW_BASE+name\n    dispatch_dir=Path('/opt/fourth-law-agent/dispatched-releases')\n    dispatch_dir.mkdir(parents=True, exist_ok=True)\n    tmp=dispatch_dir/name\n    try:\n        urllib.request.urlretrieve(url,tmp)\n        got=hashlib.sha256(tmp.read_bytes()).hexdigest()\n        if got.lower()!=sha256.lower():\n            try: tmp.unlink()\n            except Exception: pass\n            return False,f'checksum mismatch {got}'\n        tmp.chmod(0o700)\n        unit='fourthlaw-release-'+str(int(time.time()))+'-'+hashlib.sha256(name.encode()).hexdigest()[:8]\n        p=subprocess.run(\n            ['systemd-run','--unit='+unit,'--collect','--no-block','/bin/bash',str(tmp)],\n            text=True,capture_output=True,timeout=30\n        )\n        return p.returncode==0,('dispatched '+unit+'\\n'+p.stdout+p.stderr)[-6000:]\n    except Exception as e:\n        return False,repr(e)\n"
s=s[:start]+new_func+s[end:]
s=s.replace("BRIDGE_ONLINE '+json.dumps({'version':'1.1'", "BRIDGE_ONLINE '+json.dumps({'version':'1.3'")
p.write_text(s)
PY
python3 -m py_compile /usr/local/lib/fourthlaw-bridge/bridge.py
systemctl restart fourthlaw-command-bridge.service
sleep 2
systemctl is-active --quiet fourthlaw-command-bridge.service
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'BRIDGE_UPGRADED {"version":"1.3","release_mode":"async-systemd-dispatch"}' >/dev/null 2>&1 || true
EOS
chmod 700 "$MAINT"
systemd-run --unit=fourthlaw-bridge-v13-maintenance --collect --no-block /bin/bash "$MAINT"
echo FOURTHLAW_BRIDGE_V1_3_MAINTENANCE_DISPATCHED

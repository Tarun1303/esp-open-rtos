#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="/opt/fourth-law-agent"
REPO="Tarun1303/factory"
ISSUE="7"
BRANCH_DIR="/usr/local/lib/fourthlaw-bridge"
SERVICE="fourthlaw-command-bridge"

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "GitHub CLI missing"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "GitHub CLI not authenticated"; exit 1; }
[[ -d "$PROJECT_DIR" ]] || { echo "Fourth Law project missing"; exit 1; }
[[ -f "$PROJECT_DIR/.env" ]] || { echo "Fourth Law env missing"; exit 1; }

mkdir -p "$BRANCH_DIR" /var/lib/fourthlaw-bridge
chmod 700 "$BRANCH_DIR" /var/lib/fourthlaw-bridge

cat > "$BRANCH_DIR/bridge.py" <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, time, urllib.request, urllib.error, hashlib, re
from pathlib import Path

REPO=os.environ.get('FOURTHLAW_BRIDGE_REPO','Tarun1303/factory')
ISSUE=os.environ.get('FOURTHLAW_BRIDGE_ISSUE','7')
PROJECT=Path('/opt/fourth-law-agent')
STATE=Path('/var/lib/fourthlaw-bridge/state.json')
PREFIX='CHATGPT_COMMAND '
ALLOWED_AUTHOR=os.environ.get('FOURTHLAW_BRIDGE_AUTHOR','Tarun1303')
RAW_BASE='https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases/'

def load_env():
    out={}
    for line in (PROJECT/'.env').read_text(errors='ignore').splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k,v=line.split('=',1); out[k.strip()]=v.strip()
    return out

def gh(*args):
    return subprocess.check_output(['gh',*args], text=True, stderr=subprocess.STDOUT)

def post(msg):
    subprocess.run(['gh','issue','comment',ISSUE,'--repo',REPO,'--body',msg], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def req(method,path,payload=None):
    env=load_env(); token=env.get('ADMIN_TOKEN','')
    data=None if payload is None else json.dumps(payload).encode()
    r=urllib.request.Request('http://127.0.0.1:8787'+path,data=data,method=method,headers={'Content-Type':'application/json','X-Admin-Token':token})
    try:
        with urllib.request.urlopen(r,timeout=180) as x:
            return x.status, x.read().decode(errors='replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors='replace')
    except Exception as e:
        return 0, repr(e)

def restart_agent():
    p=subprocess.run(['docker','compose','restart','agent'],cwd=PROJECT,text=True,capture_output=True,timeout=120)
    return p.returncode, (p.stdout+p.stderr)[-6000:]

def apply_release(name, sha256):
    if not re.fullmatch(r'[A-Za-z0-9._-]+\.sh', name or ''):
        return False,'invalid release name'
    if not re.fullmatch(r'[a-fA-F0-9]{64}', sha256 or ''):
        return False,'invalid sha256'
    url=RAW_BASE+name
    tmp=Path('/tmp')/('fourthlaw-release-'+name)
    try:
        urllib.request.urlretrieve(url,tmp)
        got=hashlib.sha256(tmp.read_bytes()).hexdigest()
        if got.lower()!=sha256.lower():
            return False,f'checksum mismatch got={got}'
        tmp.chmod(0o700)
        p=subprocess.run(['/bin/bash',str(tmp)],text=True,capture_output=True,timeout=900)
        return p.returncode==0,(p.stdout+p.stderr)[-10000:]
    except Exception as e:
        return False,repr(e)
    finally:
        try: tmp.unlink()
        except Exception: pass

def execute(cmd):
    typ=cmd.get('type')
    cid=str(cmd.get('id') or '')[:120]
    if typ=='health':
        s,b=req('GET','/health'); return cid, s==200, {'http':s,'body':b[:6000]}
    if typ=='mission':
        payload={'goal':str(cmd.get('goal','')),'context':str(cmd.get('context','')),'max_depth':int(cmd.get('max_depth',2))}
        s,b=req('POST','/task',payload); return cid, 200<=s<300, {'http':s,'body':b[:10000]}
    if typ=='continue':
        job=str(cmd.get('job_id',''))
        payload={'instruction':str(cmd.get('instruction',''))}
        s,b=req('POST',f'/task/{job}/continue',payload); return cid, 200<=s<300, {'http':s,'body':b[:10000]}
    if typ=='restart_agent':
        rc,b=restart_agent(); return cid, rc==0, {'rc':rc,'body':b}
    if typ=='decision':
        # v0.5+ endpoint; bounded no-op on older versions.
        decision_id=str(cmd.get('decision_id',''))
        payload={'answer':str(cmd.get('answer',''))}
        s,b=req('POST',f'/decisions/{decision_id}/answer',payload); return cid, 200<=s<300, {'http':s,'body':b[:10000]}
    if typ=='apply_release':
        ok,b=apply_release(str(cmd.get('name','')),str(cmd.get('sha256','')))
        return cid, ok, {'body':b}
    return cid,False,{'error':'unsupported command type'}

def state_load():
    try: return json.loads(STATE.read_text())
    except Exception: return {'last_comment_id':0}

def state_save(s):
    STATE.write_text(json.dumps(s)); os.chmod(STATE,0o600)

def main():
    post('BRIDGE_ONLINE '+json.dumps({'version':'1.0','accepted':['health','mission','continue','decision','restart_agent','apply_release']}))
    st=state_load()
    while True:
        try:
            raw=gh('api',f'repos/{REPO}/issues/{ISSUE}/comments','--paginate')
            rows=json.loads(raw)
            for row in rows:
                rid=int(row.get('id',0))
                if rid<=int(st.get('last_comment_id',0)): continue
                st['last_comment_id']=rid; state_save(st)
                body=row.get('body') or ''
                author=((row.get('user') or {}).get('login') or '')
                if author!=ALLOWED_AUTHOR or not body.startswith(PREFIX): continue
                try:
                    cmd=json.loads(body[len(PREFIX):].strip())
                    cid,ok,result=execute(cmd)
                    post('SERVER_ACK '+json.dumps({'id':cid,'ok':ok,'result':result},ensure_ascii=False))
                except Exception as e:
                    post('SERVER_ACK '+json.dumps({'id':'unknown','ok':False,'result':{'error':repr(e)}}))
        except Exception as e:
            # Never die on transient GitHub/network errors.
            try: Path('/var/log/fourthlaw-bridge.log').write_text(time.strftime('%F %T ') + repr(e) + '\n')
            except Exception: pass
        time.sleep(12)

if __name__=='__main__': main()
PY
chmod 700 "$BRANCH_DIR/bridge.py"

cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=Fourth Law GitHub Command Bridge
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
Environment=FOURTHLAW_BRIDGE_REPO=${REPO}
Environment=FOURTHLAW_BRIDGE_ISSUE=${ISSUE}
Environment=FOURTHLAW_BRIDGE_AUTHOR=Tarun1303
ExecStart=/usr/bin/python3 ${BRANCH_DIR}/bridge.py
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=/var/lib/fourthlaw-bridge /var/log /opt/fourth-law-agent /tmp
PrivateTmp=false

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ${SERVICE}.service
sleep 2
systemctl is-active --quiet ${SERVICE}.service

echo "FOURTHLAW_PERMANENT_BRIDGE_READY"

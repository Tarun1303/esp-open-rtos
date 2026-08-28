#!/usr/bin/env python3
import hashlib, json, os, re, subprocess, time, urllib.error, urllib.request
from pathlib import Path
REPO="Tarun1303/factory"; ISSUE="7"; PROJECT=Path("/opt/fourth-law-agent")
STATE=Path("/var/lib/fourthlaw-bridge/state.json"); LOG=Path("/var/log/fourthlaw-bridge.log")
PREFIX="CHATGPT_COMMAND "; RAW_BASE="https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases/"
ENV={**os.environ,"HOME":"/root","GH_CONFIG_DIR":"/root/.config/gh"}
def log(s):
    with LOG.open("a") as f:f.write(time.strftime("%F %T ")+s+"\n")
def gh(*args):return subprocess.check_output(["gh",*args],text=True,stderr=subprocess.STDOUT,env=ENV)
def post(body):
    p=subprocess.run(["gh","issue","comment",ISSUE,"--repo",REPO,"--body",body],text=True,capture_output=True,env=ENV)
    if p.returncode:log("POST_FAIL "+(p.stdout+p.stderr)[-2000:])
def load_env():
    out={}
    for line in (PROJECT/".env").read_text(errors="ignore").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k,v=line.split("=",1);out[k.strip()]=v.strip()
    return out
def req(method,path,payload=None):
    token=load_env().get("ADMIN_TOKEN","");data=None if payload is None else json.dumps(payload).encode()
    q=urllib.request.Request("http://127.0.0.1:8787"+path,data=data,method=method,headers={"Content-Type":"application/json","X-Admin-Token":token})
    try:
        with urllib.request.urlopen(q,timeout=240) as r:return r.status,r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:return e.code,e.read().decode(errors="replace")
    except Exception as e:return 0,repr(e)
def apply_release(name,sha):
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.sh",name or ""):return False,"invalid name"
    if not re.fullmatch(r"[a-fA-F0-9]{64}",sha or ""):return False,"invalid sha"
    tmp=Path("/tmp")/("flrel-"+name)
    try:
        urllib.request.urlretrieve(RAW_BASE+name,tmp);got=hashlib.sha256(tmp.read_bytes()).hexdigest()
        if got.lower()!=sha.lower():return False,f"checksum mismatch {got}"
        p=subprocess.run(["/bin/bash",str(tmp)],text=True,capture_output=True,timeout=1200)
        return p.returncode==0,(p.stdout+p.stderr)[-12000:]
    except Exception as e:return False,repr(e)
    finally:
        try:tmp.unlink()
        except Exception:pass
def execute(c):
    typ=c.get("type");cid=str(c.get("id") or "")[:120]
    if typ=="health":
        s,b=req("GET","/health");return cid,s==200,{"http":s,"body":b[:6000]}
    if typ=="state":
        s,b=req("GET","/control-state");return cid,s==200,{"http":s,"body":b[:12000]}
    if typ=="mission":
        p={"goal":str(c.get("goal","")),"context":str(c.get("context","")),"max_depth":int(c.get("max_depth",3))}
        s,b=req("POST","/task",p);return cid,200<=s<300,{"http":s,"body":b[:12000]}
    if typ=="continue":
        p={"instruction":str(c.get("instruction",""))};s,b=req("POST",f"/task/{c.get('job_id','')}/continue",p);return cid,200<=s<300,{"http":s,"body":b[:12000]}
    if typ=="decision":
        p={"answer":str(c.get("answer",""))};s,b=req("POST",f"/decisions/{c.get('decision_id','')}/answer",p);return cid,200<=s<300,{"http":s,"body":b[:12000]}
    if typ=="restart_agent":
        p=subprocess.run(["docker","compose","restart","agent"],cwd=PROJECT,text=True,capture_output=True,timeout=180);return cid,p.returncode==0,{"rc":p.returncode,"body":(p.stdout+p.stderr)[-6000:]}
    if typ=="apply_release":
        ok,b=apply_release(str(c.get("name","")),str(c.get("sha256","")));return cid,ok,{"body":b}
    return cid,False,{"error":"unsupported command type"}
def load_state():
    try:return json.loads(STATE.read_text())
    except Exception:return {"last_comment_id":0}
def save_state(s):STATE.write_text(json.dumps(s));os.chmod(STATE,0o600)
def fetch_comments():return json.loads(gh("api",f"repos/{REPO}/issues/{ISSUE}/comments?per_page=100"))
def main():
    log("START");post("BRIDGE_ONLINE "+json.dumps({"version":"1.1","accepted":["health","state","mission","continue","decision","restart_agent","apply_release"]}))
    st=load_state()
    while True:
        try:
            for row in fetch_comments():
                rid=int(row.get("id",0))
                if rid<=int(st.get("last_comment_id",0)):continue
                st["last_comment_id"]=rid;save_state(st);body=row.get("body") or "";author=((row.get("user") or {}).get("login") or "")
                if author!="Tarun1303" or not body.startswith(PREFIX):continue
                try:
                    cmd=json.loads(body[len(PREFIX):].strip());cid,ok,res=execute(cmd);post("SERVER_ACK "+json.dumps({"id":cid,"ok":ok,"result":res},ensure_ascii=False))
                except Exception as e:log("EXEC_ERROR "+repr(e));post("SERVER_ACK "+json.dumps({"id":"unknown","ok":False,"result":{"error":repr(e)}}))
        except Exception as e:log("LOOP_ERROR "+repr(e))
        time.sleep(10)
if __name__=="__main__":main()

#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
MAIN="$PROJECT/app/main.py"
CR="$PROJECT/app/control_room.py"
HTML="$PROJECT/app/static/control_room.html"
STAMP="$(date +%s)"
BACKUP="$PROJECT/backups/v0.10.2-human-intervention-$STAMP"
mkdir -p "$BACKUP"
cp "$MAIN" "$BACKUP/main.py"
cp "$CR" "$BACKUP/control_room.py"
cp "$HTML" "$BACKUP/control_room.html"
rollback(){
  set +e
  cp "$BACKUP/main.py" "$MAIN"
  cp "$BACKUP/control_room.py" "$CR"
  cp "$BACKUP/control_room.html" "$HTML"
  cd "$PROJECT"
  docker compose build agent >/tmp/fl0102-rb-build.log 2>&1 || true
  docker compose up -d --force-recreate agent >/tmp/fl0102-rb-up.log 2>&1 || true
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'HUMAN_INTERVENTION_V0_10_2_ROLLED_BACK' >/dev/null 2>&1 || true
  exit 1
}
trap rollback ERR

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/control_room.py')
s=p.read_text()

# Request model.
anchor='''class TaskSubmit(BaseModel):\n    goal: str = Field(min_length=3, max_length=16000)\n    context: str = Field(default='', max_length=50000)\n'''
insert=anchor+'''\n\nclass InterventionAnswer(BaseModel):\n    answer: str = Field(min_length=1, max_length=12000)\n'''
if 'class InterventionAnswer(BaseModel):' not in s:
    if anchor not in s: raise SystemExit('TaskSubmit anchor missing')
    s=s.replace(anchor,insert,1)

# Atomic same-job decision writer. No admin token is exposed to browser and no new job is created.
anchor='''def _stage(status: str) -> str:\n'''
helper='''def _answer_pending_decision(job_id: str, decision_id: str, answer: str) -> dict[str, Any]:\n    clean = str(answer or '').strip()\n    if not clean:\n        raise HTTPException(status_code=422, detail='Decision answer is required')\n    p = JOBS_DIR / f'{job_id}.json'\n    job = _read_job(job_id)\n    target = None\n    for d in job.get('decisions', []):\n        if str(d.get('id', '')) == str(decision_id):\n            target = d\n            break\n    if target is None:\n        raise HTTPException(status_code=404, detail='Decision not found in this mission')\n    if str(target.get('status', '')) != 'pending':\n        raise HTTPException(status_code=409, detail='Decision is no longer pending')\n    target['answer'] = clean\n    target['status'] = 'answered'\n    target['answered_at'] = time.time()\n    job.setdefault('events', []).append({\n        'ts': time.time(), 'type': 'human_decision_answered',\n        'summary': 'Human intervention received; same mission may resume.',\n        'node_id': target.get('node_id'), 'decision_id': target.get('id'),\n    })\n    tmp = p.with_suffix('.json.tmp')\n    tmp.write_text(json.dumps(job, ensure_ascii=False, indent=2))\n    tmp.replace(p)\n    return {'ok': True, 'job_id': job_id, 'decision_id': decision_id, 'status': 'answered'}\n\n\n'''
if 'def _answer_pending_decision(' not in s:
    if anchor not in s: raise SystemExit('stage anchor missing')
    s=s.replace(anchor,helper+anchor,1)

# Expose pending count in summaries so the browser can find the waiting mission cheaply.
old="""        'agents_created': job.get('agents_created', 1), 'created_at': job.get('created_at'),\n        'updated_at': p.stat().st_mtime, 'root_name': root.get('name', 'Supervisor'),\n"""
new="""        'agents_created': job.get('agents_created', 1), 'created_at': job.get('created_at'),\n        'updated_at': p.stat().st_mtime, 'root_name': root.get('name', 'Supervisor'),\n        'pending_decisions': sum(1 for d in job.get('decisions', []) if str(d.get('status', '')) == 'pending'),\n"""
if "'pending_decisions': sum(1 for d in job.get('decisions'" not in s:
    if old not in s: raise SystemExit('summary anchor missing')
    s=s.replace(old,new,1)

# Session-authenticated decision endpoint. It writes only a decision belonging to this exact job.
anchor="""@router.get('/control-room/api/stream/{job_id}')\n"""
route="""@router.post('/control-room/api/jobs/{job_id}/interventions/{decision_id}')\nasync def answer_intervention(job_id: str, decision_id: str, req: InterventionAnswer, fl_session: str | None = Cookie(default=None)):\n    _auth(fl_session)\n    return _answer_pending_decision(job_id, decision_id, req.answer)\n\n\n"""
if "interventions/{decision_id}" not in s:
    if anchor not in s: raise SystemExit('stream route anchor missing')
    s=s.replace(anchor,route+anchor,1)

# Safe browser/session version marker only.
s=s.replace("'version': '0.9.8'", "'version': '0.10.2'")
p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/main.py')
s=p.read_text()
s=s.replace('"version":"0.9.8"','"version":"0.10.2"')
s=s.replace('"version": "0.9.8"','"version": "0.10.2"')
s=s.replace('version="0.9.8"','version="0.10.2"')
marker='truthful-orchestration-v0.9.8'
if 'human-intervention-v0.10.2' not in s:
    if marker not in s: raise SystemExit('architecture marker missing')
    s=s.replace(marker,marker+'+human-intervention-v0.10.2',1)
p.write_text(s)
PY

python3 - <<'PY'
from pathlib import Path
p=Path('/opt/fourth-law-agent/app/static/control_room.html')
s=p.read_text()
if 'fl-human-intervention-v0102' not in s:
    css=r'''
<style id="fl-human-intervention-v0102">
#flHumanIntervention{position:fixed;right:20px;bottom:20px;width:min(420px,calc(100vw - 32px));z-index:9999;background:rgba(10,14,16,.97);border:1px solid rgba(232,184,82,.34);box-shadow:0 18px 55px rgba(0,0,0,.42);border-radius:14px;padding:14px 14px 12px;color:#e7ebe8;font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;display:none}
#flHumanIntervention[data-open="1"]{display:block}
.flhi-head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:8px}.flhi-kicker{font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:#e5b65b}.flhi-state{font-size:11px;color:#aab3af}.flhi-question{font-size:14px;line-height:1.4;font-weight:600;margin:4px 0 6px}.flhi-reason{font-size:12px;line-height:1.45;color:#98a39e;margin-bottom:9px}.flhi-text{width:100%;box-sizing:border-box;min-height:78px;max-height:180px;resize:vertical;border-radius:9px;border:1px solid #303a37;background:#111715;color:#eef2ef;padding:10px 11px;font:13px/1.45 inherit;outline:none}.flhi-text:focus{border-color:#b98c3e;box-shadow:0 0 0 2px rgba(185,140,62,.13)}.flhi-actions{display:flex;justify-content:flex-end;align-items:center;gap:10px;margin-top:9px}.flhi-msg{margin-right:auto;font-size:11px;color:#96a09c}.flhi-send{border:1px solid rgba(229,182,91,.48);background:#1d1910;color:#f2d18d;border-radius:8px;padding:8px 12px;font-size:12px;cursor:pointer}.flhi-send:disabled{opacity:.45;cursor:wait}@media(max-width:700px){#flHumanIntervention{right:12px;bottom:12px;width:calc(100vw - 24px)}}
</style>
'''
    panel=r'''
<section id="flHumanIntervention" aria-live="polite" aria-label="Human intervention required">
  <div class="flhi-head"><div class="flhi-kicker">Human input required</div><div class="flhi-state" id="flhiState">Waiting</div></div>
  <div class="flhi-question" id="flhiQuestion"></div>
  <div class="flhi-reason" id="flhiReason"></div>
  <textarea class="flhi-text" id="flhiAnswer" maxlength="12000" placeholder="Give the Supervisor your decision or requested information…"></textarea>
  <div class="flhi-actions"><span class="flhi-msg" id="flhiMsg"></span><button class="flhi-send" id="flhiSend" type="button">Send to mission</button></div>
</section>
<script>
(()=>{
 const panel=document.getElementById('flHumanIntervention'), q=document.getElementById('flhiQuestion'), reason=document.getElementById('flhiReason'), ans=document.getElementById('flhiAnswer'), send=document.getElementById('flhiSend'), msg=document.getElementById('flhiMsg'), state=document.getElementById('flhiState');
 let current=null,busy=false,lastKey='';
 async function jsonFetch(url,opt){const r=await fetch(url,opt);let data={};try{data=await r.json()}catch(e){}if(!r.ok)throw new Error(data.detail||('HTTP '+r.status));return data}
 async function poll(){
  if(busy)return;
  try{
   const list=await jsonFetch('/control-room/api/jobs');
   const summaries=(list.jobs||[]); const hit=summaries.find(x=>Number(x.pending_decisions||0)>0);
   if(!hit){current=null;panel.dataset.open='0';return}
   const job=await jsonFetch('/control-room/api/jobs/'+encodeURIComponent(hit.id));
   const d=(job.decisions||[]).find(x=>x.status==='pending');
   if(!d){panel.dataset.open='0';current=null;return}
   const key=hit.id+':'+d.id;
   current={jobId:hit.id,decisionId:d.id};
   q.textContent=d.question||'The Supervisor needs your decision.';
   reason.textContent=d.reason||''; state.textContent='Mission · '+(job.stage||'Waiting'); panel.dataset.open='1';
   if(key!==lastKey){ans.value='';msg.textContent='';lastKey=key;setTimeout(()=>ans.focus(),80)}
  }catch(e){ /* keep current UI stable on transient disconnect */ }
 }
 async function submit(){
  if(!current||busy)return; const text=ans.value.trim(); if(!text){msg.textContent='Enter your decision first.';ans.focus();return}
  busy=true;send.disabled=true;msg.textContent='Sending…';
  try{
   await jsonFetch('/control-room/api/jobs/'+encodeURIComponent(current.jobId)+'/interventions/'+encodeURIComponent(current.decisionId),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({answer:text})});
   msg.textContent='Received by the same mission.'; state.textContent='Answered'; setTimeout(()=>{panel.dataset.open='0';current=null;poll()},650)
  }catch(e){msg.textContent=e.message||'Could not send.'} finally{busy=false;send.disabled=false}
 }
 send.addEventListener('click',submit); ans.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key==='Enter')submit()});
 poll();setInterval(poll,1100);
})();
</script>
'''
    if '</head>' not in s or '</body>' not in s: raise SystemExit('HTML anchors missing')
    s=s.replace('</head>',css+'</head>',1)
    s=s.replace('</body>',panel+'</body>',1)
p.write_text(s)
PY

python3 -m py_compile "$MAIN" "$CR"
grep -q 'interventions/{decision_id}' "$CR"
grep -q 'fl-human-intervention-v0102' "$HTML"

cd "$PROJECT"
docker compose build agent >/tmp/fl0102-build.log 2>&1
docker compose up -d --force-recreate agent >/tmp/fl0102-up.log 2>&1
ok=0
for i in $(seq 1 75); do
  if body=$(curl -fsS http://127.0.0.1:8787/health 2>/dev/null); then
    if printf '%s' "$body" | grep -q '"version":"0.10.2"'; then ok=1; break; fi
  fi
  sleep 1
done
[[ "$ok" = 1 ]]
curl -fsS http://127.0.0.1:8787/control-room >/tmp/fl0102-ui.html
grep -q 'fl-human-intervention-v0102' /tmp/fl0102-ui.html

# Free/local functional regression: synthetic same-job decision is answered atomically.
docker compose exec -T agent python - <<'PY'
import json,time
from pathlib import Path
from app.control_room import _answer_pending_decision
p=Path('/data/jobs/__fl_hi_test__.json')
p.write_text(json.dumps({'id':'__fl_hi_test__','status':'waiting_human','root':{},'decisions':[{'id':'d1','node_id':'n1','question':'test','reason':'test','status':'pending','answer':''}],'events':[]}))
r=_answer_pending_decision('__fl_hi_test__','d1','approved test')
j=json.loads(p.read_text())
assert r['status']=='answered'
assert j['decisions'][0]['status']=='answered'
assert j['decisions'][0]['answer']=='approved test'
assert j['events'][-1]['type']=='human_decision_answered'
p.unlink()
print('HUMAN_INTERVENTION_LOCAL_TEST_OK')
PY

trap - ERR
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body 'HUMAN_INTERVENTION_V0_10_2_DEPLOYED {"same_job_decision":true,"browser_admin_token":false,"pending_decision_live_panel":true,"textarea":true,"session_auth":true,"atomic_write":true,"local_functional_test":"ok","health":"ok","control_room":"ok"}' >/dev/null 2>&1 || true
echo HUMAN_INTERVENTION_V0_10_2_READY

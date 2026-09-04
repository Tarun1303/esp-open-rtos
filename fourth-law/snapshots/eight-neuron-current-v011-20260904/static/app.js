const $ = (id) => document.getElementById(id);
let inputBits = Array(8).fill(0);
let lastState = null;
let toastTimer = null;

function toast(message, bad=false){
  const el=$('toast'); el.textContent=message; el.style.background=bad?'#ffced3':'#eaf6ff';
  el.classList.add('show'); clearTimeout(toastTimer); toastTimer=setTimeout(()=>el.classList.remove('show'),2300);
}
async function api(path, method='GET', body=null){
  const response=await fetch(path,{method,headers:{'Content-Type':'application/json'},body:body?JSON.stringify(body):null});
  const data=await response.json(); if(!response.ok||data.ok===false) throw new Error(data.error||`HTTP ${response.status}`); return data;
}
function buildBits(){
  $('inputBits').innerHTML=''; $('outputBits').innerHTML='';
  for(let i=0;i<8;i++){
    const b=document.createElement('button'); b.className='bit'; b.textContent='0';
    b.onclick=()=>{inputBits[i]=inputBits[i]?0:1;b.textContent=String(inputBits[i]);b.classList.toggle('on',!!inputBits[i]);};
    $('inputBits').appendChild(b);
    const o=document.createElement('div'); o.className='bit'; o.textContent='0'; o.dataset.index=i; $('outputBits').appendChild(o);
  }
}
function lineColor(area){
  const t=Math.max(0,Math.min(1,(area-.45)/1.8));
  const hue=205-(165*t); return `hsl(${hue} 88% ${48+12*t}%)`;
}
function renderNetwork(state){
  const svg=$('network'); const W=900,H=580,pad=70;
  const map=(n)=>({x:pad+n.x*(W-2*pad),y:pad+n.y*(H-2*pad)});
  let html='<defs><filter id="glow"><feGaussianBlur stdDeviation="4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>';
  for(const e of state.edges){
    const a=map(state.nodes[e.a]),b=map(state.nodes[e.b]); const width=1.1+e.area_mean*2.2;
    const flow=Math.max(e.flow_ab,e.flow_ba); const opacity=.28+Math.min(.65,e.area_mean/3);
    html+=`<line x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}" stroke="${lineColor(e.area_mean)}" stroke-width="${width}" opacity="${opacity}" stroke-linecap="round"/>`;
    if(flow>.01){
      const dir=e.flow_ab>=e.flow_ba?1:-1; const phase=(state.sim_time*1.9)%1; const t=dir>0?phase:1-phase;
      const x=a.x+(b.x-a.x)*t,y=a.y+(b.y-a.y)*t,r=3+Math.min(5,flow*2);
      html+=`<circle cx="${x}" cy="${y}" r="${r}" fill="#fff" filter="url(#glow)" opacity=".95"/>`;
    }
  }
  for(const n of state.nodes){
    const p=map(n), ratio=Math.min(1.2,n.energy/Math.max(n.threshold,.01));
    const color=n.spiking?'#ffffff':ratio>=1?'#ffb342':`hsl(${205-40*ratio} 88% ${42+15*ratio}%)`;
    const glow=n.spiking?18:4+ratio*9;
    html+=`<g><circle cx="${p.x}" cy="${p.y}" r="34" fill="#07111d" stroke="${color}" stroke-width="${2+ratio*2}" style="filter:drop-shadow(0 0 ${glow}px ${color})"/>`;
    html+=`<circle cx="${p.x}" cy="${p.y}" r="${10+ratio*10}" fill="${color}" opacity="${.35+.45*ratio}"/>`;
    html+=`<text x="${p.x}" y="${p.y+4}" fill="#fff" text-anchor="middle" font-size="13" font-weight="800">N${n.id}</text>`;
    html+=`<text x="${p.x}" y="${p.y+53}" fill="#7f91a8" text-anchor="middle" font-size="10">E ${n.energy.toFixed(2)} / Θ ${n.threshold.toFixed(2)}</text></g>`;
  }
  svg.innerHTML=html;
}
function renderRaster(state){
  const c=$('raster'),ctx=c.getContext('2d'),w=c.width,h=c.height; ctx.clearRect(0,0,w,h); ctx.fillStyle='#070b12';ctx.fillRect(0,0,w,h);
  ctx.strokeStyle='#182437';ctx.lineWidth=1;ctx.font='14px ui-monospace';ctx.fillStyle='#718198';
  for(let i=0;i<8;i++){const y=22+i*24;ctx.beginPath();ctx.moveTo(40,y);ctx.lineTo(w-12,y);ctx.stroke();ctx.fillText(`N${i}`,8,y+4);}
  const start=state.sim_time-30;
  for(const s of state.spikes){if(s.time<start)continue;const x=40+(s.time-start)/30*(w-55),y=22+s.neuron*24;ctx.strokeStyle='#61e7ff';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(x,y-7);ctx.lineTo(x,y+7);ctx.stroke();}
}
function renderScores(output){
  const ranked=(output.ranking||Object.entries(output.scores||{}).sort((a,b)=>b[1]-a[1])).slice(0,5);
  $('scores').innerHTML=ranked.map(([s,v])=>`<div class="score-row"><b>${s}</b><div class="score-track"><div class="score-fill" style="width:${Math.max(0,Math.min(100,v*100))}%"></div></div><span>${Number(v).toFixed(2)}</span></div>`).join('');
}
function render(state){
  lastState=state; $('runDot').classList.add('live');$('runText').textContent='Runtime online';
  const m=state.metrics,rt=state.runtime,out=state.output||{};
  $('activityPill').textContent=m.persistent_activity?'Persistent firing detected':'Temporarily silent';
  $('activityPill').className=`pill ${m.persistent_activity?'active':'silent'}`;
  $('simTime').textContent=`${state.sim_time.toFixed(2)} s`; $('cycles').textContent=rt.training_cycles; $('mode').textContent=rt.training?'conditioning':'free run';
  $('prediction').textContent=out.predicted??'—'; $('confidence').textContent=`confidence gap ${Number(out.confidence||0).toFixed(3)}`;
  [...$('outputBits').children].forEach((el,i)=>{const bit=(out.bits||[])[i]||0;el.textContent=bit;el.classList.toggle('on',!!bit);});
  $('spikeRate').textContent=`${m.spike_rate_hz.toFixed(2)} Hz`; $('lastSpike').textContent=m.last_spike_age_s==null?'—':`${m.last_spike_age_s.toFixed(2)} s ago`;
  $('distinct').textContent=`${m.distinct_neurons_in_window} / 8`; $('entropy').textContent=`${m.selection_entropy_bits.toFixed(2)} bits`;
  $('storedEnergy').textContent=m.stored_energy.toFixed(3); $('dissipated').textContent=m.dissipated_energy.toFixed(2);
  renderNetwork(state);renderRaster(state);renderScores(out);
}
async function refresh(){try{render(await api('/api/state'));}catch(e){$('runDot').classList.remove('live');$('runText').textContent='Disconnected';}}
async function action(fn){try{await fn();await refresh();}catch(e){toast(e.message,true);}}

$('train').onclick=()=>action(async()=>{await api('/api/train/start','POST',{expression:$('expression').value,target:$('target').value});toast('Continuous conditioning started');});
$('stop').onclick=()=>action(async()=>{const r=await api('/api/train/stop','POST',{});toast(`Stopped after ${r.cycles} cycles`);});
$('recall').onclick=()=>action(async()=>{toast('Running time-locked recall probes');const r=await api('/api/recall','POST',{expression:$('expression').value,trials:5,controlled:true});toast(`Recall output: ${r.result.predicted??'no firing'}`);});
$('injectBits').onclick=()=>action(async()=>{await api('/api/inject','POST',{bits:inputBits});toast(`Injected ${inputBits.join('')}`);});
$('resetDynamic').onclick=()=>action(async()=>{await api('/api/reset/dynamic','POST',{});toast('Fast state cleared; memory retained');});
$('resetMemory').onclick=()=>action(async()=>{if(confirm('Reset every learned path to baseline?')){await api('/api/reset/memory','POST',{});toast('Structural memory reset');}});
$('speed').oninput=async(e)=>{$('speedValue').textContent=`${e.target.value}×`;await api('/api/runtime','POST',{speed:Number(e.target.value)});};
$('rate').oninput=async(e)=>{$('rateValue').textContent=e.target.value;await api('/api/runtime','POST',{background_rate:Number(e.target.value)});};

buildBits();refresh();setInterval(refresh,220);

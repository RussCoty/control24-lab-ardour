import {geometry, upper, lower, panelAt, faderLocation, path as projectedPath} from './geometry.mjs';
const $ = s => document.querySelector(s);
const esc = x => String(x ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let state, catalog, surfaceLayout, controls, selected = 'fader:0', channel = 0, cursor = 0, events = [], paused = false, editing, draft;
let hotspots = true, calibrating = false, calibration = {}, commandQueue = Promise.resolve(), connected = false;
try { calibration = JSON.parse(localStorage.getItem('control24-calibration') || '{}'); } catch {}
const points = new Map();
const svgNS = 'http://www.w3.org/2000/svg';
function error(e) { $('#error').hidden = false; $('#error').textContent = e.message || e; }
function post(path, data) {
  const run = async () => {
    const r = await fetch('/api/' + path, {method:'POST', headers:{'Content-Type':'application/json','X-Control24-Token':state.token}, body:JSON.stringify(data)});
    const result = await r.json();
    if (!r.ok) throw Error(result.error || 'Local bridge request failed');
    $('#error').hidden = true;
    return result;
  };
  const result = commandQueue.then(run);
  commandQueue = result.catch(error);
  return result;
}
function send(control, value, feedback = false) { return post('event', {control, value, feedback}).catch(error); }
function download(name, data) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], {type:'application/json'}));
  const a = document.createElement('a'); a.href = url; a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function tab(name) {
  document.querySelectorAll('.tab').forEach(e => e.classList.toggle('active',e.id === name));
  document.querySelectorAll('[data-tab]').forEach(e => e.classList.toggle('active',e.dataset.tab === name));
}
function activeProfile() { return state.profiles.find(p => p.id === state.active); }
function select(id) {
  if (!controls.has(id)) return;
  const previousChannel = channel;
  selected = id;
  const c = controls.get(id);
  if (c.channel) channel = c.channel - 1;
  renderInspector(); if (channel !== previousChannel || !$('#channel-buttons').children.length) renderFocus(); updateSurface();
}
function detail(name, value) { return `<div><dt>${esc(name)}</dt><dd>${esc(value)}</dd></div>`; }
function renderInspector() {
  const c = controls.get(selected), mapping = activeProfile().mappings[selected];
  $('#inspect-name').textContent = c.name;
  $('#inspect-kind').textContent = c.kind.toUpperCase();
  $('#inspect-details').innerHTML = detail('Control ID', c.id) + detail('Address', c.section !== undefined ? `sec ${c.section.toString(16)} · note ${c.note.toString(16)}` : c.channel ? `Channel ${c.channel}` : 'See evidence') + detail('Evidence', c.evidence) + detail('Hardware verified', 'No') + detail('Pressed', state.pressed[selected] ? 'Yes' : 'No') + detail('Feedback LED', state.leds[selected] === undefined ? 'Unknown' : state.leds[selected] ? 'On' : 'Off');
  $('#inspect-input').innerHTML = '';
  const container = $('#inspect-input');
  if (['button','touch'].includes(c.kind)) {
    const b = document.createElement('button'); b.textContent = 'Hold to press'; bindPress(b, selected); container.append(b);
  } else if (['fader','encoder'].includes(c.kind)) {
    const b = document.createElement('button'); b.textContent = c.kind === 'fader' ? 'Select channel below the surface' : 'Send +1 detent';
    b.onclick = () => c.kind === 'fader' ? $('#focus-fader').focus() : send(c.id,1); container.append(b);
  } else container.textContent = c.kind === 'analog' ? 'Analog inventory candidate; Ethernet observability is not established.' : 'Output / feedback control';
  const feedback = $('#inspect-feedback'); feedback.innerHTML = '';
  if (c.led || ['fader','ring','scribble','counter'].includes(c.kind)) {
    const input = document.createElement('input'); input.id = 'feedback-value';
    if (c.led) {input.type='checkbox'; input.checked=!!state.leds[selected]; input.setAttribute('aria-label','Feedback LED on');}
    else if (c.kind === 'fader' || c.kind === 'ring') {input.type='number'; input.min=0; input.max=c.kind==='fader'?16383:14; input.value=state.values[selected]??0; input.setAttribute('aria-label','Feedback value');}
    else {input.value=c.kind==='counter'?'01020304':state.values[selected]??'CH01'; input.maxLength=c.kind==='counter'?8:4; input.setAttribute('aria-label','Display text');}
    const b = document.createElement('button'); b.textContent = 'Preview encoding & feedback';
    b.onclick = async () => {
      try {
        const value = c.led ? input.checked : ['fader','ring'].includes(c.kind) ? Number(input.value) : input.value;
        const result = await post('preview',{control:c.id,value});
        $('#native-preview').textContent = `NATIVE  ${result.native}\n\nFRAME  ${result.frame}\n\nPreview only · no hardware transmission`;
        await send(c.id,value,true);
      } catch(e) {error(e);}
    };
    feedback.append(input,b);
  } else feedback.textContent = 'Encoding not implemented for this control.';
  $('#native-preview').textContent = 'No hardware command has been sent.';
  $('#inspect-mapping').textContent = mapping ? `${mapping.path} ${JSON.stringify(mapping.args)}` : 'Unmapped · input is still logged';
  $('#inspect-source').href = c.source || 'https://github.com/Davitekk/C24-Engine-Renewed';
}
function bindPress(element, id) {
  let held = false;
  const down = () => { if (!held) {held=true; if(selected!==id)select(id); send(id,true);} };
  const up = () => { if (held) {held=false; send(id,false);} };
  element.addEventListener('pointerdown', e => {if(e.button !== 0) return; e.preventDefault(); element.setPointerCapture(e.pointerId); down();});
  element.addEventListener('pointerup',up); element.addEventListener('pointercancel',up); element.addEventListener('lostpointercapture',up);
  element.addEventListener('keydown',e=>{if([' ','Enter'].includes(e.key)){e.preventDefault();down();}});
  element.addEventListener('keyup',e=>{if([' ','Enter'].includes(e.key)){e.preventDefault();up();}});
  window.addEventListener('blur',up);
  window.addEventListener('pointerup',up);
  window.addEventListener('pointercancel',up);
}
function svg(tag, attrs={}, parent) {
  const el=document.createElementNS(svgNS,tag); Object.entries(attrs).forEach(([k,v])=>el.setAttribute(k,v)); if(parent)parent.append(el); return el;
}
function panelDisplay(panel,x,y,width,height,textAttrs) {
  const [u,v]=panel.inverse(x,y),right=panel.project(u+1/panel.physicalWidth,v),down=panel.project(u,v+1/panel.physicalHeight);
  const mask=svg('path',{d:projectedPath(panel.outline(u,v,width,height)),fill:'#152017','pointer-events':'none'},$('#overlay'));
  const transform=`matrix(${right[0]-x} ${right[1]-y} ${down[0]-x} ${down[1]-y} ${x} ${y})`;
  const text=svg('text',{x:0,y:2,'text-anchor':'middle',transform,'pointer-events':'none',...textAttrs},$('#overlay'));
  return text;
}
function hotspot(id, x,y, w=10,h=8,shape='rect') {
  if (!controls.has(id)) return;
  const saved = calibration[id];
  if (Array.isArray(saved) && saved.length===2 && saved.every(Number.isFinite)) [x,y]=saved;
  points.set(id,{x,y,w,h,shape});
  const panel=panelAt(x,y),[u,v]=panel.inverse(x,y);
  const shapePath=projectedPath(panel.outline(u,v,w,h,shape==='circle'),[x,y]);
  const g=svg('g',{'class':'hotspot','data-control':id,tabindex:0,role:'button','aria-label':controls.get(id).name,transform:`translate(${x} ${y})`},$('#overlay'));
  svg('title',{},g).textContent=controls.get(id).name;
  svg('path',{d:shapePath,class:'hit'},g);
  const c=controls.get(id);
  if(c.led)svg('path',{d:projectedPath(panel.outline(u+w/panel.physicalWidth/2,v-(h/2+2)/panel.physicalHeight,2.8,2.8,true),[x,y]),class:'led-dot'},g);
  if (c.kind==='button'||c.kind==='touch') bindPress(g,id);
  else {
    g.addEventListener('click',()=>select(id));
    g.addEventListener('keydown',e=>{if(e.key==='Enter')select(id);});
    if(c.kind==='encoder')g.addEventListener('wheel',e=>{e.preventDefault();select(id);send(id,e.deltaY<0?1:-1);},{passive:false});
  }
  return g;
}
function buildSurface() {
  const overlay=$('#overlay'); overlay.innerHTML=''; points.clear();
  const defs=svg('defs',{},overlay), grad=svg('linearGradient',{id:'cap',x1:0,y1:0,x2:0,y2:1},defs);
  svg('stop',{offset:'0%','stop-color':'#d7dad1'},grad);svg('stop',{offset:'45%','stop-color':'#7f8b7b'},grad);svg('stop',{offset:'55%','stop-color':'#e5e8de'},grad);svg('stop',{offset:'100%','stop-color':'#87917e'},grad);
  for(let ch=0;ch<24;ch++) {
    const x=181+20.4*ch;
    // A photo-backed lane masks the photographed cap; its overlay follows normalized position.
    const [u,topV]=faderLocation(ch,16383),[,bottomV]=faderLocation(ch,0);
    const top=lower.project(u,topV),bottom=lower.project(u,bottomV),middle=lower.project(u,(topV+bottomV)/2);
    const laneHeight=(bottomV-topV)*lower.physicalHeight;
    svg('path',{d:projectedPath(lower.outline(u,(topV+bottomV)/2,10,laneHeight+9)),fill:'#777a70'},overlay);
    svg('path',{d:`M ${top.join(' ')} L ${bottom.join(' ')}`,stroke:'#111711','stroke-width':1.6},overlay);
    const f=hotspot(`fader:${ch}`,middle[0],middle[1],16,laneHeight+12);
    const cap=svg('path',{class:'fader-cap','data-fader-cap':ch},overlay);
    const drag=(e)=>{
      const pt=overlay.createSVGPoint();pt.x=e.clientX;pt.y=e.clientY;
      const p=pt.matrixTransform(overlay.getScreenCTM().inverse());
      const [,v]=lower.inverse(p.x,p.y);
      send(`fader:${ch}`,Math.round(Math.max(0,Math.min(1,(bottomV-v)/(bottomV-topV)))*16383));
    };
    let dragging=false;
    f.addEventListener('pointerdown',e=>{if(calibrating)return;e.preventDefault();select(`fader:${ch}`);dragging=true;f.setPointerCapture(e.pointerId);send(`button:${ch}:9`,true);drag(e);});
    f.addEventListener('pointermove',e=>{if(dragging)drag(e);});
    const release=()=>{if(dragging){dragging=false;send(`button:${ch}:9`,false);}};
    f.addEventListener('pointerup',release);f.addEventListener('pointercancel',release);f.addEventListener('lostpointercapture',release);window.addEventListener('blur',release);
    cap.style.pointerEvents='none';
    panelDisplay(upper,x,192,18,10,{class:'scribble-text','data-scribble':ch}).textContent='----';
    const [ku,kv]=upper.inverse(x,207);const ring=svg('path',{d:projectedPath(upper.outline(ku,kv,18,18,true)),fill:'none',stroke:'#263522','stroke-width':2.3,'data-ring':ch},overlay);ring.style.pointerEvents='none';
    const label=svg('text',{x:bottom[0],y:bottom[1]+13,'text-anchor':'middle',fill:'#acb69e','font-size':6,'font-family':'monospace'},overlay); label.textContent=String(ch+1).padStart(2,'0');
  }
  for (const region of surfaceLayout.regions) {
    const panel=region.plane==='upper'?upper:lower;
    const [x,y]=panel.project(region.u,region.v);
    hotspot(region.id,x,y,region.width*panel.physicalWidth,region.height*panel.physicalHeight,region.shape);
  }
  panelDisplay(upper,799,54,94,20,{class:'counter-text',id:'counter-text',y:5}).textContent='--------';
  updateSurface();
}
function updateSurface() {
  if(!state)return;
  document.querySelectorAll('#overlay [data-control]').forEach(g=>{
    const id=g.dataset.control;
    g.classList.toggle('selected',id===selected);g.classList.toggle('down',!!state.pressed[id]);g.classList.toggle('lit',!!state.leds[id]);
  });
  for(let ch=0;ch<24;ch++) {
    const [u,v]=faderLocation(ch,state.values[`fader:${ch}`]??0);
    const cap=document.querySelector(`[data-fader-cap="${ch}"]`);if(cap)cap.setAttribute('d',projectedPath(lower.outline(u,v,11,12)));
    const s=document.querySelector(`[data-scribble="${ch}"]`);if(s)s.textContent=state.values[`scribble:${ch}`]??'----';
    const ring=document.querySelector(`[data-ring="${ch}"]`);if(ring){const value=state.values[`ring:${ch}`];ring.setAttribute('stroke',value===undefined?'#263522':'#efb76b');ring.setAttribute('stroke-dasharray',value===undefined?'0 60':`${(value+1)*3.5} 100`);}
  }
  if($('#counter-text'))$('#counter-text').textContent=state.values.counter??'--------';
  $('#channel-title').textContent=`Channel ${String(channel+1).padStart(2,'0')}`;
  if(document.activeElement!==$('#focus-fader'))$('#focus-fader').value=state.values[`fader:${channel}`]??0;
  $('#fader-value').textContent=`${state.values[`fader:${channel}`]??0} / 16383`;
  const details=$('#inspect-details').children;
  if(details.length===6){details[4].lastElementChild.textContent=state.pressed[selected]?'Yes':'No';details[5].lastElementChild.textContent=state.leds[selected]===undefined?'Unknown':state.leds[selected]?'On':'Off';}
}
function renderFocus() {
  $('#channel-buttons').innerHTML='';
  for(const [note,label] of [[6,'SELECT'],[7,'SOLO'],[8,'MUTE'],[0,'REC'],[9,'TOUCH']]) {
    const b=document.createElement('button');b.textContent=label;bindPress(b,`button:${channel}:${note}`);$('#channel-buttons').append(b);
  }
}
function renderInventory() {
  const q=$('#search').value.toLowerCase(),kind=$('#kind-filter').value,group=$('#group-filter').value;
  const list=catalog.controls.filter(c=>(!kind||c.kind===kind)&&(!group||c.group===group)&&`${c.name} ${c.id} ${c.group}`.toLowerCase().includes(q));
  $('#results-count').textContent=`${list.length} controls`;
  $('#inventory-rows').innerHTML=list.map(c=>`<tr class="inventory-row" data-id="${esc(c.id)}" tabindex="0"><td>${esc(c.name)}</td><td>${esc(c.kind)}</td><td>${esc(c.id)}</td><td>${esc(c.kind==='analog'?'Inventory candidate':'Source-reported')}</td><td>${c.led?'Address known':'—'}</td></tr>`).join('');
}
function renderProfiles() {
  $('#profiles-quick').innerHTML=state.profiles.map(p=>`<button data-profile="${esc(p.id)}" class="${p.id===state.active?'active':''}">${esc(p.name)}</button>`).join('');
  $('#profile-cards').innerHTML=state.profiles.map((p,i)=>`<button type="button" class="profile-card ${p.id===editing?'active':''}" data-edit-profile="${esc(p.id)}"><span class="key">⇧⌥F${i+1}</span><strong>${esc(p.name)}</strong><small>${esc(p.host)}${p.port?':'+p.port:''} · ${esc(p.adapter.toUpperCase())}<br>${esc(p.status)}</small></button>`).join('');
}
function editProfile(id) {
  editing=id;draft=structuredClone(state.profiles.find(p=>p.id===id));
  const form=$('#profile-form');['name','host','port','adapter'].forEach(n=>form.elements[n].value=draft[n]);
  $('#profile-note').textContent=draft.status;
  $('#save-status').textContent='';renderProfiles();loadMapping();
}
function loadMapping() {
  const mapping=draft.mappings[$('#mapping-control').value];
  $('#mapping-path').value=mapping?.path??'';$('#mapping-args').value=JSON.stringify(mapping?.args??[],null,2);
}
function applyMapping() {
  const id=$('#mapping-control').value,path=$('#mapping-path').value.trim(),args=JSON.parse($('#mapping-args').value);
  if(!path.startsWith('/')||!Array.isArray(args))throw Error('Enter an OSC address beginning with / and a JSON argument array.');
  draft.mappings[id]={path,args};$('#save-status').textContent='Draft updated · save to persist';
}
function renderEvents() {
  if(paused)return;
  const filter=$('#event-filter').value;
  const rows=events.filter(e=>!filter||e.kind===filter).slice(-120).reverse();
  $('#event-count').textContent=`${state.sequence} events`;
  $('#event-rows').innerHTML=rows.length?rows.map(e=>`<tr><td>${esc(new Date(e.time*1000).toLocaleTimeString('en-GB',{hour12:false}))}.${String(Math.floor(e.time*1000)%1000).padStart(3,'0')}</td><td><span class="event-kind ${esc(e.kind)}">${esc(e.kind)}</span></td><td>${esc(controls.get(e.control)?.name??e.path??e.error??e.control??e.value??e.raw??'—')}</td><td>${esc(e.value===undefined?e.args?JSON.stringify(e.args):'—':String(e.value))}</td><td>${esc(e.kind==='route'?`${e.mode} · ${e.target}`:e.source)}</td></tr>`).join(''):'<tr><td colspan="5" class="empty">No matching events. Interact with the surface to record input.</td></tr>';
}
async function poll() {
  try {
    const r=await fetch(`/api/state?after=${cursor}`,{cache:'no-store'});if(!r.ok)throw Error('Local bridge is unavailable');
    const next=await r.json();const changed=state&&next.generation!==state.generation;
    const updated=!connected||!state||next.sequence!==state.sequence;
    // A restarted local bridge starts sequence numbers again.
    if(state&&next.token!==state.token){cursor=0;events=[];location.reload();return;}
    state=next;cursor=state.sequence;events.push(...state.events);if(events.length>3000)events=events.slice(-3000);
    connected=true;
    if(!updated)return;
    $('#connection').textContent='Local bridge online';$('#connection-dot').style.background='var(--lime)';
    $('#active-name').textContent=activeProfile().name;$('#target-address').textContent=`${activeProfile().host}:${activeProfile().port||'—'}`;
    $('#adapter-status').textContent=`${activeProfile().adapter.toUpperCase()} · ${state.armed?'OUTPUT ENABLED':'preview only'}`;
    $('#output').textContent=state.armed?'Disable OSC output':'Enable OSC output';$('#output').classList.toggle('enabled',state.armed);
    $('#output').disabled=activeProfile().adapter!=='osc';$('#footer-state').textContent=state.armed?'OSC OUTPUT ENABLED · HARDWARE OFFLINE':'LOCAL BRIDGE · PREVIEW MODE';
    $('#feedback-info').textContent=state.feedback_port?`OSC feedback listener: UDP ${state.feedback_port}. Only the active profile's source IP is accepted. Configure the DAW to return strip IDs 1–24.`:'OSC feedback listener is off. Restart with --osc-port 9124 to receive feedback.';
    if(changed){renderProfiles();renderInspector();}
    updateSurface();renderEvents();
  } catch(e) {connected=false;$('#connection').textContent='Local bridge disconnected';$('#connection-dot').style.background='#e18e6b';$('#output').disabled=true;}
}
async function init() {
  const [s,c,l]=await Promise.all([fetch('/api/state').then(r=>r.json()),fetch('/api/catalog').then(r=>r.json()),fetch('/api/layout').then(r=>r.json())]);
  state=s;catalog=c;surfaceLayout=l;controls=new Map(c.controls.map(x=>[x.id,x]));
  $('#control-count').textContent=c.controls.length;
  for(const type of [...new Set(c.controls.map(c=>c.kind))].sort())$('#kind-filter').add(new Option(type,type));
  for(const group of [...new Set(c.controls.map(c=>c.group))].sort())$('#group-filter').add(new Option(group,group));
  for(const c of catalog.controls.filter(c=>['button','fader','encoder'].includes(c.kind)))$('#mapping-control').add(new Option(c.name,c.id));
  $('#mapping-control').value=selected;editing=state.active;editProfile(editing);
  buildSurface();renderInventory();select(selected);await poll();setInterval(poll,350);
}
document.querySelectorAll('[data-tab]').forEach(b=>b.onclick=()=>tab(b.dataset.tab));
$('#profiles-quick').onclick=e=>{const b=e.target.closest('[data-profile]');if(b)post('profile',{id:b.dataset.profile}).catch(error);};
$('#profile-cards').onclick=e=>{const b=e.target.closest('[data-edit-profile]');if(b)editProfile(b.dataset.editProfile);};
$('#output').onclick=()=>{if(connected)post('arm',{enabled:!state.armed}).catch(error);};
$('#hotspots').onclick=()=>{hotspots=!hotspots;$('#overlay').classList.toggle('hide-hotspots',!hotspots);$('#hotspots').textContent=`Hotspots ${hotspots?'on':'off'}`;$('#hotspots').setAttribute('aria-pressed',hotspots);};
$('#calibrate').onclick=()=>{calibrating=!calibrating;$('#overlay').classList.toggle('calibrating',calibrating);$('#calibrate').setAttribute('aria-pressed',calibrating);$('#surface-help').textContent=calibrating?'Click the photo to place the selected control':'Click a control to inspect · drag a fader · scroll an encoder';};
$('#overlay').addEventListener('click',e=>{
  if(!calibrating)return;
  const p=$('#overlay').createSVGPoint();p.x=e.clientX;p.y=e.clientY;const pos=p.matrixTransform($('#overlay').getScreenCTM().inverse());
  calibration[selected]=[Math.round(pos.x*10)/10,Math.round(pos.y*10)/10];localStorage.setItem('control24-calibration',JSON.stringify(calibration));
  if(!points.has(selected))hotspot(selected,pos.x,pos.y);
  const g=[...document.querySelectorAll('[data-control]')].find(g=>g.dataset.control===selected);if(g)g.setAttribute('transform',`translate(${pos.x} ${pos.y})`);
});
$('#focus-fader').oninput=e=>send(`fader:${channel}`,Number(e.target.value));
$('#focus-fader').onpointerdown=()=>send(`button:${channel}:9`,true);
$('#focus-fader').onpointerup=()=>send(`button:${channel}:9`,false);
$('#focus-fader').onpointercancel=()=>send(`button:${channel}:9`,false);
$('#focus-encoder').onchange=e=>{const value=Number(e.target.value);$('#encoder-value').textContent=(value>0?'+':'')+value;send(`encoder:${channel}`,value);e.target.value=0;};
['search','kind-filter','group-filter'].forEach(id=>$('#'+id).addEventListener(id==='search'?'input':'change',renderInventory));
$('#inventory-rows').addEventListener('click',e=>{const row=e.target.closest('[data-id]');if(row){select(row.dataset.id);tab('surface');}});
$('#inventory-rows').addEventListener('keydown',e=>{if(e.key==='Enter')e.target.click();});
$('#export-catalog').onclick=()=>download('control24-catalog.json',catalog);
$('#export-calibration').onclick=()=>download('control24-calibration.json',{image:'control24-reference.png',viewBox:[0,0,1000,527],positions:calibration});
$('#edit-mapping').onclick=()=>{tab('profiles');editProfile(state.active);$('#mapping-control').value=selected;loadMapping();};
$('#mapping-control').onchange=loadMapping;
$('#apply-mapping').onclick=()=>{try{applyMapping();}catch(e){error(e);}};
$('#remove-mapping').onclick=()=>{delete draft.mappings[$('#mapping-control').value];loadMapping();$('#save-status').textContent='Removed from draft · save to persist';};
$('#profile-form').onsubmit=async e=>{
  e.preventDefault();try {
    if($('#mapping-path').value.trim())applyMapping();
    ['name','host','adapter'].forEach(n=>draft[n]=e.target.elements[n].value.trim());draft.port=Number(e.target.elements.port.value);
    await post('profile/save',draft);await poll();$('#save-status').textContent='Saved locally · output disabled';renderProfiles();
  }catch(err){error(err);}
};
$('#sample-frame').onclick=()=>{$('#raw-frame').value='00 18 00 00 00 00 00 01 00 00 00 00 00 00 00 02 90 10 5c b0 00 40 20 00';};
$('#decode-frame').onclick=async()=>{try{await post('raw',{hex:$('#raw-frame').value});$('#decode-result').textContent='Decoded into the event stream. Offline replay: OSC was not sent.';}catch(e){error(e);}};
$('#pause-log').onclick=()=>{paused=!paused;$('#pause-log').textContent=paused?'Resume view':'Pause view';renderEvents();};
$('#event-filter').onchange=renderEvents;
init().catch(error);

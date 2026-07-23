// API_TOKEN_PLACEHOLDER
if(typeof window.API_TOKEN==='undefined')window.API_TOKEN='';
// Pure helpers (esc, dim, withApiAuth, apiUrl) live in app-utils.js
// so they can be unit-tested under Node.js without a browser.
// fetchWithTimeout stays here because it patches window.fetch and
// needs the original fetch reference at module load time. setHtml and
// setText also stay here because they touch document.getElementById.
const {esc,dim,apiUrl,withApiAuth}=window.OWRT_UTILS;
function setHtml(id,html){let el=document.getElementById(id);if(el)el.innerHTML=html;}
function setText(id,text){let el=document.getElementById(id);if(el)el.innerText=text;}
const _origFetch=window.fetch;
window.fetch=function(url,options){
  if(typeof url==='string'&&url.includes('/cgi-bin/wardriving_api')&&window.API_TOKEN){
    options=withApiAuth(options);
  }
  return _origFetch(url,options);
};
// fetchWithTimeout: wrap fetch with an AbortController that fires
// after `ms` milliseconds. Returns a promise that rejects with a
// TimeoutError. Used by apiJson so the dashboard never sits waiting
// on a hung uhttpd worker (the router has a small finite pool).
// Long-running calls (downloads, large uploads) opt out by passing
// {timeout: 0} or omitting the field.
function fetchWithTimeout(url,options){
  options=options||{};
  const ms=options.timeout===undefined?10000:options.timeout;
  if(!ms||typeof AbortController==='undefined')return _origFetch(url,options);
  const ctl=new AbortController();
  let timedOut=false;
  const timer=setTimeout(()=>{timedOut=true;ctl.abort();},ms);
  return _origFetch(url,Object.assign({},options,{signal:ctl.signal}))
    .catch(e=>{
      if(timedOut)throw new Error('request timeout ('+ms+'ms)');
      throw e;
    })
    .finally(()=>clearTimeout(timer));
}
function apiJson(action,params,options){
  return fetchWithTimeout(apiUrl(action,params),withApiAuth(options)).then(r=>r.json().catch(()=>({error:'bad json'}))).then(d=>{
    if(d&&d.error)throw new Error(d.error);
    return d;
  });
}

// GLOBALS
let isRunning=false,lastGpsFixTime=Date.now(),lastHandshakeCount=-1,lastHandshakeAt=0,lastStatusAt=0;
let audioEnabled=localStorage.getItem('audioEnabled')==='true';
let map,onlineLayer,offlineLayer,carMarker,firstLoc=true,watchId=null,browserGpsActive=false,followMode=true;
let wpsMarkers={},crackedMarkers=[],networkMarkers=[],clientMarkers=[],replayNetworkMarkers=[],heatLayer=null,replayTimer=null;
let networkLayerItems=[],clientLayerItems=[];
let currentMode='passive';
let replayDiscoveredItems={};
let excludedSSIDs=[],targetMacs=[],alertedTargets=[];
let petMood='sleep',petLastMoodChange=Date.now(),petHandshakeBurst=0,petLastHandshakes=0,petPwnagotchiDetected=false;
let dlTimer=null,replayMap=null,replayMarker=null,replayPollTimer=null,replayEvents=[],lastReplayState='idle';
let replayFollowMode=true;
let replayDiscoveredTimer=null;

// NMEA PARSERS
function parseNMEARMC(l){if(!l||!l.match(/^\$[A-Z]{2}RMC/))return null;let p=l.split(',');if(p[2]!=='A')return null;let r=parseFloat(p[3]),lat=Math.floor(r/100)+((r/100)%1)*100/60;if(p[4]==='S')lat=-lat;let r2=parseFloat(p[5]),lon=Math.floor(r2/100)+((r2/100)%1)*100/60;if(p[6]==='W')lon=-lon;return{lat,lon,speedKmh:(parseFloat(p[7])||0)*1.852,time:p[1]};}
function parseNMEAWPL(l){if(!l||!l.startsWith('$GPWPL'))return null;let p=l.split(','),r=parseFloat(p[1]),lat=Math.floor(r/100)+((r/100)%1)*100/60;if(p[2]==='S')lat=-lat;let r2=parseFloat(p[3]),lon=Math.floor(r2/100)+((r2/100)%1)*100/60;if(p[4]==='W')lon=-lon;return{lat,lon,mac:(p[5]||'').split('*')[0]};}

// INIT MAP
function initMap(){
  map=L.map('map',{zoomControl:false}).setView([0,0],2);
  L.control.zoom({position:'topright'}).addTo(map);
  onlineLayer=L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'© OSM'});
  offlineLayer=L.tileLayer('/wardriving/captures/tiles/{z}/{x}/{y}.png',{maxZoom:18,errorTileUrl:'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='});
  let uo=localStorage.getItem('useOnlineMaps')==='true';
  document.getElementById('chkOnlineTiles').checked=uo;
  document.getElementById('chkCracked').checked=localStorage.getItem('showCracked')!=='false';
  if(uo)onlineLayer.addTo(map);else offlineLayer.addTo(map);
  carMarker=L.circleMarker([0,0],{radius:8,fillColor:'#00ffff',color:'#fff',weight:2,opacity:1,fillOpacity:1}).addTo(map).bindPopup('<b>Current Location</b>');
  map.on('dragstart',()=>{followMode=false;updateFollowButton();});
  map.on('zoomend',refreshVisibleLayers);
  loadCrackedNetworks();
  updateMapButtons();
}
initMap();
function initReplayMap(){
  replayMap=L.map('replayMap',{zoomControl:true}).setView([0,0],2);
  let uo=localStorage.getItem('useOnlineMaps')==='true';
  let layer=uo?L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'© OSM'}):L.tileLayer('/wardriving/captures/tiles/{z}/{x}/{y}.png',{maxZoom:18,errorTileUrl:'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='});
  layer.addTo(replayMap);
  replayMarker=L.circleMarker([0,0],{radius:10,fillColor:'#ffb000',color:'#fff',weight:2,opacity:1,fillOpacity:1}).addTo(replayMap).bindPopup('Replay vehicle');
  updateReplayFollowButton();
}
setTimeout(initReplayMap,250);

// TABS
let currentTab='dashboard';
function switchTab(id,el){
  // Leaving a tab that owns a polling interval: kill the timer so it
  // doesn't keep hitting the CGI in the background. The owning
  // function (replay_start, downloadBBox) re-creates the interval the
  // next time the user enters the tab and triggers an action.
  if(currentTab==='replay'&&id!=='replay'){
    if(replayPollTimer){clearInterval(replayPollTimer);replayPollTimer=null;}
    if(replayDiscoveredTimer){clearInterval(replayDiscoveredTimer);replayDiscoveredTimer=null;}
  }
  if(currentTab==='captures'&&id!=='captures'){
    if(dlTimer){clearInterval(dlTimer);dlTimer=null;}
  }
  currentTab=id;
  document.querySelectorAll('.view').forEach(v=>{v.classList.remove('active');v.style.display='none';});
  document.querySelectorAll('#icon-nav .nav-icon').forEach(v=>v.classList.remove('active'));
  let view=document.getElementById('view-'+id);
  if(view){view.classList.add('active');view.style.display=(id==='dashboard'||id==='console')?'flex':'block';}
  if(el)el.classList.add('active');
  if(id==='dashboard')setTimeout(()=>{if(map)map.invalidateSize()},300);
  if(id==='replay')setTimeout(()=>{if(replayMap)replayMap.invalidateSize();loadReplayStatus();},300);
  if(id==='settings')loadExclusions(true);
  if(id==='history')loadHistory();
}

// DRIVER SIDE
function setDriverSide(){
  let s=document.getElementById('selDriverSide').value;localStorage.setItem('driverSide',s);
  let nav=document.getElementById('icon-nav'),lp=document.getElementById('left-panel');
  if(s==='right'){nav.style.order='3';lp.style.order='2';}else{nav.style.order='1';lp.style.order='2';}
}
(function(){let s=localStorage.getItem('driverSide')||'left',el=document.getElementById('selDriverSide');if(el)el.value=s;})();

// TOGGLE WARDIRIVING
function toggleWardriving(){
  let a=isRunning?'stop':'start';
  let btn=document.getElementById('btnToggle');
  btn.innerText=a==='start'?'⏳ STARTING':'⏳ STOPPING';
  btn.disabled=true;
  apiJson(a).then(()=>{
    setTimeout(()=>{ btn.disabled=false; updateStatus(); },a==='start'?4500:1500);
  }).catch(e=>{
    btn.disabled=false;
    setHtml('logBox','Action '+esc(a)+' failed: '+esc(e.message||'unknown'));
    updateStatus();
  });
}

function ageLabel(sec){
  sec=parseInt(sec||0);
  if(!sec)return 'now';
  if(sec<60)return sec+'s';
  return Math.round(sec/60)+'m';
}
function setPipe(id,state,label){
  let el=document.getElementById(id);if(!el)return;
  el.className='pipe-node '+state;
  let v=el.querySelector('.p-val');if(v)v.innerText=label;
}
function updatePipeline(d){
  setPipe('pipeCapture',isRunning?'ok':'warn',isRunning?'LIVE':'STOP');
  let remoteOn=String(d.remote_enabled||'0')==='1',rs=d.remote_state||'local',extraction=String(d.extraction_mode||'local'),gpuCracking=String(d.gpu_cracking_enabled==null?'1':d.gpu_cracking_enabled)==='1';
  if(extraction==='local'&&!gpuCracking){setPipe('pipeGpu','warn','LOCAL');setPipe('pipeTx','warn','IDLE');}
  else if(extraction==='local'&&rs==='local'){setPipe('pipeGpu','warn',gpuCracking?'CRACK':'LOCAL');setPipe('pipeTx','warn','IDLE');}
  else if(!remoteOn){setPipe('pipeGpu','warn','LOCAL');setPipe('pipeTx','warn','IDLE');}
  else if(rs==='ok'||rs==='synced'||rs==='extracted'){setPipe('pipeGpu','ok','OK');setPipe('pipeTx','ok',ageLabel(Math.max(0,Math.floor(Date.now()/1000)-parseInt(d.remote_updated||0))));}
  else if(rs==='uploading'){setPipe('pipeGpu','warn','WAIT');setPipe('pipeTx','warn','TX');}
  else if(rs==='fallback'||rs==='sync_error'||rs==='unconfigured'){setPipe('pipeGpu','err',rs==='fallback'?'FALLBACK':'ERROR');setPipe('pipeTx','err',d.remote_code||'ERR');}
  else{setPipe('pipeGpu','warn','WAIT');setPipe('pipeTx','warn','--');}
  let health='OK',hstate='ok';
  if(String(d.fix)==='0'){health='GPS';hstate='err';}
  else if(parseInt(d.usb_pct)>90){health='USB';hstate='err';}
  else if(parseInt(d.ram)>85){health='RAM';hstate='warn';}
  setPipe('pipeHealth',hstate,health);
}
function updateGpsVisual(hasFix){
  let alertEl=document.getElementById('gpsMapAlert');
  if(alertEl)alertEl.className='gps-map-alert'+(hasFix?'':' show');
  if(carMarker)carMarker.setStyle({fillColor:hasFix?'#00ffff':'#ff3333',color:hasFix?'#fff':'#ffaaaa',radius:hasFix?8:11});
  if(!hasFix&&followMode){followMode=false;updateFollowButton();}
}
function updateFreshness(ok){
  let el=document.getElementById('hdr_fresh');if(!el)return;
  if(ok)lastStatusAt=Date.now();
  let age=Math.floor((Date.now()-lastStatusAt)/1000);
  if(!lastStatusAt){el.innerText='waiting';el.style.color='var(--c-dim)';return;}
  el.innerText=ok?'updated '+ageLabel(age):'API ERROR';
  el.style.color=!ok||age>30?'var(--c-red)':(age>10?'var(--c-amber)':'var(--c-dim)');
}
function refreshFreshnessAge(){
  let el=document.getElementById('hdr_fresh');if(!el||!lastStatusAt)return;
  let age=Math.floor((Date.now()-lastStatusAt)/1000);
  el.innerText='updated '+ageLabel(age);
  el.style.color=age>30?'var(--c-red)':(age>10?'var(--c-amber)':'var(--c-dim)');
}
function showToast(msg,kind){
  let t=document.getElementById('toast');
  if(!t){t=document.createElement('div');t.id='toast';t.className='toast';document.body.appendChild(t);}
  t.innerText=msg;t.style.borderColor=kind==='err'?'var(--c-red)':(kind==='warn'?'var(--c-amber)':'var(--c-green)');
  t.classList.add('show');clearTimeout(window.toastTimer);window.toastTimer=setTimeout(()=>t.classList.remove('show'),1800);
}

// STATUS POLL
function updateStatus(){
  apiJson('status').then(d=>{
    updateFreshness(true);
    isRunning=d.running;
    if(d.mode)syncModeUi(d.mode);
    let btn=document.getElementById('btnToggle'),dot=document.getElementById('hdr_dot');
    if(isRunning){btn.innerHTML='⏹ STOP';btn.className='btn huge stop';dot.className='status-dot on';dot.innerHTML='● LIVE<span id="hdr_fresh">updated 0s</span>';}
    else{btn.innerHTML='▶ START';btn.className='btn huge';dot.className='status-dot off';dot.innerHTML='● STOPPED<span id="hdr_fresh">updated 0s</span>';}
    let browserGps=d.gps_source==='browser';
    document.getElementById('hdr_gps').querySelector('.val').innerText=browserGps?'BROWSER':(d.sats||'0');
    let gu=document.getElementById('hdr_gps').querySelector('.unit');if(gu)gu.innerText=d.fix!=='0'?(browserGps?'GPS':'sats'):'NO FIX';
    document.getElementById('hdr_gps').className='metric'+(d.fix==='0'?' crit':'');
    updateGpsVisual(d.fix!=='0');
    let skm=Math.round((parseFloat(d.speed)||0)*1.852);
    document.getElementById('hdr_speed').querySelector('.val').innerText=skm;
    
    document.getElementById('hdr_hs').querySelector('.val').innerText=d.handshakes||'0';
    let ue=document.getElementById('hdr_usb');ue.querySelector('.val').innerText=(d.usb_pct||'?')+'%';
    ue.className='metric'+(parseInt(d.usb_pct)>90?' crit':(parseInt(d.usb_pct)>75?' warn':''));
    updatePipeline(d);

    let ch=parseInt(d.handshakes||0);
    if(lastHandshakeCount!==-1&&ch>lastHandshakeCount){
      let delta=ch-lastHandshakeCount,hs=document.getElementById('hdr_hs'),de=document.getElementById('hdr_hs_delta');
      lastHandshakeAt=Date.now();if(de)de.innerText='+'+delta;
      if(hs){hs.classList.add('flash');setTimeout(()=>hs.classList.remove('flash'),1800);}
      setText('lastHsText','Last HS: now');
      if(audioEnabled&&'speechSynthesis' in window)window.speechSynthesis.speak(new SpeechSynthesisUtterance('Captured '+delta+' new handshake'+(delta>1?'s':'')));
      setTimeout(()=>{let dlt=document.getElementById('hdr_hs_delta');if(dlt)dlt.innerText='';},5000);
    }
    lastHandshakeCount=ch;
    if(lastHandshakeAt)setText('lastHsText','Last HS: '+ageLabel(Math.floor((Date.now()-lastHandshakeAt)/1000))+' ago');

    if(d.logs){let lb=document.getElementById('logBox');lb.innerText=d.logs.replace(/\\n/g,'\n');if(lb.scrollHeight-lb.scrollTop<lb.clientHeight+100)lb.scrollTop=lb.scrollHeight;}

    if(d.channels_data&&Array.isArray(d.channels_data)){
      // Save open channel state before rebuild
      let openChs=new Set();
      document.querySelectorAll('#specList .ch-detail.open').forEach(el=>{
        let chEl=el.previousElementSibling;if(chEl)openChs.add(chEl.querySelector('.ch-n').innerText);
      });
      let rawCount=d.channels_data.length,fd=d.channels_data.filter(i=>!excludedSSIDs.includes(i.s)),cm={};
      fd.forEach(i=>{if(!cm[i.c])cm[i.c]=[];cm[i.c].push(i.s);});
      let sh='',chs=[1,2,3,4,5,6,7,8,9,10,11];
      let emptyText=rawCount===0?'no data':(fd.length===0?'filtered':'empty');
      let max=1;chs.forEach(c=>{let n=(cm[c]||[]).length;if(n>max)max=n;});
      chs.forEach(c=>{let ss=cm[c]||[],w=Math.max(2,Math.round((ss.length/max)*100)),hot=ss.length>=10?' hot':(ss.length>=5?' med':'');if(ss.length||[1,6,11].includes(c))sh+='<div class="ch-row"><span class="ch-n">CH '+c+'</span><span class="bar-track"><span class="bar-fill'+hot+'" style="width:'+w+'%"></span></span><span class="ch-c">'+ss.length+'</span></div>';});
      if(!sh)sh='<span style="color:var(--c-dim)">'+emptyText+'</span>';
      document.getElementById('specList').innerHTML=sh;
      updateScores(d.channels_data);
    }else{
      updateScores([]);
    }
  }).catch(e=>{
    updateFreshness(false);
    setHtml('specList',dim('status error: '+(e.message||'unknown')));
    let btn=document.getElementById('btnToggle');if(btn){btn.innerHTML='▶ START';btn.className='btn huge';}
    let dot=document.getElementById('hdr_dot');if(dot){dot.className='status-dot off';dot.innerHTML='● API ERR<span id="hdr_fresh">API ERROR</span>';}
    setPipe('pipeHealth','err','API');
  });
}

function updateScores(channelsData){
  let rows=Array.isArray(channelsData)?channelsData:[];
  function encRank(v){v=String(v||'?');if(v.indexOf('WPA3')>=0)return 5;if(v.indexOf('WPA2')>=0)return 4;if(v.indexOf('WPA')>=0)return 3;if(v==='PSK')return 2;if(v==='OPEN'||v==='WEP')return 1;return 0;}
  let grouped={},order=[];
  rows.forEach(n=>{
    let ssid=String(n.s||'').trim(),chan=parseInt(n.c||0);
    if(!ssid||excludedSSIDs.includes(ssid))return;
    let key=chan+'|'+ssid;
    let enc=String(n.e||'?').trim().toUpperCase();
    if(!grouped[key]){grouped[key]={ssid,chan,count:0,enc:'?'};order.push(key);}
    if(encRank(enc)>encRank(grouped[key].enc))grouped[key].enc=enc;
    grouped[key].count++;
  });
  let items=order.map(k=>grouped[k]).sort((a,b)=>b.count-a.count||a.chan-b.chan).slice(0,12);
  if(!items.length){setHtml('scoresList','<span style="color:var(--c-dim);font-size:18px">Sin redes cerca</span>');return;}
  let h='';
  items.forEach(n=>{
    let countLabel=n.count>1?' | visto '+esc(n.count)+' veces':'';
    let encLabel=n.enc&&n.enc!=='?'?esc(n.enc):'ENC ?';
    h+='<div class="sr"><div class="sr-top"><span class="sr-ssid">'+esc(n.ssid)+'</span><span class="sr-pts" style="color:var(--c-green)">LIVE</span></div><div class="sr-info">CH '+esc(n.chan||'?')+' <span class="sr-enc">'+encLabel+'</span>'+countLabel+'</div></div>';
  });
  setHtml('scoresList',h);
}

// MAP POLL
function updateMap(){
  if(!isRunning)return;
  apiJson('map_data').then(d=>{
    if(!d.nmea_b64){setText('logBox','Map data: no route/NMEA data yet.');return;}let ls=atob(d.nmea_b64).split('\n'),cl=null,cln=null;
    ls.forEach(l=>{let r=parseNMEARMC(l);if(r){cl=r.lat;cln=r.lon;window.carLat=r.lat;window.carLng=r.lon;return;}
      let w=parseNMEAWPL(l);if(w&&!wpsMarkers[w.mac]&&!isNaN(w.lat)&&!isNaN(w.lon)){wpsMarkers[w.mac]=L.circleMarker([w.lat,w.lon],{radius:5,fillColor:'#00ff00',color:'#00aa00',weight:1,opacity:1,fillOpacity:0.7}).addTo(map).bindPopup('<b>Handshake:</b><br>'+w.mac);}});
    if(cl!==null&&!isNaN(cl)){carMarker.setLatLng([cl,cln]);if(firstLoc){map.setView([cl,cln],16);firstLoc=false;}else if(followMode){map.panTo([cl,cln],{animate:true,duration:0.4});}}
  }).catch(e=>{setText('logBox','Map data failed: '+(e.message||'unknown'));});
}

function markerStyle(n){
  if(n.is_cracked)return{color:'#00ff41',fillColor:'#00ff41',label:'🔓'};
  if(n.has_handshake)return{color:'#ffb000',fillColor:'#ffb000',label:'🔑'};
  return{color:'#00ffff',fillColor:'#00ffff',label:''};
}
function clusterPixelSize(targetMap){
  let z=targetMap&&targetMap.getZoom?targetMap.getZoom():16;
  if(z>=18)return 1;
  if(z>=16)return 42;
  if(z>=14)return 56;
  if(z>=12)return 76;
  return 100;
}
function joinSamples(a,b,limit){
  let out=[],seen={};
  String(a||'').split(',').concat(String(b||'').split(',')).forEach(s=>{s=s.trim();if(s&&!seen[s]&&out.length<limit){seen[s]=1;out.push(s);}});
  return out.join(',');
}
function clusterMapItems(targetMap,items,kind){
  if(!targetMap||!items)return[];
  let cell=clusterPixelSize(targetMap);
  if(cell<=1)return items;
  let groups={},order=[];
  items.forEach(n=>{
    let lat=parseFloat(n.lat),lon=parseFloat(n.lon);if(isNaN(lat)||isNaN(lon)||lat===0||lon===0)return;
    let p=targetMap.project([lat,lon],targetMap.getZoom()),key=Math.floor(p.x/cell)+','+Math.floor(p.y/cell);
    if(!groups[key]){groups[key]=Object.assign({},n,{latSum:0,lonSum:0,weight:0,count:0,client_count:0,ap_count:0,associated:0});order.push(key);}
    let g=groups[key],w=parseInt(n.count||n.client_count||1);if(!w||w<1)w=1;
    g.latSum+=lat*w;g.lonSum+=lon*w;g.weight+=w;g.count+=parseInt(n.count||1);
    g.rssi=Math.max(parseInt(g.rssi||-999),parseInt(n.rssi||-999));
    g.has_handshake=!!(g.has_handshake||n.has_handshake);g.is_cracked=!!(g.is_cracked||n.is_cracked);
    g.ssids=joinSamples(g.ssids,n.ssids||n.ssid,6);
    if(kind==='clients'){g.client_count+=parseInt(n.client_count||n.count||1);g.ap_count+=parseInt(n.ap_count||1);g.associated+=parseInt(n.associated||0);g.channels=joinSamples(g.channels,n.channels,8);g.kind='clients';}
  });
  return order.map(k=>{let g=groups[k];g.lat=g.latSum/g.weight;g.lon=g.lonSum/g.weight;delete g.latSum;delete g.lonSum;delete g.weight;return g;});
}
function refreshVisibleLayers(){
  if(!map)return;
  if(currentMode==='passive'){
    networkMarkers=drawNetworkLayer(map,clusterMapItems(map,networkLayerItems,'networks'),networkMarkers,false);
  }else{
    clientMarkers=drawClientLayer(map,clusterMapItems(map,clientLayerItems,'clients'),clientMarkers);
  }
}
function drawNetworkLayer(targetMap,items,store,isReplay){
  if(!targetMap||!items)return store||[];
  (store||[]).forEach(m=>targetMap.removeLayer(m));
  let next=[];
  items.forEach(n=>{
    let lat=parseFloat(n.lat),lon=parseFloat(n.lon);if(isNaN(lat)||isNaN(lon)||lat===0||lon===0)return;
    let st=markerStyle(n),count=parseInt(n.count||1),r=count>1?Math.min(18,7+count):6;
    let label=st.label||(count>1?String(count):'');
    let marker=L.circleMarker([lat,lon],{radius:r,fillColor:st.fillColor,color:st.color,weight:n.is_cracked?3:(n.has_handshake?2:1),opacity:0.95,fillOpacity:isReplay?0.55:0.38}).addTo(targetMap);
    let ssids=String(n.ssids||n.ssid||'').split(',').filter(Boolean).slice(0,5).map(esc).join('<br>');
    marker.bindPopup('<b>'+esc(label||'Network')+' '+count+' net'+(count===1?'':'s')+'</b><br>'+ssids+(n.has_handshake?'<br>Handshake: yes':'')+(n.is_cracked?'<br>Cracked: yes':''));
    if(isReplay)marker.on('click',()=>{replayFollowMode=false;updateReplayFollowButton();});
    next.push(marker);
    if(label){
      let div=L.marker([lat,lon],{interactive:false,icon:L.divIcon({className:'net-label',html:'<div style="color:#000;background:'+st.fillColor+';border-radius:10px;min-width:18px;height:18px;text-align:center;font:bold 12px/18px sans-serif;box-shadow:0 0 8px '+st.fillColor+'">'+esc(label)+'</div>',iconSize:[20,20]})}).addTo(targetMap);
      next.push(div);
    }
  });
  return next;
}
function loadNetworkMap(){
  if(currentMode==='passive'){
    clientLayerItems=[];
    clientMarkers=drawClientLayer(map,[],clientMarkers);
    apiJson('networks_map').then(d=>{networkLayerItems=d||[];networkMarkers=drawNetworkLayer(map,clusterMapItems(map,networkLayerItems,'networks'),networkMarkers,false);}).catch(()=>{});
  }else{
    networkLayerItems=[];
    networkMarkers=drawNetworkLayer(map,[],networkMarkers,false);
    apiJson('clients_map').then(d=>{
      clientLayerItems=d||[];
      clientMarkers=drawClientLayer(map,clusterMapItems(map,clientLayerItems,'clients'),clientMarkers);
      setText('modeHint',(currentMode==='smart'?'Smart':'Active')+' lens: '+((d&&d.length)?'client groups '+d.length:'no clients mapped yet'));
    }).catch(()=>{});
  }
}
function drawClientLayer(targetMap,items,store){
  if(!targetMap||!items)return store||[];
  (store||[]).forEach(m=>targetMap.removeLayer(m));
  let next=[];
  items.forEach(n=>{
    let lat=parseFloat(n.lat),lon=parseFloat(n.lon);if(isNaN(lat)||isNaN(lon)||lat===0||lon===0)return;
    let clients=parseInt(n.client_count||n.count||1),aps=parseInt(n.ap_count||1),r=Math.min(22,8+clients);
    let marker=L.circleMarker([lat,lon],{radius:r,fillColor:'#ff00ff',color:'#ffffff',weight:n.associated>0?3:2,opacity:0.95,fillOpacity:0.48}).addTo(targetMap);
    let ssids=String(n.ssids||'').split(',').filter(Boolean).slice(0,5).map(esc).join('<br>');
    marker.bindPopup('<b>'+clients+' client'+(clients===1?'':'s')+'</b><br>APs: '+aps+(n.associated?'<br>Assoc/Auth frames: '+esc(n.associated):'')+(ssids?'<br>'+ssids:'')+(n.channels?'<br>Channels: '+esc(n.channels):''));
    next.push(marker);
    let div=L.marker([lat,lon],{interactive:false,icon:L.divIcon({className:'client-label',html:'<div style="color:#fff;background:#8b008b;border:1px solid #fff;border-radius:10px;min-width:20px;height:20px;text-align:center;font:bold 12px/20px sans-serif;box-shadow:0 0 10px #ff00ff">'+clients+'</div>',iconSize:[22,22]})}).addTo(targetMap);
    next.push(div);
  });
  return next;
}
function modeHint(mode){
  if(mode==='passive')return 'AP survey';
  if(mode==='smart')return 'Target list';
  return 'Clients';
}
function syncModeUi(mode){
  currentMode=mode||'passive';
  let a=document.getElementById('dashMode'),b=document.getElementById('selMode');
  if(a)a.querySelectorAll('.mode-btn').forEach(btn=>btn.classList.toggle('active',btn.dataset.mode===currentMode));
  if(b&&b.value!==currentMode)b.value=currentMode;
  setText('modeHint',modeHint(currentMode));
}
function setOperationMode(mode){
  if(mode==='active'&&!confirm('⚠️ Activating ACTIVE mode will enable full injection and deauth. Continue?'))return;
  syncModeUi(mode);
  apiJson('set_mode',{mode}).then(d=>{syncModeUi(d.mode||mode);showToast('Mode: '+(d.mode||mode)+(d.capture_restarted?' (capture restarted)':''));loadNetworkMap();}).catch(e=>showToast('Mode change failed: '+(e.message||'unknown'),'err'));
}
function networkKey(n){
  let lat=parseFloat(n.lat),lon=parseFloat(n.lon);
  if(isNaN(lat)||isNaN(lon))return '';
  return lat.toFixed(4)+','+lon.toFixed(4)+','+String(n.ssids||n.ssid||'');
}
function mergeReplayNetworks(items){
  (items||[]).forEach(n=>{
    let k=networkKey(n);if(!k)return;
    let cur=replayDiscoveredItems[k];
    if(cur){
      cur.count=Math.max(parseInt(cur.count||1),parseInt(n.count||1));
      cur.has_handshake=!!(cur.has_handshake||n.has_handshake);
      cur.is_cracked=!!(cur.is_cracked||n.is_cracked);
      cur.rssi=Math.max(parseInt(cur.rssi||-999),parseInt(n.rssi||-999));
      cur.ssids=cur.ssids||n.ssids||n.ssid||'';
    }else{
      replayDiscoveredItems[k]=Object.assign({},n);
    }
  });
}
function renderReplayNetworks(){
  replayNetworkMarkers=drawNetworkLayer(replayMap,Object.values(replayDiscoveredItems),replayNetworkMarkers,true);
}
function loadReplayDiscovered(){
  apiJson('replay_discovered').then(d=>{if(d&&d.length){mergeReplayNetworks(d);renderReplayNetworks();}}).catch(()=>{});
}

// MAP CONTROLS
function toggleTiles(){let o=document.getElementById('chkOnlineTiles').checked;localStorage.setItem('useOnlineMaps',o);if(o){map.removeLayer(offlineLayer);onlineLayer.addTo(map);}else{map.removeLayer(onlineLayer);offlineLayer.addTo(map);}}
function toggleHeatmap(){if(document.getElementById('chkHeatmap').checked){fetch(apiUrl('heatmap_data')).then(r=>r.json()).then(d=>{if(d.length>0)heatLayer=L.heatLayer(d,{radius:25,blur:15,maxZoom:17}).addTo(map);});}else{if(heatLayer){map.removeLayer(heatLayer);heatLayer=null;}}}
function startReplay(){if(replayTimer){clearInterval(replayTimer);replayTimer=null;return;}fetch(apiUrl('map_data')).then(r=>r.json()).then(d=>{if(!d.nmea_b64)return;let co=[],ls=atob(d.nmea_b64).split('\n');ls.forEach(l=>{let r=parseNMEARMC(l);if(r)co.push([r.lat,r.lon]);});if(!co.length)return;let i=0;replayTimer=setInterval(()=>{if(i>=co.length){clearInterval(replayTimer);replayTimer=null;return;}map.setView(co[i],16);carMarker.setLatLng(co[i]);i++;},500);});}
function updateFollowButton(){let b=document.getElementById('btnFollow');if(!b)return;b.className='map-action '+(followMode?'on':'warn');b.innerText=followMode?'📍 FOLLOW':'⊙ FREE';}
function toggleFollowMode(){followMode=!followMode;if(followMode&&window.carLat&&window.carLng)map.panTo([window.carLat,window.carLng],{animate:true,duration:0.3});updateFollowButton();}
function updateMapButtons(){
  let gps=document.getElementById('btnBrowserGPS'),tiles=document.getElementById('btnTiles'),heat=document.getElementById('btnHeatmap'),cracked=document.getElementById('btnCracked');
  if(gps)gps.className='map-action '+(browserGpsActive?'on':'off');
  if(tiles)tiles.className='map-action '+(document.getElementById('chkOnlineTiles').checked?'on':'off');
  if(heat)heat.className='map-action '+(document.getElementById('chkHeatmap').checked?'on':'off');
  if(cracked)cracked.className='map-action '+(document.getElementById('chkCracked').checked?'on':'off');
  updateFollowButton();
}
function toggleTilesButton(){let c=document.getElementById('chkOnlineTiles');c.checked=!c.checked;toggleTiles();updateMapButtons();}
function toggleHeatmapButton(){let c=document.getElementById('chkHeatmap');c.checked=!c.checked;toggleHeatmap();updateMapButtons();}
function clearCrackedMarkers(){crackedMarkers.forEach(m=>{if(map)map.removeLayer(m);});crackedMarkers=[];}
function toggleCrackedButton(){let c=document.getElementById('chkCracked');c.checked=!c.checked;localStorage.setItem('showCracked',c.checked?'true':'false');if(c.checked)loadCrackedNetworks();else clearCrackedMarkers();updateMapButtons();}
function toggleBrowserGPSButton(){let c=document.getElementById('chkBrowserGPS');c.checked=!c.checked;toggleBrowserGPS();updateMapButtons();}

// BROWSER GPS
function toggleBrowserGPS(){
  browserGpsActive=document.getElementById('chkBrowserGPS').checked;localStorage.setItem('browserGpsActive',browserGpsActive);
  if(browserGpsActive){
    if(!navigator.geolocation){document.getElementById('chkBrowserGPS').checked=false;browserGpsActive=false;return;}
    watchId=navigator.geolocation.watchPosition(p=>{
      window.carLat=p.coords.latitude;window.carLng=p.coords.longitude;carMarker.setLatLng([window.carLat,window.carLng]);
      if(firstLoc){map.setView([window.carLat,window.carLng],16);firstLoc=false;}
      else if(followMode){map.panTo([window.carLat,window.carLng],{animate:true,duration:0.3});}
      window.nmeaBuffer = window.nmeaBuffer || [];
      window.nmeaBuffer.push(generateNMEA(p));
      /* Bound the buffer: drop oldest entries if the GPS push is failing
         repeatedly (network down, CGI capped at 8KB). 32 GPRMC/GGA pairs is
         ~8 minutes of 4-second flushes, enough to ride out a transient
         outage without unbounded growth. */
      window.GPS_BUFFER_MAX=window.GPS_BUFFER_MAX||32;
      if(window.nmeaBuffer.length>window.GPS_BUFFER_MAX)window.nmeaBuffer.splice(0,window.nmeaBuffer.length-window.GPS_BUFFER_MAX);
      window.lastGpsPush = window.lastGpsPush || 0;
      let now = Date.now();
      if(now - window.lastGpsPush > 4000){
        fetch(apiUrl('gps_push'),{method:'POST',body:window.nmeaBuffer.join('')}).then(()=>{window.nmeaBuffer=[];window.lastGpsPush=now;}).catch(()=>{/* keep buffer, will retry on next interval */});
      }
    },()=>{document.getElementById('chkBrowserGPS').checked=false;browserGpsActive=false;updateMapButtons();window.nmeaBuffer=[];window.lastGpsPush=0;},{enableHighAccuracy:window.GPS_HIGH_ACCURACY||false,maximumAge:1000,timeout:10000});
  }else{if(watchId!==null)navigator.geolocation.clearWatch(watchId);}
  updateMapButtons();
}
function generateNMEA(pos){
  let c=pos.coords,d=new Date(pos.timestamp),pad=(n,w=2)=>n.toString().padStart(w,'0');
  let ts=pad(d.getUTCHours())+pad(d.getUTCMinutes())+pad(d.getUTCSeconds())+'.00';
  let ds=pad(d.getUTCDate())+pad(d.getUTCMonth()+1)+pad(d.getUTCFullYear()%100);
  let fc=(dec,isLat)=>{let dir=dec>=0?(isLat?'N':'E'):(isLat?'S':'W'),a=Math.abs(dec),deg=Math.floor(a),min=((a-deg)*60).toFixed(5);return pad(deg,isLat?2:3)+pad(min,8)+','+dir;};
  let cs=s=>{let ck=0;for(let i=0;i<s.length;i++)ck^=s.charCodeAt(i);return ck.toString(16).toUpperCase().padStart(2,'0');};
  let rmc='GPRMC,'+ts+',A,'+fc(c.latitude,true)+','+fc(c.longitude,false)+','+((c.speed||0)*1.94384).toFixed(1)+','+(c.heading||0).toFixed(1)+','+ds+',,,A';
  let gga='GPGGA,'+ts+','+fc(c.latitude,true)+','+fc(c.longitude,false)+',1,08,1.0,'+(c.altitude||0).toFixed(1)+',M,0.0,M,,';
  return '$'+rmc+'*'+cs(rmc)+'\r\n$'+gga+'*'+cs(gga)+'\r\n';
}

// CAPTURES
function loadFiles(){apiJson('list_files').then(d=>{let c=document.getElementById('fileList');if(!c)return;c.innerHTML='';if(!d||!d.length){c.innerHTML='<span style="color:var(--c-dim)">No captures yet.</span>';return;}d.forEach(f=>{let name=String(f.name||'');let item=document.createElement('div');item.className='file-item';let nameDiv=document.createElement('div');nameDiv.className='fi-name';nameDiv.textContent=name;let netsDiv=document.createElement('div');netsDiv.className='fi-nets';netsDiv.textContent=String(f.nets||'');let metaDiv=document.createElement('div');metaDiv.className='fi-meta';metaDiv.textContent=String(f.size||'')+' '+String(f.date||'');let btn=document.createElement('button');btn.className='btn small stop';btn.textContent='✕';btn.addEventListener('click',()=>deleteFile(encodeURIComponent(name)));item.appendChild(nameDiv);item.appendChild(netsDiv);item.appendChild(metaDiv);item.appendChild(btn);c.appendChild(item);});}).catch(e=>{setHtml('fileList',dim('files error: '+(e.message||'unknown')));});}
function deleteFile(fn){fetch(apiUrl('delete_file') + '&file='+fn).then(()=>{loadFiles();updateStatus();});}
function togglePcap(){fetch(apiUrl('set_pcap_retention') + '&keep='+document.getElementById('chkKeepPcap').checked);}
function uploadPotfile(){let f=document.getElementById('potfileInput').files[0];if(!f)return;document.getElementById('potfileStatus').innerText='Uploading...';fetch(apiUrl('upload_potfile'),{method:'POST',body:f}).then(()=>{document.getElementById('potfileStatus').innerText='✓ Uploaded!';loadCrackedNetworks();});}
function loadCrackedNetworks(){
  if(!map)return;
  let c=document.getElementById('chkCracked');
  if(c&&!c.checked){clearCrackedMarkers();return;}
  let openLatLon=null;
  crackedMarkers.forEach(m=>{if(m.isPopupOpen())openLatLon=m.getLatLng().lat.toFixed(7)+','+m.getLatLng().lng.toFixed(7);});
  apiJson('cracked_networks').then(d=>{
    crackedMarkers.forEach(m=>map.removeLayer(m));crackedMarkers=[];
    if(!d||!d.length)return;
    let groups={};
    d.forEach(n=>{let lat=parseFloat(n.lat),lon=parseFloat(n.lon);if(isNaN(lat)||isNaN(lon))return;let k=lat.toFixed(7)+','+lon.toFixed(7);if(!groups[k])groups[k]={lat,lon,nets:[]};groups[k].nets.push({ssid:String(n.ssid||'??'),pwd:String(n.password||'')});});
    Object.keys(groups).forEach(k=>{
      let g=groups[k],count=g.nets.length;
      let badge=count>1?'<span style="position:absolute;right:-5px;top:-7px;background:#00ff66;color:#001b0a;border-radius:9px;min-width:16px;height:16px;font:bold 11px/16px sans-serif;text-align:center;box-shadow:0 0 5px #0f0">'+count+'</span>':'';
      let rows=g.nets.map(n=>'<div style="margin:6px 0;font-size:18px">📶 <b>'+esc(n.ssid)+'</b>'+(n.pwd?'<br><b style="font-size:18px">🔑 '+esc(n.pwd)+'</b>':'')+'</div>').join('');
      let popup='<div style="font-size:18px"><b style="font-size:18px">🔓 CRACKED'+(count>1?' x'+count:'')+'!</b><br>'+rows+'</div>';
      let m=L.marker([g.lat,g.lon],{icon:L.divIcon({className:'cracked-icon',html:'<div style="position:relative;font-size:22px;text-shadow:0 0 5px #0f0;line-height:28px;text-align:center">🔓'+badge+'</div>',iconSize:[34,34]})}).addTo(map).bindPopup(popup,{maxWidth:340,minWidth:220});
      if(openLatLon&&openLatLon===k)m.openPopup();
      crackedMarkers.push(m);
    });
  }).catch(e=>{setText('logBox','Cracked networks failed: '+(e.message||'unknown'));});
}

// REPLAY THEATER
function renderReplayEvent(kind,msg){
  replayEvents.unshift({kind,msg});
  replayEvents=replayEvents.slice(0,40);
  let h=replayEvents.map(e=>'<div class="event-row"><span class="kind">'+esc(e.kind)+'</span>'+esc(e.msg)+'</div>').join('');
  setHtml('rpEvents',h||'<div class="event-row"><span class="kind">idle</span>Waiting for replay.</div>');
}
function updateReplayUi(d){
  d=d||{};
  lastReplayState=d.state||'idle';
  let idx=parseInt(d.index||0),total=parseInt(d.total||0),pct=total?Math.min(100,Math.round(idx*100/total)):0;
  setText('rpPoint',idx+' / '+total);
  setText('rpNearby',(d.nearby||0)+' nets');
  setText('rpSent',(d.sent||0)+' sent');
  setText('rpGpu',d.gpu||'IDLE');
  setText('rpCracks',d.cracks||0);
  setText('rpEvent',d.event||'No replay loaded');
  setText('rpCoords',(d.lat||0)+', '+(d.lon||0));
  let startBtn=document.getElementById('btnReplayStart');
  if(startBtn)startBtn.innerText=d.paused?'▶ Resume':(d.state==='running'?'▶ Running':'▶ Start');
  let tl=document.getElementById('rpTimeline');if(tl)tl.style.width=pct+'%';
  setText('replayStatusText',(d.state||'idle').toUpperCase()+' | queue '+(d.queue_pending||0)+'/'+(d.queue_done||0)+' | delay '+(d.effective_delay_ms||'?')+'ms | tx '+(d.tx||'IDLE'));
  let lat=parseFloat(d.lat),lon=parseFloat(d.lon);
  if(replayMap&&replayMarker&&!isNaN(lat)&&!isNaN(lon)&&lat!==0&&lon!==0){
    replayMarker.setLatLng([lat,lon]);
    if(replayFollowMode){
      replayMap.panTo([lat,lon],{animate:true,duration:0.3});
      if(replayMap.getZoom()<15)replayMap.setZoom(16);
    }
  }
  if(d.nearby_networks&&d.nearby_networks.length){mergeReplayNetworks(d.nearby_networks);renderReplayNetworks();}
  if(d.state==='running'||d.state==='paused'||d.state==='done')loadReplayDiscovered();
  if(d.event&&window.lastReplayEvent!==d.event){
    window.lastReplayEvent=d.event;
    renderReplayEvent(d.state||'frame',d.event);
  }
  if(d.state==='running'){
    setPipe('pipeCapture','ok','REPLAY');setPipe('pipeGpu',d.gpu==='ERR'?'err':(d.gpu==='UPLOAD'?'warn':'ok'),d.gpu||'GPU');setPipe('pipeTx',d.tx==='TX'?'warn':'ok',d.tx||'IDLE');
  }
}
function updateReplayFollowButton(){
  let b=document.getElementById('btnReplayFollow');if(!b)return;
  b.className='btn small '+(replayFollowMode?'cyan':'dim');
  b.innerText=replayFollowMode?'📍 Follow':'⊙ Free';
}
function toggleReplayFollow(){
  replayFollowMode=!replayFollowMode;
  updateReplayFollowButton();
}
function fitReplayNetworks(){
  let pts=Object.values(replayDiscoveredItems).map(n=>[parseFloat(n.lat),parseFloat(n.lon)]).filter(p=>!isNaN(p[0])&&!isNaN(p[1])&&p[0]!==0&&p[1]!==0);
  if(!pts.length||!replayMap)return;
  replayFollowMode=false;updateReplayFollowButton();
  replayMap.fitBounds(L.latLngBounds(pts),{padding:[28,28],maxZoom:16});
}
function loadReplayStatus(){
  apiJson('replay_status').then(updateReplayUi).catch(e=>setText('replayStatusText','Replay status error: '+(e.message||'unknown')));
}
function startReplayTheater(){
  let f=document.getElementById('replayCsv').files[0];
  if(!f&&lastReplayState!=='paused'){showToast('Choose a WiGLE CSV first','warn');return;}
  let delay=document.getElementById('replayDelay').value||500,radius=document.getElementById('replayRadius').value||75,clean=document.getElementById('replayClean').checked?'1':'0';
  replayEvents=[];window.lastReplayEvent='';
  let body=f||new Blob([]);
  renderReplayEvent(f?'upload':'resume',f?'Uploading '+f.name:'Resuming replay');
  setText('replayStatusText',f?'Uploading replay CSV...':'Resuming replay...');
  if(f){replayFollowMode=true;updateReplayFollowButton();replayDiscoveredItems={};if(replayMap)replayNetworkMarkers=drawNetworkLayer(replayMap,[],replayNetworkMarkers,true);}
  fetch(apiUrl('replay_start',{delay,radius,clean,resume:f?'0':'1'}),{method:'POST',body}).then(r=>r.json()).then(d=>{
    if(d.status==='started'||d.status==='resumed'){
      renderReplayEvent(d.status,d.status+' job '+d.pid);
      if(replayPollTimer)clearInterval(replayPollTimer);
      replayPollTimer=setInterval(loadReplayStatus,2000);
      if(replayDiscoveredTimer)clearInterval(replayDiscoveredTimer);
      replayDiscoveredTimer=setInterval(loadReplayDiscovered,3000);
      loadReplayStatus();
      loadReplayDiscovered();
    }else{
      setText('replayStatusText','Error: '+(d.reason||d.error||'unknown'));
      showToast(d.reason||d.error||'Replay failed','err');
    }
  }).catch(e=>{setText('replayStatusText','Replay start failed: '+(e.message||'unknown'));});
}
function stopReplayTheater(){
  apiJson('replay_stop').then(()=>{renderReplayEvent('stop','Stop requested');loadReplayStatus();loadReplayDiscovered();}).catch(e=>setText('replayStatusText','Stop failed: '+(e.message||'unknown')));
}
function pauseReplayTheater(){
  apiJson('replay_pause').then(()=>{renderReplayEvent('pause','Replay paused');loadReplayStatus();}).catch(e=>setText('replayStatusText','Pause failed: '+(e.message||'unknown')));
}
function seekReplayTheater(delta){
  let cur=parseInt((document.getElementById('rpPoint').innerText||'0').split('/')[0])||0;
  let idx=Math.max(0,cur+delta);
  apiJson('replay_seek',{idx}).then(()=>{renderReplayEvent('seek','Jump requested to point '+idx);}).catch(e=>setText('replayStatusText','Seek failed: '+(e.message||'unknown')));
}

// SETTINGS
function syncNightButton(){let b=document.getElementById('btnNightDrive'),on=document.body.classList.contains('night-mode');if(b)b.innerText=on?'☀':'☾';let c=document.getElementById('chkNight');if(c)c.checked=on;}
function toggleNightMode(){let n=document.getElementById('chkNight').checked;localStorage.setItem('nightMode',n);if(n)document.body.classList.add('night-mode');else document.body.classList.remove('night-mode');syncNightButton();}
function toggleNightModeQuick(){let n=!document.body.classList.contains('night-mode');localStorage.setItem('nightMode',n);if(n)document.body.classList.add('night-mode');else document.body.classList.remove('night-mode');syncNightButton();showToast(n?'Night mode on':'Night mode off');}
if(localStorage.getItem('nightMode')==='true'){document.body.classList.add('night-mode');window.addEventListener('DOMContentLoaded',syncNightButton);}else{window.addEventListener('DOMContentLoaded',syncNightButton);}
function isFullscreen(){return !!(document.fullscreenElement||document.webkitFullscreenElement);}
function syncFullscreenButton(){let b=document.getElementById('btnFullscreen');if(!b)return;let on=isFullscreen();b.classList.toggle('active',on);b.innerText=on?'↙':'⛶';b.title=on?'Exit fullscreen':'Fullscreen';}
function toggleFullscreen(){let root=document.documentElement;if(isFullscreen()){let exit=document.exitFullscreen||document.webkitExitFullscreen;if(exit){let r=exit.call(document);if(r&&r.catch)r.catch(()=>showToast('Fullscreen exit failed','warn'));}else showToast('Fullscreen unavailable','warn');return;}let req=root.requestFullscreen||root.webkitRequestFullscreen;if(req){let r=req.call(root);if(r&&r.catch)r.catch(()=>showToast('Fullscreen blocked','warn'));}else showToast('Fullscreen unavailable','warn');}
document.addEventListener('fullscreenchange',syncFullscreenButton);
document.addEventListener('webkitfullscreenchange',syncFullscreenButton);
window.addEventListener('DOMContentLoaded',syncFullscreenButton);
let wakeLockSentinel=null,wakeLockDesired=localStorage.getItem('screenWakeLock')==='true',wakeLockBlockedReason='';
function wakeLockSupported(){return !!(navigator.wakeLock&&navigator.wakeLock.request&&window.isSecureContext);}
function syncWakeLockButton(){
  let b=document.getElementById('btnWakeLock');if(!b)return;
  let active=!!wakeLockSentinel,blocked=wakeLockDesired&&!active&&!!wakeLockBlockedReason;
  b.classList.toggle('active',active);
  b.classList.toggle('warn',blocked);
  b.innerText=active?'◉':(blocked?'!':'◌');
  b.title=active?'Screen wake lock active':(wakeLockDesired?'Screen wake lock pending':'Keep screen awake');
}
async function requestWakeLock(showMessage){
  wakeLockBlockedReason='';
  if(!wakeLockSupported()){
    wakeLockBlockedReason=window.isSecureContext?'unsupported':'https';
    syncWakeLockButton();
    if(showMessage)showToast(window.isSecureContext?'Wake lock unsupported by this browser':'Open dashboard with HTTPS for screen lock','warn');
    return false;
  }
  if(document.hidden)return false;
  try{
    wakeLockSentinel=await navigator.wakeLock.request('screen');
    wakeLockSentinel.addEventListener('release',()=>{wakeLockSentinel=null;syncWakeLockButton();});
    syncWakeLockButton();
    if(showMessage)showToast('Screen lock on');
    return true;
  }catch(e){
    wakeLockBlockedReason=(e&&e.name)||'blocked';
    syncWakeLockButton();
    if(showMessage)showToast('Screen lock blocked: '+wakeLockBlockedReason,'warn');
    return false;
  }
}
async function releaseWakeLock(){
  wakeLockDesired=false;localStorage.setItem('screenWakeLock','false');
  let w=wakeLockSentinel;wakeLockSentinel=null;wakeLockBlockedReason='';
  if(w&&w.release){try{await w.release();}catch(e){}}
  syncWakeLockButton();showToast('Screen lock off');
}
function toggleWakeLock(){
  if(wakeLockDesired)return releaseWakeLock();
  wakeLockDesired=true;localStorage.setItem('screenWakeLock','true');
  requestWakeLock(true);
}
window.addEventListener('DOMContentLoaded',()=>{syncWakeLockButton();if(wakeLockDesired)setTimeout(()=>requestWakeLock(false),500);});
function toggleHighAccuracyGPS(){let e=document.getElementById('chkHighGPS').checked;window.GPS_HIGH_ACCURACY=e;localStorage.setItem('gpsHighAccuracy',e);}
window.GPS_HIGH_ACCURACY=localStorage.getItem('gpsHighAccuracy')==='true';
window.addEventListener('DOMContentLoaded',()=>{if(window.GPS_HIGH_ACCURACY){let c=document.getElementById('chkHighGPS');if(c)c.checked=true;}});
function toggleAudio(){audioEnabled=document.getElementById('chkAudio').checked;localStorage.setItem('audioEnabled',audioEnabled);if(audioEnabled&&'Notification' in window)Notification.requestPermission();}
if(audioEnabled){let c=document.getElementById('chkAudio');if(c)c.checked=true;}
function testAudio(){if('speechSynthesis' in window){window.speechSynthesis.speak(new SpeechSynthesisUtterance('OpenWardRivingT audio active.'));sendNotification('OpenWardRivingT','Audio enabled');}}
function sendNotification(t,b){if('Notification' in window&&Notification.permission==='granted')new Notification(t,{body:b});}
function loadHW(){apiJson('get_hw').then(d=>{let s=document.getElementById('selLED');if(!s)return;s.innerHTML='';let leds=Array.isArray(d.leds)?d.leds:[];if(!leds.length&&d.current_led)leds=[d.current_led];leds.forEach(l=>{let o=document.createElement('option');o.value=l;o.text=l;if(l===d.current_led)o.selected=true;s.appendChild(o);});if(!s.options.length){let o=document.createElement('option');o.value='';o.text='No LEDs found';s.appendChild(o);}let b=document.getElementById('selBtn');if(b)b.value=(d.current_button==='wifi'?'wifi':'wps');syncModeUi(d.mode||'passive');}).catch(e=>{let s=document.getElementById('selLED');if(s){s.innerHTML='';let o=document.createElement('option');o.value='';o.text='LED status unavailable';s.appendChild(o);}console.log('loadHW failed',e);});}
function saveHW(){let l=document.getElementById('selLED').value,b=document.getElementById('selBtn').value,m=document.getElementById('selMode').value;fetch(apiUrl('set_hw') + '&led='+encodeURIComponent(l)+'&btn='+b+'&mode='+m).then(r=>r.json()).then(d=>{syncModeUi(m);if(d.status==='saved')showToast('Hardware saved');});}
function saveWigle(){let t=document.getElementById('wigleToken').value;if(!t)return;fetch(apiUrl('save_wigle_token'),{method:'POST',body:t}).then(r=>r.json()).then(d=>{if(d.status==='ok'){document.getElementById('wigleStatus').innerText='Token Saved!';setTimeout(()=>document.getElementById('wigleStatus').innerText='',3000);}});}
function uploadWigle(){document.getElementById('wigleStatus').innerText='Uploading...';fetch(apiUrl('wigle_upload')).then(r=>r.json()).then(d=>{document.getElementById('wigleStatus').innerText=d.success?'✓ Uploaded!':'Error: '+(d.error||'Unknown');}).catch(()=>{document.getElementById('wigleStatus').innerText='Network Error!';});}
function downloadBBox(){if(!map)return;let b=map.getBounds(),zMin=document.getElementById('dlZoomMin').value||12,zMax=document.getElementById('dlZoomMax').value||16;let n=b.getNorth(),s=b.getSouth(),e=b.getEast(),w=b.getWest();document.getElementById('bboxStatus').innerText='Starting...';fetch(apiUrl('download_bbox') + '&n='+n+'&s='+s+'&e='+e+'&w='+w+'&z1='+zMin+'&z2='+zMax).then(r=>r.json()).then(d=>{if(d.status==='started'){document.getElementById('bboxStatus').innerText='Downloading...';if(dlTimer)clearInterval(dlTimer);dlTimer=setInterval(()=>{fetch(apiUrl('download_status')).then(rr=>rr.json()).then(dd=>{if(dd.status==='DONE'){document.getElementById('bboxStatus').innerText='✓ Done!';clearInterval(dlTimer);}});},3000);}}).catch(()=>{document.getElementById('bboxStatus').innerText='Error';});}
function uploadTiles(){let f=document.getElementById('tilesFile').files[0];if(!f)return;document.getElementById('uploadStatus').innerText='Uploading...';fetch(apiUrl('upload_tiles'),{method:'POST',body:f}).then(r=>r.json()).then(d=>{document.getElementById('uploadStatus').innerText=d.status==='ok'?'✓ Installed!':'Error';setTimeout(()=>{if(map)map.invalidateSize();},1000);}).catch(()=>{document.getElementById('uploadStatus').innerText='Error';});}


// PROCESSING SETTINGS
function loadProcessing(){apiJson('get_processing').then(d=>{let m=document.getElementById('selExtractionMode'),g=document.getElementById('selGpuCracking'),u=document.getElementById('remoteUrl');if(m)m.value=d.extraction_mode||((d.enabled==='1')?'remote':'local');if(g)g.value=String(d.gpu_cracking_enabled== null?'1':d.gpu_cracking_enabled);if(u)u.value=d.url||'';toggleRemoteServerUrl();}).catch(()=>{});}
function toggleRemoteServerUrl(){let m=document.getElementById('selExtractionMode'),g=document.getElementById('selGpuCracking'),box=document.getElementById('remoteUrlContainer');if(box)box.style.display=((m&&m.value==='remote')||(g&&g.value==='1'))?'block':'none';}
function saveProcessing(){let m=document.getElementById('selExtractionMode').value,g=document.getElementById('selGpuCracking').value,u=document.getElementById('remoteUrl').value.trim();if((m==='remote'||g==='1')&&!u){showToast('GPU server URL required','warn');return;}apiJson('set_processing',{extraction_mode:m,gpu_cracking_enabled:g,url:u}).then(d=>{if(d.status==='saved')showToast('Processing saved');}).catch(e=>showToast('Processing save failed: '+(e.message||'unknown'),'err'));}
loadProcessing();

// EXCLUSIONS & TARGETS

function settingsVisible(){let v=document.getElementById('view-settings');return !!(v&&v.classList.contains('active'));}
function loadExclusions(force){if(!force&&!settingsVisible())return;fetch(apiUrl('get_exclusions')).then(r=>r.json()).then(d=>{excludedSSIDs=d||[];renderExclusions();});}
function renderExclusions(){let c=document.getElementById('exclusionsList');if(!c)return;c.innerHTML='';if(!excludedSSIDs.length){let span=document.createElement('span');span.style.color='var(--c-dim)';span.textContent='None';c.appendChild(span);return;}excludedSSIDs.forEach(s=>{let d=document.createElement('div');d.style.cssText='display:flex;justify-content:space-between;padding:8px;border:1px solid var(--border);margin-bottom:4px;border-radius:6px';let span=document.createElement('span');span.textContent=s;let btn=document.createElement('button');btn.className='btn small';btn.style.cssText='border-color:var(--c-red);color:var(--c-red);min-width:60px;min-height:30px';btn.textContent='✕';btn.addEventListener('click',()=>removeExclusion(encodeURIComponent(s)));d.appendChild(span);d.appendChild(btn);c.appendChild(d);});}
function addExclusion(){let v=document.getElementById('newExclusion').value.trim();if(!v)return;fetch(apiUrl('add_exclusion') + '&ssid='+encodeURIComponent(v)).then(()=>{document.getElementById('newExclusion').value='';loadExclusions(true);});}
function removeExclusion(s){fetch(apiUrl('remove_exclusion') + '&ssid='+s).then(()=>loadExclusions(true));}
loadExclusions();setInterval(loadExclusions,30000);
function loadTargets(){fetch(apiUrl('get_targets')).then(r=>r.json()).then(d=>{targetMacs=d||[];renderTargets();});}
function renderTargets(){let c=document.getElementById('targetsList');if(!c)return;c.innerHTML='';targetMacs.forEach(m=>{let d=document.createElement('div');d.style.cssText='display:flex;justify-content:space-between;padding:8px;border:1px solid var(--c-red);margin-bottom:4px;border-radius:6px';let span=document.createElement('span');span.style.cssText='color:var(--c-red);font-weight:bold';span.textContent=m;let btn=document.createElement('button');btn.className='btn small';btn.style.cssText='border-color:var(--c-red);color:var(--c-red);min-width:60px;min-height:30px';btn.textContent='✕';btn.addEventListener('click',()=>removeTarget(encodeURIComponent(m)));d.appendChild(span);d.appendChild(btn);c.appendChild(d);});}
function addTarget(){let m=document.getElementById('newTarget').value.trim().toUpperCase();if(!m)return;fetch(apiUrl('add_target') + '&mac='+encodeURIComponent(m)).then(()=>{document.getElementById('newTarget').value='';loadTargets();});}
function removeTarget(m){fetch(apiUrl('remove_target') + '&mac='+m).then(()=>loadTargets());}
function checkTargets(){if(!isRunning||!targetMacs.length)return;fetch(apiUrl('check_targets')).then(r=>r.json()).then(d=>{if(d&&d.length)d.forEach(n=>{if(!alertedTargets.includes(n.mac)){alertedTargets.push(n.mac);if(audioEnabled&&'speechSynthesis' in window)window.speechSynthesis.speak(new SpeechSynthesisUtterance('Target detected! '+n.ssid));}});});}
loadTargets();setInterval(checkTargets,10000);

// HISTORY
function loadHistory(){fetch(apiUrl('history')).then(r=>r.json()).then(d=>{document.getElementById('stHistTotal').innerText=d.total;document.getElementById('stHistWpa3').innerText=d.wpa3;document.getElementById('stHistHs').innerText=d.hs;document.getElementById('stHistDays').innerText=d.days;let c=document.getElementById('historyList');if(!c)return;c.innerHTML='';if(!d.sessions||!d.sessions.length){let span=document.createElement('span');span.style.color='var(--c-dim)';span.textContent='No data';c.appendChild(span);return;}d.sessions.forEach(s=>{let div=document.createElement('div');div.style.cssText='padding:8px;border:1px solid var(--border);border-radius:6px;margin-bottom:4px;display:flex;justify-content:space-between';let s1=document.createElement('span');s1.textContent='📅 '+(s.date||'');let s2=document.createElement('span');s2.textContent=(s.count||0)+' nets';div.appendChild(s1);div.appendChild(s2);c.appendChild(div);});});}

// PWNAGOTCHI
function fetchPwnagotchi(){fetch(apiUrl('pwnagotchi_status')).then(r=>r.json()).then(d=>{let c=document.getElementById('pwnagotchiStatus');if(!c)return;if(!d||!d.uptime){c.innerHTML='<span style="color:var(--c-dim)">No pwnagotchi detected</span>';petPwnagotchiDetected=false;return;}petPwnagotchiDetected=true;c.textContent='Uptime: '+(Math.floor(d.uptime/60)||0)+'m | Mode: '+(d.mode||'AUTO')+' | Hands: '+(d.handshakes||0)+' | Pwns: '+(d.pwnd_tot||0);updatePet();}).catch(()=>{let c=document.getElementById('pwnagotchiStatus');if(c){c.innerHTML='<span style="color:var(--c-dim)">No pwnagotchi detected</span>';petPwnagotchiDetected=false;}});};
setInterval(()=>pollVisible(fetchPwnagotchi),10000);fetchPwnagotchi();

// PET ENGINE
const PF={sleep:['(⇀‿‿↼)','(≖‿‿≖)','(－_－)zZZ'],awake:['(◕‿‿◕)','(◉‿‿◉)','(⊙‿‿⊙)'],bored:['(-__-)','(—__—)','(￣ω￣)'],happy:['(•‿‿•)','(^‿‿^)','(◕‿◕)'],excited:['(ᵔ◡◡ᵔ)','(✜‿‿✜)','(★‿★)'],intense:['(°▃▃°)','(°ロ°)','(⚆ᗝ⚆)'],sad:['(╥﹏╥)','(ಥ﹏ಥ)','(｡•́︿•̀｡)'],grateful:['(♥‿‿♥)','(♡‿‿♡)','(♥ω♥)'],cool:['(⌐■_■)','(단__단)','(▀̿Ĺ̯▀̿ ̿)'],lonely:['(ب__ب)','(︶︹︺)','(๑•́ ₃ •̀๑)']};
const PQ={sleep:['Zzzz...','Dreaming of packets','Recharging'],awake:['Ready to hunt!','New day, new pwns!','Sniff.Deauth.Repeat.'],bored:['I\'m bored...','Let\'s go driving!','Any Wi-Fi around?'],happy:['Best day ever!','All packets belong to us','I pwn therefore I am'],excited:['So many networks!!!','Living the life!','Hack the Planet!'],intense:['Deauth everything!','No more Mr Wi-Fi!','Pretty fly 4 a Wi-Fi'],sad:['Shitty day :/','USB is crying...','Need more space!'],grateful:['Good friends!','Synced & happy!','Home sweet home!'],cool:['I\'ll be back.','Hasta la vista, Wi-Fi','May the Wi-Fi be with you'],lonely:['Nobody to play...','Where is everybody?','So alone...']};
function updatePet(){let f=document.getElementById('petFace'),q=document.getElementById('petQuote'),b=document.getElementById('petBridge');if(!f||!q)return;let fs=PF[petMood]||PF.sleep,qs=PQ[petMood]||PQ.sleep;f.innerText=fs[Math.floor(Math.random()*fs.length)];q.innerText=qs[Math.floor(Math.random()*qs.length)];if(b)b.style.display=petPwnagotchiDetected?'block':'none';}
function setPetMood(m){if(m!==petMood){petMood=m;petLastMoodChange=Date.now();updatePet();}}
function evalMood(hs,r,u,g){if(!r){setPetMood('sleep');return;}if(parseInt(u)>=95){setPetMood('sad');return;}if(g==='0'||g===0){setPetMood('lonely');return;}let n=Date.now(),a=(n-petLastMoodChange)/1000;if(hs>petLastHandshakes){petHandshakeBurst+=(hs-petLastHandshakes);petLastHandshakes=hs;}if(petHandshakeBurst>=5)setPetMood('excited');else if(petHandshakeBurst>=3)setPetMood('happy');else if(petHandshakeBurst>0)setPetMood('intense');else if(hs>0&&a>60)setPetMood('awake');else if(a>300&&hs===0)setPetMood('bored');else if(hs>0)setPetMood('cool');if(a>30&&petHandshakeBurst>0)petHandshakeBurst=Math.max(0,petHandshakeBurst-1);}
function evalMoodDOM(){let hs=parseInt(document.getElementById('hdr_hs').querySelector('.val').innerText)||0;evalMood(hs,isRunning,0,1);}
updatePet();setInterval(updatePet,15000);setInterval(evalMoodDOM,5000);

// POLL INTERVALS
let lastHiddenStatusPoll=0;
function isTabHidden(){return typeof document.hidden==='boolean'&&document.hidden;}
function pollStatus(){let now=Date.now();if(isTabHidden()&&now-lastHiddenStatusPoll<20000)return;lastHiddenStatusPoll=now;updateStatus();}
function pollVisible(fn){if(!isTabHidden())fn();}
document.addEventListener('visibilitychange',()=>{if(!isTabHidden()){if(wakeLockDesired&&!wakeLockSentinel)requestWakeLock(false);updateStatus();updateMap();loadCrackedNetworks();loadNetworkMap();loadReplayStatus();fetchPwnagotchi();}});
setInterval(pollStatus,5000);setInterval(()=>pollVisible(updateMap),10000);setInterval(()=>pollVisible(loadCrackedNetworks),15000);setInterval(()=>pollVisible(loadNetworkMap),20000);setInterval(refreshFreshnessAge,1000);setInterval(()=>pollVisible(loadReplayStatus),5000);
updateStatus();loadFiles();loadHW();loadNetworkMap();
loadReplayStatus();
if(localStorage.getItem('browserGpsActive')==='true'){document.getElementById('chkBrowserGPS').checked=true;toggleBrowserGPS();}
updateMapButtons();
if("serviceWorker" in navigator) {
  navigator.serviceWorker.register("./sw.js").then(reg => console.log("SW registered")).catch(err => console.log("SW error", err));
}

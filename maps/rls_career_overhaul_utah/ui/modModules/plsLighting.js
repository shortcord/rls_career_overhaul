const mod = angular.module('plsLighting', []);
export function install() {
  if (window.__plsLightingVersion === 2026101903) return;
  const host = document.getElementById('angular-root');
  const injector = host && angular.element(host).injector();
  if (!injector) { setTimeout(install, 300); return; }
  window.__plsLightingCleanup?.();
  document.getElementById('pls-game-overlay')?.remove();
  window.__plsLightingVersion = 2026101903;
  const scope = injector.get('$rootScope');
  let state = null, frame = null;
  let typing=false;
  const setTyping=active=>{if(typing===active)return;typing=active;bngApi.engineLua('setCEFTyping('+active+')');};
  const send = data => {
    const bytes = new TextEncoder().encode(JSON.stringify(data));
    const literal = '"' + Array.from(bytes, b => '\\' + String(b).padStart(3, '0')).join('') + '"';
    bngApi.engineLua('if extensions.hbpRgbLighting then extensions.hbpRgbLighting.uiCommand(jsonDecode(' + literal + ')) end');
  };
  const root = document.createElement('div');root.id='pls-game-overlay';
  root.innerHTML='<style>#pls-game-overlay{position:fixed;inset:0;pointer-events:none;z-index:1100;font-family:Arial,sans-serif}#pls-game-launch{position:absolute;right:32px;bottom:55px;pointer-events:auto;display:flex;width:max-content;white-space:nowrap;align-items:center;gap:12px;border-radius:40px;padding:7px 23px 7px 7px;min-height:54px;background:linear-gradient(170deg,#284d3c,#06140d 45%,#0b2618 85%,#3d7555);border:1px solid #00ff7c88;color:#e9fff2;box-shadow:inset 0 2px 2px #d9ffe67d,inset 0 -2px 3px #00ff7c44,0 7px 20px #0006;font-size:14px;cursor:pointer}#pls-game-launch:hover{border-color:#81ffbd;box-shadow:0 0 18px #00ff7c66,inset 0 2px 2px #d9ffe680}#pls-game-launch span{display:grid;place-items:center;width:38px;height:38px;flex:0 0 38px;box-sizing:border-box;border-radius:50%;background:radial-gradient(at 30% 10%,#477e60,#0b2416 65%);border:1px solid #72d89d88;color:#00ff7c;font-size:25px}#pls-game-overlay iframe{position:absolute;right:24px;top:20px;width:min(460px,calc(100vw - 32px));height:calc(100vh - 40px);border:0;pointer-events:auto;background:transparent}#pls-game-launch[hidden]{display:none}</style><button id="pls-game-launch" hidden><span aria-hidden="true">⏻</span>A · Open Lighting Controller</button>';
  document.body.append(root);const launch=root.querySelector('button');
  const launcherStyle=root.querySelector('style'),launcherBase=launcherStyle.textContent;
  function theme(p){const color=/^#[0-9a-f]{6}$/i.test(p?.accent)?p.accent:'#00ff7c';launcherStyle.textContent=launcherBase.replace(/#00ff7c/gi,color);}
  try{theme(JSON.parse(localStorage.getItem('pls-ui-preferences')))}catch(e){}
  launch.querySelector('span').innerHTML='<svg viewBox="0 0 24 24" width="23" height="23" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M12 3v8M6.2 5.7a8 8 0 1 0 11.6 0"/></svg>';
  launch.title='Click to open · drag to move';
  let position=null,drag=null,suppressClick=false;
  try{position=JSON.parse(localStorage.getItem('pls-launch-position'))}catch(e){}
  function place(){if(!position)return;const r=launch.getBoundingClientRect(),x=Math.max(8,Math.min(innerWidth-r.width-8,position.x*(innerWidth-r.width))),y=Math.max(8,Math.min(innerHeight-r.height-8,position.y*(innerHeight-r.height)));launch.style.left=x+'px';launch.style.top=y+'px';launch.style.right='auto';launch.style.bottom='auto'}
  launch.style.touchAction='none';
  launch.onpointerdown=e=>{if(e.button!==0)return;const r=launch.getBoundingClientRect();drag={id:e.pointerId,x:e.clientX,y:e.clientY,left:r.left,top:r.top,moved:false};launch.setPointerCapture(e.pointerId)};
  launch.onpointermove=e=>{if(!drag)return;const dx=e.clientX-drag.x,dy=e.clientY-drag.y;if(Math.hypot(dx,dy)>6)drag.moved=true;if(!drag.moved)return;position={x:(drag.left+dx)/Math.max(1,innerWidth-launch.offsetWidth),y:(drag.top+dy)/Math.max(1,innerHeight-launch.offsetHeight)};place()};
  launch.onpointerup=()=>{if(!drag)return;suppressClick=drag.moved;if(drag.moved){position.x=Math.max(0,Math.min(1,position.x));position.y=Math.max(0,Math.min(1,position.y));try{localStorage.setItem('pls-launch-position',JSON.stringify(position))}catch(e){}}drag=null};
  launch.onpointercancel=()=>{drag=null;suppressClick=true};
  launch.onclick=()=>{if(suppressClick){suppressClick=false;return}send({action:'open'})};
  window.addEventListener('resize',place);
  function render(data){
    state=data;if(!data.inside)stopRepeat();if(!data.panel)colorAdjust=false;launch.hidden=!data.inside||data.panel;if(!launch.hidden)place();
    if(data.panel&&!frame){frame=document.createElement('iframe');frame.title='Punisher Lighting Controller';frame.allow='autoplay';frame.src='/ui/modModules/plsLighting-controller.html?v=2026101903';root.append(frame);}
    if(!data.panel&&frame){setTyping(false);const closing=frame;frame=null;closing.style.display='none';setTimeout(()=>closing.remove(),1200);}
    if(frame)frame.contentWindow.postMessage({pls:'state',data},'*');
  }
  let held=null,repeatDelay=null,repeatTimer=null,colorAdjust=false;
  function stopRepeat(){clearTimeout(repeatDelay);clearInterval(repeatTimer);held=null;}
  function navigate(action){if(!state?.inside)return;if(frame)frame.contentWindow.postMessage({pls:'navigate',action},'*');else if(action==='select')send({action:'open'});}
  const rawUnsubscribe=scope.$on('RawInputChanged',(_e,data)=>{
    if(!state?.inside||!data?.devName?.startsWith('xinput'))return;
    if(colorAdjust&&frame&&['thumblx','thumbly'].includes(data.control)){frame.contentWindow.postMessage({pls:'colorAxis',axis:data.control,value:Number(data.value)},'*');return;}
    const action={btn_a:'select',btn_b:'back',upov:'up',dpov:'down',lpov:'left',rpov:'right'}[data.control];
    if(!action)return;
    if(Number(data.value)<.5){if(held===data.control)stopRepeat();if(frame)frame.contentWindow.postMessage({pls:'padRelease'},'*');return;}
    if(held===data.control)return;
    stopRepeat();held=data.control;navigate(action);
    if(['up','down','left','right'].includes(action))repeatDelay=setTimeout(()=>{repeatTimer=setInterval(()=>navigate(action),60)},400);
  });
  const suspendPad=()=>{setTyping(false);stopRepeat();if(frame)frame.contentWindow.postMessage({pls:'padCancel'},'*')};
  window.addEventListener('blur',suspendPad);
  const escape=e=>{if(frame&&e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();navigate('back')}};
  window.addEventListener('keydown',escape,true);
  const unsubscribe=scope.$on('PLSLightingState',(_e,data)=>render(data));
  const typingUnsubscribe=scope.$on('CEFTypingLostFocus',()=>{setTyping(false);if(frame)frame.contentWindow.postMessage({pls:'releaseFavoriteTyping'},'*');});
  const onMessage=e=>{
    if(!frame||e.source!==frame.contentWindow||!e.data||e.data.pls!=='command')return;
    if(e.data.data.action==='favoriteTyping'){
      const input=frame.contentDocument?.activeElement;
      setTyping(Boolean(e.data.data.active&&state?.panel&&input?.matches('.favorite-name')&&input.getClientRects().length));return;
    }
    if(e.data.data.action==='ready'){let preferences={};try{preferences=JSON.parse(localStorage.getItem('pls-ui-preferences'))||{}}catch(err){}frame.contentWindow.postMessage({pls:'preferences',data:preferences},'*');frame.contentWindow.postMessage({pls:'state',data:state},'*');return;}
    if(e.data.data.action==='preferences'){theme(e.data.data.preferences);try{localStorage.setItem('pls-ui-preferences',JSON.stringify(e.data.data.preferences))}catch(err){}return;}
    if(e.data.data.action==='colorAdjust')colorAdjust=e.data.data.active===true;
    send(e.data.data);
  };
  window.addEventListener('message',onMessage);
  window.__plsLightingCleanup=()=>{setTyping(false);typingUnsubscribe?.();unsubscribe?.();window.removeEventListener('message',onMessage);window.removeEventListener('resize',place);stopRepeat();window.removeEventListener('blur',suspendPad);rawUnsubscribe?.();window.removeEventListener('keydown',escape,true);root.remove();window.__plsLightingVersion=null;};
  send({action:'status'});
}
mod.run(()=>install());
export default mod;

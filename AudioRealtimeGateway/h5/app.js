const $ = id => document.getElementById(id)
const ui = { badge: $('connectionBadge'), gateway: $('gatewayUrl'), token: $('token'), connect: $('connectButton'), record: $('recordButton'), recordLabel: $('recordLabel'), recordHint: $('recordHint'), end: $('endButton'), notice: $('notice'), noticeTitle: $('noticeTitle'), noticeBody: $('noticeBody'), retry: $('retryButton'), messages: $('messages'), empty: $('emptyState'), clear: $('clearButton'), sessionHint: $('sessionHint'), level: $('level') }
const saved = localStorage.getItem('qwen.gateway.url')
ui.gateway.value = saved || `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/api/realtime`
ui.token.value = sessionStorage.getItem('qwen.session.token') || ''

let ws, stream, context, source, worklet, recording = false, sequence = 0, scope, playAt = 0, retryAction
const states = { offline:'未连接', connecting:'连接中', online:'已连接', failed:'连接失败', reconnecting:'重连中' }
function setState(state) { ui.badge.className=`badge ${state}`; ui.badge.querySelector('b').textContent=states[state]; ui.connect.textContent=state==='online'?'重新连接':'连接 Gateway'; ui.record.disabled=state!=='online'; ui.end.disabled=state!=='online' }
function notice(title, body, action='重试', fn=connect) { ui.notice.hidden=false; ui.noticeTitle.textContent=title; ui.noticeBody.textContent=body; ui.retry.textContent=action; retryAction=fn }
function clearNotice(){ ui.notice.hidden=true }
function addMessage(role, text) { if(!text?.trim())return; ui.empty.hidden=true; const item=document.createElement('li'); item.className=`message ${role}`; const who=document.createElement('small'); who.textContent=role==='user'?'你':'Qwen'; const content=document.createElement('div'); content.textContent=text; item.append(who,content); ui.messages.append(item); item.scrollIntoView({behavior:'smooth',block:'nearest'}) }
function id(prefix){return `${prefix}_${crypto.randomUUID()}`}

async function connect(reconnecting=false){
  await closeSession(false); clearNotice(); setState(reconnecting?'reconnecting':'connecting')
  const gateway=ui.gateway.value.trim(), credential=ui.token.value.trim()
  if(!/^wss?:\/\//.test(gateway)) { setState('failed'); return notice('地址无效','Gateway 地址必须以 wss:// 或 ws:// 开头。','修改配置',()=>ui.gateway.focus()) }
  let token=credential, issuedScope=null
  if(credential.startsWith('{')){try{const issued=JSON.parse(credential);token=issued.token;issuedScope=issued.scope}catch{return failed(new Error('签发响应 JSON 无法解析'))}}
  if(!/^rtk_[A-Za-z0-9_]+$/.test(token)) { setState('failed'); return notice('需要会话 token','请输入开发 token，或粘贴 /v1/realtime/session-token 返回的完整 JSON。','填写 token',()=>ui.token.focus()) }
  localStorage.setItem('qwen.gateway.url',gateway); sessionStorage.setItem('qwen.session.token',credential)
  scope=issuedScope||{device_id:'h5-browser',session_id:id('session'),request_id:id('request'),generation:1}
  if(!scope.device_id||!scope.session_id||!scope.request_id||!Number.isInteger(scope.generation)) return failed(new Error('签发响应缺少完整 scope'))
  const url=new URL(gateway); Object.entries(scope).forEach(([k,v])=>url.searchParams.set(k,v))
  try { ws=new WebSocket(url,['realtime-v1',token]) } catch(error) { return failed(error) }
  const timeout=setTimeout(()=>{ws?.close();failed(new Error('连接超时'))},10000)
  ws.onopen=()=>{clearTimeout(timeout);ws.send(JSON.stringify({type:'session.start',session_id:scope.session_id,request_id:scope.request_id,generation:scope.generation,protocol_version:1}))}
  ws.onmessage=event=>handleMessage(JSON.parse(event.data))
  ws.onerror=()=>failed(new Error('无法连接 Gateway'))
  ws.onclose=event=>{clearTimeout(timeout);if(ws){ws=null;if(recording)stopRecording(false);setState('failed');notice('连接已断开',event.reason||`WebSocket 已关闭（${event.code}）`,'重新连接',()=>connect(true))}}
}
function failed(error){setState('failed');notice('连接失败',error?.message||'请检查 Gateway 地址、token 与网络。','重试',()=>connect(true))}
function send(type, extra={}){if(ws?.readyState!==WebSocket.OPEN)return;ws.send(JSON.stringify({type,session_id:scope.session_id,request_id:scope.request_id,generation:scope.generation,...extra}))}
function handleMessage(msg){
  if(msg.type==='ready'){setState('online');clearNotice();ui.recordHint.textContent='点击开始录音';ui.sessionHint.textContent='Gateway 已就绪';return}
  if(msg.type==='transcript.final'){addMessage(msg.role,msg.content);return}
  if(msg.type==='audio.delta'){playPcm(msg.audio,msg.sample_rate||24000,msg.response_id);return}
  if(msg.type==='audio.segment_done'){ui.sessionHint.textContent='正在继续回答…';return}
  if(msg.type==='audio.done'){ui.sessionHint.textContent='回答完成';send('playback.ended',{response_id:msg.response_id});return}
  if(msg.type==='error'){notice('会话出错',`${msg.code}${msg.detail?`：${msg.detail}`:''}`,msg.retriable?'重新连接':'关闭提示',msg.retriable?()=>connect(true):clearNotice)}
}

async function startRecording(){
  if(!navigator.mediaDevices?.getUserMedia) return notice('浏览器不支持录音','请使用最新版 Chrome 或 Safari，并通过 HTTPS（localhost 除外）访问。','知道了',clearNotice)
  try{
    stream=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true,autoGainControl:true}})
    context ||= new AudioContext(); await context.resume(); source=context.createMediaStreamSource(stream)
    const code=`class P extends AudioWorkletProcessor{process(i){const c=i[0]?.[0];if(c)this.port.postMessage(c);return true}}registerProcessor('pcm-capture',P)`
    const blob=URL.createObjectURL(new Blob([code],{type:'text/javascript'})); await context.audioWorklet.addModule(blob); URL.revokeObjectURL(blob)
    worklet=new AudioWorkletNode(context,'pcm-capture'); source.connect(worklet); worklet.connect(context.destination); sequence=0; recording=true
    worklet.port.onmessage=e=>sendPcm(resample(e.data,context.sampleRate,16000))
    ui.record.classList.add('recording');ui.recordLabel.textContent='停止并发送';ui.recordHint.textContent='正在聆听…';ui.sessionHint.textContent='录音中'
  }catch(error){const denied=error?.name==='NotAllowedError';notice(denied?'麦克风权限被拒绝':'无法开启麦克风',denied?'请在浏览器网站设置中允许麦克风，然后重试。':error.message,denied?'再次授权':'重试',startRecording)}
}
function sendPcm(samples){if(!samples.length)return;const pcm=new Int16Array(samples.length);let peak=0;for(let i=0;i<samples.length;i++){const v=Math.max(-1,Math.min(1,samples[i]));peak=Math.max(peak,Math.abs(v));pcm[i]=v<0?v*32768:v*32767}ui.level.style.setProperty('--level',String(1+peak*3));const bytes=new Uint8Array(pcm.buffer);let s='';for(let i=0;i<bytes.length;i+=8192)s+=String.fromCharCode(...bytes.subarray(i,i+8192));send('audio.append',{sequence:sequence++,audio:btoa(s),codec:'pcm_s16le',sample_rate:16000})}
function resample(input,from,to){if(from===to)return input;const n=Math.round(input.length*to/from),out=new Float32Array(n),ratio=from/to;for(let i=0;i<n;i++)out[i]=input[Math.min(input.length-1,Math.floor(i*ratio))];return out}
function stopRecording(commit=true){if(!recording)return;recording=false;worklet?.disconnect();source?.disconnect();stream?.getTracks().forEach(t=>t.stop());worklet=source=stream=null;ui.record.classList.remove('recording');ui.recordLabel.textContent='开始说话';ui.recordHint.textContent=commit?'正在等待回答…':'点击开始录音';if(commit&&sequence>0){send('audio.commit',{sequence:sequence-1});ui.sessionHint.textContent='Qwen 正在思考…'}}
async function playPcm(base64,rate,responseId){context ||= new AudioContext();await context.resume();const raw=atob(base64),pcm=new Int16Array(raw.length/2);for(let i=0;i<pcm.length;i++)pcm[i]=(raw.charCodeAt(i*2)|(raw.charCodeAt(i*2+1)<<8));const buffer=context.createBuffer(1,pcm.length,rate),data=buffer.getChannelData(0);for(let i=0;i<pcm.length;i++)data[i]=pcm[i]/32768;const node=context.createBufferSource();node.buffer=buffer;node.connect(context.destination);playAt=Math.max(context.currentTime+.03,playAt);node.start(playAt);if(playAt<=context.currentTime+.04)send('playback.started',{response_id:responseId});playAt+=buffer.duration;ui.sessionHint.textContent='正在播放回答'}
async function closeSession(graceful=true){if(recording)stopRecording(false);if(ws){if(graceful)send('close',{reason:'user_ended'});const old=ws;ws=null;old.onclose=null;old.close()}setState('offline');ui.recordHint.textContent='需先连接 Gateway'}

ui.connect.addEventListener('click',()=>connect());ui.record.addEventListener('click',()=>recording?stopRecording():startRecording());ui.end.addEventListener('click',()=>closeSession());ui.retry.addEventListener('click',()=>retryAction?.());ui.clear.addEventListener('click',()=>{ui.messages.replaceChildren();ui.empty.hidden=false});window.addEventListener('pagehide',()=>closeSession());setState('offline')

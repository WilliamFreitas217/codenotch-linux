// ===== Notification history (inbox.rs) =====
// A bell after the rings while there is any history, its badge the unread count. Hovering it opens
// the history in the same card the rings use (hoverId 'inbox'); opening it, or clicking the bell,
// marks everything seen. A reply or a permission request jumps to its session when clicked.
function inboxCellHtml(i){
  return `<div class="cell inbox" data-p="inbox" style="--i:${i}"><div class="ringwrap">`
    +`<svg class="bell" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2 2 0 0 0 4 0"/></svg>`
    +`<span class="badge"></span></div></div>`;
}
function renderInboxCell(){
  const cell=pill.querySelector('.cell.inbox'); if(!cell) return;
  const n=inbox.filter(i=>!i.read).length;
  cell.classList.toggle('unread',n>0);
  cell.querySelector('.badge').textContent=n>9?'9+':String(n);
}
function ibText(s){
  const pt={'Notifications':'Notificações','Nothing here yet.':'Nada por aqui ainda.','Clear':'Limpar',
    reply:'resposta',renewal:'renovação',permission:'permissão'};
  return (uiLang==='pt-BR'&&pt[s])||s;
}
function ibTime(at){
  const d=new Date(at), locale=ui().locale;
  const t=d.toLocaleTimeString(locale,{hour:'numeric',minute:'2-digit',hourCycle:stateSnap.clock_24h?'h23':'h12'});
  return daysApart(at,Date.now())===0?t:d.toLocaleDateString(locale,{month:'short',day:'numeric'})+' '+t;
}
function renderInboxCard(c){
  // Seen as soon as it opens; what was new keeps its dot until the card closes (hideCard)
  if(inboxLit===null){
    inboxLit=new Set(inbox.filter(i=>!i.read).map(i=>i.id));
    if(inboxLit.size) invoke('inbox_seen').catch(()=>{});
  }
  const kind={reply:'reply',reset:'renewal',attention:'permission'};
  let html=`<div class="c-head"><span class="c-title">${esc(ibText('Notifications'))}</span></div>`;
  if(!inbox.length) html+=`<div class="c-note">${esc(ibText('Nothing here yet.'))}</div>`;
  inbox.forEach((it,i)=>{
    const p=providers().find(x=>x.base===it.provider);
    const icon=p?(glyphHtml(p,true)||esc(p.glyph)):'';
    const cls=`ib-row ${it.kind}${inboxLit.has(it.id)?' new':''}${it.session?' go':''}`;
    html+=`<div class="${cls}" data-i="${i}"><span class="ib-icon">${icon}</span><div class="ib-main">`
      +`<div class="ib-top"><span class="ib-title">${esc(it.title)}</span><span class="ib-time">${esc(ibText(kind[it.kind]||it.kind))} · ${esc(ibTime(it.at))}</span></div>`
      +`<div class="ib-text">${esc(it.text)}</div></div></div>`;
  });
  if(inbox.length) html+=`<div class="ib-foot"><button id="ib-clear">${esc(ibText('Clear'))}</button></div>`;
  c.innerHTML=html;
  c.querySelectorAll('.ib-row.go').forEach(row=>{
    row.onclick=e=>{ e.stopPropagation(); const it=inbox[+row.dataset.i]; if(it) invoke('focus_session',{id:it.session}).catch(()=>{}); };
  });
  const clear=c.querySelector('#ib-clear');
  if(clear) clear.onclick=e=>{ e.stopPropagation(); invoke('inbox_clear').catch(()=>{}); };
  placeCard();
}
function onInbox(){
  // Cleared while open: the bell is leaving, so the card goes with it
  if(!inbox.length&&hoverId==='inbox'){ hoverId=(providers()[0]||{}).id||'claude'; hideCard(); }
  renderRing();
  if(hoverId==='inbox'&&card.classList.contains('show')){ renderCard(); armWatchdog(); }
}
listen('inbox',e=>{ inbox=e.payload||[]; onInbox(); }).catch(()=>{});
invoke('get_inbox').then(list=>{ inbox=list||[]; onInbox(); }).catch(()=>{});

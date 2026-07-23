
/* ================= LADDER SIM ENGINE (addresses with multiple committed positions) ================= */
const COLORS=['#1DB954','#2434C9','#E5484D','#E8A33D','#9B51E0','#0FA3B1','#D96BA0','#6B6B78',
 '#7A4E2D','#3E7C17','#C2185B','#00695C','#5D4037','#7B1FA2','#F57F17','#1565C0','#4E342E','#827717',
 '#008B8B','#8B0000','#2F4F4F','#B8860B','#4B0082','#556B2F','#B22222'];
const NAMES=['A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y'];
let S=null, timer=null, paused=false;

function cfg(){
 // Explicit finite parse — zeros survive (never `|| default`, which coerces 0→default)
 const num=(id,d)=>{const n=Number(document.getElementById(id).value);return Number.isFinite(n)?n:d};
 return{
 N:Math.max(5,num('c-n',5)|0),
 lpShare:Math.min(100,Math.max(0,num('c-lp',80)))/100,
 kappa:Math.min(5,Math.max(1,num('c-k',1.3))),
 holdbackPct:Math.min(90,Math.max(0,num('c-hb',0))),
 excessMode:(()=>{const v=document.getElementById('c-x').value;return (v!==undefined&&v!==null&&v!=='')?v:'lp'})(),
 alpha:Math.log(1+(Math.max(0,num('c-sb',0)))/100)/Math.LN2,
 supply:Math.max(1,num('c-s',1)),
 floorMcap:Math.max(1,num('c-p',1)),
 g:1+Math.max(0,num('c-g',0.2))/100,

 capPct:Math.max(0.0001,num('c-w',0.0001)),
 threshold:Math.max(0,num('c-t',0)),
 ms:Math.max(60,num('c-ms',450)|0)}}

function makeWeights(N){
 const K=Math.max(1,Math.floor(N*0.8)), M=N-K;
 const w=new Array(N).fill(0);
 let sPre=0; for(let i=1;i<=K;i++){w[i-1]=i;sPre+=i}
 for(let i=0;i<K;i++)w[i]=w[i]*0.4/sPre;
 if(M>0){
  const a=w[K-1]; // smooth handoff: finale enters at the shallow curve's exit rate
  if(M===1){w[K]=0.6}
  else if(a*M>=0.6){for(let j=0;j<M;j++)w[K+j]=0.6/M}
  else{
   let lo=1+1e-9,hi=100;
   const f=r=>a*(Math.pow(r,M)-1)/(r-1)-0.6;
   for(let i=0;i<80;i++){const mid=(lo+hi)/2;if(f(mid)>0)hi=mid;else lo=mid}
   const r=(lo+hi)/2;
   for(let j=0;j<M;j++)w[K+j]=a*Math.pow(r,j);
   const sFin=w.slice(K).reduce((x,y)=>x+y,0);
   for(let j=0;j<M;j++)w[K+j]*=0.6/sFin;
  }
 } else { for(let i=0;i<K;i++)w[i]=w[i]/0.4; }
 return w}

function reserveRem(sim){return Math.max(0,sim.reserve-(sim.extraSold||0))}
function auctionSold(sim){return sim.sold-(sim.extraSold||0)}
function schedFor(sim){
 const b=sim.block;
 if(b>=sim.N)return 0;
 const rem=Math.max(0,sim.auctionSupply-auctionSold(sim));
 if(rem<=0)return 0;
 let ws=0;for(let i=b;i<sim.N;i++)ws+=sim.w[i];
 let q=rem*sim.w[b]/(ws||1);
 if(!sim.comp)q=Math.min(q,sim.flatBase);
 return Math.min(q,rem)}
function offeredFor(sim){
 const sched=schedFor(sim);
 // OVERSUBSCRIPTION TOP-UP: once graduated, excess demand buys FROM the reserve (guarded, same block price)
 let topup=0;
 if(sim.threshold>0&&sim.raised>=sim.threshold){
  const rr=reserveRem(sim), p=sim.price;
  if(rr>0){
   const needNow=sim.lpShare*sim.raised/p;                                    // raise so far (conservative: p <= P_final)
   const futureNeed=sim.lpShare*Math.max(0,sim.auctionSupply-auctionSold(sim))/sim.kappa; // headroom at design κ̂
   const drain=Math.max(0,Math.min((rr-needNow-futureNeed)/(1+sim.lpShare), rr));
   let ws=0;for(let i=sim.block;i<sim.N;i++)ws+=sim.w[i];
   topup=drain*(sim.w[Math.min(sim.block,sim.N-1)]/(ws||1)); // weight-paced drain: ramps with the schedule, fully drains by the final block, no one-block cliff
  }}
 return sched+topup}

function newSim(){
 const c=cfg();
 c.floor=c.floorMcap/c.supply;
 c.launchSupply=c.supply*(100-c.holdbackPct)/100;
 c.auctPct=100*c.kappa/(c.kappa+c.lpShare); // auto: auction:reserve = κ̂ : LP-share (reserve = need at a full raise)
 c.auctionSupply=c.launchSupply*c.auctPct/100;
 c.reserve=Math.max(0,c.launchSupply-c.auctionSupply);
 const sp=document.getElementById('splitshow');
 if(sp)sp.textContent='sell '+c.auctPct.toFixed(1)+'% · reserve '+(100-c.auctPct).toFixed(1)+'% of launch (κ̂='+c.kappa+', LP '+(c.lpShare*100).toFixed(0)+'%)';
 return{...c,w:makeWeights(c.N),flatBase:null,block:0,price:c.floor,sold:0,raised:0,comp:false,done:false,graduated:null,
  addrs:[],hist:[],lastSoldPrice:null,deadLogged:false}}

/* ---- addresses & positions ---- */
function addrTok(a){return a.positions.reduce((s,p)=>s+p.tok,0)}
function addrSpent(a){return a.positions.reduce((s,p)=>s+p.spent,0)}
function addrBud(a){return a.positions.reduce((s,p)=>s+p.bud,0)}
function activePos(a){return a.positions.filter(p=>p.status==='active')}
function addrActive(sim,a){return activePos(a).length>0&&addrTok(a)<sim.supply*sim.capPct/100-1e-12}

function startSim(){
 if(S&&!S.done&&S.block>0){log('auction already running, fren. reset first.');return}
 const keep=S?S.addrs:[];
 S=newSim();
 S.flatBase=S.auctionSupply*S.w[0];
 keep.forEach(a=>{if(a.positions.length)S.addrs.push(a)});
 refreshWho();
 log('🔔 auction started. '+S.N+' blocks · '+fmtT(S.supply)+' tokens · floor mcap $'+S.floorMcap.toLocaleString()+' ('+fmt(S.floor)+'/token) · finale at block '+(Math.floor(S.N*0.8)+1));
 runTimer();draw()}

function runTimer(){clearInterval(timer);paused=false;document.getElementById('pausebtn').textContent='⏸ pause';
 timer=setInterval(()=>{if(!paused)tick()},S.ms)}
function pauseSim(){paused=!paused;document.getElementById('pausebtn').textContent=paused?'▶ resume':'⏸ pause'}
function stepOnce(){if(!S){startSim();return}if(!S.done){paused=true;document.getElementById('pausebtn').textContent='▶ resume';tick()}}
function resetSim(){clearInterval(timer);S=null;document.getElementById('banner').className='banner';
 document.getElementById('stats').textContent='press START, fren.';document.getElementById('chart1').innerHTML='';
 document.getElementById('chart2').innerHTML='';document.getElementById('btbody').innerHTML='<tr><td colspan="8" style="text-align:center;color:#6B6B78">no bids yet.</td></tr>';
 document.getElementById('log').innerHTML='';refreshWho()}

function refreshWho(){const sel=document.getElementById('b-who');
 sel.innerHTML=NAMES.map(n=>{
  const a=S&&S.addrs.find(x=>x.name===n);
  const c=a?a.positions.length:0;
  return `<option value="${n}">${n}${c?` (has ${c} bid${c>1?'s':''} — add another)`:''}</option>`}).join('');
 // auto-advance to the next fresh buyer (you can still manually pick a used one to add more bids)
 const next=NAMES.find(n=>!(S&&S.addrs.find(x=>x.name===n&&x.positions.length)));
 if(next)sel.value=next}
function scrambleBud(){document.getElementById('b-bud').value=Math.round(Math.random()*500)}
function placeBid(){
 const name=document.getElementById('b-who').value;
 const bud=+document.getElementById('b-bud').value, maxP=+document.getElementById('b-max').value;
 if(!(bud>0&&maxP>0)){log('bid needs budget and max price.');return}
 addBid(name,bud,maxP)}
function addBid(name,bud,maxP){
 if(!S){S=newSim();S.flatBase=S.supply*S.w[0]}
 if(S.done){log('auction is over. reset for a new one.');return}
 let a=S.addrs.find(x=>x.name===name);
 if(!a){a={name,color:COLORS[NAMES.indexOf(name)%COLORS.length],positions:[],series:[]};S.addrs.push(a)}
 a.positions.push({bud,maxP,spent:0,tok:0,status:'active',blk:S.block});
 log('✋ '+name+' commits $'+bud+' @ max '+fmt(maxP)+' (bid #'+a.positions.length+(S.block>0?', block '+(S.block+1):', pre-start')+') — all of '+name+"'s bids share ONE per-capita share");
 scrambleBud();
 refreshWho();drawTable();drawStats()}

/* ---- one block ---- */
function tick(){
 if(!S||S.done)return;
 const price=S.price;
 // price-outs per position (outbid at max -> that position's leftover is claimable now)
 S.addrs.forEach(a=>a.positions.forEach((p,i)=>{
  if(p.status==='active'&&p.maxP<price){p.status='out_price';
   log('😱 '+a.name+' bid #'+(i+1)+' priced out at '+fmt(p.maxP)+' — $'+(p.bud-p.spent).toFixed(2)+' claimable now')}}));
 // competition ratchet on ADDRESSES
 const activeAddrs=S.addrs.filter(a=>addrActive(S,a));
 if(!S.comp&&activeAddrs.length>1){S.comp=true;log('⚔ block '+(S.block+1)+': competition! release curve begins.')}
 const offered=offeredFor(S);
 const cap=S.supply*S.capPct/100;
 // outer water-fill over address snapshots (each address = ONE share)
 const snaps=S.addrs.map(a=>({a,tok:addrTok(a),spent0:addrSpent(a),
  bud:activePos(a).reduce((s,p)=>s+p.bud,0),spent:activePos(a).reduce((s,p)=>s+p.spent,0),
  status:addrActive(S,a)?'active':'idle',dTok:0}));
 let remaining=offered;
 const wOf=x=>Math.pow(Math.max(1,x.bud),S.alpha); // committed capital, sub-linear tilt
 for(let it=0;it<8&&remaining>1e-12;it++){
  const act=snaps.filter(x=>x.status==='active');
  if(!act.length)break;
  const totW=act.reduce((s2,x)=>s2+wOf(x),0);let used=0;
  act.forEach(x=>{
   const share=remaining*wOf(x)/totW;
   const capLeft=Math.max(0,cap-x.tok), budLeft=Math.max(0,x.bud-x.spent)/price;
   const take=Math.min(share,capLeft,budLeft);
   x.tok+=take;x.spent+=take*price;x.dTok+=take;used+=take;
   if(take<share-1e-12)x.status=(capLeft<=budLeft)?'cap_hit':'bud_hit'});
  remaining-=used}
 // exhaustion sweep: any active position with no budget left is ALL IN (prevents phantom actives)
 S.addrs.forEach(a=>a.positions.forEach((p,i)=>{
  if(p.status==='active'&&p.bud-p.spent<=1e-9){p.status='out_budget';
   log('🫡 '+a.name+' bid #'+(i+1)+' is ALL IN')}}));
 // inner: distribute each address's fill across its active positions (mini water-fill)
 snaps.forEach(x=>{
  if(x.dTok<=1e-15)return;
  let d=x.dTok;const act=activePos(x.a);
  for(let it=0;it<6&&d>1e-15;it++){
   const live=act.filter(p=>p.status==='active');if(!live.length)break;
   const per2=d/live.length;let used2=0;
   live.forEach(p=>{
    const budLeft=Math.max(0,p.bud-p.spent)/price;
    const take=Math.min(per2,budLeft);
    p.tok+=take;p.spent+=take*price;used2+=take;
    if(take<per2-1e-12){p.status='out_budget';log('🫡 '+x.a.name+' bid #'+(x.a.positions.indexOf(p)+1)+' is ALL IN')}});
   d-=used2}
  if(x.status==='cap_hit'){activePos(x.a).forEach(p=>p.status='capped');
   log('😎 '+x.a.name+' hit the wallet cap ('+S.capPct+'%) — all their bids stop, leftovers locked til end')}});
 const soldNow=offered-Math.max(0,remaining);
 // price advances when sales cover the block's ORIGINAL schedule (squished/top-up extra is bonus supply, not a higher bar)
 const schedQty=schedFor(S);
 const gate=Math.min(schedQty,S.w[S.block]*S.auctionSupply);
 S.extraSold=(S.extraSold||0); // ensure init
 const fullySold=gate>0&&soldNow>=gate-Math.max(1e-12,gate*1e-9);
 S.sold+=soldNow;S.raised+=soldNow*price;
 S.extraSold+=Math.max(0,soldNow-schedQty); // over-schedule sales come from the reserve
 if(soldNow>0)S.lastSoldPrice=price;
 const actNow=S.addrs.filter(a=>addrActive(S,a)).length;
 if(actNow===0&&!S.deadLogged&&S.addrs.length){S.deadLogged=true;
  log('🧊 block '+(S.block+1)+': the book is EMPTY — ladder frozen at '+fmt(price)+'. place a new bid (any buyer, even a top-up) to thaw it.')}
 if(actNow>0)S.deadLogged=false;
 S.hist.push({block:S.block+1,offered,sold:soldNow,price,phase:phase()});
 S.addrs.forEach(a=>a.series.push(addrTok(a)));
 if(fullySold)S.price*=effStep(S);
 S.block++;
 if(auctionSold(S)>=S.auctionSupply-1e-9&&offeredFor(S)<=1e-9&&S.raised>=S.threshold){finish('fully distributed at block '+S.block)}
 else if(S.block>=S.N){finish('time up — block '+S.block)}
 draw()}

function committedLive(sim){let t=0;sim.addrs.forEach(a=>a.positions.forEach(p=>{if(p.status!=='out_price')t+=p.bud}));return t}
function effStep(sim){const d=sim.threshold>0?committedLive(sim)/sim.threshold:0;return 1+(sim.g-1)*(1+d)}
function phase(){if(!S.comp)return 'flat';return S.block>=Math.floor(S.N*0.8)?'FINALE 🔥':'shallow'}
function finish(why){
 S.done=true;clearInterval(timer);
 S.graduated=S.raised>=S.threshold;
 const bn=document.getElementById('banner');
 if(S.graduated){
  const P=S.lastSoldPrice||S.price;
  const fundsLP=S.lpShare*S.raised, toCreator=S.raised-fundsLP, tokensNeeded=fundsLP/P;
  const rr=reserveRem(S), extraSold=S.extraSold||0;
  const paired=Math.min(tokensNeeded,rr);
  const auctionExcess=Math.max(0,S.auctionSupply-auctionSold(S)); // offered but not sold
  const surplus=Math.max(0,rr-tokensNeeded);                // pairing surplus (solvency slack)
  const excess=surplus+auctionExcess;
  const modes={lp:'→ thicker LP (single-sided depth ABOVE the print — does not change opening price)',holders:'→ pro-rata airdrop to holders 🎁',creator:'→ creator wallet',burn:'→ BURNED 🔥'};
  bn.className='banner ok';bn.textContent='🔔 GRADUATED — settled at '+fmt(P)+' · raised $'+S.raised.toFixed(2)+' ($'+fundsLP.toFixed(2)+' → LP, $'+toCreator.toFixed(2)+' → creator) · pool: '+fmtT(paired)+' paired · leftover '+fmtT(excess)+' ('+fmtT(surplus)+' pairing surplus + '+fmtT(auctionExcess)+' auction excess) '+modes[S.excessMode]+(S.excessMode==='lp'?' · POOL: '+fmtT(paired+excess)+' tokens + $'+fundsLP.toFixed(2)+' = TVL $'+((paired+excess)*P+fundsLP).toFixed(2)+' at the print':'');
  log('🔔 auction ends ('+why+'). GRADUATED ✓');
  log('⚗ settlement: sold tokens ('+fmtT(S.sold)+') go to bidders'+(extraSold>0?' (incl. '+fmtT(extraSold)+' oversubscription sold FROM the reserve)':'')+' — the pool is built from the remaining reserve ('+fmtT(rr)+' of '+fmtT(S.reserve)+').');
  if(auctionExcess>0)log('⚗ auction excess ('+fmtT(auctionExcess)+' offered but unsold) follows the disposal choice.');
  {const avg=S.sold>0?S.raised/S.sold:P;
   log('⚗ realized κ = '+(P/avg).toFixed(2)+' (design κ̂ = '+S.kappa+') — print '+fmt(P)+' vs avg sale '+fmt(avg)+'. κ > κ̂ → surplus; κ < κ̂ → shortfall (single-sided fallback).');}
  if(surplus>0){const avg=S.sold>0?S.raised/S.sold:P;
   log('⚗ pairing surplus ('+fmtT(surplus)+') — the APPRECIATION DIVIDEND: avg sale price '+fmt(avg)+' vs print '+fmt(P)+' ('+(P/avg).toFixed(1)+'× climb). dollars ÷ print pairs fewer tokens than were sold; the hotter the climb, the bigger the surplus. follows the disposal choice.');}
  log('⚗ initial LP: $'+fundsLP.toFixed(2)+' ('+(S.lpShare*100).toFixed(0)+'% of raise) paired with '+fmtT(paired)+' tokens spanning the print — the RATIO is what makes the pool open at '+fmt(P)+' (deposit everything full-range instead and the pool would open at '+fmt(fundsLP/Math.max(1,paired+excess))+', '+(100*(1-(fundsLP/Math.max(1,paired+excess))/P)).toFixed(0)+'% below the print). creator receives $'+toCreator.toFixed(2)+'.');
  if(excess>0){
   if(S.excessMode==='holders'){
    log('🎁 leftover tokens ('+fmtT(excess)+') airdropped pro-rata to holders:');
    S.addrs.forEach(a=>{const t=addrTok(a);if(t>0){const bonus=excess*t/S.sold;
     log('   🎁 '+a.name+': +'+fmtT(bonus)+' bonus ('+(t/S.sold*100).toFixed(1)+'% of sold)')}})}
   else log('⚗ leftover tokens ('+fmtT(excess)+') '+modes[S.excessMode]);
  }
  if(tokensNeeded>S.reserve)log('⚠ reserve short by '+fmtT(tokensNeeded-S.reserve)+' — leftover funds seed single-sided. (lower auction%/holdback%, or lower LP share.)')}
 else{bn.className='banner fail';bn.textContent='🪦 DID NOT GRADUATE — raised $'+S.raised.toFixed(2)+' < $'+S.threshold+' · everyone refunded 100%';
  log('💀 auction ends ('+why+'). below threshold — ALL refunds, dev never touched the money.')}
 draw()}

/* ================= DRAWING ================= */
function fmt(n){n=Number(n);const d=n>=1?2:n>=.01?4:n>=.0001?6:8;return '$'+n.toFixed(d)}
function fmtT(n){return n>=1e9?(n/1e9).toFixed(2)+'B':n>=1e6?(n/1e6).toFixed(2)+'M':n>=1e3?(n/1e3).toFixed(1)+'K':Math.round(n)+''}
function log(m){const el=document.getElementById('log');el.innerHTML+='<div>'+m+'</div>';el.scrollTop=el.scrollHeight}
function draw(){drawStats();drawChart1();drawChart2();drawTable()}

function drawStats(){
 if(!S)return;
 const el=document.getElementById('stats');
 const pct=(S.sold/S.auctionSupply*100);
 const actN=S.addrs.filter(a=>addrActive(S,a)).length;
 const posN=S.addrs.reduce((s,a)=>s+a.positions.length,0);
 el.innerHTML=`<span>block <b>${S.block}/${S.N}</b></span>
 <span>price <b>${fmt(S.price)}</b> (mcap $${(S.price*S.supply).toLocaleString(undefined,{maximumFractionDigits:0})})</span>
 <span class="ph">phase: <b>${phase()}</b></span>
 <span>step <b>${((effStep(S)-1)*100).toFixed(2)}%</b>/blk (${S.threshold>0?(committedLive(S)/S.threshold).toFixed(1):'0'}× grad bid)</span>
 <span>sold <b>${pct.toFixed(1)}%</b> of auction (auto ${S.auctPct.toFixed(1)}% of launch · ${fmtT(S.sold)})${(S.extraSold||0)>0?' <b class="up">+'+fmtT(S.extraSold)+' from reserve 🔥</b>':''}</span>
 <span>raised <b>$${S.raised.toFixed(2)}</b> / $${S.threshold} ${S.raised>=S.threshold?'<b class="up">✓ graduates</b>':'<b class="down">not yet</b>'}</span>
 <span>active <b>${actN}</b> / ${S.addrs.length} addrs (${posN} bids)</span>
 <span>clear next block: <b>$${(S.price*offeredFor(S)).toFixed(2)}</b> (${(offeredFor(S)/S.supply*100).toFixed(3)}% of supply)${actN===0&&S.addrs.length&&!S.done?' <b class="down">🧊 book frozen — bid to thaw</b>':''}</span>`}

function drawChart1(){
 if(!S)return;
 const W=760,H=250,pl=44,pr=52,pt=10,pb=22;
 const iw=W-pl-pr, ih=H-pt-pb;
 const N=S.N;
 const maxOff=Math.max(...S.hist.map(h=>h.offered),S.auctionSupply*0.02,1e-9);
 const maxPrice=Math.max(...S.hist.map(h=>h.price),S.price)*1.1;
 const X=b=>pl+(b-0.5)/N*iw, BW=Math.max(1.5,iw/N-2);
 const Yq=v=>pt+ih-v/maxOff*ih, Yp=v=>pt+ih-v/maxPrice*ih;
 const finX=pl+Math.floor(N*0.8)/N*iw;
 let bars='';
 S.hist.forEach(h=>{
  const x=X(h.block)-BW/2;
  bars+=`<rect x="${x.toFixed(1)}" y="${Yq(h.offered).toFixed(1)}" width="${BW.toFixed(1)}" height="${(ih+pt-Yq(h.offered)).toFixed(1)}" fill="#E9E9F2" stroke="#B9B9C2" stroke-width="0.5"/>`;
  bars+=`<rect x="${x.toFixed(1)}" y="${Yq(h.sold).toFixed(1)}" width="${BW.toFixed(1)}" height="${(ih+pt-Yq(h.sold)).toFixed(1)}" fill="#1DB954"/>`});
 const pline=S.hist.map(h=>X(h.block).toFixed(1)+','+Yp(h.price).toFixed(1)).join(' ');
 let marks='';
 S.addrs.forEach(a=>a.positions.forEach(p=>{if(p.blk>0)marks+=`<text x="${X(p.blk+0.5).toFixed(1)}" y="${pt+9}" font-size="9" fill="${a.color}" font-family="IBM Plex Mono">▼${a.name}</text>`}));
 document.getElementById('chart1').innerHTML=
 `<svg viewBox="0 0 ${W} ${H}">
   <rect x="${finX.toFixed(1)}" y="${pt}" width="${(pl+iw-finX).toFixed(1)}" height="${ih}" fill="#F8E3A0" opacity="0.55"/>
   ${bars}
   <polyline points="${pline}" fill="none" stroke="#B03A3E" stroke-width="2"/>
   ${marks}
   <line x1="${pl}" y1="${pt+ih}" x2="${pl+iw}" y2="${pt+ih}" stroke="#000"/>
   <text x="${pl}" y="${H-6}" font-size="9" font-family="IBM Plex Mono" fill="#3A3A46">block 1</text>
   <text x="${pl+iw-40}" y="${H-6}" font-size="9" font-family="IBM Plex Mono" fill="#3A3A46">block ${N}</text>
   <text x="4" y="${pt+10}" font-size="9" font-family="IBM Plex Mono" fill="#3A3A46">${fmtT(maxOff)}</text>
   <text x="${W-4}" y="${pt+10}" font-size="9" font-family="IBM Plex Mono" fill="#B03A3E" text-anchor="end">${fmt(maxPrice)}</text>
   <text x="${(finX+6).toFixed(1)}" y="${pt+ih-6}" font-size="10" font-family="IBM Plex Mono" fill="#9A6A12">FINALE — 60% lives here</text>
  </svg>`}

function drawChart2(){
 if(!S)return;
 const W=760,H=170,pl=44,pr=8,pt=8,pb=20;
 const iw=W-pl-pr, ih=H-pt-pb;
 const n=Math.max(1,S.hist.length);
 const cap=S.supply*S.capPct/100;
 const maxTok=Math.max(cap*1.05,...S.addrs.map(a=>addrTok(a)),1e-9);
 const X=i=>pl+i/Math.max(1,n-1)*iw, Y=v=>pt+ih-v/maxTok*ih;
 const capY=Y(cap);
 const lines=S.addrs.map(a=>{
  if(!a.series.length)return '';
  const pts=a.series.map((v,i)=>X(i).toFixed(1)+','+Y(v).toFixed(1)).join(' ');
  return `<polyline points="${pts}" fill="none" stroke="${a.color}" stroke-width="2"/>
   <text x="${(X(a.series.length-1)+3).toFixed(1)}" y="${(Y(addrTok(a))+3).toFixed(1)}" font-size="10" font-weight="700" fill="${a.color}" font-family="IBM Plex Mono">${a.name}</text>`}).join('');
 document.getElementById('chart2').innerHTML=
 `<svg viewBox="0 0 ${W} ${H}">
   <line x1="${pl}" y1="${capY.toFixed(1)}" x2="${pl+iw}" y2="${capY.toFixed(1)}" stroke="#E8A33D" stroke-dasharray="5,3"/>
   <text x="${pl+4}" y="${(capY-4).toFixed(1)}" font-size="9" font-family="IBM Plex Mono" fill="#9A6A12">wallet cap ${S.capPct}% (${fmtT(cap)})</text>
   ${lines}
   <line x1="${pl}" y1="${pt+ih}" x2="${pl+iw}" y2="${pt+ih}" stroke="#000"/>
   <text x="4" y="${pt+10}" font-size="9" font-family="IBM Plex Mono" fill="#3A3A46">${fmtT(maxTok)}</text>
   <text x="${pl}" y="${H-5}" font-size="9" font-family="IBM Plex Mono" fill="#3A3A46">tokens accumulated per ADDRESS (all bids combined) →</text>
  </svg>`}

function drawTable(){
 const tb=document.getElementById('btbody');
 if(!S||!S.addrs.length){tb.innerHTML='<tr><td colspan="9" style="text-align:center;color:#6B6B78">no bids yet.</td></tr>';return}
 const stl={active:['filling','up'],out_price:['priced out','down'],out_budget:['all in','amb'],capped:['capped','up']};
 let html='';
 S.addrs.forEach(a=>{
  a.positions.forEach((p,i)=>{
   const claim=S.done?(S.graduated?p.bud-p.spent:p.bud):(p.status==='out_price'?p.bud-p.spent:0);
   const l=stl[p.status];
   html+=`<tr><td><span class="dot" style="background:${a.color}"></span><b>${a.name}</b> <span style="color:#6B6B78">#${i+1}</span></td>
    <td>$${p.bud.toFixed(2)}</td><td>${fmt(p.maxP)}</td><td>$${p.spent.toFixed(2)}</td>
    <td>${fmtT(p.tok)}</td><td>${p.tok>0?fmt(p.spent/p.tok):'—'}</td><td>${(p.tok/S.supply*100).toFixed(2)}%</td>
    <td class="${l[1]}">${S.done?(S.graduated?'settled ✓':'refunded'):l[0]}</td>
    <td class="up">${claim>0.005?'$'+claim.toFixed(2):'—'}</td></tr>`});
  if(a.positions.length>1){
   html+=`<tr style="font-weight:700"><td style="color:${a.color}">↳ ${a.name} total (one share)</td>
    <td>$${addrBud(a).toFixed(2)}</td><td></td><td>$${addrSpent(a).toFixed(2)}</td>
    <td>${fmtT(addrTok(a))}</td><td>${addrTok(a)>0?fmt(addrSpent(a)/addrTok(a)):'—'}</td><td>${(addrTok(a)/S.supply*100).toFixed(2)}%</td><td></td><td></td></tr>`}});
 tb.innerHTML=html}

/* ================= SCENARIOS ================= */
function scnABC(){resetSim();S=newSim();S.flatBase=S.auctionSupply*S.w[0];
 addBid('A',100,1);addBid('B',200,1);addBid('C',250,1);
 log('📖 the example: equal fills regardless of size. watch A run out first.');
 runTimer();draw()}
function scnWhale(){resetSim();S=newSim();S.flatBase=S.auctionSupply*S.w[0];
 addBid('A',5000,1);['B','C','D','E','F'].forEach(n=>addBid(n,50,1));
 log('🐋 one $5000 whale vs five $50 frens — same per-block fill until frens run dry.');
 runTimer();draw()}
function scnGhost(){resetSim();S=newSim();S.flatBase=S.auctionSupply*S.w[0];
 log('👻 ghost town: no bids until block 15 — watch the schedule squish the missed supply into later blocks.');
 runTimer();
 const bidAt=(blk,n,bud,mx)=>{const iv=setInterval(()=>{if(!S||S.done){clearInterval(iv);return}if(S.block>=blk){addBid(n,bud,mx);clearInterval(iv)}},60)};
 bidAt(15,'A',300,1);bidAt(15,'B',300,1);bidAt(22,'C',400,1);
 draw()}

function updSplit(){
 const num=(id,d)=>{const n=Number(document.getElementById(id).value);return Number.isFinite(n)?n:d};
 const lp=Math.min(100,Math.max(0,num('c-lp',80)))/100;
 const k=Math.min(5,Math.max(1,num('c-k',1.3)));
 const a=100*k/(k+lp);
 const sp=document.getElementById('splitshow');
 if(sp)sp.textContent='sell '+a.toFixed(1)+'% · reserve '+(100-a).toFixed(1)+'% of launch (κ̂='+k+', LP '+(lp*100).toFixed(0)+'%)'}
refreshWho();scrambleBud();updSplit();

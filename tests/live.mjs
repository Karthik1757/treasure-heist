import fs from 'node:fs';
import {createGameClient,ensureGuest,invoke} from '../src/client.js';
import {actionPayload} from '../src/game.js';
const dir=`test-results/live-${new Date().toISOString().replace(/[:.]/g,'-')}`;fs.mkdirSync(dir,{recursive:true});
const report={started:new Date().toISOString(),complete:false,checks:[],failures:[],requests:[],fixtures:{},mode:'two genuine anonymous SDK clients, no simulated backend'};
const save=()=>fs.writeFileSync(`${dir}/results.json`,JSON.stringify({...report,passed:report.checks.length,failed:report.failures.length},null,2));
const check=(name,ok)=>{if(!ok)throw new Error(name);report.checks.push(name);save();console.log('PASS',name)};
const clients=[0,1].map(()=>createGameClient({auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}}));
let snap,room,match,members=[],channels=[],received=[[],[]];
async function rpc(i,op,payload={},opts={}){
 const params={room,match,round:snap?.round,payload,...opts},id=crypto.randomUUID(),event={actor:i,op,id,start:new Date().toISOString()};
 try{const data=await invoke(clients[i],op,{...params,requestId:id});event.ok=data.ok;event.error=data.error;event.revision=data.snapshot?.revision;event.phase=data.snapshot?.phase;event.deadline=data.snapshot?.deadline;if(data.snapshot&&(!snap||data.snapshot.revision>=snap.revision))snap=data.snapshot;return data;}
 catch(e){event.error=e.name;throw e;}finally{event.end=new Date().toISOString();report.requests.push(event);save();}
}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let phasePulse=null; let keepWarm=null;
async function waitPhase(phase,round){
 const limit=Date.now()+65000;
 while(Date.now()<limit){
  if(snap.phase===phase&&(!round||snap.round===round))return;
  if(!phasePulse&&Date.now()>=Date.parse(snap.deadline))phasePulse=rpc(0,'heartbeat_and_advance').finally(()=>{phasePulse=null;});
  await sleep(50);
 }
 throw new Error('phase not reached '+phase);
}
try{
 const sessions=await Promise.all(clients.map(ensureGuest));check('two distinct genuine anonymous identities',sessions.every(s=>s.user.is_anonymous)&&sessions[0].user.id!==sessions[1].user.id);report.fixtures.users=sessions.map(s=>s.user.id);
 let a=await rpc(0,'create_room',{nickname:'SDK Captain'},{room:null,match:null,round:null});check('room created through frontend client',a.ok);room=snap.room_id;members[0]=a.member_id;report.fixtures.room=room;
 a=await rpc(1,'join_room',{nickname:'SDK Rival',code:snap.code},{room:null,match:null,round:null});check('join by eight-character code',a.ok&&snap.code.length===8&&snap.players.length===2);members[1]=a.member_id;
 await Promise.all(clients.map((db,i)=>new Promise((resolve,reject)=>{
  const timer=setTimeout(()=>reject(new Error('Realtime subscription timeout')),25000);
  const c=db.channel('qa-'+room+'-'+i).on('postgres_changes',{event:'UPDATE',schema:'public',table:'room_snapshots',filter:'room_id=eq.'+room},ev=>{received[i].push(ev.new.payload);if(ev.new.payload.revision>snap.revision)snap=ev.new.payload;}).subscribe(status=>{if(status==='SUBSCRIBED'){clearTimeout(timer);resolve();}});channels.push(c);
 })));
 check('both frontend SDK Realtime subscriptions active',channels.length===2);
 // Keep HTTP pools warm across the 8-second reveal: cold proxy connections cost ~8s here.
 keepWarm=setInterval(()=>{for(const c of clients)c.rpc('get_snapshot',{p_room:room}).then(()=>{});},1500);
 report.transport='HTTP connection pools kept warm with read-only snapshots; production deadlines unchanged';
 const ready=await Promise.all([rpc(0,'set_ready',{ready:true}),rpc(1,'set_ready',{ready:true})]);check('both players ready',ready.every(x=>x.ok));
 a=await rpc(0,'start_match',{expected_revision:snap.revision});check('host starts match',a.ok&&snap.round===1);match=snap.match_id;report.fixtures.match=match;
 const plans=[ [{kind:'explore',island:0},{kind:'defend',bank:0}], [{kind:'steal',target:members[1]},{kind:'bluff'}], [{kind:'defend',bank:4},{kind:'explore',island:4}], [{kind:'bluff'},{kind:'steal',target:members[0]}], [{kind:'defend',bank:4},{kind:'defend',bank:0}] ];
 for(let round=1;round<=5;round++){
  await waitPhase('signal',round);
  const signals=await Promise.all([rpc(0,'set_signal',{claim:'guarding'}),rpc(1,'set_signal',{claim:'hunting'})]);check('round '+round+' signals accepted',signals.every(x=>x.ok));
  await waitPhase('plan',round);const before=structuredClone(snap),actions=plans[round-1].map((d,i)=>actionPayload(d,before.players.find(p=>p.id===members[i])));
  const results=await Promise.all(actions.map((p,i)=>rpc(i,'submit_action',p)));check('round '+round+' both actions accepted',results.every(x=>x.ok));await waitPhase('reveal',round);
  const history=snap.history.at(-1);check('round '+round+' intended actions revealed',actions.every((a,i)=>{const x=history.actions.find(x=>x.member_id===members[i]);return x.kind===a.kind&&!x.timed_out&&(a.kind!=='defend'||x.bank_amount===a.bank_amount)}));
  const expected=before.players.map(p=>({id:p.id,purse:p.purse,vault:p.vault}));
  for(let i=0;i<2;i++)if(actions[i].kind==='defend'){expected[i].purse-=actions[i].bank_amount;expected[i].vault+=actions[i].bank_amount+(before.event==='royal_bounty'?2:1);}
  for(let i=0;i<2;i++)if(actions[i].kind==='steal'){const j=1-i;if(actions[j].kind!=='defend'){const gold=Math.min(before.event==='low_tide'?2:3,expected[j].purse);expected[j].purse-=gold;expected[i].purse+=gold;}}
  for(let i=0;i<2;i++)if(actions[i].kind==='bluff')expected[i].purse+=actions[1-i].kind==='steal'?-Math.min(2,expected[i].purse):4;
  for(let i=0;i<2;i++)if(actions[i].kind==='explore'){const l=history.ledger.find(x=>x.member_id===members[i]&&x.kind==='explore');const extra=(before.event==='trade_winds'?1:0)+(before.event==='moonrise'&&actions[i].island===4?2:0);check('round '+round+' explore reward within exact rule set',(actions[i].island===0?[3]:[3,5]).map(x=>x+extra).includes(l.gold));expected[i].purse+=l.gold;}
  check('round '+round+' independent score calculation matches',expected.every(e=>{const p=snap.players.find(p=>p.id===e.id);return p.purse===e.purse&&p.vault===e.vault}));
  for(let w=0;w<50&&!received.every(xs=>xs.some(x=>x.round===round&&x.phase==='reveal'));w++)await sleep(100);
  check('round '+round+' both clients received reveal',received.every(xs=>xs.some(x=>x.round===round&&x.phase==='reveal')));
  report.lastSnapshot=snap;save();
 }
 await waitPhase('results');const ordered=[...snap.players].sort((a,b)=>(b.purse+b.vault)-(a.purse+a.vault)||b.vault-a.vault),best=ordered[0];
 check('final leaderboard and winner calculation',snap.results.length===2&&snap.results.every(x=>x.score===x.purse+x.vault&&x.winner===(x.score===best.purse+best.vault&&x.vault===best.vault)));
 const old=match;a=await rpc(0,'return_to_lobby',{expected_revision:snap.revision});check('return to lobby resets readiness',a.ok&&snap.status==='lobby'&&snap.players.every(p=>!p.ready));
 await Promise.all([rpc(0,'set_ready',{ready:true}),rpc(1,'set_ready',{ready:true})]);a=await rpc(0,'start_match',{expected_revision:snap.revision});check('rematch has fresh match and starting scores',a.ok&&snap.match_id!==old&&snap.players.every(p=>p.purse===6&&p.vault===0));report.complete=true;
}catch(e){report.failures.push({name:e.name,message:e.message.replace(/https?:\/\/\S+/g,'[url]')});console.log('FAIL',e.name);process.exitCode=1;}
finally{clearInterval(keepWarm);report.ended=new Date().toISOString();save();await Promise.all(clients.map(c=>c.removeAllChannels()));console.log('RESULT',dir);}

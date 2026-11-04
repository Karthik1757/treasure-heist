"""Live HTTP tests. Uses temporary authenticated fixtures, never privileged gameplay endpoints."""
import json,time,uuid,threading,concurrent.futures,urllib.request,urllib.error,pathlib
ROOT=pathlib.Path(__file__).parent
USERS=json.loads((ROOT/'test_sessions.json').read_text())
BASE=__import__("os").environ["SUPABASE_URL"]
KEY=__import__("os").environ["SUPABASE_PUBLIC_KEY"]
checks=[];rooms=[];overlaps=[]
def check(name,ok):
 if not ok:raise AssertionError(name)
 checks.append(name)
 print('PASS',name,flush=True)
def http(i,path,data=None,method=None):
 headers={'apikey':KEY,'Content-Type':'application/json'}
 if i is not None:headers['Authorization']='Bearer '+USERS[i]['token']
 req=urllib.request.Request(BASE+path,data=None if data is None else json.dumps(data).encode(),headers=headers,method=method)
 try:
  with urllib.request.urlopen(req,timeout=30) as res:return res.status,json.load(res)
 except urllib.error.HTTPError as e:
  return e.code,json.loads(e.read())
def rpc(i,op,r=None,g=None,rnd=None,p=None,req=None):
 status,data=http(i,'/rest/v1/rpc/'+op,{'p_request_id':req or str(uuid.uuid4()),'p_room':r,'p_match':g,'p_round':rnd,'p_payload':p or {}})
 if status!=200:raise RuntimeError((op,status,data))
 return data
def snap(i,r):
 status,d=http(i,'/rest/v1/rpc/get_snapshot',{'p_room':r})
 if status!=200:raise RuntimeError((status,d))
 return d['snapshot']
def parallel(name,funcs):
 bar=threading.Barrier(len(funcs));intervals=[]
 def run(f):
  bar.wait();start=time.monotonic();ans=f();end=time.monotonic();intervals.append((start,end));return ans
 with concurrent.futures.ThreadPoolExecutor(max_workers=len(funcs)) as ex:results=list(ex.map(run,funcs))
 overlap=max(x[0] for x in intervals)<min(x[1] for x in intervals)
 overlaps.append({'name':name,'requests':len(funcs),'overlap':overlap,'span_ms':round((max(x[1] for x in intervals)-min(x[0] for x in intervals))*1000,1)})
 check(name+' requests overlap',overlap)
 return results
def room(players):
 a=rpc(players[0],'create_room',p={'nickname':'Captain'+str(players[0])});assert a['ok'],a
 r=a['room_id'];rooms.append(r)
 (ROOT/'http_test_rooms.json').write_text(json.dumps(rooms))
 for i in players[1:]:assert rpc(i,'join_room',p={'nickname':'Player'+str(i),'code':a['snapshot']['code']})['ok']
 return r,a['snapshot']['code']
def ready(players,r):
 for i in players:assert rpc(i,'set_ready',r,p={'ready':True})['ok']
def wait_deadline(s):
 from datetime import datetime,timezone
 remaining=datetime.fromisoformat(s['deadline']).timestamp()-time.time()+.12
 if remaining>0:time.sleep(min(remaining,50))

# All requests use genuine access tokens issued by this project's Auth service.
r,code=room([6,0,1,2,3])
out=parallel('race for final seat',[lambda i=i:rpc(i,'join_room',p={'nickname':'Last'+str(i),'code':code}) for i in [4,5]])
check('exactly one final seat accepted',sum(x['ok'] for x in out)==1 and any(x.get('error')=='room_full' for x in out))
check('capacity remains six',len(snap(6,r)['players'])==6)
r,code=room([5,0]);ready([5,0],r);rev=snap(5,r)['revision']
out=parallel('start versus join',[lambda:rpc(5,'start_match',r,p={'expected_revision':rev}),lambda:rpc(1,'join_room',p={'nickname':'LatePlayer','code':code})])
s=snap(5,r)
check('start join race preserves membership', (s['status']=='playing' and len(s['players'])==2 and out[0]['ok'] and not out[1]['ok']) or (s['status']=='lobby' and len(s['players'])==3 and out[1]['ok'] and not out[0]['ok']))

for count,players in [(2,[4,0]),(3,[3,0,1]),(6,[2,0,1,3,4,5])]:
 r,code=room(players);ready(players,r);s=snap(players[0],r)
 if count==2:
  out=parallel('duplicate start',[lambda:rpc(players[0],'start_match',r,p={'expected_revision':s['revision']}) for _ in range(2)])
  check('only one duplicate start accepted',sum(x['ok'] for x in out)==1)
 else:assert rpc(players[0],'start_match',r,p={'expected_revision':s['revision']})['ok']
 s=snap(players[0],r);g=s['match_id'];initial=g
 for rnd in range(1,6):
  out=parallel(f'{count}p round {rnd} signals',[lambda i=i:rpc(i,'set_signal',r,g,rnd,{'claim':'hunting'}) for i in players])
  check(f'{count}p round {rnd} signals accepted',all(x['ok'] for x in out))
  s=snap(players[0],r);assert s['phase']=='plan',s
  if count==2 and rnd==1:
   req=str(uuid.uuid4())
   out=parallel('same UUID double submission',[lambda:rpc(players[0],'submit_action',r,g,rnd,{'kind':'bluff'},req) for _ in range(2)])
   check('simultaneous retry returns identical receipt',out[0]==out[1] and out[0]['ok'])
   assert rpc(players[1],'submit_action',r,g,rnd,{'kind':'bluff'})['ok']
  elif count==2 and rnd==2:
   out=parallel('competing actions by same seat',[lambda p=p:rpc(players[0],'submit_action',r,g,rnd,p) for p in [{'kind':'bluff'},{'kind':'defend','bank_amount':0}]])
   check('one action per seat despite competing requests',sum(x['ok'] for x in out)==1 and any(x.get('error')=='already_locked' for x in out))
   assert rpc(players[1],'submit_action',r,g,rnd,{'kind':'bluff'})['ok']
  else:
   out=parallel(f'{count}p round {rnd} final locks',[lambda i=i:rpc(i,'submit_action',r,g,rnd,{'kind':'bluff'}) for i in players])
   check(f'{count}p round {rnd} final locks accepted',all(x['ok'] for x in out))
  s=snap(players[0],r)
  check(f'{count}p round {rnd} resolves once',s['phase']=='reveal' and len(s['history'])==rnd and len(s['history'][-1]['actions'])==count)
  snapshots=[snap(i,r) for i in players]
  check(f'{count}p round {rnd} snapshots converge',all(x==snapshots[0] for x in snapshots))
  wait_deadline(s)
  out=parallel(f'{count}p round {rnd} concurrent expiry',[lambda i=i:rpc(i,'heartbeat_and_advance',r) for i in players[:2]])
  check(f'{count}p round {rnd} expiry accepted',all(x['ok'] for x in out))
  s=snap(players[0],r)
  check(f'{count}p round {rnd} one phase advancement',s['phase']==('results' if rnd==5 else 'signal') and s['round']==(5 if rnd==5 else rnd+1))
 s=snap(players[0],r)
 check(f'{count}p complete synchronized match',s['status']=='results' and s['match_id']==initial and len(s['history'])==5 and len(s['results'])==count)
 check(f'{count}p results match all devices',all(snap(i,r)==s for i in players))
 check(f'{count}p final rankings valid',sum(x['winner'] for x in s['results'])>=1 and all(x['score']==x['purse']+x['vault'] for x in s['results']))
 # Unauthorized outsider cannot read this room through the actual REST API.
 status,denied=http(7,'/rest/v1/rpc/get_snapshot',{'p_room':r})
 check(f'{count}p outsider REST denied',status in [401,403])
 status,rows=http(7,'/rest/v1/room_snapshots?room_id=eq.'+r)
 check(f'{count}p outsider REST table hidden',status==200 and rows==[])
 status,denied=http(players[0],'/rest/v1/rpc/resolve_round',{'p_match':g})
 check(f'{count}p internal resolver not exposed',status==404)

report={'passed':len(checks),'checks':checks,'concurrency':overlaps,'rooms':rooms,'auth_mode':'temporary password-based test fixtures; production anonymous sign-ins remain disabled','project':'noxkiahycepomvbhmxsx'}
(ROOT/'http_test_results.json').write_text(json.dumps(report,indent=2))
print('ALL PASSED',len(checks),flush=True)

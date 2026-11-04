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


for fixture in json.loads((ROOT/'http_fixtures.json').read_text()):
 n=fixture['n'];r=fixture['room'];g=fixture['match'];players=list(range(n))
 if n==2:
  req=str(uuid.uuid4())
  results=parallel('same UUID concurrent retry',[lambda:rpc(0,'submit_action',r,g,1,{'kind':'bluff'},req) for _ in range(2)])
  check('identical retries share one receipt',results[0]==results[1] and results[0]['ok'])
  ans=rpc(0,'submit_action',r,g,1,{'kind':'defend','bank_amount':0})
  check('conflicting second request cannot replace action',ans.get('error')=='already_locked')
  check('remaining player resolves round',rpc(1,'submit_action',r,g,1,{'kind':'bluff'})['ok'])
 else:
  results=parallel(str(n)+' simultaneous final locks',[lambda i=i:rpc(i,'submit_action',r,g,1,{'kind':'bluff'}) for i in players])
  check(str(n)+' concurrent actions all accepted',all(x['ok'] for x in results))
 snapshots=parallel(str(n)+' simultaneous snapshot reads',[lambda i=i:snap(i,r) for i in players])
 check(str(n)+' snapshots identical',all(x==snapshots[0] for x in snapshots))
 s=snapshots[0]
 check(str(n)+' round resolved exactly once',s['phase']=='reveal' and len(s['history'])==1 and len(s['history'][0]['actions'])==n and all(x['purse']==10 for x in s['players']))
 status,denied=http(7,'/rest/v1/rpc/get_snapshot',{'p_room':r})
 check(str(n)+' outsider RPC denied',status in [401,403])
 status,rows=http(7,'/rest/v1/room_snapshots?room_id=eq.'+r)
 check(str(n)+' outsider RLS table hidden',status==200 and rows==[])
 status,denied=http(0,'/rest/v1/rpc/resolve_round',{'p_match':g})
 check(str(n)+' resolver not exposed',status==404)
report={'passed':len(checks),'checks':checks,'concurrency':overlaps,'test_clock':'planning deadline extended in test fixtures only','auth_mode':'temporary password fixture users; production anonymous auth disabled'}
(ROOT/'http_concurrency_results.json').write_text(json.dumps(report,indent=2));print('ALL PASSED',len(checks),flush=True)

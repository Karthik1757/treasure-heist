"""Focused anonymous acceptance. No password identity or privileged API is used."""
import ast,base64,concurrent.futures,datetime,hashlib,json,pathlib,sys,threading,time,urllib.request,urllib.error,uuid
from websockets.sync.client import connect
ROOT=pathlib.Path(__file__).parent
C={}
for node in ast.parse((ROOT/'http_tests.py').read_text()).body:
 if isinstance(node,ast.Assign) and isinstance(node.value,ast.Constant):
  for target in node.targets:
   if isinstance(target,ast.Name):C[target.id]=node.value.value
BASE=__import__('os').environ['SUPABASE_URL'];KEY=__import__('os').environ['SUPABASE_PUBLIC_KEY']
RUN=ROOT/'anonymous-runs'/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');RUN.mkdir(parents=True)
sessions=[];checks=[];failures=[];requests=[];fixtures={};sockets=[];guard=threading.Lock();complete=False
def utc():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def report():
 p=RUN/'results.json';tmp=RUN/'results.tmp';tmp.write_text(json.dumps({'project':'noxkiahycepomvbhmxsx','complete':complete,'passed':len(checks),'failed':len(failures),'checks':checks,'failures':failures,'fixtures':fixtures,'requests':requests,'auth_mode':'genuine anonymous signup only','source_sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'production_clock_modified':False},indent=2));tmp.replace(p)
def check(name,ok):
 if not ok:failures.append({'check':name,'type':'AssertionError'});raise AssertionError(name)
 checks.append(name);print('PASS',name,flush=True);report()
def call(actor,path,data=None,method=None,extra=None):
 headers={'apikey':KEY,'Content-Type':'application/json'}
 if actor is not None:headers['Authorization']='Bearer '+sessions[actor]['access_token']
 headers.update(extra or {})
 event={'operation':path.split('?')[0],'actor':actor,'start_utc':utc(),'start_monotonic':time.monotonic(),'request_id':data.get('p_request_id') if isinstance(data,dict) else None}
 try:
  req=urllib.request.Request(BASE+path,data=None if data is None else json.dumps(data).encode(),headers=headers,method=method)
  try:
   with urllib.request.urlopen(req,timeout=30) as res:status=res.status;raw=res.read()
  except urllib.error.HTTPError as e:status=e.code;raw=e.read()
  try:body=json.loads(raw) if raw else None
  except ValueError:body={}
  event['status']=status
  if isinstance(body,dict):
   s=body.get('snapshot') or {};code=body.get('error_code') or body.get('code') or body.get('error')
   event.update({'ok':body.get('ok'),'error_code':code if isinstance(code,str) and len(code)<80 and all(c.isalnum() or c=='_' for c in code) else None,'server_time':body.get('server_time'),'phase':s.get('phase'),'round':s.get('round'),'revision':s.get('revision'),'deadline':s.get('deadline')})
  return status,body
 except Exception as e:event['transport_error']=type(e).__name__;raise
 finally:
  event['end_utc']=utc();event['duration_ms']=round((time.monotonic()-event.pop('start_monotonic'))*1000,2)
  with guard:
   requests.append(event)
   with (RUN/'requests.jsonl').open('a') as f:f.write(json.dumps(event)+'\n')
def rpc(i,name,r=None,g=None,rnd=None,p=None):
 status,body=call(i,'/rest/v1/rpc/'+name,{'p_request_id':str(uuid.uuid4()),'p_room':r,'p_match':g,'p_round':rnd,'p_payload':p or {}})
 if status!=200:raise RuntimeError('rpc_http_failure')
 return body
def parallel(fs):
 with concurrent.futures.ThreadPoolExecutor(max_workers=len(fs)) as ex:return list(ex.map(lambda f:f(),fs))
def identity(i):
 status,user=call(i,'/auth/v1/user');token=sessions[i]['access_token'];part=token.split('.')[1];claims=json.loads(base64.urlsafe_b64decode(part+'='*(-len(part)%4)))
 # JWT is accepted by Auth's authenticated user endpoint; decoding alone is not verification.
 valid=status==200 and user.get('is_anonymous') is True and claims.get('is_anonymous') is True and claims.get('role')=='authenticated' and claims.get('sub')==user.get('id')==sessions[i]['user']['id'] and claims.get('iss')==BASE+'/auth/v1' and claims.get('aud')=='authenticated' and claims.get('exp',0)>time.time()
 return valid,{'user_id':user.get('id'),'is_anonymous':claims.get('is_anonymous'),'role':claims.get('role'),'issuer_matches':claims.get('iss')==BASE+'/auth/v1','audience_matches':claims.get('aud')=='authenticated','expires_at':claims.get('exp'),'auth_server_validated':status==200}
def subscribe(i,r):
 ws=connect(BASE.replace('https://','wss://')+'/realtime/v1/websocket?apikey='+KEY+'&vsn=1.0.0',open_timeout=25)
 ws.send(json.dumps({'topic':'realtime:anon:'+r,'event':'phx_join','payload':{'config':{'broadcast':{'ack':False,'self':False},'presence':{'key':''},'postgres_changes':[{'event':'UPDATE','schema':'public','table':'room_snapshots','filter':'room_id=eq.'+r}]},'access_token':sessions[i]['access_token']},'ref':'1'}))
 while True:
  m=json.loads(ws.recv(timeout=20))
  if m['event']=='phx_reply':
   if m['payload']['status']!='ok':raise RuntimeError('subscription_rejected')
   return ws
def receive(ws,rev):
 until=time.monotonic()+25
 while time.monotonic()<until:
  m=json.loads(ws.recv(timeout=max(.01,until-time.monotonic())))
  if m['event']=='postgres_changes':
   record=m['payload']['data']['record']
   if record['revision']==rev:return record['payload']
   if record['revision']>rev:raise AssertionError('expected_revision_missed')
 raise TimeoutError('revision_not_delivered')
def converge(s):return parallel([lambda ws=ws:receive(ws,s['revision']) for ws in sockets[:3]])
def close_all():
 global sockets
 old=sockets;sockets=[]
 parallel([lambda ws=ws:ws.close() for ws in old]) if old else None
try:
 status,settings=call(None,'/auth/v1/settings');check('live anonymous provider enabled',status==200 and settings.get('external',{}).get('anonymous_users') is True)
 (RUN/'auth-settings.json').write_text(json.dumps({'checked_at_utc':utc(),'anonymous_users':True,'changed_by_test':False},indent=2))
 for i in range(4):
  status,data=call(None,'/auth/v1/signup',{})
  check('genuine anonymous signup '+str(i),status==200 and data.get('user',{}).get('is_anonymous') is True and bool(data.get('access_token')) and bool(data.get('refresh_token')))
  sessions.append(data)
 fixtures['user_ids']=[x['user']['id'] for x in sessions];report()
 ids=parallel([lambda i=i:identity(i) for i in range(4)])
 check('all four anonymous identities server validated',all(x[0] for x in ids) and len(set(fixtures['user_ids']))==4)
 (RUN/'identity-evidence.json').write_text(json.dumps([x[1] for x in ids],indent=2))
 a=rpc(0,'create_room',p={'nickname':'AnonymousHost'});check('anonymous host creates room',a['ok']);r=a['room_id'];fixtures['room']=r;code=a['snapshot']['code']
 joins=parallel([lambda i=i:rpc(i,'join_room',p={'nickname':'Anonymous'+str(i),'code':code}) for i in [1,2]])
 check('two anonymous peers join isolated room',all(x['ok'] for x in joins));report()
 # One fresh outsider has no membership. Database-role anon is also denied RPC access.
 tests=parallel([lambda:call(3,'/rest/v1/rpc/get_snapshot',{'p_room':r}),lambda:call(3,'/rest/v1/room_snapshots?room_id=eq.'+r),lambda:call(0,'/rest/v1/sealed_actions?select=*',extra={'Accept-Profile':'heist_private'}),lambda:call(0,'/rest/v1/rpc/resolve_round',{'p_match':str(uuid.uuid4())}),lambda:call(None,'/rest/v1/rpc/get_snapshot',{'p_room':r})])
 check('anonymous outsider room RPC denied',tests[0][0] in (401,403))
 check('anonymous outsider snapshot RLS hides row',tests[1]==(200,[]))
 check('private schema not exposed to anonymous member',tests[2][0] in (403,404,406))
 check('private resolver unavailable through public RPC',tests[3][0]==404)
 check('unsigned API-key-only request denied',tests[4][0] in (401,403))
 status,body=call(0,'/rest/v1/room_snapshots?room_id=eq.'+r,{'revision':-1},method='PATCH')
 check('anonymous member cannot directly write snapshot',status in (401,403))
 old_id=sessions[0]['user']['id'];old_refresh=sessions[0]['refresh_token']
 status,new=call(None,'/auth/v1/token?grant_type=refresh_token',{'refresh_token':old_refresh})
 check('genuine refresh grant succeeds without password',status==200 and bool(new.get('access_token')) and bool(new.get('refresh_token')));sessions[0]=new
 verified,claims=identity(0);check('refresh preserves anonymous identity and role',verified and claims['user_id']==old_id)
 sockets=parallel([lambda i=i:subscribe(i,r) for i in range(4)]);check('anonymous Realtime subscriptions established',len(sockets)==4)
 out=parallel([lambda i=i:rpc(i,'set_ready',r,p={'ready':True}) for i in range(3)]);check('anonymous players can ready',all(x['ok'] for x in out));s=max((x['snapshot'] for x in out),key=lambda x:x['revision'])
 check('all members receive identical lobby snapshot',all(x==s for x in converge(s)))
 seen=False
 try:
  until=time.monotonic()+3
  while time.monotonic()<until:
   if json.loads(sockets[3].recv(timeout=max(.01,until-time.monotonic())))['event']=='postgres_changes':seen=True;break
 except TimeoutError:pass
 check('anonymous outsider receives no room events',not seen)
 unauthorized=rpc(1,'start_match',r,p={'expected_revision':s['revision']});check('anonymous non-host cannot start match',not unauthorized['ok'] and unauthorized.get('error')=='host_required')
 s=unauthorized['snapshot'];a=rpc(0,'start_match',r,p={'expected_revision':s['revision']});check('refreshed anonymous host starts match',a['ok']);g=a['snapshot']['match_id'];fixtures['match']=g;report()
 out=parallel([lambda i=i:rpc(i,'set_signal',r,g,1,{'claim':'hunting'}) for i in range(3)]);check('three anonymous signals accepted',all(x['ok'] for x in out));s=max((x['snapshot'] for x in out),key=lambda x:x['revision']);check('planning committed to all anonymous clients',s['phase']=='plan' and all(x==s for x in converge(s)))
 a=rpc(0,'submit_action',r,g,1,{'kind':'bluff'});check('anonymous action submission accepted',a['ok'])
 reads=parallel([lambda i=i:call(i,'/rest/v1/rpc/get_own_action',{'p_room':r,'p_match':g,'p_round':1}) for i in [0,1]])
 check('own sealed action visible only to its submitter',reads[0][0]==200 and reads[0][1]['action']['kind']=='bluff' and reads[1][0]==200 and reads[1][1]['action'] is None)
 check('shared planning snapshot excludes sealed action details',a['snapshot']['history']==[] and all('kind' not in x and 'target_member_id' not in x and 'bank_amount' not in x for x in a['snapshot']['players']))
 out=parallel([lambda i=i:rpc(i,'submit_action',r,g,1,{'kind':'bluff'}) for i in [1,2]]);check('remaining anonymous actions accepted',all(x['ok'] for x in out));s=max((x['snapshot'] for x in out),key=lambda x:x['revision']);check('anonymous round resolves once with exact scores',s['phase']=='reveal' and len(s['history'])==1 and all(x['purse']==10 for x in s['players']))
 check('anonymous clients receive identical resolved round',all(x==s for x in converge(s)))
 # Actual long outage, not a clock rewrite. All clients disconnect for > full match duration.
 close_all();start=time.monotonic();began=utc();print('OUTAGE_BEGIN 300 seconds',flush=True)
 (RUN/'outage.json').write_text(json.dumps({'started_at':began,'planned_seconds':300},indent=2));report()
 while time.monotonic()-start<300:time.sleep(min(5,300-(time.monotonic()-start)))
 duration=time.monotonic()-start
 sockets=parallel([lambda i=i:subscribe(i,r) for i in range(3)])
 a=rpc(0,'heartbeat_and_advance',r);check('returning anonymous heartbeat catches up overdue match',a['ok'] and a['snapshot']['phase']=='results' and len(a['snapshot']['history'])==5);s=a['snapshot']
 check('reconnected anonymous clients receive catch-up revision',all(x==s for x in converge(s)))
 reads=parallel([lambda i=i:call(i,'/rest/v1/rpc/get_snapshot',{'p_room':r}) for i in range(3)])
 check('long outage restores same room and seats',all(x[0]==200 and x[1]['snapshot']==s for x in reads) and {x['id'] for x in s['players']}=={x['id'] for x in a['snapshot']['players']} and len(s['players'])==3)
 check('long outage produces valid persisted winners',len(s['results'])==3 and any(x['winner'] for x in s['results']) and all(x['score']==x['purse']+x['vault'] and x['purse']>=0 and x['vault']>=0 for x in s['results']))
 late=rpc(1,'submit_action',r,g,1,{'kind':'bluff'});check('stale queued action rejected after reconnect',not late['ok'] and late.get('error')=='stale_turn')
 (RUN/'outage.json').write_text(json.dumps({'started_at':began,'ended_at':utc(),'disconnected_seconds':duration,'production_clock_modified':False},indent=2))
 complete=True
except BaseException as e:
 if not failures:failures.append({'type':type(e).__name__,'check':'unhandled anonymous harness failure'})
 (RUN/'failure.log').write_text(json.dumps(failures,indent=2));print('FAILED',type(e).__name__,flush=True)
finally:
 report()
 try:close_all()
 except Exception:pass
 print('RESULT',RUN/'results.json',flush=True)
sys.exit(0 if complete else 1)

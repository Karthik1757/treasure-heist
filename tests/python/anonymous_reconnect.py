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
RUN=ROOT/'anonymous-runs'/('reconnect-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'));RUN.mkdir(parents=True)
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

def persist_private_sessions():
 import os
 p=ROOT/'anonymous-private';p.mkdir(exist_ok=True,mode=0o700)
 fd=os.open(p/(RUN.name+'.json'),os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
 with os.fdopen(fd,'w') as f:json.dump(sessions,f)
def subscribe_logged(i,r):
 for attempt in range(2):
  event={'actor':i,'attempt':attempt+1,'start_utc':utc(),'stage':'connect'};ws=None
  try:
   ws=connect(BASE.replace('https://','wss://')+'/realtime/v1/websocket?apikey='+KEY+'&vsn=1.0.0',open_timeout=25)
   event['connected_utc']=utc();event['stage']='join'
   ws.send(json.dumps({'topic':'realtime:anon:'+r,'event':'phx_join','payload':{'config':{'broadcast':{'ack':False,'self':False},'presence':{'key':''},'postgres_changes':[{'event':'UPDATE','schema':'public','table':'room_snapshots','filter':'room_id=eq.'+r}]},'access_token':sessions[i]['access_token']},'ref':'1'}))
   until=time.monotonic()+25;event['received_events']=[]
   while time.monotonic()<until:
    msg=json.loads(ws.recv(timeout=max(.01,until-time.monotonic())));event['received_events'].append(msg.get('event'))
    if msg.get('event')=='phx_reply':
     if msg['payload']['status']!='ok':raise RuntimeError('join_rejected')
     event['stage']='subscribed';return ws
   raise TimeoutError('join_deadline')
  except Exception as e:
   event['error_type']=type(e).__name__
   if ws:
    try:ws.close()
    except Exception:pass
   if attempt==1:raise
  finally:
   event['end_utc']=utc()
   with guard:
    with (RUN/'connections.jsonl').open('a') as f:f.write(json.dumps(event)+'\n')
try:
 for i in range(2):
  status,data=call(None,'/auth/v1/signup',{})
  check('fresh anonymous reconnect fixture '+str(i),status==200 and data.get('user',{}).get('is_anonymous') is True)
  sessions.append(data)
 persist_private_sessions();fixtures['user_ids']=[x['user']['id'] for x in sessions]
 a=rpc(0,'create_room',p={'nickname':'ReconnectHost'});check('isolated reconnect room created',a['ok']);r=a['room_id'];fixtures['room']=r
 a=rpc(1,'join_room',p={'nickname':'ReconnectPeer','code':a['snapshot']['code']});check('anonymous reconnect peer joined',a['ok'])
 baseline=sorted((p['id'],p['seat']) for p in a['snapshot']['players']);fixtures['initial_seats']=baseline
 sockets=parallel([lambda i=i:subscribe_logged(i,r) for i in [0,1]])
 out=parallel([lambda i=i:rpc(i,'set_ready',r,p={'ready':True}) for i in [0,1]]);check('anonymous reconnect fixtures ready',all(x['ok'] for x in out));s=max((x['snapshot'] for x in out),key=lambda x:x['revision'])
 check('pre-outage anonymous subscription delivery',all(x==s for x in converge(s)))
 a=rpc(0,'start_match',r,p={'expected_revision':s['revision']});check('production timer match started',a['ok']);fixtures['match']=a['snapshot']['match_id'];report()
 close_all();began=utc();start=time.monotonic();(RUN/'outage.json').write_text(json.dumps({'started_at':began,'planned_seconds':300},indent=2));print('OUTAGE_BEGIN 300 seconds',flush=True)
 while time.monotonic()-start<300:time.sleep(min(5,300-(time.monotonic()-start)))
 duration=time.monotonic()-start
 # Validate the same token against Auth before reconnecting; no re-login.
 ids=parallel([lambda i=i:identity(i) for i in [0,1]])
 check('same anonymous identities valid after long outage',all(x[0] for x in ids))
 sockets=parallel([lambda i=i:subscribe_logged(i,r) for i in [0,1]])
 a=rpc(0,'heartbeat_and_advance',r);s=a['snapshot'];check('long outage catches up all five production rounds',a['ok'] and s['phase']=='results' and len(s['history'])==5)
 check('resumed anonymous subscriptions receive results',all(x==s for x in converge(s)))
 reads=parallel([lambda i=i:call(i,'/rest/v1/rpc/get_snapshot',{'p_room':r}) for i in [0,1]])
 check('reconnect restores identical room and original seats',all(x[0]==200 and x[1]['snapshot']==s for x in reads) and sorted((p['id'],p['seat']) for p in s['players'])==baseline)
 check('timeout scores and shared winners correct',len(s['results'])==2 and all(x['winner'] and x['score']==12 and x['vault']==12 and x['purse']==0 for x in s['results']))
 late=rpc(1,'submit_action',r,fixtures['match'],1,{'kind':'bluff'});check('stale queued action rejected after recovery',not late['ok'] and late.get('error')=='stale_turn')
 (RUN/'outage.json').write_text(json.dumps({'started_at':began,'ended_at':utc(),'disconnected_seconds':duration,'production_clock_modified':False},indent=2));complete=True
except BaseException as e:
 import traceback
 if not failures:failures.append({'type':type(e).__name__,'check':'focused anonymous reconnect exception','frames':[{'function':f.name,'line':f.lineno} for f in traceback.extract_tb(e.__traceback__)]})
 (RUN/'failure.log').write_text(json.dumps(failures,indent=2));print('FAILED',type(e).__name__,flush=True)
finally:
 report()
 try:close_all()
 except Exception:pass
 print('RESULT',RUN/'results.json',flush=True)
sys.exit(0 if complete else 1)

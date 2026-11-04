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
RUN=ROOT/'anonymous-runs'/('resume-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'));RUN.mkdir(parents=True)
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
 original=sorted((ROOT/'anonymous-runs').glob('reconnect-*/results.json'))[-1]
 prior=json.loads(original.read_text());fixtures=prior['fixtures'];r=fixtures['room'];g=fixtures['match']
 sessions=json.loads(sorted((ROOT/'anonymous-private').glob('*.json'),key=lambda p:p.stat().st_mtime)[-1].read_text())
 check('resume uses original anonymous identities only',all(x['user']['is_anonymous'] for x in sessions) and [x['user']['id'] for x in sessions]==fixtures['user_ids'])
 for i in range(2):
  status,new=call(None,'/auth/v1/token?grant_type=refresh_token',{'refresh_token':sessions[i]['refresh_token']})
  check('refresh original anonymous session '+str(i),status==200 and new.get('user',{}).get('id')==fixtures['user_ids'][i] and new['user']['is_anonymous'])
  sessions[i]=new
 persist_private_sessions()
 checks_id=parallel([lambda i=i:identity(i) for i in range(2)]);check('resumed JWT identities server validated',all(x[0] for x in checks_id))
 sockets=parallel([lambda i=i:subscribe_logged(i,r) for i in [0,1]])
 check('Realtime subscriptions re-established after outage',len(sockets)==2)
 
 request={'p_request_id':str(uuid.uuid4()),'p_room':r,'p_match':None,'p_round':None,'p_payload':{}}
 for attempt in range(2):
  try:
   status,a=call(0,'/rest/v1/rpc/heartbeat_and_advance',request);break
  except urllib.error.URLError:
   if attempt:raise
 s=a['snapshot'];check('catch-up completes five timed-out rounds',a['ok'] and s['phase']=='results' and len(s['history'])==5)
 check('both resumed sockets receive committed result',all(x==s for x in converge(s)))
 reads=parallel([lambda i=i:call(i,'/rest/v1/rpc/get_snapshot',{'p_room':r}) for i in [0,1]])
 check('latest snapshot recovered by both original members',all(x[0]==200 and x[1]['snapshot']==s for x in reads))
 check('original seats and member IDs preserved',sorted([p['id'],p['seat']] for p in s['players'])==fixtures['initial_seats'])
 check('timeout-generated scores and winners exact',len(s['results'])==2 and all(x['winner'] and x['score']==12 and x['vault']==12 and x['purse']==0 for x in s['results']))
 late=rpc(1,'submit_action',r,g,1,{'kind':'bluff'});check('stale action rejected after recovery',not late['ok'] and late.get('error')=='stale_turn')
 outage=json.loads((original.parent/'outage.json').read_text());outage.update({'ended_at':utc(),'disconnected_seconds':(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(outage['started_at'])).total_seconds(),'original_run':original.parent.name,'session_interrupted':True,'resumed_same_auth_identities':True})
 (RUN/'outage.json').write_text(json.dumps(outage,indent=2));complete=True
except BaseException as ex:
 import traceback
 if not failures:failures.append({'type':type(ex).__name__,'check':'anonymous resume failure','frames':[{'function':f.name,'line':f.lineno} for f in traceback.extract_tb(ex.__traceback__)]})
 (RUN/'failure.log').write_text(json.dumps(failures,indent=2));print('FAILED',type(ex).__name__,flush=True)
finally:
 report()
 try:close_all()
 except Exception:pass
 print('RESULT',RUN/'results.json',flush=True)
sys.exit(0 if complete else 1)

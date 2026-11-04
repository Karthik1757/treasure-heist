"""Six real Auth clients complete five rounds using committed Realtime snapshots.
No administrative clock changes. Independent from the retained REST-read harness.
"""
import http_tests as h
import concurrent.futures,json,time,datetime,pathlib,hashlib,sys
from websockets.sync.client import connect
N=6;players=list(range(N));sockets=[];complete=False
def epoch(x):return datetime.datetime.fromisoformat(x).timestamp()
def subscribe(i,r):
 ws=connect(h.BASE.replace('https://','wss://')+'/realtime/v1/websocket?apikey='+h.KEY+'&vsn=1.0.0',open_timeout=25)
 ws.send(json.dumps({'topic':'realtime:production:'+r,'event':'phx_join','payload':{'config':{'broadcast':{'ack':False,'self':False},'presence':{'key':''},'postgres_changes':[{'event':'UPDATE','schema':'public','table':'room_snapshots','filter':'room_id=eq.'+r}]},'access_token':h.USERS[i]['token']},'ref':'1'}))
 while True:
  m=json.loads(ws.recv(timeout=20))
  if m['event']=='phx_reply':
   if m['payload']['status']!='ok':raise RuntimeError('subscription_rejected')
   return ws
def receive_revision(ws,rev):
 until=time.monotonic()+20
 while time.monotonic()<until:
  m=json.loads(ws.recv(timeout=max(.01,until-time.monotonic())))
  if m['event']=='postgres_changes':
   rec=m['payload']['data']['record']
   if rec['revision']==rev:return rec['payload']
   if rec['revision']>rev:raise AssertionError('target committed revision missed')
 raise TimeoutError('revision not delivered')
def converge(snapshot,label):
 with concurrent.futures.ThreadPoolExecutor(max_workers=N) as ex:
  bodies=list(ex.map(lambda ws:receive_revision(ws,snapshot['revision']),sockets))
 h.check(label+' six clients receive exact committed snapshot',all(x==snapshot for x in bodies))
def latest(out):return max((x['snapshot'] for x in out),key=lambda x:x['revision'])
try:
 r,code=h.room(players)
 with concurrent.futures.ThreadPoolExecutor(max_workers=N) as ex:sockets=list(ex.map(lambda i:subscribe(i,r),players))
 h.ready(players,r);s=h.snap(0,r)
 a=h.rpc(0,'start_match',r,p={'expected_revision':s['revision']});h.check('six-client match started',a['ok']);s=a['snapshot'];g=s['match_id']
 h.check('production initial signal duration unchanged',11.5<epoch(s['deadline'])-epoch(a['server_time'])<=12)
 converge(s,'start')
 for rnd in range(1,6):
  out=h.parallel(f'round {rnd} signals',[lambda i=i:h.rpc(i,'set_signal',r,g,rnd,{'claim':'hunting'}) for i in players])
  h.check(f'round {rnd} all six signals accepted',all(x['ok'] for x in out));s=latest(out)
  h.check(f'round {rnd} enters planning',s['phase']=='plan' and s['round']==rnd)
  converge(s,f'round {rnd} plan')
  out=h.parallel(f'round {rnd} actions',[lambda i=i:h.rpc(i,'submit_action',r,g,rnd,{'kind':'bluff'}) for i in players])
  h.check(f'round {rnd} all six actions accepted',all(x['ok'] for x in out));s=latest(out)
  h.check(f'round {rnd} exactly one correct resolution',s['phase']=='reveal' and len(s['history'])==rnd and len(s['history'][-1]['actions'])==6 and all(x['purse']==6+4*rnd and x['vault']==0 for x in s['players']))
  converge(s,f'round {rnd} reveal')
  # Dispatch only two seconds ahead to accommodate this environment's measured
  # outbound delay. Early server arrivals are identified by server timestamps.
  remaining=epoch(s['deadline'])-time.time()-2
  if remaining>0:time.sleep(remaining)
  for attempt in range(3):
   out=h.parallel(f'round {rnd} expiry attempt {attempt+1}',[lambda i=i:h.rpc(i,'heartbeat_and_advance',r) for i in [0,1]])
   if all(x['ok'] and x['snapshot']['phase']=='reveal' and epoch(x['server_time'])<epoch(s['deadline']) for x in out):continue
   break
  h.check(f'round {rnd} expiry calls accepted',all(x['ok'] for x in out));s=latest(out)
  h.check(f'round {rnd} advances exactly once',s['phase']==('results' if rnd==5 else 'signal') and s['round']==(5 if rnd==5 else rnd+1))
  converge(s,f'round {rnd} transition')
 h.check('six-player five-round exact shared victory',s['status']=='results' and len(s['results'])==6 and all(x['winner'] and x['score']==26 and x['vault']==0 for x in s['results']))
 bodies=h.parallel('final REST reconciliation',[lambda i=i:h.snap(i,r) for i in players])
 h.check('six final REST snapshots match Realtime results',all(x==s for x in bodies))
 complete=True
except BaseException as e:
 if not h.failures:h.failures.append({'type':type(e).__name__,'check':'six-client Realtime lifecycle exception'})
 (h.RUN/'failure.log').write_text(json.dumps(h.failures,indent=2));print('FAILED',type(e).__name__,flush=True)
finally:
 for ws in sockets:
  try:ws.close()
  except Exception:pass
 (h.RUN/'lifecycle-source.json').write_text(json.dumps({'sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'timers':'production 12/35/8','clients':6}))
 h.save_report(complete);print('RESULT',h.RUN/'results.json',flush=True)
sys.exit(0 if complete else 1)

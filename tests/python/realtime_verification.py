"""Six authorized sockets, one outsider, and reconnect plus fresh delivery."""
import http_tests as h
import json,concurrent.futures,time,datetime,hashlib,pathlib
from websockets.sync.client import connect
players=[7,0,1,2,3,4];sockets=[];complete=False
(h.RUN/'realtime-source.json').write_text(json.dumps({'sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()}))
def subscribe(i,r):
 ws=connect(h.BASE.replace('https://','wss://')+'/realtime/v1/websocket?apikey='+h.KEY+'&vsn=1.0.0',open_timeout=25)
 ws.send(json.dumps({'topic':'realtime:audit:'+r,'event':'phx_join','payload':{'config':{'broadcast':{'ack':False,'self':False},'presence':{'key':''},'postgres_changes':[{'event':'UPDATE','schema':'public','table':'room_snapshots','filter':'room_id=eq.'+r}]},'access_token':h.USERS[i]['token']},'ref':'1'}))
 while True:
  m=json.loads(ws.recv(timeout=20))
  if m['event']=='phx_reply':
   if m['payload']['status']!='ok':raise RuntimeError('subscription_rejected')
   return ws
def receive(ws):
 while True:
  m=json.loads(ws.recv(timeout=25))
  if m['event']=='postgres_changes':
   rec=m['payload']['data']['record']
   return rec,round((time.time()-datetime.datetime.fromisoformat(rec['updated_at']).timestamp())*1000,2)
try:
 a=h.rpc(7,'create_room',p={'nickname':'AuditRealtime'});h.check('realtime room created',a['ok']);r=a['room_id'];h.rooms.append(r)
 code=a['snapshot']['code']
 with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:joins=list(ex.map(lambda i:h.rpc(i,'join_room',p={'nickname':'Socket'+str(i),'code':code}),players[1:]))
 h.check('five socket peers joined',all(x['ok'] for x in joins))
 with concurrent.futures.ThreadPoolExecutor(max_workers=7) as ex:sockets=list(ex.map(lambda i:subscribe(i,r),players+[6]))
 with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
  futures=[ex.submit(receive,ws) for ws in sockets[:6]]
  a=h.rpc(7,'set_ready',r,p={'ready':True});h.check('realtime source mutation accepted',a['ok'])
  records=[f.result() for f in futures]
 h.check('six sockets receive identical committed record',all(x[0]==records[0][0] for x in records))
 h.check('six socket payloads equal RPC snapshot',all(x[0]['payload']==a['snapshot'] for x in records))
 (h.RUN/'latencies.json').write_text(json.dumps({'cross_clock_server_update_to_receive_ms':[x[1] for x in records]},indent=2))
 outsider=False
 try:
  until=time.monotonic()+3
  while time.monotonic()<until:
   if json.loads(sockets[-1].recv(timeout=max(.01,until-time.monotonic())))['event']=='postgres_changes':outsider=True;break
 except TimeoutError:pass
 h.check('outsider receives no event in observation window',not outsider)
 for ws in sockets:ws.close()
 sockets=[]
 a=h.rpc(7,'set_ready',r,p={'ready':False});h.check('missed snapshot mutation accepted',a['ok'])
 ws=subscribe(0,r);sockets=[ws];s=h.snap(0,r);h.check('reconnect fetch restores missed snapshot',s==a['snapshot'])
 with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
  future=ex.submit(receive,ws);a=h.rpc(7,'set_ready',r,p={'ready':True});record,latency=future.result()
 h.check('reconnected socket receives subsequent revision',record['payload']==a['snapshot'] and record['revision']>s['revision'])
 complete=True
except BaseException as e:
 if not h.failures:h.failures.append({'type':type(e).__name__,'check':'realtime harness exception'})
 (h.RUN/'failure.log').write_text(json.dumps(h.failures,indent=2));print('FAILED',type(e).__name__,flush=True)
finally:
 for ws in sockets:
  try:ws.close()
  except Exception:pass
 h.save_report(complete);print('RESULT',h.RUN/'results.json',flush=True)

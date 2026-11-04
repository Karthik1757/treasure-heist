import json,uuid,time,urllib.request,pathlib,concurrent.futures,datetime
from websockets.sync.client import connect
ROOT=pathlib.Path(__file__).parent
users=json.loads((ROOT/'test_sessions.json').read_text());key=__import__("os").environ["SUPABASE_PUBLIC_KEY"];base=__import__("os").environ["SUPABASE_URL"]
def rpc(i,op,**kw):
 req=urllib.request.Request(base+'/rest/v1/rpc/'+op,data=json.dumps(kw).encode(),headers={'apikey':key,'Authorization':'Bearer '+users[i]['token'],'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=20) as r:return json.load(r)
a=rpc(7,'create_room',p_request_id=str(uuid.uuid4()),p_payload={'nickname':'RealtimeHost'});assert a['ok'],a
room=a['room_id'];(ROOT/'realtime_test_room.json').write_text(json.dumps(room))
a=rpc(6,'join_room',p_request_id=str(uuid.uuid4()),p_payload={'nickname':'RealtimeGuest','code':a['snapshot']['code']});assert a['ok']
url='wss://noxkiahycepomvbhmxsx.supabase.co/realtime/v1/websocket?apikey='+key+'&vsn=1.0.0'
def subscribe(i):
 ws=connect(url,open_timeout=20)
 ws.send(json.dumps({'topic':'realtime:heist:'+room,'event':'phx_join','payload':{'config':{'broadcast':{'ack':False,'self':False},'presence':{'key':''},'postgres_changes':[{'event':'UPDATE','schema':'public','table':'room_snapshots','filter':'room_id=eq.'+room}]},'access_token':users[i]['token']},'ref':'1'}))
 while True:
  msg=json.loads(ws.recv(timeout=15))
  if msg['event']=='phx_reply':
   assert msg['payload']['status']=='ok',msg
   break
 return ws
sockets=[subscribe(i) for i in [7,6,5]]
start=time.monotonic()
def receive(ws):
 while True:
  m=json.loads(ws.recv(timeout=20))
  if m['event']=='postgres_changes':
   rec=m['payload']['data']['record'];now=time.time()
   committed=datetime.datetime.fromisoformat(rec['updated_at']).timestamp()
   return rec,round((now-committed)*1000,1)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 futures=[pool.submit(receive,ws) for ws in sockets[:2]]
 a=rpc(7,'set_ready',p_request_id=str(uuid.uuid4()),p_room=room,p_payload={'ready':True});assert a['ok'],a
 results=[f.result() for f in futures]
records=[x[0] for x in results];latency=[x[1] for x in results]
assert records[0]==records[1] and records[0]['revision']==a['snapshot']['revision'],records
assert records[0]['payload']==a['snapshot']
outsider_received=False
try:
 deadline=time.monotonic()+2
 while time.monotonic()<deadline:
  m=json.loads(sockets[2].recv(timeout=max(.01,deadline-time.monotonic())))
  if m['event']=='postgres_changes':outsider_received=True;break
except TimeoutError:pass
assert not outsider_received
for ws in sockets:ws.close()
# Reconnect and fetch after missing a revision.
a=rpc(7,'set_ready',p_request_id=str(uuid.uuid4()),p_room=room,p_payload={'ready':False})
ws=subscribe(6);b=rpc(6,'get_snapshot',p_room=room);assert b['snapshot']==a['snapshot'];ws.close()
report={'passed':4,'checks':['two authenticated sockets receive identical committed snapshot','broadcast revision matches RPC result','outsider receives no private room changes','reconnect plus snapshot fetch restores latest revision'],'server_update_to_socket_receive_ms':latency,'room':room}
(ROOT/'realtime_test_results.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)

"""Overlapping real HTTP requests against isolated, administratively seeded fixtures.
These controlled fixtures do not certify production timing or complete matches.
"""
import http_tests as h
import json,uuid,sys,hashlib,pathlib
cases=json.loads((h.ROOT/'runs/race-fixtures.json').read_text())
name=sys.argv[1];f=next(x for x in cases if x['case_name']==name)
r,g,n=f['room'],f['match'],f['n'];h.rooms.append(r)
(h.RUN/'fixture.json').write_text(json.dumps(dict(f,source_sha256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),clock_mode='controlled fixture; not production-timer acceptance'),indent=2))
def action(i,p,req=None):return h.rpc(i,'submit_action',r,g,1,p,req)
def beat(i):return h.rpc(i,'heartbeat_and_advance',r)
complete=False
try:
 if name in ('identical','conflict','competing'):
  req=str(uuid.uuid4())
  p={'kind':'bluff'};q=p if name=='identical' else {'kind':'defend','bank_amount':0}
  out=h.parallel(name,[lambda:action(0,p,req),lambda:action(0,q,req if name!='competing' else str(uuid.uuid4()))])
  if name=='identical':h.check('identical concurrent UUID returns exact receipt',out[0]==out[1] and out[0]['ok'])
  else:h.check('exactly one competing submission accepted',sum(x['ok'] for x in out)==1 and any(x.get('error')==('request_id_reused' if name=='conflict' else 'already_locked') for x in out))
  winner=next(x for x in out if x['ok']);last=action(1,p);h.check('remaining player action accepted',last['ok'])
  status,own=h.http(0,'/rest/v1/rpc/get_own_action',{'p_room':r,'p_match':g,'p_round':1})
  h.check('committed own action retains accepted request',status==200 and own['action']['request_id'] in [req]+[x['request_id'] for x in h.requests if x['request_id']])
 elif name=='six_final':
  out=h.parallel(name,[lambda i=i:action(i,{'kind':'bluff'}) for i in range(n)])
  h.check('six competing final actions accepted',all(x['ok'] for x in out))
 elif name=='action_timeout':
  out=h.parallel(name,[lambda:action(0,{'kind':'bluff'}),lambda:beat(1)])
  h.check('late action rejected while timeout succeeds',not out[0]['ok'] and out[0].get('error') in ('wrong_phase','late_action','stale_turn') and out[1]['ok'])
 else:
  out=h.parallel(name,[lambda:beat(0),lambda:beat(1)])
  h.check('both expiry heartbeats accepted',all(x['ok'] for x in out))
 snaps=h.parallel('snapshot reads '+name,[lambda i=i:h.snap(i,r) for i in range(n)])
 s=snaps[0];h.check('snapshots identical '+name,all(x==s for x in snaps))
 if name in ('identical','conflict','competing','six_final','action_timeout','expiry'):
  h.check('round resolves exactly once '+name,s['phase']=='reveal' and len(s['history'])==1 and len(s['history'][0]['actions'])==n)
  if name in ('action_timeout','expiry'):h.check('timeout banks once per player',all(x['purse']==2 and x['vault']==5 for x in s['players']))
  if name in ('identical','six_final'):h.check('bluff scores applied once',all(x['purse']==10 and x['vault']==0 for x in s['players']))
 elif name=='reveal_next':h.check('reveal advances to next signal once',s['phase']=='signal' and s['round']==2)
 elif name=='final_results':h.check('final reveal yields persisted shared winners',s['phase']=='results' and s['round']==5 and len(s['results'])==2 and all(x['winner'] and x['score']==6 for x in s['results']))
 h.check('response revisions never exceed committed snapshot',all((x.get('snapshot') or {}).get('revision',0)<=s['revision'] for x in out))
 complete=True
except BaseException as e:
 if not h.failures:h.failures.append({'type':type(e).__name__,'check':'uncaught harness exception'})
 (h.RUN/'failure.log').write_text(json.dumps(h.failures,indent=2));print('FAILED',name,type(e).__name__,flush=True)
finally:
 h.save_report(complete);print('RESULT',h.RUN/'results.json',flush=True)
sys.exit(0 if complete else 1)

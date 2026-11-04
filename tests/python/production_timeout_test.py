"""Natural server deadlines; no administrative clock changes."""
import http_tests as h
import time,datetime,json,hashlib,pathlib
complete=False
def epoch(s):return datetime.datetime.fromisoformat(s).timestamp()
def wait_actual(deadline):
 while time.time()<epoch(deadline)+.15:time.sleep(min(1,max(.01,epoch(deadline)+.15-time.time())))
try:
 r,code=h.room([6,5]);h.ready([6,5],r);s=h.snap(6,r)
 a=h.rpc(6,'start_match',r,p={'expected_revision':s['revision']});h.check('natural timeout match started',a['ok']);s=a['snapshot'];g=s['match_id']
 first_deadline=s['deadline'];h.check('initial signal window is 12 seconds',11.5<epoch(first_deadline)-epoch(a['server_time'])<=12)
 wait_actual(first_deadline)
 a=h.rpc(6,'heartbeat_and_advance',r);s=a['snapshot'];h.check('natural 12-second signal expiry reaches plan',a['ok'] and s['phase']=='plan' and s['round']==1)
 plan_deadline=s['deadline'];h.check('planning deadline adds exactly 35 seconds',abs(epoch(plan_deadline)-epoch(first_deadline)-35)<.001)
 wait_actual(plan_deadline)
 out=h.parallel('natural timeout action versus heartbeat',[lambda:h.rpc(6,'submit_action',r,g,1,{'kind':'bluff'}),lambda:h.rpc(5,'heartbeat_and_advance',r)])
 h.check('natural late action rejected',not out[0]['ok'] and out[0].get('error') in ('wrong_phase','late_action','stale_turn') and out[1]['ok'])
 s=max((x['snapshot'] for x in out),key=lambda x:x['revision']);reveal_deadline=s['deadline']
 h.check('natural plan expiry resolves once',s['phase']=='reveal' and len(s['history'])==1 and all(x['timed_out'] for x in s['history'][0]['actions']))
 h.check('reveal deadline adds exactly 8 seconds',abs(epoch(reveal_deadline)-epoch(plan_deadline)-8)<.001)
 wait_actual(reveal_deadline)
 out=h.parallel('natural multiple reveal expiry heartbeats',[lambda i=i:h.rpc(i,'heartbeat_and_advance',r) for i in [6,5]])
 s=max((x['snapshot'] for x in out),key=lambda x:x['revision'])
 h.check('natural reveal expiry advances once',all(x['ok'] for x in out) and s['phase']=='signal' and s['round']==2)
 h.check('next signal deadline adds exactly 12 seconds',abs(epoch(s['deadline'])-epoch(reveal_deadline)-12)<.001)
 complete=True
except BaseException as e:
 if not h.failures:h.failures.append({'type':type(e).__name__,'check':'natural timing harness exception'})
 (h.RUN/'failure.log').write_text(json.dumps(h.failures,indent=2))
finally:
 (h.RUN/'timing-source.json').write_text(json.dumps({'sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'clock':'unmodified production deadlines'}))
 h.save_report(complete);print('RESULT',h.RUN/'results.json',flush=True)

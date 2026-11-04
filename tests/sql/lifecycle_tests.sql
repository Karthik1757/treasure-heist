begin;
create temporary table checks(name text primary key,passed boolean);
create function pg_temp.check_it(n text, v boolean) returns void language plpgsql as $$begin if v is not true then raise exception 'FAIL: %',n;end if;insert into checks values(n,true);end$$;
create function pg_temp.rpc(u uuid,op text,r uuid default null,g uuid default null,rnd int default null,p jsonb default '{}'::jsonb,req uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare ans jsonb;
begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
 set local role authenticated;
 execute format('select public.%I($1,$2,$3,$4,$5)',op) into ans using req,r,g,rnd,p;
 reset role;return ans;
exception when others then reset role;raise;
end$$;
create function pg_temp.snapshot(u uuid,r uuid) returns jsonb language plpgsql as $$declare ans jsonb;begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);set local role authenticated;
 ans=public.get_snapshot(r);reset role;return ans;
exception when others then reset role;raise;end$$;

do $$
declare us uuid[];r uuid;g uuid;a jsonb;s jsonb;ids uuid[];i int;j int;n int;v bigint;req uuid;before_state jsonb;after_state jsonb;
begin
select array_agg(gen_random_uuid()) into us from generate_series(1,8);insert into auth.users(id,is_anonymous) select x,true from unnest(us)x;
a=pg_temp.rpc(us[1],'create_room',p=>'{"nickname":"Host"}'::jsonb);r=(a->>'room_id')::uuid;s=a->'snapshot';
for i in 2..3 loop a=pg_temp.rpc(us[i],'join_room',p=>jsonb_build_object('nickname','Guest'||i,'code',s->>'code'));end loop;
select array_agg(id order by seat) into ids from heist_private.members where room_id=r;
a=pg_temp.rpc(us[2],'claim_host',r);perform pg_temp.check_it('active host cannot be replaced',a->>'error'='host_still_active');
update heist_private.members set last_seen_at=clock_timestamp()-interval '31 seconds' where room_id=r and user_id=us[1];
a=pg_temp.rpc(us[3],'claim_host',r);perform pg_temp.check_it('later guest cannot steal host',a->>'error'='earlier_seat_available');
a=pg_temp.rpc(us[2],'claim_host',r);perform pg_temp.check_it('earliest active guest claims host',(a->>'ok')::boolean);
s=a->'snapshot';a=pg_temp.rpc(us[2],'kick_member',r,p=>jsonb_build_object('expected_revision',s->'revision','member_id',ids[3]));
perform pg_temp.check_it('host can remove lobby seat',(a->>'ok')::boolean and jsonb_array_length(a->'snapshot'->'players')=2);
begin perform pg_temp.snapshot(us[3],r);raise exception 'kicked read succeeded';exception when insufficient_privilege then perform pg_temp.check_it('removed seat loses snapshot access',true);end;
s=a->'snapshot';a=pg_temp.rpc(us[2],'lock_room',r,p=>jsonb_build_object('expected_revision',s->'revision','locked',true));
a=pg_temp.rpc(us[4],'join_room',p=>jsonb_build_object('nickname','Late','code',s->>'code'));perform pg_temp.check_it('locked lobby rejects entry',a->>'error'='room_unavailable');
for i in 1..2 loop a=pg_temp.rpc(us[i],'set_ready',r,p=>'{"ready":true}'::jsonb);end loop;
s=pg_temp.snapshot(us[2],r)->'snapshot';a=pg_temp.rpc(us[2],'start_match',r,p=>jsonb_build_object('expected_revision',s->'revision'));g=(a->'snapshot'->>'match_id')::uuid;
update heist_private.matches set deadline=clock_timestamp()-interval '1 millisecond' where id=g;
a=pg_temp.rpc(us[1],'set_signal',r,g,1,'{"claim":"guarding"}'::jsonb);
perform pg_temp.check_it('late signal rejected',a->>'error'='invalid_signal');
perform pg_temp.check_it('late request preserves deadline progression',a->'snapshot'->>'phase'='plan');
a=pg_temp.rpc(us[1],'leave_room',r);perform pg_temp.check_it('two-player forfeit abandons game',(select status='abandoned' from heist_private.rooms where id=r));
perform pg_temp.check_it('abandoned game has no winner',(select results='[]'::jsonb from heist_private.matches where id=g));
update heist_private.rooms set expires_at=clock_timestamp()-interval '1 second' where id=r;
begin perform pg_temp.snapshot(us[2],r);raise exception 'expired read succeeded';exception when insufficient_privilege then perform pg_temp.check_it('expired room read denied',true);end;
-- Five complete rounds at minimum and intermediate player counts.
foreach n in array array[2,3] loop
 a=pg_temp.rpc(us[4],'create_room',p=>'{"nickname":"MatchHost"}'::jsonb);r=(a->>'room_id')::uuid;s=a->'snapshot';
 for i in 5..(3+n) loop a=pg_temp.rpc(us[i],'join_room',p=>jsonb_build_object('nickname','Crew'||i,'code',s->>'code'));end loop;
 for i in 4..(3+n) loop a=pg_temp.rpc(us[i],'set_ready',r,p=>'{"ready":true}'::jsonb);end loop;
 s=a->'snapshot';a=pg_temp.rpc(us[4],'start_match',r,p=>jsonb_build_object('expected_revision',s->'revision'));g=(a->'snapshot'->>'match_id')::uuid;
 for j in 1..5 loop
  update heist_private.matches set deadline=clock_timestamp()+interval '10 minutes' where id=g;
  for i in 4..(3+n) loop a=pg_temp.rpc(us[i],'set_signal',r,g,j,'{"claim":"hunting"}'::jsonb);end loop;
  for i in 4..(3+n) loop a=pg_temp.rpc(us[i],'submit_action',r,g,j,'{"kind":"bluff"}'::jsonb);end loop;
  perform pg_temp.check_it(n||'p round '||j||' resolves',a->'snapshot'->>'phase'='reveal');
  update heist_private.matches set deadline=clock_timestamp()-interval '1 millisecond' where id=g;a=pg_temp.rpc(us[4],'heartbeat_and_advance',r);
 end loop;
 perform pg_temp.check_it(n||'p full match exact final score',(select bool_and(purse=26 and vault=0) from heist_private.scores where match_id=g) and a->'snapshot'->>'phase'='results');
 perform pg_temp.check_it(n||'p final snapshot agreement',(pg_temp.snapshot(us[4],r)->'snapshot')=(pg_temp.snapshot(us[5],r)->'snapshot'));
end loop;
-- Mutation budget persists on expected errors; rejected calls cannot roll it back.
for i in 1..60 loop a=pg_temp.rpc(us[8],'set_ready',gen_random_uuid(),p=>'{"ready":true}'::jsonb);end loop;
a=pg_temp.rpc(us[8],'set_ready',gen_random_uuid(),p=>'{"ready":true}'::jsonb);perform pg_temp.check_it('mutation rate ceiling enforced',a->>'error'='rate_limited');
for i in 1..5 loop a=pg_temp.rpc(us[7],'create_room',p=>jsonb_build_object('nickname','RateHost'||i));end loop;
a=pg_temp.rpc(us[7],'create_room',p=>'{"nickname":"Sixth"}'::jsonb);perform pg_temp.check_it('room creation hourly ceiling enforced',a->>'error'='rate_limited');
end$$;
select count(*) as passed,jsonb_agg(name order by name) as checks from checks;
rollback;

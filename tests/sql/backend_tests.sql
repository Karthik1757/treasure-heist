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
declare us uuid[];ms uuid[];r uuid;g uuid;rr uuid;other uuid;ans jsonb;s jsonb;tmp jsonb;rid uuid;req uuid=gen_random_uuid();i int;j int;before_n int;after_n int;event_names text[];v int;own jsonb;cnt int;
begin
 select array_agg(gen_random_uuid()) into us from generate_series(1,8);
 insert into auth.users(id,is_anonymous) select x,true from unnest(us)x;
 ans=pg_temp.rpc(us[1],'create_room',p=>'{"nickname":"Captain"}',req=>req);
 perform pg_temp.check_it('create succeeds',(ans->>'ok')::boolean);
 r=(ans->>'room_id')::uuid;s=ans->'snapshot';
 tmp=pg_temp.rpc(us[1],'create_room',p=>'{"nickname":"Captain"}',req=>req);
 perform pg_temp.check_it('same request returns exact receipt',tmp=ans);
 tmp=pg_temp.rpc(us[1],'create_room',p=>'{"nickname":"Changed"}',req=>req);
 perform pg_temp.check_it('changed payload with same UUID rejected',tmp->>'error'='request_id_reused');
 perform pg_temp.check_it('eight-character room code',length(s->>'code')=8);
 tmp=pg_temp.rpc(us[2],'join_room',p=>jsonb_build_object('nickname','captain','code',s->>'code'));
 perform pg_temp.check_it('case insensitive duplicate name rejected',tmp->>'error'='nickname_taken');
 for i in 2..6 loop
 ans=pg_temp.rpc(us[i],'join_room',p=>jsonb_build_object('nickname','Sailor'||i,'code',s->>'code'));
 perform pg_temp.check_it('join seat '||i,(ans->>'ok')::boolean);
 end loop;
 ans=pg_temp.rpc(us[7],'join_room',p=>jsonb_build_object('nickname','Seventh','code',s->>'code'));
 perform pg_temp.check_it('seventh player rejected',ans->>'error'='room_full');
 select array_agg(id order by seat) into ms from heist_private.members where room_id=r and active;
 perform pg_temp.check_it('six unique seats',array_length(ms,1)=6);
 begin perform pg_temp.snapshot(us[7],r);raise exception 'outside read succeeded';exception when insufficient_privilege then perform pg_temp.check_it('outsider snapshot denied',true);end;
 -- Assert actual RLS for a room member and outsider using restricted database role.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',us[7],'role','authenticated')::text,true);
 set local role authenticated;select count(*) into cnt from public.room_snapshots where room_id=r;reset role;
 perform pg_temp.check_it('RLS hides room from outsider',cnt=0);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',us[1],'role','authenticated')::text,true);
 set local role authenticated;select count(*) into cnt from public.room_snapshots where room_id=r;reset role;
 perform pg_temp.check_it('RLS permits member snapshot',cnt=1);
 begin set local role authenticated;perform 1 from heist_private.sealed_actions;reset role;raise exception 'hidden read succeeded';exception when insufficient_privilege then reset role;perform pg_temp.check_it('direct sealed-action read denied',true);end;
 begin set local role authenticated;update public.room_snapshots set revision=999 where room_id=r;reset role;raise exception 'snapshot write succeeded';exception when insufficient_privilege then reset role;perform pg_temp.check_it('direct snapshot write denied',true);end;
 begin set local role anon;perform public.get_snapshot(r);reset role;raise exception 'anon succeeded';exception when insufficient_privilege then reset role;perform pg_temp.check_it('unauthenticated read denied',true);end;
 s=pg_temp.snapshot(us[1],r)->'snapshot';
 ans=pg_temp.rpc(us[2],'start_match',r,p=>jsonb_build_object('expected_revision',s->'revision'));
 perform pg_temp.check_it('guest start denied',ans->>'error'='host_required');
 s=pg_temp.snapshot(us[1],r)->'snapshot';
 ans=pg_temp.rpc(us[1],'start_match',r,p=>jsonb_build_object('expected_revision',s->'revision'));
 perform pg_temp.check_it('start requires readiness',ans->>'error'='players_not_ready');
 for i in 1..6 loop ans=pg_temp.rpc(us[i],'set_ready',r,p=>'{"ready":true}');end loop;
 s=pg_temp.snapshot(us[1],r)->'snapshot';
 ans=pg_temp.rpc(us[1],'start_match',r,p=>jsonb_build_object('expected_revision',s->'revision'));
 perform pg_temp.check_it('ready match starts',(ans->>'ok')::boolean);
 g=(ans->'snapshot'->>'match_id')::uuid;
 perform pg_temp.check_it('initial balance 6 and 0',(select bool_and(purse=6 and vault=0) from heist_private.scores where match_id=g));
 perform pg_temp.check_it('event deck contains all five once',(select count(distinct event)=5 from heist_private.rounds where match_id=g));
 perform pg_temp.check_it('future events and random draws hidden',not((ans->'snapshot')?'random_draws') and not((ans->'snapshot')?'event_order') and jsonb_array_length(ans->'snapshot'->'history')=0);
 -- Keep tests independent of execution/network duration; no production clock override exists.
 update heist_private.matches set deadline=clock_timestamp()+interval '10 minutes' where id=g;
 ans=pg_temp.rpc(us[1],'set_signal',r,g,1,'{"claim":"guarding"}');
 s=pg_temp.snapshot(us[2],r)->'snapshot';
 perform pg_temp.check_it('claims hidden until planning',s->'players'->0->'signal'='null'::jsonb);
 ans=pg_temp.rpc(us[1],'set_signal',r,g,1,'{"claim":"hunting"}');
 perform pg_temp.check_it('second signal rejected',ans->>'error'='already_locked');
 for i in 2..6 loop ans=pg_temp.rpc(us[i],'set_signal',r,g,1,'{"claim":"hunting"}');end loop;
 perform pg_temp.check_it('all signals advance to plan',ans->'snapshot'->>'phase'='plan');
 update heist_private.matches set deadline=clock_timestamp()+interval '10 minutes' where id=g;
 update heist_private.rounds set event='royal_bounty' where match_id=g and number=1;
 -- Validate all banking bounds, including fractional JSON values before SQL coercion.
 for tmp in select value from jsonb_array_elements('[{}, {"bank_amount":null},{"bank_amount":-1},{"bank_amount":5},{"bank_amount":1.5},{"bank_amount":"2"}]') loop
 ans=pg_temp.rpc(us[1],'submit_action',r,g,1,tmp||'{"kind":"defend"}');
 perform pg_temp.check_it('invalid bank '||tmp::text,ans->>'error'='invalid_bank_amount');
 end loop;
 update heist_private.scores set purse=1 where match_id=g and member_id=ms[1];
 ans=pg_temp.rpc(us[1],'submit_action',r,g,1,'{"kind":"defend","bank_amount":2}');
 perform pg_temp.check_it('unaffordable bank rejected',ans->>'error'='unaffordable_bank');
 update heist_private.scores set purse=6 where match_id=g and member_id=ms[1];
 ans=pg_temp.rpc(us[2],'submit_action',r,g,1,jsonb_build_object('kind','steal','target_member_id',ms[2]));
 perform pg_temp.check_it('self steal rejected',ans->>'error'='invalid_target');
 ans=pg_temp.rpc(us[2],'submit_action',r,g,1,jsonb_build_object('kind','steal','target_member_id',gen_random_uuid()));
 perform pg_temp.check_it('foreign target rejected',ans->>'error'='invalid_target');
 req=gen_random_uuid();ans=pg_temp.rpc(us[1],'submit_action',r,g,1,'{"kind":"defend","bank_amount":0}',req);
 tmp=pg_temp.rpc(us[1],'submit_action',r,g,1,'{"kind":"defend","bank_amount":0}',req);
 perform pg_temp.check_it('action retry stable',ans=tmp);
 ans=pg_temp.rpc(us[1],'submit_action',r,g,1,'{"kind":"bluff"}');
 perform pg_temp.check_it('second action rejected',ans->>'error'='already_locked');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',us[1],'role','authenticated')::text,true);set local role authenticated;own=public.get_own_action(r,g,1);reset role;
 perform pg_temp.check_it('refresh restores own action',own->'action'->>'kind'='defend');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',us[2],'role','authenticated')::text,true);set local role authenticated;own=public.get_own_action(r,g,1);reset role;
 perform pg_temp.check_it('other player cannot recover opponents action',own->'action'='null'::jsonb);
 s=pg_temp.snapshot(us[2],r)->'snapshot';
 perform pg_temp.check_it('locked action not in public planning snapshot',not(s::text like '%"bank_amount"%') and jsonb_array_length(s->'history')=0 and (s->'players'->0->>'locked')::boolean);
 ans=pg_temp.rpc(us[2],'submit_action',r,g,1,jsonb_build_object('kind','steal','target_member_id',ms[1]));
 ans=pg_temp.rpc(us[3],'submit_action',r,g,1,'{"kind":"explore","island":0}');
 ans=pg_temp.rpc(us[4],'submit_action',r,g,1,'{"kind":"explore","island":0}');
 ans=pg_temp.rpc(us[5],'submit_action',r,g,1,'{"kind":"bluff"}');
 ans=pg_temp.rpc(us[6],'submit_action',r,g,1,jsonb_build_object('kind','steal','target_member_id',ms[5]));
 perform pg_temp.check_it('last lock resolves atomically',ans->'snapshot'->>'phase'='reveal' and jsonb_array_length(ans->'snapshot'->'history')=1);
 perform pg_temp.check_it('bank zero Royal Bounty protects and awards 2',(select purse=6 and vault=2 from heist_private.scores where match_id=g and member_id=ms[1]));
 perform pg_temp.check_it('failed raid has no fee',(select purse=6 from heist_private.scores where match_id=g and member_id=ms[2]));
 perform pg_temp.check_it('crowded safe island yields 2 each',(select bool_and(purse=8) from heist_private.scores where match_id=g and member_id in(ms[3],ms[4])));
 perform pg_temp.check_it('targeted bluff loses stolen 3 plus penalty 2',(select purse=1 from heist_private.scores where match_id=g and member_id=ms[5]));
 perform pg_temp.check_it('successful thief receives 3',(select purse=9 from heist_private.scores where match_id=g and member_id=ms[6]));
 tmp=heist_private.resolve_round(g);
 perform pg_temp.check_it('re-resolution has no additional score change',(select purse=9 from heist_private.scores where match_id=g and member_id=ms[6]));
 for j in 2..5 loop
 update heist_private.matches set deadline=clock_timestamp()-interval '1 millisecond' where id=g;
 ans=pg_temp.rpc(us[1],'heartbeat_and_advance',r);
 perform pg_temp.check_it('advance to round '||j,(ans->'snapshot'->>'round')::int=j and ans->'snapshot'->>'phase'='signal');
 update heist_private.matches set deadline=clock_timestamp()+interval '10 minutes' where id=g;
 for i in 1..6 loop ans=pg_temp.rpc(us[i],'set_signal',r,g,j,'{"claim":"hunting"}');end loop;
 update heist_private.matches set deadline=clock_timestamp()+interval '10 minutes' where id=g;
 for i in 1..6 loop ans=pg_temp.rpc(us[i],'submit_action',r,g,j,'{"kind":"defend","bank_amount":0}');end loop;
 perform pg_temp.check_it('round '||j||' resolves',ans->'snapshot'->>'phase'='reveal');
 end loop;
 update heist_private.matches set deadline=clock_timestamp()-interval '1 millisecond' where id=g;
 ans=pg_temp.rpc(us[1],'heartbeat_and_advance',r);
 perform pg_temp.check_it('five rounds produce results',ans->'snapshot'->>'phase'='results' and jsonb_array_length(ans->'snapshot'->'results')=6 and jsonb_array_length(ans->'snapshot'->'history')=5);
 perform pg_temp.check_it('winner calculation greatest score', (select member_id=ms[6] from (select member_id from heist_private.scores where match_id=g order by purse+vault desc,vault desc limit 1)t) and (select (value->>'winner')::boolean from jsonb_array_elements(ans->'snapshot'->'results') where value->>'member_id'=ms[6]::text));
 s=ans->'snapshot';
 ans=pg_temp.rpc(us[1],'return_to_lobby',r,g,p=>jsonb_build_object('expected_revision',s->'revision'));
 perform pg_temp.check_it('rematch lobby resets readiness',ans->'snapshot'->>'status'='lobby' and (select bool_and(not ready) from heist_private.members where room_id=r and active));
 for i in 1..6 loop ans=pg_temp.rpc(us[i],'set_ready',r,p=>'{"ready":true}');end loop;
 s=pg_temp.snapshot(us[1],r)->'snapshot';ans=pg_temp.rpc(us[1],'start_match',r,p=>jsonb_build_object('expected_revision',s->'revision'));
 rr=(ans->'snapshot'->>'match_id')::uuid;
 perform pg_temp.check_it('rematch uses fresh identity',rr<>g);
 tmp=pg_temp.rpc(us[1],'submit_action',r,g,1,'{"kind":"bluff"}');
 perform pg_temp.check_it('stale prior match action rejected',tmp->>'error'='stale_turn');
 -- Entire unattended match advances on one authenticated call, using documented timeout defaults.
 update heist_private.matches set deadline=clock_timestamp()-interval '20 minutes' where id=rr;
 ans=pg_temp.rpc(us[1],'heartbeat_and_advance',r);
 perform pg_temp.check_it('unattended timeout match completes',ans->'snapshot'->>'phase'='results');
 perform pg_temp.check_it('timeout banks at most 4',(select bool_and(bank_amount between 0 and 4 and timed_out) from heist_private.sealed_actions where match_id=rr));
 perform pg_temp.check_it('timeout match shared victory',(select bool_and((value->>'winner')::boolean and (value->>'rank')::int=1) from jsonb_array_elements(ans->'snapshot'->'results')));
 -- Explicit winner tiebreak test.
 update heist_private.scores set purse=10,vault=0 where match_id=rr;
 update heist_private.scores set purse=5,vault=5 where match_id=rr and member_id=ms[1];
 perform heist_private.finish_match(rr);s=heist_private.publish_snapshot(r);
 perform pg_temp.check_it('vault breaks total-score tie',(select (value->>'winner')::boolean from jsonb_array_elements(s->'results') where value->>'member_id'=ms[1]::text) and (select count(*)=1 from jsonb_array_elements(s->'results') where (value->>'winner')::boolean));
 -- Bad joins consume rate budget and do not enumerate rooms.
 for j in 1..20 loop ans=pg_temp.rpc(us[8],'join_room',p=>'{"nickname":"NoRoom","code":"ZZZZZZZZ"}');end loop;
 ans=pg_temp.rpc(us[8],'join_room',p=>'{"nickname":"NoRoom","code":"ZZZZZZZZ"}');
 perform pg_temp.check_it('failed joins rate limited',ans->>'error'='rate_limited');
 perform pg_temp.check_it('only snapshot table published',(select count(*)=1 and bool_and(schemaname='public' and tablename='room_snapshots') from pg_publication_tables where pubname='supabase_realtime'));
 perform pg_temp.check_it('no client execute on resolver',not has_function_privilege('authenticated','heist_private.resolve_round(uuid)','execute'));
 perform pg_temp.check_it('nonnegative scores',(select bool_and(purse>=0 and vault>=0) from heist_private.scores where match_id in(g,rr)));
end$$;
select count(*) as passed,jsonb_agg(name order by name) as checks from checks;
rollback;

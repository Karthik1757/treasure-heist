-- Forward-only Stage 1 extension; does not recreate the applied foundation.
alter table heist_private.rooms add column entry_locked boolean not null default false;
alter table heist_private.members add column active boolean not null default true;
alter table heist_private.matches add column results jsonb;
alter table heist_private.members drop constraint members_room_id_seat_key;
drop index heist_private.members_name;
create unique index members_active_seat on heist_private.members(room_id,seat) where active;
create unique index members_active_name on heist_private.members(room_id,lower(nickname)) where active;
create index rooms_expiry on heist_private.rooms(expires_at);
create index scores_member on heist_private.scores(member_id);
create index actions_target on heist_private.sealed_actions(match_id,target_member_id);
create index receipts_created on heist_private.request_receipts(created_at);

create or replace function heist_private.is_member(p_room uuid) returns boolean language sql stable security definer set search_path='' as $$
select auth.uid() is not null and exists(select 1 from heist_private.members m join heist_private.rooms r on r.id=m.room_id where m.room_id=p_room and m.user_id=auth.uid() and m.active and r.expires_at>now())
$$;

create function heist_private.publish_snapshot(p_room uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r heist_private.rooms;g heist_private.matches;players jsonb;hist jsonb;body jsonb;order_ids jsonb;event_name text;
begin
 select * into r from heist_private.rooms where id=p_room for update;
 if r.status<>'lobby' then select * into g from heist_private.matches where room_id=p_room order by match_no desc limit 1;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'nickname',m.nickname,'seat',m.seat,'ready',m.ready,'host',m.user_id=r.host_user_id,'last_seen_at',m.last_seen_at,'forfeited',m.forfeited,'purse',s.purse,'vault',s.vault,'signal',case when g.phase<>'signal' then si.claim else null end,'signalled',si.member_id is not null,'locked',a.member_id is not null) order by m.seat),'[]') into players
 from heist_private.members m left join heist_private.scores s on s.member_id=m.id and s.match_id=g.id
 left join heist_private.signals si on si.member_id=m.id and si.match_id=g.id and si.round=g.round
 left join heist_private.sealed_actions a on a.member_id=m.id and a.match_id=g.id and a.round=g.round
 where m.room_id=p_room and m.active;
 select coalesce(jsonb_agg(jsonb_build_object('round',rr.number,'event',rr.event,'ledger',rr.reveal,'actions',(select jsonb_agg(jsonb_build_object('member_id',a.member_id,'kind',a.kind,'island',a.island,'target_member_id',a.target_member_id,'bank_amount',a.bank_amount,'timed_out',a.timed_out) order by a.member_id) from heist_private.sealed_actions a where a.match_id=g.id and a.round=rr.number)) order by rr.number),'[]') into hist from heist_private.rounds rr where rr.match_id=g.id and rr.resolved;
 if g.id is not null then
 select event into event_name from heist_private.rounds where match_id=g.id and number=g.round;
 select jsonb_agg(v order by mod(ord::int-1-(g.round-1)%array_length(g.priority_order,1)+array_length(g.priority_order,1),array_length(g.priority_order,1))) into order_ids from unnest(g.priority_order) with ordinality x(v,ord);
 end if;
 update heist_private.rooms set revision=revision+1 where id=p_room returning * into r;
 body=jsonb_build_object('room_id',r.id,'code',r.code,'status',r.status,'entry_locked',r.entry_locked,'revision',r.revision,'expires_at',r.expires_at,'players',players,'match_id',g.id,'round',g.round,'phase',g.phase,'deadline',g.deadline,'event',event_name,'priority_order',order_ids,'history',hist,'results',g.results,'rules_version','1.2');
 insert into public.room_snapshots(room_id,revision,payload,updated_at) values(r.id,r.revision,body,clock_timestamp()) on conflict(room_id) do update set revision=excluded.revision,payload=excluded.payload,updated_at=excluded.updated_at;
 return body;
end$$;

create function heist_private.finish_match(p_match uuid) returns void language plpgsql security definer set search_path='' as $$
declare ranking jsonb;rid uuid;
begin
 select room_id into rid from heist_private.matches where id=p_match;
 select jsonb_agg(jsonb_build_object('member_id',member_id,'nickname',nickname,'purse',purse,'vault',vault,'score',purse+vault,'rank',case when forfeited then null else place end,'winner',not forfeited and place=1,'forfeited',forfeited) order by forfeited,place,member_id) into ranking from (
 select s.*,m.nickname,m.forfeited,rank() over(order by m.forfeited asc,(s.purse+s.vault) desc,s.vault desc) as place from heist_private.scores s join heist_private.members m on m.id=s.member_id where s.match_id=p_match) q;
 update heist_private.matches set phase='results',results=ranking where id=p_match;
 update heist_private.rooms set status='results',expires_at=clock_timestamp()+interval '24 hours' where id=rid;
end$$;

create function heist_private.advance_room(p_room uuid) returns void language plpgsql security definer set search_path='' as $$
declare g heist_private.matches;r heist_private.rooms;cnt int;done int;due boolean;anchor timestamptz;i int;
begin
 select * into r from heist_private.rooms where id=p_room for update;
 if r.status<>'playing' then return;end if;
 for i in 1..20 loop
 select * into g from heist_private.matches where room_id=p_room order by match_no desc limit 1;
 if g.phase in('results','abandoned') then return;end if;
 select count(*) into cnt from heist_private.scores where match_id=g.id;
 due=clock_timestamp()>=g.deadline;
 anchor=case when due then g.deadline else clock_timestamp() end;
 if g.phase='signal' then
 select count(*) into done from heist_private.signals where match_id=g.id and round=g.round;
 if not due and done<cnt then return;end if;
 insert into heist_private.signals(match_id,round,member_id,claim) select g.id,g.round,member_id,'hunting' from heist_private.scores where match_id=g.id on conflict do nothing;
 update heist_private.matches set phase='plan',deadline=anchor+interval '35 seconds' where id=g.id;
 elsif g.phase='plan' then
 select count(*) into done from heist_private.sealed_actions where match_id=g.id and round=g.round;
 if not due and done<cnt then return;end if;
 perform heist_private.resolve_round(g.id);
 -- Preserve historical deadlines when recovering an unattended room.
 update heist_private.matches set deadline=anchor+interval '8 seconds' where id=g.id;
 elsif g.phase='reveal' then
 if not due then return;end if;
 if g.round=5 then perform heist_private.finish_match(g.id);return;end if;
 update heist_private.matches set round=round+1,phase='signal',deadline=anchor+interval '12 seconds' where id=g.id;
 end if;
 end loop;
 raise exception 'Phase progression bound exceeded';
end$$;

create function heist_private.take_rate(p_uid uuid,p_op text) returns boolean language plpgsql security definer set search_path='' as $$
declare bucket timestamptz;lim int;val int;scope text;
begin
 bucket=date_trunc(case when p_op='create_room' then 'hour' else 'minute' end,clock_timestamp());
 lim=case p_op when 'create_room' then 5 when 'join_room' then 20 else 60 end;
 scope=encode(extensions.digest(p_uid::text,'sha256'),'hex');
 insert into heist_private.rate_buckets(scope_hash,window_start,operation,count) values(scope,bucket,case when p_op in('create_room','join_room') then p_op else 'mutations' end,1)
 on conflict(scope_hash,window_start,operation) do update set count=least(heist_private.rate_buckets.count+1,1000000) returning count into val;
 return val<=lim;
end$$;

-- Expected validation failures return JSON so rate counters and expiry advancement commit.
create function heist_private.dispatch(p_operation text,p_request_id uuid,p_room uuid,p_match uuid,p_round integer,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid=auth.uid();r heist_private.rooms;m heist_private.members;g heist_private.matches;receipt heist_private.request_receipts;fp text;res jsonb;body jsonb;nm text;cd text;newid uuid;seatno int;cnt int;j int;k int;events text[];order_ids uuid[];draws jsonb='{}';rd jsonb;mid uuid;ev text;amount int;isle int;target uuid;kind text;expected bigint;changed boolean=false;err text;
begin
 if uid is null then raise exception using errcode='42501',message='Authentication required';end if;
 if p_request_id is null or p_payload is null or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>2048 then return jsonb_build_object('ok',false,'error','invalid_request');end if;
 if not(p_operation=any(array['create_room','join_room','set_ready','start_match','set_signal','submit_action','heartbeat_and_advance','claim_host','leave_room','return_to_lobby','kick_member','lock_room'])) then return jsonb_build_object('ok',false,'error','invalid_operation');end if;
 perform pg_advisory_xact_lock(hashtextextended(uid::text,91217));
 fp=encode(extensions.digest(jsonb_build_array(p_operation,p_room,p_match,p_round,p_payload)::text,'sha256'),'hex');
 select * into receipt from heist_private.request_receipts where user_id=uid and request_id=p_request_id;
 if found then
 if receipt.request_hash<>fp then return jsonb_build_object('ok',false,'error','request_id_reused');end if;
 return receipt.result;
 end if;
 if not heist_private.take_rate(uid,p_operation) then return jsonb_build_object('ok',false,'error','rate_limited');end if;
 -- Catch only expected input/domain failures. Unexpected failures roll back atomically.
 begin
 if p_operation in('create_room','join_room') then
 nm=btrim(p_payload->>'nickname');
 if nm is null or length(nm)<2 or length(nm)>18 or nm ~ '[[:cntrl:]]' then raise exception 'invalid_nickname';end if;
 end if;
 if p_operation='create_room' then
 for j in 1..8 loop
 cd='';for k in 1..8 loop cd=cd||substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',get_byte(extensions.gen_random_bytes(1),0)%32+1,1);end loop;
 begin
 insert into heist_private.rooms(code,host_user_id) values(cd,uid) returning * into r;exit;
 exception when unique_violation then if j=8 then raise exception 'code_allocation_failed';end if;end;
 end loop;
 insert into heist_private.members(room_id,user_id,nickname,seat) values(r.id,uid,nm,0) returning * into m;
 elsif p_operation='join_room' then
 cd=upper(btrim(p_payload->>'code'));
 select * into r from heist_private.rooms where code=cd and expires_at>clock_timestamp() for update;
 if not found then raise exception 'room_unavailable';end if;
 select * into m from heist_private.members where room_id=r.id and user_id=uid;
 if m.id is not null and m.active then
 -- Rejoining the same browser restores the existing seat even after start.
 null;
 else
 if r.status<>'lobby' or r.entry_locked then raise exception 'room_unavailable';end if;
 select min(v) into seatno from generate_series(0,5) v where not exists(select 1 from heist_private.members where room_id=r.id and active and seat=v);
 if seatno is null then raise exception 'room_full';end if;
 if exists(select 1 from heist_private.members where room_id=r.id and active and lower(nickname)=lower(nm)) then raise exception 'nickname_taken';end if;
 if m.id is null then insert into heist_private.members(room_id,user_id,nickname,seat) values(r.id,uid,nm,seatno) returning * into m;
 else update heist_private.members set active=true,seat=seatno,nickname=nm,ready=false,forfeited=false,last_seen_at=clock_timestamp() where id=m.id returning * into m;end if;
 end if;
 else
 select * into r from heist_private.rooms where id=p_room and expires_at>clock_timestamp() for update;
 if not found then raise exception 'room_unavailable';end if;
 select * into m from heist_private.members where room_id=r.id and user_id=uid and active;
 if not found then raise exception 'room_unavailable';end if;
 end if;
 exception when raise_exception or invalid_text_representation or numeric_value_out_of_range or unique_violation then
 get stacked diagnostics err=message_text;
 res=jsonb_build_object('ok',false,'error',case when sqlstate='23505' then 'nickname_taken' else err end);
 end;
 if res is null then
 -- Persist deadline advancement even if the submitted action is stale.
 perform heist_private.advance_room(r.id);
 select * into r from heist_private.rooms where id=r.id;
 select * into g from heist_private.matches where room_id=r.id order by match_no desc limit 1;
 begin
 if p_operation not in('claim_host') then update heist_private.members set last_seen_at=clock_timestamp() where id=m.id;end if;
 if p_operation='set_ready' then
 if r.status<>'lobby' or jsonb_typeof(p_payload->'ready') is distinct from 'boolean' then raise exception 'invalid_ready';end if;
 update heist_private.members set ready=(p_payload->>'ready')::boolean where id=m.id;
 elsif p_operation in('start_match','return_to_lobby','lock_room','kick_member') then
 if r.host_user_id<>uid then raise exception 'host_required';end if;
 if (p_payload->>'expected_revision') is null or (p_payload->>'expected_revision') !~ '^[0-9]+$' then raise exception 'revision_required';end if;
 expected=(p_payload->>'expected_revision')::bigint;
 if expected<>r.revision then raise exception 'stale_revision';end if;
 if p_operation='start_match' then
 if r.status<>'lobby' then raise exception 'wrong_phase';end if;
 select count(*) into cnt from heist_private.members where room_id=r.id and active;
 if cnt<2 or cnt>6 or exists(select 1 from heist_private.members where room_id=r.id and active and (not ready or last_seen_at<clock_timestamp()-interval '30 seconds')) then raise exception 'players_not_ready';end if;
 select array_agg(id order by extensions.gen_random_bytes(16)) into order_ids from heist_private.members where room_id=r.id and active;
 select array_agg(e order by extensions.gen_random_bytes(16)) into events from unnest(array['trade_winds','emerald_bloom','low_tide','royal_bounty','moonrise']) e;
 insert into heist_private.matches(room_id,match_no,phase,deadline,priority_order) values(r.id,coalesce(g.match_no,0)+1,'signal',clock_timestamp()+interval '12 seconds',order_ids) returning * into g;
 insert into heist_private.scores(match_id,member_id) select g.id,id from heist_private.members where room_id=r.id and active;
 for j in 1..5 loop
 insert into heist_private.rounds(match_id,number,event) values(g.id,j,events[j]);rd='{}';
 foreach mid in array order_ids loop rd=rd||jsonb_build_object(mid::text,get_byte(extensions.gen_random_bytes(1),0)%2);end loop;
 draws=draws||jsonb_build_object(j::text,rd);
 end loop;
 insert into heist_private.private_match_data(match_id,event_order,random_draws) values(g.id,to_jsonb(events),draws);
 update heist_private.rooms set status='playing',entry_locked=true where id=r.id;
 elsif p_operation='return_to_lobby' then
 if r.status not in('results','abandoned') then raise exception 'wrong_phase';end if;
 if p_match is distinct from g.id then raise exception 'stale_match';end if;
 update heist_private.members set ready=false,forfeited=false where room_id=r.id and active;
 update heist_private.rooms set status='lobby',entry_locked=false,expires_at=clock_timestamp()+interval '24 hours' where id=r.id;
 elsif p_operation='lock_room' then
 if r.status<>'lobby' or jsonb_typeof(p_payload->'locked') is distinct from 'boolean' then raise exception 'wrong_phase';end if;
 update heist_private.rooms set entry_locked=(p_payload->>'locked')::boolean where id=r.id;
 else
 if r.status<>'lobby' then raise exception 'wrong_phase';end if;
 target=(p_payload->>'member_id')::uuid;
 if target is null or target=m.id then raise exception 'invalid_target';end if;
 update heist_private.members set active=false,ready=false where room_id=r.id and id=target and active;
 if not found then raise exception 'invalid_target';end if;
 end if;
 elsif p_operation in('set_signal','submit_action') then
 if r.status<>'playing' or p_match is distinct from g.id or p_round is distinct from g.round or m.forfeited then raise exception 'stale_turn';end if;
 if clock_timestamp()>=g.deadline then raise exception 'late_action';end if;
 if p_operation='set_signal' then
 if g.phase<>'signal' or (p_payload->>'claim') is null or (p_payload->>'claim') not in('guarding','hunting') then raise exception 'invalid_signal';end if;
 if exists(select 1 from heist_private.signals where match_id=g.id and round=g.round and member_id=m.id) then raise exception 'already_locked';end if;
 insert into heist_private.signals(match_id,round,member_id,claim) values(g.id,g.round,m.id,p_payload->>'claim');
 else
 if g.phase<>'plan' then raise exception 'wrong_phase';end if;
 if exists(select 1 from heist_private.sealed_actions where match_id=g.id and round=g.round and member_id=m.id) then raise exception 'already_locked';end if;
 kind=p_payload->>'kind';
 if kind is null or kind not in('explore','steal','defend','bluff') then raise exception 'invalid_action';end if;
 if (kind='explore' and (p_payload - array['kind','island'])<>'{}') or (kind='steal' and (p_payload-array['kind','target_member_id'])<>'{}') or (kind='defend' and (p_payload-array['kind','bank_amount'])<>'{}') or (kind='bluff' and (p_payload-'kind')<>'{}') then raise exception 'invalid_action_fields';end if;
 if kind='explore' then
 if jsonb_typeof(p_payload->'island') is distinct from 'number' or (p_payload->>'island') !~ '^[0-4]$' then raise exception 'invalid_island';end if;isle=(p_payload->>'island')::int;
 elsif kind='steal' then
 target=(p_payload->>'target_member_id')::uuid;
 if target is null or target=m.id or not exists(select 1 from heist_private.scores where match_id=g.id and member_id=target) then raise exception 'invalid_target';end if;
 elsif kind='defend' then
 if jsonb_typeof(p_payload->'bank_amount') is distinct from 'number' or (p_payload->>'bank_amount') !~ '^[0-4]$' then raise exception 'invalid_bank_amount';end if;
 amount=(p_payload->>'bank_amount')::int;
 if amount>(select purse from heist_private.scores where match_id=g.id and member_id=m.id) then raise exception 'unaffordable_bank';end if;
 end if;
 insert into heist_private.sealed_actions(match_id,round,member_id,request_id,kind,island,target_member_id,bank_amount) values(g.id,g.round,m.id,p_request_id,kind,isle,target,amount);
 end if;
 elsif p_operation='claim_host' then
 if exists(select 1 from heist_private.members where room_id=r.id and user_id=r.host_user_id and active and last_seen_at>clock_timestamp()-interval '30 seconds') then raise exception 'host_still_active';end if;
 -- The claimant's request is evidence of its presence; refresh before electing.
 update heist_private.members set last_seen_at=clock_timestamp() where id=m.id;
 select id into target from heist_private.members where room_id=r.id and active and not forfeited and last_seen_at>clock_timestamp()-interval '30 seconds' order by seat limit 1;
 if target is distinct from m.id then raise exception 'earlier_seat_available';end if;
 update heist_private.rooms set host_user_id=uid where id=r.id;
 elsif p_operation='leave_room' then
 if r.status='lobby' then
 update heist_private.members set active=false,ready=false where id=m.id;
 if r.host_user_id=uid then
 select user_id into newid from heist_private.members where room_id=r.id and active order by seat limit 1;
 if newid is not null then update heist_private.rooms set host_user_id=newid where id=r.id;else update heist_private.rooms set expires_at=clock_timestamp() where id=r.id;end if;
 end if;
 else
 update heist_private.members set forfeited=true where id=m.id;
 if r.status='playing' and (select count(*) from heist_private.members where room_id=r.id and active and not forfeited)<2 then
 update heist_private.rooms set status='abandoned' where id=r.id;
 update heist_private.matches set phase='abandoned',results='[]' where id=g.id;
 end if;
 end if;
 end if;
 perform heist_private.advance_room(r.id);
 res=jsonb_build_object('ok',true,'room_id',r.id,'member_id',m.id);
 exception when raise_exception or invalid_text_representation or numeric_value_out_of_range or unique_violation then
 get stacked diagnostics err=message_text;
 res=jsonb_build_object('ok',false,'error',case when sqlstate='22P02' then 'invalid_input' when sqlstate='23505' then 'already_locked' else err end);
 end;
 body=heist_private.publish_snapshot(r.id);
 -- Leaving is acknowledged without returning a room snapshot after membership loss.
 if p_operation<>'leave_room' then res=res||jsonb_build_object('snapshot',body);end if;
 end if;
 res=res||jsonb_build_object('server_time',clock_timestamp());
 insert into heist_private.request_receipts(user_id,request_id,request_hash,result) values(uid,p_request_id,fp,res);
 return res;
end$$;
revoke all on function heist_private.dispatch(text,uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function heist_private.dispatch(text,uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.get_snapshot(p_room uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare body jsonb;mid uuid;
begin
 if not heist_private.is_member(p_room) then raise exception using errcode='42501',message='Room unavailable';end if;
 select id into mid from heist_private.members where room_id=p_room and user_id=auth.uid() and active;
 select payload into body from public.room_snapshots where room_id=p_room;
 return jsonb_build_object('ok',true,'member_id',mid,'snapshot',body,'server_time',clock_timestamp());
end$$;
create function public.get_own_action(p_room uuid,p_match uuid,p_round int) returns jsonb language plpgsql security definer set search_path='' as $$
declare body jsonb;
begin
 if not heist_private.is_member(p_room) or not exists(select 1 from heist_private.matches where id=p_match and room_id=p_room) then raise exception using errcode='42501',message='Room unavailable';end if;
 select jsonb_build_object('kind',a.kind,'island',a.island,'target_member_id',a.target_member_id,'bank_amount',a.bank_amount,'request_id',a.request_id,'timed_out',a.timed_out) into body from heist_private.sealed_actions a join heist_private.members m on m.id=a.member_id where a.match_id=p_match and a.round=p_round and m.user_id=auth.uid() and m.active;
 return jsonb_build_object('action',body);
end$$;
revoke all on function public.get_snapshot(uuid),public.get_own_action(uuid,uuid,int) from public,anon,authenticated;
grant execute on function public.get_snapshot(uuid),public.get_own_action(uuid,uuid,int) to authenticated;
-- Internal helpers remain inaccessible, including direct round resolution.
revoke all on function heist_private.publish_snapshot(uuid),heist_private.finish_match(uuid),heist_private.advance_room(uuid),heist_private.take_rate(uuid,text) from public,anon,authenticated;

-- Only sanitized snapshots enter the Realtime publication.
alter publication supabase_realtime add table public.room_snapshots;

create function public.create_room(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('create_room',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.create_room(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.create_room(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.join_room(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('join_room',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.join_room(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.join_room(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.set_ready(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('set_ready',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.set_ready(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.set_ready(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.start_match(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('start_match',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.start_match(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.start_match(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.set_signal(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('set_signal',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.set_signal(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.set_signal(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.submit_action(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('submit_action',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.submit_action(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.submit_action(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.heartbeat_and_advance(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('heartbeat_and_advance',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.heartbeat_and_advance(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.heartbeat_and_advance(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.claim_host(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('claim_host',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.claim_host(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.claim_host(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.leave_room(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('leave_room',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.leave_room(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.leave_room(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.return_to_lobby(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('return_to_lobby',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.return_to_lobby(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.return_to_lobby(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.kick_member(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('kick_member',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.kick_member(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.kick_member(uuid,uuid,uuid,integer,jsonb) to authenticated;

create function public.lock_room(p_request_id uuid,p_room uuid default null,p_match uuid default null,p_round integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select heist_private.dispatch('lock_room',p_request_id,p_room,p_match,p_round,p_payload)$$;
revoke all on function public.lock_room(uuid,uuid,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.lock_room(uuid,uuid,uuid,integer,jsonb) to authenticated;

notify pgrst,'reload schema';

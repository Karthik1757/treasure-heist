-- Forward hardening after advisor and lifecycle review.
alter table heist_private.members add column joined_at timestamptz not null default now();
create index rooms_host_user on heist_private.rooms(host_user_id);
create index actions_member on heist_private.sealed_actions(match_id,member_id);
create index signals_member on heist_private.signals(match_id,member_id);
create or replace function heist_private.dispatch(p_operation text,p_request_id uuid,p_room uuid,p_match uuid,p_round integer,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
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
 else update heist_private.members set joined_at=clock_timestamp(),active=true,seat=seatno,nickname=nm,ready=false,forfeited=false,last_seen_at=clock_timestamp() where id=m.id returning * into m;end if;
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
 select id into target from heist_private.members where room_id=r.id and active and not forfeited and last_seen_at>clock_timestamp()-interval '30 seconds' order by joined_at,id limit 1;
 if target is distinct from m.id then raise exception 'earlier_seat_available';end if;
 update heist_private.rooms set host_user_id=uid where id=r.id;
 elsif p_operation='leave_room' then
 if r.status='lobby' then
 update heist_private.members set active=false,ready=false where id=m.id;
 if r.host_user_id=uid then
 select user_id into newid from heist_private.members where room_id=r.id and active order by joined_at,id limit 1;
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
create function heist_private.read_snapshot(p_room uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare body jsonb;mid uuid;
begin
 if not heist_private.is_member(p_room) then raise exception using errcode='42501',message='Room unavailable';end if;
 select id into mid from heist_private.members where room_id=p_room and user_id=auth.uid() and active;
 select payload into body from public.room_snapshots where room_id=p_room;
 return jsonb_build_object('ok',true,'member_id',mid,'snapshot',body,'server_time',clock_timestamp());
end$$;
create function heist_private.read_own_action(p_room uuid,p_match uuid,p_round int) returns jsonb language plpgsql security definer set search_path='' as $$
declare body jsonb;
begin
 if not heist_private.is_member(p_room) or not exists(select 1 from heist_private.matches where id=p_match and room_id=p_room) then raise exception using errcode='42501',message='Room unavailable';end if;
 select jsonb_build_object('kind',a.kind,'island',a.island,'target_member_id',a.target_member_id,'bank_amount',a.bank_amount,'request_id',a.request_id,'timed_out',a.timed_out) into body from heist_private.sealed_actions a join heist_private.members m on m.id=a.member_id where a.match_id=p_match and a.round=p_round and m.user_id=auth.uid() and m.active;
 return jsonb_build_object('action',body);
end$$;

revoke all on function heist_private.read_snapshot(uuid),heist_private.read_own_action(uuid,uuid,int) from public,anon,authenticated;
grant execute on function heist_private.read_snapshot(uuid),heist_private.read_own_action(uuid,uuid,int) to authenticated;
create or replace function public.get_snapshot(p_room uuid) returns jsonb language sql security invoker set search_path='' as $$select heist_private.read_snapshot(p_room)$$;
create or replace function public.get_own_action(p_room uuid,p_match uuid,p_round int) returns jsonb language sql security invoker set search_path='' as $$select heist_private.read_own_action(p_room,p_match,p_round)$$;
notify pgrst,'reload schema';

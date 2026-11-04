
alter table heist_private.sealed_actions add constraint defend_amount_required check(kind<>'defend' or bank_amount is not null);
create function heist_private.resolve_round(p_match uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare g heist_private.matches; r heist_private.rooms; ev text; a record; n int; take int; gain int; crowd int; bank int; ledger jsonb='[]'; before_scores jsonb; draws jsonb; priority uuid[];
begin
 select * into g from heist_private.matches where id=p_match;
 if not found then raise exception 'Unknown match';end if;
 select * into r from heist_private.rooms where id=g.room_id for update;
 select * into g from heist_private.matches where id=p_match for update;
 if (select resolved from heist_private.rounds where match_id=p_match and number=g.round) then
 return (select reveal from heist_private.rounds where match_id=p_match and number=g.round);end if;
 if g.phase<>'plan' then raise exception 'Wrong phase';end if;
 if clock_timestamp()<g.deadline and (select count(*) from heist_private.sealed_actions where match_id=p_match and round=g.round)<>(select count(*) from heist_private.scores where match_id=p_match) then raise exception 'Round not ready';end if;
 insert into heist_private.sealed_actions(match_id,round,member_id,request_id,kind,bank_amount,timed_out)
 select p_match,g.round,s.member_id,gen_random_uuid(),'defend',least(4,s.purse),true from heist_private.scores s where s.match_id=p_match
 on conflict(match_id,round,member_id) do nothing;
 select event into ev from heist_private.rounds where match_id=p_match and number=g.round;
 select jsonb_object_agg(member_id::text,purse) into before_scores from heist_private.scores where match_id=p_match;
 select random_draws into draws from heist_private.private_match_data where match_id=p_match;
 priority=g.priority_order;n=array_length(priority,1);
 for a in select * from heist_private.sealed_actions where match_id=p_match and round=g.round and kind='defend' loop
 if a.bank_amount>(before_scores->>a.member_id::text)::int then raise exception 'Unaffordable bank';end if;
 bank=a.bank_amount;gain=case when ev='royal_bounty' then 2 else 1 end;
 update heist_private.scores set purse=purse-bank,vault=vault+bank+gain where match_id=p_match and member_id=a.member_id;
 ledger=ledger||jsonb_build_array(jsonb_build_object('member_id',a.member_id,'kind','defend','banked',bank,'bonus',gain));
 end loop;
 -- Track only original balances; incoming proceeds cannot be stolen again.
 for a in select x.* from heist_private.sealed_actions x where match_id=p_match and round=g.round and kind='steal'
 order by mod(array_position(priority,x.member_id)-1-(g.round-1)%n+n,n) loop
 take=0;
 if not exists(select 1 from heist_private.sealed_actions where match_id=p_match and round=g.round and member_id=a.target_member_id and kind='defend') then
 take=least(case when ev='low_tide' then 2 else 3 end,(before_scores->>a.target_member_id::text)::int);
 before_scores=jsonb_set(before_scores,array[a.target_member_id::text],to_jsonb((before_scores->>a.target_member_id::text)::int-take));
 update heist_private.scores set purse=purse-take where match_id=p_match and member_id=a.target_member_id;
 update heist_private.scores set purse=purse+take where match_id=p_match and member_id=a.member_id;
 end if;
 ledger=ledger||jsonb_build_array(jsonb_build_object('member_id',a.member_id,'kind','steal','target',a.target_member_id,'gold',take));
 end loop;
 for a in select * from heist_private.sealed_actions where match_id=p_match and round=g.round and kind in('explore','bluff') loop
 if a.kind='bluff' then
 gain=case when exists(select 1 from heist_private.sealed_actions where match_id=p_match and round=g.round and kind='steal' and target_member_id=a.member_id) then -2 else 4 end;
 else
 gain=(draws->g.round::text->>a.member_id::text)::int;
 if gain is null or gain not in(0,1) then raise exception 'Missing random draw';end if;
 gain=case a.island when 0 then 3 when 1 then 2+4*gain when 2 then 8*gain when 3 then 1+6*gain when 4 then 3+2*gain end;
 gain=gain+case when ev='trade_winds' then 1 when ev='emerald_bloom' and a.island=1 then 2 when ev='moonrise' and a.island=4 then 2 else 0 end;
 select count(*)-1 into crowd from heist_private.sealed_actions where match_id=p_match and round=g.round and kind='explore' and island=a.island;
 gain=greatest(0,gain-crowd);
 end if;
 select greatest(gain,-purse) into gain from heist_private.scores where match_id=p_match and member_id=a.member_id;
 update heist_private.scores set purse=purse+gain where match_id=p_match and member_id=a.member_id;
 ledger=ledger||jsonb_build_array(jsonb_build_object('member_id',a.member_id,'kind',a.kind,'gold',gain));
 end loop;
 update heist_private.rounds set resolved=true,reveal=ledger where match_id=p_match and number=g.round;
 update heist_private.matches set phase='reveal',deadline=clock_timestamp()+interval '8 seconds' where id=p_match;
 update heist_private.rooms set revision=revision+1 where id=g.room_id;
 return ledger;
end$$;
revoke all on function heist_private.resolve_round(uuid) from public,anon,authenticated;

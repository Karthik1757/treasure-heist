-- Isolated audit fixtures only. No existing room or production function is changed.
-- Controlled deadlines here are NOT evidence of production timer acceptance.
create temporary table audit_race_fixtures(case_name text,room uuid,match uuid,n integer);
do $$
declare u uuid[]=array['eae40f24-0dbf-450f-91ce-fad2679473ea','fd2c6f9c-f689-48b4-8750-17b44503722b','a88a69da-6862-4a7a-b6f7-6981df7b267c','cbad19c9-74c0-40dc-8b6e-e7845b596fb0','7550ded9-9dde-4bb4-b8d7-2fc8e1cd86bd','cf14d6af-1bc7-4f75-8168-837ad4ec033f']::uuid[];
 name text;r uuid;g uuid;m uuid;ids uuid[];n int;i int;j int;rr int;ph text;draws jsonb;rd jsonb;
begin
foreach name in array array['identical','conflict','competing','action_timeout','expiry','reveal_next','final_results','six_final'] loop
 n=case when name='six_final' then 6 else 2 end;ids='{}';
 insert into heist_private.rooms(code,host_user_id,status,entry_locked) values(translate(upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),'01','GH'),u[1],'playing',true) returning id into r;
 for i in 1..n loop
 insert into heist_private.members(room_id,user_id,nickname,seat,ready) values(r,u[i],'AuditSeat'||i,i-1,true) returning id into m;ids=array_append(ids,m);
 end loop;
 ph=case when name in ('reveal_next','final_results') then 'reveal' else 'plan' end;rr=case when name='final_results' then 5 else 1 end;
 insert into heist_private.matches(room_id,match_no,round,phase,deadline,priority_order) values(r,1,rr,ph,clock_timestamp()+interval '1 hour',ids) returning id into g;
 insert into heist_private.scores(match_id,member_id) select g,unnest(ids);
 draws='{}';for j in 1..5 loop
 insert into heist_private.rounds(match_id,number,event,resolved,reveal) values(g,j,'trade_winds',ph='reveal' and j<=rr,case when ph='reveal' and j<=rr then '[]'::jsonb else null end);
 rd='{}';foreach m in array ids loop rd=rd||jsonb_build_object(m::text,0);end loop;draws=draws||jsonb_build_object(j::text,rd);
 end loop;
 insert into heist_private.private_match_data(match_id,event_order,random_draws) values(g,'["trade_winds","trade_winds","trade_winds","trade_winds","trade_winds"]',draws);
 perform heist_private.publish_snapshot(r);
 insert into audit_race_fixtures values(name,r,g,n);
end loop;
end$$;
select * from audit_race_fixtures;

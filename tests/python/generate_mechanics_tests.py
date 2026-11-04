from pathlib import Path
import json
base=Path('/workspace/scratch/d9dbf2caf91a/stage1')
header="""begin;
create temporary table checks(name text primary key,passed boolean);
create function pg_temp.check_it(n text,v boolean) returns void language plpgsql as $$begin if v is not true then raise exception 'FAIL: %',n;end if;insert into checks values(n,true);end$$;
create function pg_temp.scenario(n text,ev text,acts jsonb,purses jsonb,bits jsonb,expected jsonb) returns void language plpgsql as $$
declare us uuid[];ms uuid[]='{}';r uuid;g uuid;m uuid;i int;a jsonb;draws jsonb='{}';actual jsonb;outcome jsonb;
begin
select array_agg(gen_random_uuid()) into us from generate_series(1,jsonb_array_length(acts));
insert into auth.users(id,is_anonymous) select x,true from unnest(us)x;
insert into heist_private.rooms(code,host_user_id,status) values(upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),us[1],'playing') returning id into r;
for i in 1..array_length(us,1) loop
insert into heist_private.members(room_id,user_id,nickname,seat) values(r,us[i],'Test'||i,i-1) returning id into m;ms=array_append(ms,m);
end loop;
insert into heist_private.matches(room_id,match_no,phase,deadline,priority_order) values(r,1,'plan',clock_timestamp()-interval '1 second',ms) returning id into g;
insert into heist_private.rounds(match_id,number,event) values(g,1,ev);
for i in 1..array_length(us,1) loop
insert into heist_private.scores(match_id,member_id,purse) values(g,ms[i],(purses->>(i-1))::int);
end loop;
for i in 1..array_length(us,1) loop
a=acts->(i-1);
insert into heist_private.sealed_actions(match_id,round,member_id,request_id,kind,island,target_member_id,bank_amount) values(g,1,ms[i],gen_random_uuid(),a->>'kind',(a->>'island')::int,case when a?'target' then ms[(a->>'target')::int] else null end,(a->>'bank_amount')::smallint);
draws=draws||jsonb_build_object(ms[i]::text,(bits->>(i-1))::int);
end loop;
insert into heist_private.private_match_data(match_id,event_order,random_draws) values(g,'[]',jsonb_build_object('1',draws));
outcome=heist_private.resolve_round(g);
select jsonb_agg(jsonb_build_array(s.purse,s.vault) order by array_position(ms,s.member_id)) into actual from heist_private.scores s where match_id=g;
if actual<>expected then raise exception 'FAIL %: actual %, expected %',n,actual,expected;end if;
perform pg_temp.check_it(n,true);
perform heist_private.resolve_round(g);
select jsonb_agg(jsonb_build_array(s.purse,s.vault) order by array_position(ms,s.member_id)) into actual from heist_private.scores s where match_id=g;
perform pg_temp.check_it(n||' exactly once',actual=expected);
end$$;
"""
# Room code must avoid 0/1; fixture UUID-derived codes use replacements.
header=header.replace("upper(substr(replace(gen_random_uuid()::text,'-',''),1,8))","translate(upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),'01','YZ')")
lines=[header]
def case(name,event,actions,purses,bits,expected):
 vals=[name,event]+[json.dumps(x,separators=(',',':')) for x in [actions,purses,bits,expected]]
 lines.append('select pg_temp.scenario('+','.join("'"+v.replace("'","''")+"'" for v in vals)+');\n')
for ev in ['trade_winds','emerald_bloom','low_tide','royal_bounty','moonrise']:
 for island in range(5):
  for bit in range(2):
   gain=[3,2+4*bit,8*bit,1+6*bit,3+2*bit][island]
   gain+=1 if ev=='trade_winds' else 2 if (ev=='emerald_bloom' and island==1) or (ev=='moonrise' and island==4) else 0
   case(f'{ev} island {island} roll {bit}',ev,[{'kind':'explore','island':island},{'kind':'defend','bank_amount':0}],[6,6],[bit,0],[[6+gain,0],[6,2 if ev=='royal_bounty' else 1]])
for ev in ['low_tide','royal_bounty']:
 for bank in range(5):
  case(f'bank {bank} {ev}',ev,[{'kind':'defend','bank_amount':bank},{'kind':'steal','target':1}],[6,6],[0,0],[[6-bank,bank+(2 if ev=='royal_bounty' else 1)],[6,0]])
for n in range(2,7):
 case(f'crowding {n} explorers','low_tide',[{'kind':'explore','island':0}]*n,[6]*n,[0]*n,[[6+max(0,3-(n-1)),0]]*n)
case('two raiders split depleted purse','moonrise',[{'kind':'bluff'},{'kind':'steal','target':1},{'kind':'steal','target':1}],[4,6,6],[0,0,0],[[0,0],[9,0],[7,0]])
case('low tide caps each raid at 2','low_tide',[{'kind':'bluff'},{'kind':'steal','target':1},{'kind':'steal','target':1}],[6,6,6],[0,0,0],[[0,0],[8,0],[8,0]])
case('newly stolen proceeds cannot be stolen again','moonrise',[{'kind':'steal','target':2},{'kind':'steal','target':3},{'kind':'steal','target':1}],[0,6,6],[0,0,0],[[3,0],[6,0],[3,0]])
case('untargeted bluff earns 4','low_tide',[{'kind':'bluff'},{'kind':'defend','bank_amount':4}],[6,6],[0,0],[[10,0],[2,5]])
case('empty purse bluff targeted still floors to zero','low_tide',[{'kind':'bluff'},{'kind':'steal','target':1}],[0,6],[0,0],[[0,0],[6,0]])
lines.append('select count(*) as passed,jsonb_agg(name order by name) as checks from checks;\nrollback;\n')
(base/'mechanics_tests.sql').write_text(''.join(lines))
print('Generated',len(lines)-2,'mechanics scenarios with two assertions each.')

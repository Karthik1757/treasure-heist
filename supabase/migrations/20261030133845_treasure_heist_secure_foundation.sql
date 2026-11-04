
create schema heist_private;
revoke all on schema heist_private from public,anon,authenticated;
create table heist_private.rooms(
 id uuid primary key default gen_random_uuid(), code text not null unique check(code ~ '^[A-Z2-9]{8}$'),
 host_user_id uuid not null references auth.users(id), status text not null default 'lobby' check(status in('lobby','playing','results','abandoned')),
 revision bigint not null default 0, expires_at timestamptz not null default now()+interval '24 hours');
create table heist_private.members(
 id uuid primary key default gen_random_uuid(), room_id uuid not null references heist_private.rooms on delete cascade,
 user_id uuid not null references auth.users(id), nickname text not null check(length(nickname) between 2 and 18),
 seat smallint not null check(seat between 0 and 5), ready boolean not null default false,
 last_seen_at timestamptz not null default now(), forfeited boolean not null default false,
 unique(room_id,user_id),unique(room_id,seat),unique(room_id,id));
create unique index members_name on heist_private.members(room_id,lower(nickname));
create index members_user on heist_private.members(user_id,room_id);
create table heist_private.matches(
 id uuid primary key default gen_random_uuid(),room_id uuid not null references heist_private.rooms on delete cascade,
 match_no int not null check(match_no>0), round int not null default 1 check(round between 1 and 5),
 phase text not null check(phase in('signal','plan','reveal','results','abandoned')), deadline timestamptz not null,
 priority_order uuid[] not null, rules_version text not null default '1.2',unique(room_id,match_no),unique(room_id,id));
create table heist_private.scores(
 match_id uuid not null references heist_private.matches on delete cascade, member_id uuid not null references heist_private.members,
 purse int not null default 6 check(purse>=0),vault int not null default 0 check(vault>=0),primary key(match_id,member_id));
create table heist_private.rounds(
 match_id uuid not null references heist_private.matches on delete cascade,number int not null check(number between 1 and 5),
 event text not null check(event in('trade_winds','emerald_bloom','low_tide','royal_bounty','moonrise')),
 resolved boolean not null default false,reveal jsonb,primary key(match_id,number));
create table heist_private.signals(
 match_id uuid not null,round int not null,member_id uuid not null,
 claim text not null check(claim in('guarding','hunting')),primary key(match_id,round,member_id),
 foreign key(match_id,round) references heist_private.rounds on delete cascade,
 foreign key(match_id,member_id) references heist_private.scores);
create table heist_private.sealed_actions(
 match_id uuid not null,round int not null,member_id uuid not null,request_id uuid not null,
 kind text not null check(kind in('explore','steal','defend','bluff')),
 island int check(island between 0 and 4),target_member_id uuid,bank_amount smallint,
 accepted_at timestamptz not null default now(),timed_out boolean not null default false,
 primary key(match_id,round,member_id),unique(member_id,request_id),
 foreign key(match_id,round) references heist_private.rounds on delete cascade,
 foreign key(match_id,member_id) references heist_private.scores,
 foreign key(match_id,target_member_id) references heist_private.scores,
 check(target_member_id is distinct from member_id),
 check((kind='explore' and island is not null and target_member_id is null and bank_amount is null)
 or(kind='steal' and island is null and target_member_id is not null and bank_amount is null)
 or(kind='defend' and island is null and target_member_id is null and bank_amount between 0 and 4)
 or(kind='bluff' and island is null and target_member_id is null and bank_amount is null)));
create table heist_private.private_match_data(match_id uuid primary key references heist_private.matches on delete cascade,event_order jsonb not null,random_draws jsonb not null);
create table heist_private.request_receipts(user_id uuid not null references auth.users,request_id uuid not null,request_hash text not null,result jsonb not null,created_at timestamptz not null default now(),primary key(user_id,request_id));
create table heist_private.rate_buckets(scope_hash text not null,window_start timestamptz not null,operation text not null,count int not null check(count>=0),primary key(scope_hash,window_start,operation));
create table public.room_snapshots(room_id uuid primary key references heist_private.rooms on delete cascade,revision bigint not null,payload jsonb not null,updated_at timestamptz not null default now());
alter table public.room_snapshots enable row level security;
revoke all on public.room_snapshots from public,anon,authenticated;
grant select on public.room_snapshots to authenticated;
create function heist_private.is_member(p_room uuid) returns boolean language sql stable security definer set search_path=''
as $$ select auth.uid() is not null and exists(select 1 from heist_private.members m join heist_private.rooms r on r.id=m.room_id where m.room_id=p_room and m.user_id=auth.uid() and r.expires_at>now()) $$;
revoke all on function heist_private.is_member(uuid) from public,anon;
grant usage on schema heist_private to authenticated;
grant execute on function heist_private.is_member(uuid) to authenticated;
create policy room_members_read on public.room_snapshots for select to authenticated using(heist_private.is_member(room_id));
do $$declare t record;begin for t in select tablename from pg_tables where schemaname='heist_private' loop execute format('alter table heist_private.%I enable row level security',t.tablename);execute format('revoke all on heist_private.%I from public,anon,authenticated',t.tablename);end loop;end$$;
alter default privileges in schema heist_private revoke execute on functions from public;
alter default privileges in schema heist_private revoke all on tables from anon,authenticated;

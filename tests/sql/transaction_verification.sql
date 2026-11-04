begin;
create temporary table verification(name text,passed boolean);
do $$
declare uid uuid='eae40f24-0dbf-450f-91ce-fad2679473ea';req uuid=gen_random_uuid();a jsonb;
 rooms_before bigint;receipts_before bigint;snapshots_before bigint;rates_before jsonb;rates_after jsonb;
begin
 select count(*) into rooms_before from heist_private.rooms;
 select count(*) into receipts_before from heist_private.request_receipts where user_id=uid;
 select count(*) into snapshots_before from public.room_snapshots;
 select coalesce(jsonb_agg(to_jsonb(t) order by window_start,operation),'[]') into rates_before from heist_private.rate_buckets t where scope_hash=encode(extensions.digest(uid::text,'sha256'),'hex');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'role','authenticated')::text,true);
 begin
  a=public.create_room(req,null,null,null,'{"nickname":"RollbackAudit"}');
  if not (a->>'ok')::boolean then raise exception using errcode='22000',message='fixture create failed';end if;
  raise exception using errcode='P1234',message='audit rollback injection';
 exception when sqlstate 'P1234' then null;
 end;
 select coalesce(jsonb_agg(to_jsonb(t) order by window_start,operation),'[]') into rates_after from heist_private.rate_buckets t where scope_hash=encode(extensions.digest(uid::text,'sha256'),'hex');
 insert into verification values
 ('caller transaction rollback removes created room',(select count(*)=rooms_before from heist_private.rooms)),
 ('rollback removes request receipt',(select count(*)=receipts_before from heist_private.request_receipts where user_id=uid) and not exists(select 1 from heist_private.request_receipts where user_id=uid and request_id=req)),
 ('rollback removes published snapshot',(select count(*)=snapshots_before from public.room_snapshots)),
 ('rollback restores rate counters',rates_before=rates_after);
end$$;
insert into verification values
('all game tables RLS enabled',not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and (n.nspname='heist_private' or n.nspname='public' and c.relname='room_snapshots') and not c.relrowsecurity)),
('private client table grants absent',not exists(select 1 from information_schema.role_table_grants where table_schema='heist_private' and grantee in ('anon','authenticated','PUBLIC'))),
('private resolver client execution denied',not has_function_privilege('authenticated','heist_private.resolve_round(uuid)','EXECUTE') and not has_function_privilege('anon','heist_private.resolve_round(uuid)','EXECUTE')),
('snapshot client write denied',not has_table_privilege('authenticated','public.room_snapshots','INSERT') and not has_table_privilege('authenticated','public.room_snapshots','UPDATE') and not has_table_privilege('authenticated','public.room_snapshots','DELETE')),
('public functions are invoker',not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)),
('snapshot-only game publication',(select count(*)=1 and bool_and(schemaname='public' and tablename='room_snapshots') from pg_publication_tables where pubname='supabase_realtime'));
select count(*) filter(where passed) as passed,count(*) filter(where not passed) as failed,jsonb_agg(to_jsonb(verification)) as checks from verification;
rollback;

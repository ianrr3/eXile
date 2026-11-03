-- =====================================================================
-- eXile Community (RF Online Next) - Supabase schema, RLS and RPCs
-- Run in the SQL editor of your EXISTING Supabase project.
-- Inspect your current tables first. The file is safe to re-run.
-- Untested against a live database: run in a staging branch first.
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- enums ----------
do $$ begin create type app_role as enum ('member','officer','guild_leader','super_admin'); exception when duplicate_object then null; end $$;
do $$ begin create type event_type as enum ('world_boss','guild_boss','raid','pvp','mining_war','faction_war','special'); exception when duplicate_object then null; end $$;
do $$ begin create type event_status as enum ('upcoming','completed','cancelled'); exception when duplicate_object then null; end $$;
do $$ begin create type attendance_status as enum ('present','absent','excused'); exception when duplicate_object then null; end $$;
do $$ begin create type item_rarity as enum ('common','rare','epic','legendary'); exception when duplicate_object then null; end $$;
do $$ begin create type claim_period as enum ('draft','open','closed'); exception when duplicate_object then null; end $$;
do $$ begin create type claim_status as enum ('pending','awarded','not_selected','withdrawn'); exception when duplicate_object then null; end $$;
do $$ begin create type passdown_status as enum ('available','reserved','pending_transfer','transferred'); exception when duplicate_object then null; end $$;
do $$ begin create type dist_type as enum ('guild_loot','pass_down'); exception when duplicate_object then null; end $$;

-- ---------- core ----------
create table if not exists guilds(
  id uuid primary key default gen_random_uuid(),
  slug text unique not null, name text not null, description text);
insert into guilds(slug,name,description) values
  ('exile','eXile','Main Guild'),('sakalam','Sakalam','Secondary Guild')
on conflict (slug) do nothing;

create table if not exists profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now());
alter table profiles add column if not exists display_name text;
alter table profiles add column if not exists avatar_url text;
alter table profiles add column if not exists timezone text not null default 'UTC';
alter table profiles add column if not exists role app_role not null default 'member';
alter table profiles add column if not exists guild_id uuid references guilds(id);

create table if not exists members(
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references profiles(id) on delete set null,  -- one account, one character
  guild_id uuid not null references guilds(id),
  character_name text not null unique,
  avatar_url text,
  level int not null default 1 check (level between 1 and 99),
  cp bigint not null default 0 check (cp >= 0),
  class text check (class in ('Demolisher','Technician','Dreadnaught','Phantom','Arbiter','Enforcer','Psypher','Punisher')),
  guild_rank text not null default 'Member',
  contribution int not null default 0,
  joined_at date not null default current_date,
  created_at timestamptz not null default now());
create index if not exists members_guild_idx on members(guild_id);

-- ---------- helper functions ----------
create or replace function public.is_super() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid() and role='super_admin') $$;
create or replace function public.is_any_officer() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid() and role in ('officer','guild_leader','super_admin')) $$;
create or replace function public.is_officer_of(g uuid) returns boolean language sql stable security definer set search_path=public as
$$ select public.is_super() or exists(select 1 from profiles where id=auth.uid() and guild_id=g and role in ('officer','guild_leader')) $$;
create or replace function public.is_leader_of(g uuid) returns boolean language sql stable security definer set search_path=public as
$$ select public.is_super() or exists(select 1 from profiles where id=auth.uid() and guild_id=g and role='guild_leader') $$;
create or replace function public.my_member() returns uuid language sql stable security definer set search_path=public as
$$ select id from members where user_id=auth.uid() $$;
create or replace function public.my_guild() returns uuid language sql stable security definer set search_path=public as
$$ select guild_id from members where user_id=auth.uid() $$;
create or replace function public.member_guild(m uuid) returns uuid language sql stable security definer set search_path=public as
$$ select guild_id from members where id=m $$;

-- new auth user -> profile
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as
$$ begin insert into profiles(id,display_name) values(new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email,'@',1))) on conflict do nothing; return new; end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ---------- community: announcements, events, attendance ----------
create table if not exists announcements(
  id uuid primary key default gen_random_uuid(),
  guild_id uuid references guilds(id),               -- null = community-wide
  title text not null, content text not null,
  author_id uuid default auth.uid(),
  priority smallint not null default 0, pinned boolean not null default false,
  published_at timestamptz not null default now());

create table if not exists events(
  id uuid primary key default gen_random_uuid(),
  guild_id uuid references guilds(id),               -- null = shared by both guilds
  name text not null, event_type event_type not null,
  starts_at timestamptz not null,                    -- stored in UTC, shown in each viewer's zone
  description text, status event_status not null default 'upcoming',
  created_by uuid default auth.uid(), created_at timestamptz not null default now());

create table if not exists event_participants(      -- confirmed roster
  event_id uuid not null references events(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  confirmed_by uuid default auth.uid(),
  primary key(event_id,member_id));

create table if not exists attendance(
  event_id uuid not null references events(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  status attendance_status not null,
  marked_by uuid default auth.uid(), marked_at timestamptz not null default now(),
  primary key(event_id,member_id));

-- ---------- rankings ----------
create table if not exists cp_history(
  id bigserial primary key,
  member_id uuid not null references members(id) on delete cascade,
  guild_id uuid not null references guilds(id),
  cp bigint not null, previous_cp bigint,
  changed_by uuid, changed_at timestamptz not null default now());
create index if not exists cp_history_member_idx on cp_history(member_id, changed_at desc);

create or replace function public.log_cp() returns trigger language plpgsql security definer set search_path=public as
$$ begin
  if tg_op='INSERT' or new.cp is distinct from old.cp then
    insert into cp_history(member_id,guild_id,cp,previous_cp,changed_by)
    values(new.id,new.guild_id,new.cp,case when tg_op='UPDATE' then old.cp end,auth.uid());
  end if; return new; end $$;
drop trigger if exists trg_log_cp on members;
create trigger trg_log_cp after insert or update of cp on members for each row execute function public.log_cp();

-- ---------- loot ----------
create table if not exists loot_events(
  id uuid primary key default gen_random_uuid(),
  guild_id uuid not null references guilds(id),
  source_event_id uuid references events(id) on delete set null,
  name text not null, event_date timestamptz not null default now(),
  claim_status claim_period not null default 'draft',
  created_by uuid default auth.uid(), created_at timestamptz not null default now());

-- One row per physical item (quantity 3 = three rows) so each can be awarded once.
create table if not exists loot_items(
  id uuid primary key default gen_random_uuid(),
  loot_event_id uuid not null references loot_events(id) on delete cascade,
  guild_id uuid not null references guilds(id),
  name text not null, image_url text,
  rarity item_rarity not null default 'rare', item_type text,
  enhancement int not null default 0 check (enhancement >= 0), notes text,
  status text not null default 'available' check (status in ('available','awarded')),
  created_by uuid default auth.uid(), created_at timestamptz not null default now());

create table if not exists loot_event_participants(
  loot_event_id uuid not null references loot_events(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  guild_id uuid not null references guilds(id),
  confirmed_by uuid default auth.uid(),
  primary key(loot_event_id,member_id));

create table if not exists loot_claims(
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references loot_items(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  guild_id uuid not null references guilds(id),
  status claim_status not null default 'pending',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(item_id,member_id));

create table if not exists passdown_items(
  id uuid primary key default gen_random_uuid(),
  guild_id uuid not null references guilds(id),
  owner_member_id uuid not null references members(id) on delete cascade,
  name text not null, image_url text, rarity item_rarity not null default 'rare',
  item_type text, enhancement int not null default 0 check (enhancement >= 0), notes text,
  status passdown_status not null default 'available',
  created_at timestamptz not null default now());

create table if not exists passdown_interests(
  id uuid primary key default gen_random_uuid(),
  passdown_id uuid not null references passdown_items(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(passdown_id,member_id));

-- Permanent records. Written only by confirm_distribution(); never updated or deleted.
create table if not exists loot_distributions(
  id uuid primary key default gen_random_uuid(),
  guild_id uuid not null references guilds(id),
  distribution_type dist_type not null,
  loot_item_id uuid references loot_items(id) on delete restrict,
  passdown_id uuid references passdown_items(id) on delete restrict,
  recipient_id uuid not null references members(id) on delete restrict,
  previous_owner_id uuid references members(id) on delete restrict,
  recipient_cp bigint not null,
  approved_by uuid, approver_name text, notes text,
  distributed_at timestamptz not null default now(),
  check ((distribution_type='guild_loot' and loot_item_id is not null and passdown_id is null)
      or (distribution_type='pass_down' and passdown_id is not null and loot_item_id is null)));
create unique index if not exists one_dist_per_loot_item on loot_distributions(loot_item_id) where loot_item_id is not null;
create unique index if not exists one_dist_per_passdown on loot_distributions(passdown_id) where passdown_id is not null;

create table if not exists member_reward_history(
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members(id) on delete restrict,
  guild_id uuid not null references guilds(id),
  distribution_id uuid not null references loot_distributions(id) on delete restrict,
  reward_type dist_type not null,
  loot_item_id uuid references loot_items(id) on delete restrict,
  passdown_id uuid references passdown_items(id) on delete restrict,
  item_name text not null, item_image_url text, source text,
  previous_owner_id uuid, previous_owner_name text,
  cp_at_time bigint not null, approver_name text,
  received_at timestamptz not null default now());
create index if not exists reward_history_member_idx on member_reward_history(member_id, received_at desc);

create table if not exists audit_log(
  id bigserial primary key, guild_id uuid, actor_id uuid,
  action text not null, entity text, entity_id uuid, details jsonb,
  created_at timestamptz not null default now());

create or replace function public.block_changes() returns trigger language plpgsql as
$$ begin raise exception '% records are permanent and cannot be changed or deleted', tg_table_name; end $$;
do $$ declare t text; begin
  foreach t in array array['loot_distributions','member_reward_history','audit_log'] loop
    execute format('drop trigger if exists trg_block_%1$s on %1$s', t);
    execute format('create trigger trg_block_%1$s before update or delete on %1$s for each row execute function public.block_changes()', t);
  end loop; end $$;

create or replace function public.log_audit(g uuid, a text, e text, eid uuid, d jsonb default null) returns void
language sql security definer set search_path=public as
$$ insert into audit_log(guild_id,actor_id,action,entity,entity_id,details) values(g,auth.uid(),a,e,eid,d) $$;

-- ---------- RPCs (all permission checks happen here, server-side) ----------
create or replace function public.confirm_distribution(p_type dist_type, p_item uuid, p_recipient uuid, p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_guild uuid; v_name text; v_img text; v_status text; v_source text; v_owner uuid; v_owner_name text;
        v_loot_event uuid; r_guild uuid; r_cp bigint; v_dist uuid; v_appr text;
begin
  select guild_id, cp into r_guild, r_cp from members where id=p_recipient;
  if not found then raise exception 'Recipient not found'; end if;
  select coalesce(display_name,'Officer') into v_appr from profiles where id=auth.uid();

  if p_type='guild_loot' then
    select i.guild_id,i.name,i.image_url,i.status,i.loot_event_id,e.name
      into v_guild,v_name,v_img,v_status,v_loot_event,v_source
      from loot_items i join loot_events e on e.id=i.loot_event_id where i.id=p_item for update of i;
    if not found then raise exception 'Item not found'; end if;
    if not is_officer_of(v_guild) then raise exception 'Not authorized'; end if;
    if v_status<>'available' then raise exception 'Item has already been distributed'; end if;
    if r_guild<>v_guild then raise exception 'Recipient belongs to another guild'; end if;
    if not exists(select 1 from loot_event_participants where loot_event_id=v_loot_event and member_id=p_recipient)
      then raise exception 'Recipient is not a confirmed participant'; end if;
    if not exists(select 1 from loot_claims where item_id=p_item and member_id=p_recipient and status='pending')
      then raise exception 'Recipient has no pending claim on this item'; end if;
    insert into loot_distributions(guild_id,distribution_type,loot_item_id,recipient_id,recipient_cp,approved_by,approver_name,notes)
      values(v_guild,p_type,p_item,p_recipient,r_cp,auth.uid(),v_appr,p_notes) returning id into v_dist;
    update loot_items set status='awarded' where id=p_item;
    update loot_claims set status=case when member_id=p_recipient then 'awarded'::claim_status else 'not_selected'::claim_status end,
           updated_at=now() where item_id=p_item and status='pending';
    insert into member_reward_history(member_id,guild_id,distribution_id,reward_type,loot_item_id,item_name,item_image_url,source,cp_at_time,approver_name)
      values(p_recipient,v_guild,v_dist,p_type,p_item,v_name,v_img,v_source,r_cp,v_appr);
  else
    select p.guild_id,p.name,p.image_url,p.status::text,p.owner_member_id,m.character_name
      into v_guild,v_name,v_img,v_status,v_owner,v_owner_name
      from passdown_items p join members m on m.id=p.owner_member_id where p.id=p_item for update of p;
    if not found then raise exception 'Pass-down item not found'; end if;
    if not is_officer_of(v_guild) then raise exception 'Not authorized'; end if;
    if v_status='transferred' then raise exception 'Item has already been transferred'; end if;
    if r_guild<>v_guild then raise exception 'Recipient belongs to another guild'; end if;
    if p_recipient=v_owner then raise exception 'Owner cannot receive their own item'; end if;
    if not exists(select 1 from passdown_interests where passdown_id=p_item and member_id=p_recipient)
      then raise exception 'Recipient has not expressed interest'; end if;
    insert into loot_distributions(guild_id,distribution_type,passdown_id,recipient_id,previous_owner_id,recipient_cp,approved_by,approver_name,notes)
      values(v_guild,p_type,p_item,p_recipient,v_owner,r_cp,auth.uid(),v_appr,p_notes) returning id into v_dist;
    update passdown_items set status='transferred' where id=p_item;
    insert into member_reward_history(member_id,guild_id,distribution_id,reward_type,passdown_id,item_name,item_image_url,source,previous_owner_id,previous_owner_name,cp_at_time,approver_name)
      values(p_recipient,v_guild,v_dist,p_type,p_item,v_name,v_img,'Pass-down',v_owner,v_owner_name,r_cp,v_appr);
  end if;
  perform log_audit(v_guild,'distribution_confirmed',p_type::text,v_dist,
    jsonb_build_object('item',v_name,'recipient',p_recipient,'recipient_cp',r_cp,'notes',p_notes));
  return v_dist;
end $$;

create or replace function public.submit_claim(p_item uuid) returns void language plpgsql security definer set search_path=public as $$
declare m uuid:=my_member(); v loot_items%rowtype; ev loot_events%rowtype;
begin
  if m is null then raise exception 'You need a linked character to claim loot'; end if;
  select * into v from loot_items where id=p_item; if not found then raise exception 'Item not found'; end if;
  select * into ev from loot_events where id=v.loot_event_id;
  if ev.claim_status<>'open' then raise exception 'Claiming is not open for this event'; end if;
  if v.status<>'available' then raise exception 'Item is no longer available'; end if;
  if member_guild(m)<>v.guild_id then raise exception 'This item belongs to the other guild'; end if;
  if not exists(select 1 from loot_event_participants where loot_event_id=ev.id and member_id=m)
    then raise exception 'Only confirmed participants can claim this loot'; end if;
  insert into loot_claims(item_id,member_id,guild_id) values(p_item,m,v.guild_id)
  on conflict (item_id,member_id) do update set status='pending',updated_at=now() where loot_claims.status='withdrawn';
end $$;

create or replace function public.withdraw_claim(p_item uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  update loot_claims c set status='withdrawn',updated_at=now()
  from loot_items i join loot_events e on e.id=i.loot_event_id
  where c.item_id=p_item and i.id=p_item and c.member_id=my_member() and c.status='pending' and e.claim_status='open';
  if not found then raise exception 'Claim cannot be withdrawn (closed or already decided)'; end if;
end $$;

create or replace function public.import_participants(p_loot_event uuid, p_event uuid) returns int language plpgsql security definer set search_path=public as $$
declare g uuid; n int;
begin
  select guild_id into g from loot_events where id=p_loot_event;
  if g is null or not is_officer_of(g) then raise exception 'Not authorized'; end if;
  insert into loot_event_participants(loot_event_id,member_id,guild_id,confirmed_by)
    select p_loot_event,a.member_id,g,auth.uid() from attendance a join members m on m.id=a.member_id
    where a.event_id=p_event and a.status='present' and m.guild_id=g
  on conflict do nothing;
  get diagnostics n = row_count; return n;
end $$;

create or replace function public.transfer_member(p_member uuid, p_to uuid) returns void language plpgsql security definer set search_path=public as $$
declare g_old uuid;
begin
  if not is_super() then raise exception 'Only a Super Admin can transfer members'; end if;
  select guild_id into g_old from members where id=p_member; if g_old is null then raise exception 'Member not found'; end if;
  if g_old=p_to then return; end if;
  delete from passdown_items where owner_member_id=p_member and status in ('available','reserved');
  delete from passdown_interests where member_id=p_member;
  update loot_claims set status='withdrawn',updated_at=now() where member_id=p_member and status='pending';
  update members set guild_id=p_to where id=p_member;
  update profiles set guild_id=p_to where id=(select user_id from members where id=p_member);
  perform log_audit(p_to,'member_transferred','member',p_member,jsonb_build_object('from',g_old,'to',p_to));
end $$;

create or replace function public.set_user_role(p_user uuid, p_role app_role, p_guild uuid default null) returns void language plpgsql security definer set search_path=public as $$
begin
  if is_super() then
    update profiles set role=p_role, guild_id=coalesce(p_guild,guild_id) where id=p_user;
  elsif p_role in ('member','officer') and exists(select 1 from profiles me, profiles t
        where me.id=auth.uid() and me.role='guild_leader' and t.id=p_user and t.guild_id=me.guild_id) then
    update profiles set role=p_role where id=p_user;
  else raise exception 'Not authorized'; end if;
  perform log_audit(p_guild,'role_changed','profile',p_user,jsonb_build_object('role',p_role));
end $$;

create or replace function public.link_member_to_user(p_member uuid, p_user uuid) returns void language plpgsql security definer set search_path=public as $$
declare g uuid:=member_guild(p_member);
begin
  if not is_leader_of(g) then raise exception 'Not authorized'; end if;
  update members set user_id=p_user where id=p_member;
  update profiles set guild_id=g where id=p_user;
  perform log_audit(g,'member_linked','member',p_member,jsonb_build_object('user',p_user));
end $$;

-- ---------- read views (public data only) ----------
create or replace view public.guild_stats as
  select g.id guild_id,g.slug,g.name,count(m.id) members,coalesce(max(m.cp),0) top_cp,
         coalesce(round(avg(m.cp)),0) avg_cp,coalesce(sum(m.cp),0) total_cp
  from guilds g left join members m on m.guild_id=g.id group by g.id;
create or replace view public.public_rankings as
  select m.id member_id,m.character_name,m.class,m.level,m.cp,g.slug guild_slug,g.name guild_name,
         rank() over (order by m.cp desc) community_rank,
         rank() over (partition by m.guild_id order by m.cp desc) guild_rank_pos,
         (select h.previous_cp from cp_history h where h.member_id=m.id and h.previous_cp is not null order by h.changed_at desc limit 1) previous_cp
  from members m join guilds g on g.id=m.guild_id;
create or replace view public.member_stats as
  select m.id member_id,m.guild_id,
    (select case when count(*) filter (where a.status in ('present','absent'))=0 then null
       else round(100.0*count(*) filter (where a.status='present')/count(*) filter (where a.status in ('present','absent'))) end
     from attendance a where a.member_id=m.id) attendance_pct,
    (select count(*) from member_reward_history r where r.member_id=m.id and r.reward_type='guild_loot') loot_received,
    (select count(*) from member_reward_history r where r.member_id=m.id and r.reward_type='pass_down') passdowns_received
  from members m;

-- ---------- privileges ----------
revoke insert,update,delete on all tables in schema public from anon;
revoke update on profiles from authenticated;
grant update (display_name,avatar_url,timezone) on profiles to authenticated;      -- role and guild only via RPC
revoke update on members from authenticated;
grant update (character_name,avatar_url,level,cp,class,guild_rank,contribution,joined_at) on members to authenticated;  -- guild only via transfer_member()
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant select on guilds, guild_stats, public_rankings, announcements to anon;
grant select on guild_stats, public_rankings, member_stats to authenticated;
grant execute on function public.is_super(), public.is_any_officer() to anon;

-- ---------- make re-runnable: drop this file's own policies first ----------
do $$ declare r record; begin
  for r in select tablename, policyname from pg_policies where schemaname='public' and policyname = any(array[
    'guilds_read','profiles_read','profiles_update_own','members_read','members_manage','ann_read','ann_manage',
    'events_read','events_manage','evp_read','evp_manage','att_read','att_manage','cp_read','lev_read','lev_manage',
    'li_read','li_insert','li_update','li_delete','lep_read','lep_manage','lc_read','pd_read','pd_insert_own',
    'pd_update_own','pd_delete_own','pd_officer','pdi_read','pdi_insert_own','pdi_delete_own','dist_read','rh_read','audit_read'])
  loop execute format('drop policy %I on public.%I', r.policyname, r.tablename); end loop;
end $$;

-- ---------- row level security ----------
do $$ declare t text; begin
  foreach t in array array['guilds','profiles','members','announcements','events','event_participants','attendance','cp_history',
    'loot_events','loot_items','loot_event_participants','loot_claims','passdown_items','passdown_interests',
    'loot_distributions','member_reward_history','audit_log'] loop
    execute format('alter table %I enable row level security', t);
  end loop; end $$;

create policy guilds_read on guilds for select to anon, authenticated using (true);

create policy profiles_read on profiles for select to authenticated
  using (id=auth.uid() or is_super() or (guild_id is not null and is_officer_of(guild_id)));
create policy profiles_update_own on profiles for update to authenticated using (id=auth.uid()) with check (id=auth.uid());

create policy members_read on members for select to authenticated using (true);
create policy members_manage on members for all to authenticated using (is_officer_of(guild_id)) with check (is_officer_of(guild_id));

create policy ann_read on announcements for select to anon, authenticated using (true);
create policy ann_manage on announcements for all to authenticated
  using ((guild_id is null and is_super()) or (guild_id is not null and is_officer_of(guild_id)))
  with check ((guild_id is null and is_super()) or (guild_id is not null and is_officer_of(guild_id)));

create policy events_read on events for select to authenticated using (true);
create policy events_manage on events for all to authenticated
  using ((guild_id is null and is_any_officer()) or (guild_id is not null and is_officer_of(guild_id)))
  with check ((guild_id is null and is_any_officer()) or (guild_id is not null and is_officer_of(guild_id)));

create policy evp_read on event_participants for select to authenticated using (true);
create policy evp_manage on event_participants for all to authenticated
  using (is_officer_of(member_guild(member_id))) with check (is_officer_of(member_guild(member_id)));

create policy att_read on attendance for select to authenticated
  using (member_id=my_member() or is_officer_of(member_guild(member_id)));
create policy att_manage on attendance for all to authenticated   -- members cannot mark themselves
  using (is_officer_of(member_guild(member_id))) with check (is_officer_of(member_guild(member_id)));

create policy cp_read on cp_history for select to authenticated using (true);

create policy lev_read on loot_events for select to authenticated using (true);
create policy lev_manage on loot_events for all to authenticated using (is_officer_of(guild_id)) with check (is_officer_of(guild_id));

create policy li_read on loot_items for select to authenticated using (true);
create policy li_insert on loot_items for insert to authenticated
  with check (is_officer_of(guild_id) and guild_id=(select guild_id from loot_events where id=loot_event_id));
create policy li_update on loot_items for update to authenticated using (is_officer_of(guild_id) and status='available') with check (is_officer_of(guild_id));
create policy li_delete on loot_items for delete to authenticated using (is_officer_of(guild_id) and status='available');

create policy lep_read on loot_event_participants for select to authenticated using (true);
create policy lep_manage on loot_event_participants for all to authenticated using (is_officer_of(guild_id)) with check (is_officer_of(guild_id));

create policy lc_read on loot_claims for select to authenticated using (member_id=my_member() or is_officer_of(guild_id));  -- writes: RPC only

create policy pd_read on passdown_items for select to authenticated using (true);
create policy pd_insert_own on passdown_items for insert to authenticated
  with check (owner_member_id=my_member() and guild_id=my_guild() and status='available');
create policy pd_update_own on passdown_items for update to authenticated
  using (owner_member_id=my_member() and status='available') with check (owner_member_id=my_member() and status='available');
create policy pd_delete_own on passdown_items for delete to authenticated using (owner_member_id=my_member() and status='available');
create policy pd_officer on passdown_items for all to authenticated using (is_officer_of(guild_id)) with check (is_officer_of(guild_id));

create policy pdi_read on passdown_interests for select to authenticated using (true);
create policy pdi_insert_own on passdown_interests for insert to authenticated
  with check (member_id=my_member() and exists(select 1 from passdown_items p where p.id=passdown_id
              and p.guild_id=my_guild() and p.owner_member_id<>my_member() and p.status='available'));
create policy pdi_delete_own on passdown_interests for delete to authenticated using (member_id=my_member());

create policy dist_read on loot_distributions for select to authenticated using (recipient_id=my_member() or is_officer_of(guild_id));
create policy rh_read on member_reward_history for select to authenticated using (member_id=my_member() or is_officer_of(guild_id));
create policy audit_read on audit_log for select to authenticated using (guild_id is not null and is_officer_of(guild_id) or is_super());

-- ---------- realtime ----------
do $$ declare t text; begin
  foreach t in array array['loot_items','loot_claims','passdown_items','passdown_interests','announcements','events','members'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t); exception when others then null; end;
  end loop; end $$;

-- ---------- first Super Admin (run once, with your own auth user id) ----------
-- update profiles set role='super_admin' where id='YOUR-AUTH-USER-UUID';

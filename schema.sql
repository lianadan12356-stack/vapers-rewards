-- VAPERS Rewards schema for Supabase/Postgres.
-- Run once in Supabase SQL Editor after creating the project.
-- Tables are never directly exposed to anon/authenticated clients. All access goes through RPCs.

create table if not exists public.store_settings (
  singleton boolean primary key default true check (singleton),
  store_name text not null default 'VAPERS',
  reward_label text not null default 'Free reward',
  stamps_required integer not null default 10 check (stamps_required between 2 and 50),
  updated_at timestamptz not null default now()
);

insert into public.store_settings(singleton, store_name, reward_label, stamps_required)
values (true, 'VAPERS', 'Free reward', 10)
on conflict (singleton) do nothing;

create table if not exists public.store_owners (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.loyalty_members (
  member_id uuid primary key default pg_catalog.gen_random_uuid(),
  card_token uuid not null unique default pg_catalog.gen_random_uuid(),
  member_code text not null unique,
  display_name text,
  active boolean not null default true,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.loyalty_events (
  event_id bigint generated always as identity primary key,
  member_id uuid not null references public.loyalty_members(member_id),
  event_type text not null check (event_type in ('stamp', 'redeem')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists loyalty_events_member_time_idx
  on public.loyalty_events(member_id, created_at desc);

-- Remove names from previously deleted cards while preserving their event history.
update public.loyalty_members set display_name = null where active = false;

alter table public.store_settings enable row level security;
alter table public.store_owners enable row level security;
alter table public.loyalty_members enable row level security;
alter table public.loyalty_events enable row level security;

revoke all on table public.store_settings, public.store_owners,
  public.loyalty_members, public.loyalty_events from anon, authenticated;

-- Read-only public lookup by unguessable card token. It returns only the current
-- card's display name, public member code, progress and configured reward label.
create or replace function public.get_card_status(p_card_token uuid)
returns table (
  store_name text,
  member_code text,
  display_name text,
  stamp_count integer,
  stamps_required integer,
  reward_ready boolean,
  reward_label text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
  v_member_code text;
  v_display_name text;
  v_store_name text;
  v_reward_label text;
  v_required integer;
  v_last_redeem bigint;
  v_count integer;
begin
  select m.member_id, m.member_code, m.display_name
    into v_member_id, v_member_code, v_display_name
    from public.loyalty_members as m
    where m.card_token = p_card_token and m.active = true;
  if not found then return; end if;

  select s.store_name, s.reward_label, s.stamps_required
    into v_store_name, v_reward_label, v_required
    from public.store_settings as s where s.singleton = true;
  select max(e.event_id) into v_last_redeem
    from public.loyalty_events as e
    where e.member_id = v_member_id and e.event_type = 'redeem';
  select count(*)::integer into v_count
    from public.loyalty_events as e
    where e.member_id = v_member_id
      and e.event_type = 'stamp'
      and e.event_id > coalesce(v_last_redeem, 0);

  return query select v_store_name, v_member_code, v_display_name,
    v_count, v_required, v_count >= v_required, v_reward_label;
end;
$$;

create or replace function public.owner_create_member(p_display_name text default null)
returns table (card_token uuid, member_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_token uuid;
  v_code text;
begin
  if auth.uid() is null or not exists (
    select 1 from public.store_owners as o where o.user_id = auth.uid()
  ) then raise exception 'Owner access required'; end if;
  if nullif(trim(p_display_name), '') is null then
    raise exception 'Customer name cannot be blank';
  end if;

  v_id := pg_catalog.gen_random_uuid();
  v_token := pg_catalog.gen_random_uuid();
  v_code := 'VP-' || upper(substr(replace(pg_catalog.gen_random_uuid()::text, '-', ''), 1, 8));
  insert into public.loyalty_members(member_id, card_token, member_code, display_name, created_by)
    values (v_id, v_token, v_code, nullif(trim(p_display_name), ''), auth.uid());
  return query select v_token, v_code;
end;
$$;

create or replace function public.owner_list_members()
returns table (
  card_token uuid,
  member_code text,
  display_name text,
  stamp_count integer,
  stamps_required integer,
  reward_ready boolean,
  active boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.store_owners as o where o.user_id = auth.uid()
  ) then raise exception 'Owner access required'; end if;

  return query
  select m.card_token, m.member_code, m.display_name,
    coalesce(progress.stamp_count, 0)::integer,
    s.stamps_required,
    coalesce(progress.stamp_count, 0) >= s.stamps_required,
    m.active, m.created_at
  from public.loyalty_members as m
  cross join public.store_settings as s
  left join lateral (
    select count(*)::integer as stamp_count
    from public.loyalty_events as e
    where e.member_id = m.member_id
      and e.event_type = 'stamp'
      and e.event_id > coalesce((
        select max(r.event_id) from public.loyalty_events as r
        where r.member_id = m.member_id and r.event_type = 'redeem'
      ), 0)
  ) as progress on true
  where s.singleton = true and m.active = true
  order by m.created_at desc;
end;
$$;

create or replace function public.owner_add_stamp(p_card_token uuid)
returns table (stamp_count integer, stamps_required integer, reward_ready boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
  v_count integer;
  v_required integer;
  v_last_redeem bigint;
begin
  if auth.uid() is null or not exists (
    select 1 from public.store_owners as o where o.user_id = auth.uid()
  ) then raise exception 'Owner access required'; end if;

  select m.member_id into v_member_id
    from public.loyalty_members as m
    where m.card_token = p_card_token and m.active = true
    for update;
  if not found then raise exception 'Card not found or inactive'; end if;

  select s.stamps_required into v_required
    from public.store_settings as s where s.singleton = true;
  select max(e.event_id) into v_last_redeem
    from public.loyalty_events as e
    where e.member_id = v_member_id and e.event_type = 'redeem';
  select count(*)::integer into v_count
    from public.loyalty_events as e
    where e.member_id = v_member_id
      and e.event_type = 'stamp'
      and e.event_id > coalesce(v_last_redeem, 0);
  if v_count >= v_required then raise exception 'Reward is ready to redeem before adding more stamps'; end if;

  insert into public.loyalty_events(member_id, event_type, created_by)
    values (v_member_id, 'stamp', auth.uid());
  v_count := v_count + 1;
  return query select v_count, v_required, v_count >= v_required;
end;
$$;

create or replace function public.owner_redeem_reward(p_card_token uuid)
returns table (stamp_count integer, stamps_required integer, reward_ready boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
  v_count integer;
  v_required integer;
  v_last_redeem bigint;
begin
  if auth.uid() is null or not exists (
    select 1 from public.store_owners as o where o.user_id = auth.uid()
  ) then raise exception 'Owner access required'; end if;

  select m.member_id into v_member_id
    from public.loyalty_members as m
    where m.card_token = p_card_token and m.active = true
    for update;
  if not found then raise exception 'Card not found or inactive'; end if;

  select s.stamps_required into v_required
    from public.store_settings as s where s.singleton = true;
  select max(e.event_id) into v_last_redeem
    from public.loyalty_events as e
    where e.member_id = v_member_id and e.event_type = 'redeem';
  select count(*)::integer into v_count
    from public.loyalty_events as e
    where e.member_id = v_member_id
      and e.event_type = 'stamp'
      and e.event_id > coalesce(v_last_redeem, 0);
  if v_count < v_required then raise exception 'Card has not earned the reward yet'; end if;

  insert into public.loyalty_events(member_id, event_type, created_by)
    values (v_member_id, 'redeem', auth.uid());
  return query select 0, v_required, false;
end;
$$;

create or replace function public.owner_update_member(p_card_token uuid, p_display_name text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_rows integer;
begin
  if auth.uid() is null or not exists (
    select 1 from public.store_owners as o where o.user_id = auth.uid()
  ) then raise exception 'Owner access required'; end if;
  if nullif(trim(p_display_name), '') is null then
    raise exception 'Customer name cannot be blank';
  end if;
  update public.loyalty_members
    set display_name = trim(p_display_name)
    where card_token = p_card_token and active = true;
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end;
$$;

create or replace function public.owner_deactivate_card(p_card_token uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_rows integer;
begin
  if auth.uid() is null or not exists (
    select 1 from public.store_owners as o where o.user_id = auth.uid()
  ) then raise exception 'Owner access required'; end if;
  update public.loyalty_members set active = false, display_name = null
    where card_token = p_card_token and active = true;
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end;
$$;

-- Functions are not callable by default roles unless explicitly granted.
revoke all on function public.get_card_status(uuid) from public;
revoke all on function public.owner_create_member(text) from public, anon;
revoke all on function public.owner_list_members() from public, anon;
revoke all on function public.owner_add_stamp(uuid) from public, anon;
revoke all on function public.owner_redeem_reward(uuid) from public, anon;
revoke all on function public.owner_deactivate_card(uuid) from public, anon;
revoke all on function public.owner_update_member(uuid, text) from public, anon;
grant execute on function public.get_card_status(uuid) to anon, authenticated;
grant execute on function public.owner_create_member(text) to authenticated;
grant execute on function public.owner_list_members() to authenticated;
grant execute on function public.owner_add_stamp(uuid) to authenticated;
grant execute on function public.owner_redeem_reward(uuid) to authenticated;
grant execute on function public.owner_deactivate_card(uuid) to authenticated;
grant execute on function public.owner_update_member(uuid, text) to authenticated;

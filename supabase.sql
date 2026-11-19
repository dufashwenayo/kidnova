-- KIDNOVA database setup. Run once in Supabase → SQL Editor. Safe to re-run.
-- Model: one shared workspace (all school records) + a member list with roles.
-- The first account that signs up becomes the Super Admin; after that only the
-- Super Admin can add users.

create table if not exists public.kn_members (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  full_name  text not null default '',
  role       text not null check (role in ('super_admin', 'admin')),
  created_at timestamptz not null default now()
);

create table if not exists public.kn_workspace (
  id         int primary key default 1 check (id = 1),
  data       jsonb not null,
  rev        bigint not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

alter table public.kn_members  enable row level security;
alter table public.kn_workspace enable row level security;

-- Helpers (security definer so policies can call them without recursion)
create or replace function public.kn_my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.kn_members where user_id = auth.uid()
$$;

create or replace function public.kn_has_super() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.kn_members where role = 'super_admin')
$$;

-- First login: the caller becomes Super Admin if none exists yet.
create or replace function public.kn_claim_super() returns text
language plpgsql security definer set search_path = public as $$
declare r text; u record;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  lock table public.kn_members in share row exclusive mode;
  select role into r from public.kn_members where user_id = auth.uid();
  if r is not null then return r; end if;
  if exists (select 1 from public.kn_members where role = 'super_admin') then return null; end if;
  select email, coalesce(raw_user_meta_data->>'full_name', '') as name into u from auth.users where id = auth.uid();
  insert into public.kn_members (user_id, email, full_name, role) values (auth.uid(), u.email, u.name, 'super_admin');
  return 'super_admin';
end $$;

-- Super Admin: give an existing account access (used after creating it).
create or replace function public.kn_add_member(p_email text, p_name text, p_role text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if public.kn_my_role() is distinct from 'super_admin' then raise exception 'Only the Super Admin can add users'; end if;
  if p_role not in ('super_admin', 'admin') then raise exception 'Invalid role'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'No account exists for %', p_email; end if;
  insert into public.kn_members (user_id, email, full_name, role)
  values (uid, lower(trim(p_email)), coalesce(p_name, ''), p_role)
  on conflict (user_id) do update set role = excluded.role, full_name = coalesce(nullif(excluded.full_name, ''), kn_members.full_name);
  return uid;
end $$;

-- Save with a revision check so two admins cannot silently overwrite each other.
create or replace function public.kn_save(p_data jsonb, p_rev bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare new_rev bigint;
begin
  if public.kn_my_role() is null then raise exception 'No access'; end if;
  if p_rev = 0 then
    insert into public.kn_workspace (id, data, rev, updated_by) values (1, p_data, 1, auth.uid())
    on conflict (id) do nothing returning rev into new_rev;
  else
    update public.kn_workspace set data = p_data, rev = rev + 1, updated_at = now(), updated_by = auth.uid()
    where id = 1 and rev = p_rev returning rev into new_rev;
  end if;
  if new_rev is null then raise exception 'KN_CONFLICT'; end if;
  return new_rev;
end $$;

revoke all on function public.kn_claim_super(), public.kn_add_member(text, text, text), public.kn_save(jsonb, bigint), public.kn_my_role() from public, anon;
grant execute on function public.kn_claim_super(), public.kn_add_member(text, text, text), public.kn_save(jsonb, bigint), public.kn_my_role() to authenticated;
grant execute on function public.kn_has_super() to anon, authenticated;

-- Policies
drop policy if exists kn_members_read   on public.kn_members;
drop policy if exists kn_members_update on public.kn_members;
drop policy if exists kn_members_delete on public.kn_members;
create policy kn_members_read   on public.kn_members for select to authenticated using (public.kn_my_role() is not null);
create policy kn_members_update on public.kn_members for update to authenticated using (public.kn_my_role() = 'super_admin') with check (public.kn_my_role() = 'super_admin');
create policy kn_members_delete on public.kn_members for delete to authenticated using (public.kn_my_role() = 'super_admin' and user_id <> auth.uid());

drop policy if exists kn_workspace_read on public.kn_workspace;
create policy kn_workspace_read on public.kn_workspace for select to authenticated using (public.kn_my_role() is not null);

grant select, update, delete on public.kn_members to authenticated;
grant select on public.kn_workspace to authenticated;

-- Make the API see the new functions immediately
notify pgrst, 'reload schema';

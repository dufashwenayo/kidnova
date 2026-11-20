-- KIDNOVA database setup (v2: one workspace per school, registration links).
-- Run in Supabase → SQL Editor. Safe to re-run; existing accounts and school records are kept.
--
-- Roles
--   super_admin : global. The first account to sign up claims it. Creates school
--                 registration links and can open every school.
--   director    : school level. Created when a school submits its registration
--                 link; the director email on the form becomes the login.
--   admin       : school level staff, added by the director or the Super Admin.

-- Upgrade from v1 (shared single workspace) without losing accounts.
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'kn_workspace' and column_name = 'id') then
    drop table public.kn_workspace cascade;
  end if;
end $$;
drop function if exists public.kn_add_member(text, text, text);
drop function if exists public.kn_save(jsonb, bigint);

create table if not exists public.kn_members (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  full_name  text not null default '',
  role       text not null,
  created_at timestamptz not null default now()
);
alter table public.kn_members add column if not exists school_id text;
alter table public.kn_members drop constraint if exists kn_members_role_check;
alter table public.kn_members drop constraint if exists kn_members_check;
alter table public.kn_members drop constraint if exists kn_members_scope_check;
delete from public.kn_members where role <> 'super_admin' and school_id is null;
alter table public.kn_members add constraint kn_members_role_check check (role in ('super_admin', 'director', 'admin', 'teacher'));
alter table public.kn_members add constraint kn_members_scope_check check ((role = 'super_admin') = (school_id is null));

create table if not exists public.kn_workspace (
  school_id   text primary key,
  school_name text not null,
  reg_number  text not null default '',
  data        jsonb not null,
  rev         bigint not null default 1,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

create table if not exists public.kn_invites (
  token      text primary key,
  note       text not null default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  used_at    timestamptz,
  school_id  text
);

alter table public.kn_members   enable row level security;
alter table public.kn_workspace enable row level security;
alter table public.kn_invites   enable row level security;

create or replace function public.kn_my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.kn_members where user_id = auth.uid()
$$;

create or replace function public.kn_my_school() returns text
language sql stable security definer set search_path = public as $$
  select school_id from public.kn_members where user_id = auth.uid()
$$;

create or replace function public.kn_can_school(p_school text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.kn_members m where m.user_id = auth.uid()
                 and (m.role = 'super_admin' or m.school_id = p_school))
$$;

create or replace function public.kn_has_super() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.kn_members where role = 'super_admin')
$$;

-- First account ever becomes the Super Admin. Returns the caller's role (or null).
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

-- Super Admin: create a single-use registration link token.
create or replace function public.kn_create_invite(p_note text) returns text
language plpgsql security definer set search_path = public as $$
declare t text := replace(gen_random_uuid()::text, '-', '') || substr(md5(random()::text), 1, 8);
begin
  if public.kn_my_role() is distinct from 'super_admin' then raise exception 'Only the Super Admin can create registration links'; end if;
  insert into public.kn_invites (token, note, created_by) values (t, coalesce(p_note, ''), auth.uid());
  return t;
end $$;

-- Public: is this registration link usable? ('ok' | 'used' | 'expired' | 'invalid')
create or replace function public.kn_check_invite(p_token text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select case when used_at is not null then 'used'
                               when expires_at < now() then 'expired' else 'ok' end
                   from public.kn_invites where token = p_token), 'invalid')
$$;

-- The newly signed-up director submits the school. Creates the workspace and
-- gives the caller school-level (director) access.
create or replace function public.kn_redeem_invite(p_token text, p_school_id text, p_school_name text, p_reg text, p_director_email text, p_data jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare inv record; u record;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into inv from public.kn_invites where token = p_token for update;
  if inv is null then raise exception 'This registration link is not valid.'; end if;
  if inv.used_at is not null then raise exception 'This registration link has already been used.'; end if;
  if inv.expires_at < now() then raise exception 'This registration link has expired. Ask KIDNOVA for a new one.'; end if;
  select email, coalesce(raw_user_meta_data->>'full_name', '') as name into u from auth.users where id = auth.uid();
  if lower(u.email) <> lower(trim(p_director_email)) then raise exception 'The director email must be the account that submits the form.'; end if;
  if exists (select 1 from public.kn_members where user_id = auth.uid()) then raise exception 'This email already has KIDNOVA access. Use a different director email.'; end if;
  if exists (select 1 from public.kn_workspace where lower(reg_number) = lower(trim(p_reg))) then raise exception 'A school with this registration number is already registered.'; end if;
  insert into public.kn_workspace (school_id, school_name, reg_number, data, updated_by) values (p_school_id, p_school_name, trim(p_reg), p_data, auth.uid());
  insert into public.kn_members (user_id, email, full_name, role, school_id) values (auth.uid(), lower(u.email), u.name, 'director', p_school_id);
  update public.kn_invites set used_at = now(), school_id = p_school_id where token = p_token;
  return p_school_id;
end $$;

-- Add an existing login to a school (Super Admin: any school/role; Director: admins of own school).
create or replace function public.kn_add_member(p_email text, p_name text, p_role text, p_school text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid; me text := public.kn_my_role(); my_school text := public.kn_my_school();
begin
  if p_role not in ('director', 'admin') then raise exception 'Invalid role'; end if;
  if me = 'super_admin' then
    if not exists (select 1 from public.kn_workspace where school_id = p_school) then raise exception 'Unknown school'; end if;
  elsif me = 'director' then
    if p_school is distinct from my_school or p_role <> 'admin' then raise exception 'Directors can only add staff to their own school'; end if;
  else raise exception 'Not allowed'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'No account exists for %', p_email; end if;
  if exists (select 1 from public.kn_members where user_id = uid and (role = 'super_admin' or school_id <> p_school)) then
    raise exception '% already has access to another school', p_email;
  end if;
  insert into public.kn_members (user_id, email, full_name, role, school_id)
  values (uid, lower(trim(p_email)), coalesce(p_name, ''), p_role, p_school)
  on conflict (user_id) do update set role = excluded.role, full_name = coalesce(nullif(excluded.full_name, ''), kn_members.full_name);
  return uid;
end $$;

-- Save a school's records with a revision check (no silent overwrites).
create or replace function public.kn_save(p_school text, p_data jsonb, p_rev bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare new_rev bigint; nm text := p_data #>> '{schools,0,name}'; rg text := p_data #>> '{schools,0,regNumber}';
begin
  if not public.kn_can_school(p_school) then raise exception 'No access to this school'; end if;
  update public.kn_workspace set data = p_data, rev = rev + 1, updated_at = now(), updated_by = auth.uid(),
         school_name = coalesce(nm, school_name), reg_number = coalesce(rg, reg_number)
   where school_id = p_school and rev = p_rev returning rev into new_rev;
  if new_rev is null then raise exception 'KN_CONFLICT'; end if;
  return new_rev;
end $$;

revoke all on function public.kn_claim_super(), public.kn_create_invite(text), public.kn_redeem_invite(text, text, text, text, text, jsonb),
  public.kn_add_member(text, text, text, text), public.kn_save(text, jsonb, bigint), public.kn_my_role(), public.kn_my_school(), public.kn_can_school(text) from public, anon;
grant execute on function public.kn_claim_super(), public.kn_create_invite(text), public.kn_redeem_invite(text, text, text, text, text, jsonb),
  public.kn_add_member(text, text, text, text), public.kn_save(text, jsonb, bigint), public.kn_my_role(), public.kn_my_school(), public.kn_can_school(text) to authenticated;
grant execute on function public.kn_has_super(), public.kn_check_invite(text) to anon, authenticated;

-- Policies
drop policy if exists kn_members_read on public.kn_members;
drop policy if exists kn_members_update on public.kn_members;
drop policy if exists kn_members_delete on public.kn_members;
drop policy if exists kn_workspace_read on public.kn_workspace;
drop policy if exists kn_workspace_delete on public.kn_workspace;
drop policy if exists kn_invites_read on public.kn_invites;
drop policy if exists kn_invites_delete on public.kn_invites;
create policy kn_members_read on public.kn_members for select to authenticated
  using (public.kn_my_role() = 'super_admin' or school_id = public.kn_my_school());
create policy kn_members_update on public.kn_members for update to authenticated
  using (public.kn_my_role() = 'super_admin' and role <> 'super_admin')
  with check (public.kn_my_role() = 'super_admin' and role in ('director', 'admin'));
create policy kn_members_delete on public.kn_members for delete to authenticated
  using (user_id <> auth.uid() and role <> 'super_admin' and (public.kn_my_role() = 'super_admin'
         or (public.kn_my_role() = 'director' and role = 'admin' and school_id = public.kn_my_school())));

create policy kn_workspace_read on public.kn_workspace for select to authenticated using (public.kn_can_school(school_id));
create policy kn_workspace_delete on public.kn_workspace for delete to authenticated using (public.kn_my_role() = 'super_admin');

create policy kn_invites_read on public.kn_invites for select to authenticated using (public.kn_my_role() = 'super_admin');
create policy kn_invites_delete on public.kn_invites for delete to authenticated using (public.kn_my_role() = 'super_admin' and used_at is null);

grant select, update, delete on public.kn_members to authenticated;
grant select, delete on public.kn_workspace to authenticated;
grant select, delete on public.kn_invites to authenticated;

notify pgrst, 'reload schema';

-- ===================================================================
-- v3: teacher logins with feature permissions. Safe to re-run.
--   teacher : school level; can only use the features listed in
--             kn_members.features (students, attendance, marks, reports).
-- ===================================================================
alter table public.kn_members add column if not exists features text[] not null default '{}';
alter table public.kn_members add column if not exists teacher_id text;
alter table public.kn_members drop constraint if exists kn_members_role_check;
alter table public.kn_members add constraint kn_members_role_check check (role in ('super_admin', 'director', 'admin', 'teacher'));

drop function if exists public.kn_add_member(text, text, text, text);
drop function if exists public.kn_add_member(text, text, text, text, text[], text);
create or replace function public.kn_add_member(p_email text, p_name text, p_role text, p_school text,
                                                p_features text[] default '{}', p_teacher_id text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid; me text := public.kn_my_role(); my_school text := public.kn_my_school();
begin
  if p_role not in ('director', 'admin', 'teacher') then raise exception 'Invalid role'; end if;
  if me = 'super_admin' then
    if not exists (select 1 from public.kn_workspace where school_id = p_school) then raise exception 'Unknown school'; end if;
  elsif me = 'director' then
    if p_school is distinct from my_school or p_role not in ('admin', 'teacher') then raise exception 'Directors can only add staff to their own school'; end if;
  elsif me = 'admin' then
    if p_school is distinct from my_school or p_role <> 'teacher' then raise exception 'Administrators can only add teachers to their own school'; end if;
  else raise exception 'Not allowed'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'No account exists for %', p_email; end if;
  if exists (select 1 from public.kn_members where user_id = uid and (role = 'super_admin' or school_id <> p_school)) then
    raise exception '% already has access to another school', p_email;
  end if;
  insert into public.kn_members (user_id, email, full_name, role, school_id, features, teacher_id)
  values (uid, lower(trim(p_email)), coalesce(p_name, ''), p_role, p_school, coalesce(p_features, '{}'), p_teacher_id)
  on conflict (user_id) do update set role = excluded.role, features = excluded.features,
    teacher_id = coalesce(excluded.teacher_id, kn_members.teacher_id),
    full_name = coalesce(nullif(excluded.full_name, ''), kn_members.full_name);
  return uid;
end $$;

-- Change what a teacher may use (Super Admin, or director/admin of the same school).
create or replace function public.kn_set_features(p_user uuid, p_features text[]) returns void
language plpgsql security definer set search_path = public as $$
declare m record; me text := public.kn_my_role(); my_school text := public.kn_my_school();
begin
  select * into m from public.kn_members where user_id = p_user;
  if m is null or m.role <> 'teacher' then raise exception 'Only teacher accounts have feature permissions'; end if;
  if not (me = 'super_admin' or (me in ('director', 'admin') and m.school_id = my_school)) then raise exception 'Not allowed'; end if;
  update public.kn_members set features = coalesce(p_features, '{}') where user_id = p_user;
end $$;

revoke all on function public.kn_add_member(text, text, text, text, text[], text), public.kn_set_features(uuid, text[]) from public, anon;
grant execute on function public.kn_add_member(text, text, text, text, text[], text), public.kn_set_features(uuid, text[]) to authenticated;

drop policy if exists kn_members_delete on public.kn_members;
create policy kn_members_delete on public.kn_members for delete to authenticated
  using (user_id <> auth.uid() and role <> 'super_admin' and (public.kn_my_role() = 'super_admin'
         or (public.kn_my_role() = 'director' and role in ('admin', 'teacher') and school_id = public.kn_my_school())
         or (public.kn_my_role() = 'admin' and role = 'teacher' and school_id = public.kn_my_school())));

notify pgrst, 'reload schema';

-- ===================================================================
-- v4: Super Admin can reset passwords and suspend accounts. Safe to re-run.
--   A suspended account is banned in Supabase Auth (cannot log in), its
--   sessions are ended, and it has no access to any school data.
-- ===================================================================
alter table public.kn_members add column if not exists suspended boolean not null default false;

create or replace function public.kn_my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.kn_members where user_id = auth.uid() and not suspended
$$;

create or replace function public.kn_my_school() returns text
language sql stable security definer set search_path = public as $$
  select school_id from public.kn_members where user_id = auth.uid() and not suspended
$$;

create or replace function public.kn_can_school(p_school text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.kn_members m where m.user_id = auth.uid() and not m.suspended
                 and (m.role = 'super_admin' or m.school_id = p_school))
$$;

create or replace function public.kn_claim_super() returns text
language plpgsql security definer set search_path = public as $$
declare r text; s boolean; u record;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  lock table public.kn_members in share row exclusive mode;
  select role, suspended into r, s from public.kn_members where user_id = auth.uid();
  if s then return 'suspended'; end if;
  if r is not null then return r; end if;
  if exists (select 1 from public.kn_members where role = 'super_admin') then return null; end if;
  select email, coalesce(raw_user_meta_data->>'full_name', '') as name into u from auth.users where id = auth.uid();
  insert into public.kn_members (user_id, email, full_name, role) values (auth.uid(), u.email, u.name, 'super_admin');
  return 'super_admin';
end $$;

-- Super Admin: set a new password for any account and end its sessions.
create or replace function public.kn_reset_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.kn_my_role() is distinct from 'super_admin' then raise exception 'Only the Super Admin can reset passwords'; end if;
  if p_password is null or length(p_password) < 6 then raise exception 'The new password must be at least 6 characters'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() where id = p_user;
  if not found then raise exception 'Account not found'; end if;
  if p_user <> auth.uid() then
    delete from auth.refresh_tokens where user_id = p_user::text;
    delete from auth.sessions where user_id = p_user;
  end if;
end $$;

-- Super Admin: suspend or reactivate an account (not your own, not a Super Admin).
create or replace function public.kn_set_suspended(p_user uuid, p_suspended boolean) returns void
language plpgsql security definer set search_path = public as $$
declare m record;
begin
  if public.kn_my_role() is distinct from 'super_admin' then raise exception 'Only the Super Admin can suspend accounts'; end if;
  if p_user = auth.uid() then raise exception 'You cannot suspend your own account'; end if;
  select * into m from public.kn_members where user_id = p_user;
  if m is null then raise exception 'Account not found'; end if;
  if m.role = 'super_admin' then raise exception 'A Super Admin account cannot be suspended'; end if;
  update public.kn_members set suspended = coalesce(p_suspended, false) where user_id = p_user;
  update auth.users set banned_until = case when p_suspended then now() + interval '100 years' else null end, updated_at = now() where id = p_user;
  if p_suspended then
    delete from auth.refresh_tokens where user_id = p_user::text;
    delete from auth.sessions where user_id = p_user;
  end if;
end $$;

revoke all on function public.kn_reset_password(uuid, text), public.kn_set_suspended(uuid, boolean) from public, anon;
grant execute on function public.kn_reset_password(uuid, text), public.kn_set_suspended(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';

-- ===================================================================
-- v5: teachers can only ever have attendance and marks (never report
-- cards or learner records). Safe to re-run.
-- ===================================================================
create or replace function public.kn_teacher_features(p text[]) returns text[]
language sql immutable as $$
  select coalesce(array(select distinct f from unnest(coalesce(p, '{}')) f where f in ('attendance', 'marks') order by f), '{}')
$$;
update public.kn_members set features = public.kn_teacher_features(features) where role = 'teacher';
update public.kn_members set features = '{}' where role <> 'teacher' and features <> '{}';

create or replace function public.kn_set_features(p_user uuid, p_features text[]) returns void
language plpgsql security definer set search_path = public as $$
declare m record; me text := public.kn_my_role(); my_school text := public.kn_my_school();
begin
  select * into m from public.kn_members where user_id = p_user;
  if m is null or m.role <> 'teacher' then raise exception 'Only teacher accounts have feature permissions'; end if;
  if not (me = 'super_admin' or (me in ('director', 'admin') and m.school_id = my_school)) then raise exception 'Not allowed'; end if;
  update public.kn_members set features = public.kn_teacher_features(p_features) where user_id = p_user;
end $$;

drop trigger if exists kn_members_teacher_features on public.kn_members;
create or replace function public.kn_members_clean_features() returns trigger
language plpgsql as $$
begin
  new.features := case when new.role = 'teacher' then public.kn_teacher_features(new.features) else '{}' end;
  return new;
end $$;
create trigger kn_members_teacher_features before insert or update on public.kn_members
  for each row execute function public.kn_members_clean_features();

notify pgrst, 'reload schema';

-- ===================================================================
-- v6: school approval. A school registered through a link is 'pending'
-- until the Super Admin approves it. Staff of a pending or rejected
-- school cannot open or save its records. Existing schools stay
-- 'approved'. Safe to re-run.
-- ===================================================================
alter table public.kn_workspace add column if not exists status text not null default 'approved';
alter table public.kn_workspace drop constraint if exists kn_workspace_status_check;
alter table public.kn_workspace add constraint kn_workspace_status_check check (status in ('pending', 'approved', 'rejected'));
alter table public.kn_workspace add column if not exists review_note text not null default '';
alter table public.kn_workspace add column if not exists submitted_at timestamptz;
alter table public.kn_workspace add column if not exists reviewed_at timestamptz;
alter table public.kn_workspace add column if not exists reviewed_by uuid;
update public.kn_workspace set submitted_at = created_at where submitted_at is null;

create or replace function public.kn_can_school(p_school text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.kn_members m where m.user_id = auth.uid() and not m.suspended
                 and (m.role = 'super_admin'
                      or (m.school_id = p_school and exists (select 1 from public.kn_workspace w where w.school_id = p_school and w.status = 'approved'))))
$$;

create or replace function public.kn_redeem_invite(p_token text, p_school_id text, p_school_name text, p_reg text, p_director_email text, p_data jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare inv record; u record;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into inv from public.kn_invites where token = p_token for update;
  if inv is null then raise exception 'This registration link is not valid.'; end if;
  if inv.used_at is not null then raise exception 'This registration link has already been used.'; end if;
  if inv.expires_at < now() then raise exception 'This registration link has expired. Ask KIDNOVA for a new one.'; end if;
  select email, coalesce(raw_user_meta_data->>'full_name', '') as name into u from auth.users where id = auth.uid();
  if lower(u.email) <> lower(trim(p_director_email)) then raise exception 'The director email must be the account that submits the form.'; end if;
  if exists (select 1 from public.kn_members where user_id = auth.uid()) then raise exception 'This email already has KIDNOVA access. Use a different director email.'; end if;
  if exists (select 1 from public.kn_workspace where lower(reg_number) = lower(trim(p_reg))) then raise exception 'A school with this registration number is already registered.'; end if;
  insert into public.kn_workspace (school_id, school_name, reg_number, data, updated_by, status, submitted_at)
  values (p_school_id, p_school_name, trim(p_reg), p_data, auth.uid(), 'pending', now());
  insert into public.kn_members (user_id, email, full_name, role, school_id) values (auth.uid(), lower(u.email), u.name, 'director', p_school_id);
  update public.kn_invites set used_at = now(), school_id = p_school_id where token = p_token;
  return p_school_id;
end $$;

-- The signed-in member's school, whatever its status (for the waiting screen).
create or replace function public.kn_my_school_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('school_id', w.school_id, 'school_name', w.school_name, 'reg_number', w.reg_number, 'status', w.status,
                            'note', w.review_note, 'submitted_at', w.submitted_at, 'reviewed_at', w.reviewed_at,
                            'school', w.data->'schools'->0, 'year', w.data->'academicYears'->0)
  from public.kn_workspace w join public.kn_members m on m.school_id = w.school_id
  where m.user_id = auth.uid() and not m.suspended
$$;

-- Super Admin: approve or reject a submitted school.
create or replace function public.kn_review_school(p_school text, p_approve boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.kn_my_role() is distinct from 'super_admin' then raise exception 'Only the Super Admin can review schools'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Write the reason for rejecting, so the school knows what to fix'; end if;
  update public.kn_workspace set status = case when p_approve then 'approved' else 'rejected' end,
         review_note = coalesce(trim(p_note), ''), reviewed_at = now(), reviewed_by = auth.uid()
   where school_id = p_school;
  if not found then raise exception 'School not found'; end if;
end $$;

-- Director of a rejected school: correct the registration details and submit again.
create or replace function public.kn_resubmit_school(p_fields jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare m record; w record; clean jsonb;
begin
  select * into m from public.kn_members where user_id = auth.uid() and not suspended;
  if m is null or m.role <> 'director' then raise exception 'Only the school director can resubmit the registration'; end if;
  select * into w from public.kn_workspace where school_id = m.school_id for update;
  if w.status <> 'rejected' then raise exception 'Only a rejected registration can be resubmitted'; end if;
  select coalesce(jsonb_object_agg(key, value), '{}') into clean from jsonb_each(coalesce(p_fields, '{}'))
   where key in ('name', 'regNumber', 'motto', 'district', 'sector', 'cell', 'village', 'address', 'email', 'phone', 'director', 'headteacher', 'logo');
  if coalesce(clean->>'name', '') = '' or coalesce(clean->>'regNumber', '') = '' then raise exception 'School name and registration number are required'; end if;
  if exists (select 1 from public.kn_workspace where school_id <> w.school_id and lower(reg_number) = lower(trim(clean->>'regNumber'))) then
    raise exception 'A school with this registration number is already registered.';
  end if;
  update public.kn_workspace set data = jsonb_set(data, '{schools,0}', (data->'schools'->0) || clean),
         school_name = clean->>'name', reg_number = trim(clean->>'regNumber'), status = 'pending', submitted_at = now(),
         rev = rev + 1, updated_at = now(), updated_by = auth.uid()
   where school_id = w.school_id;
end $$;

revoke all on function public.kn_my_school_info(), public.kn_review_school(text, boolean, text), public.kn_resubmit_school(jsonb) from public, anon;
grant execute on function public.kn_my_school_info(), public.kn_review_school(text, boolean, text), public.kn_resubmit_school(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- ===================================================================
-- v7: teachers may also be given discipline records. Safe to re-run.
-- ===================================================================
create or replace function public.kn_teacher_features(p text[]) returns text[]
language sql immutable as $$
  select coalesce(array(select distinct f from unnest(coalesce(p, '{}')) f where f in ('attendance', 'marks', 'discipline') order by f), '{}')
$$;
notify pgrst, 'reload schema';

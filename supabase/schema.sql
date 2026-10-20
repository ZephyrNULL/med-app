-- ============================================================
-- Care Cube â€” Supabase schema + Row Level Security
-- Run this in the Supabase SQL Editor.
--
-- NOTE: This is a fresh-setup script. It DROPS the existing app
-- tables first so re-runs always produce a consistent schema
-- (previously-created tables with mismatched column types, e.g.
-- schedules.id as bigint, would otherwise break the FKs below).
-- ============================================================

-- ---------- drop previous app tables (child -> parent order) ----------
drop table if exists public.dose_events cascade;
drop table if exists public.box_readings cascade;
drop table if exists public.schedules cascade;
drop table if exists public.boxes cascade;
drop table if exists public.patient_caregiver_links cascade;
drop table if exists public.profiles cascade;

-- ---------- profiles ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('patient','caregiver')),
  full_name text,
  email text,
  phone text,
  date_of_birth date,
  gender text,
  allergies text,
  blood_group text,
  emergency_contact_name text,
  emergency_contact_phone text,
  updated_at timestamptz default now()
);

-- ---------- patient_caregiver_links ----------
create table public.patient_caregiver_links (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.profiles(id) on delete cascade,
  caregiver_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','active')),
  unique (patient_id, caregiver_id)
);

-- ---------- boxes ----------
create table public.boxes (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.profiles(id) on delete cascade,
  device_id text unique not null,   -- must match ESP32 DEVICE_ID (carecube-xxx)
  paired_at timestamptz default now()
);

-- ---------- schedules ----------
create table public.schedules (
  id uuid primary key default gen_random_uuid(),
  box_id uuid not null references public.boxes(id) on delete cascade,
  slot int not null check (slot between 0 and 5),          -- 0-5 firmware slot
  sensor_number int not null check (sensor_number between 1 and 6), -- 7 reserved for emergency
  hour int not null check (hour between 0 and 23),
  minute int not null check (minute between 0 and 59),
  label text,
  enabled boolean default true,
  created_by uuid references public.profiles(id),
  updated_at timestamptz default now()
);

-- ---------- dose_events ----------
create table public.dose_events (
  id uuid primary key default gen_random_uuid(),
  box_id uuid not null references public.boxes(id) on delete cascade,
  schedule_id uuid references public.schedules(id), -- null for emergency
  event_type text not null check (event_type in ('reminder_started','taken','missed','emergency_taken','emergency_returned','caregiver_stopped','wrong_bay_taken','wrong_bay_returned')),
  sensor_number int not null check (sensor_number between 1 and 7),
  occurred_at timestamptz default now()
);

-- ---------- box_readings ----------
create table public.box_readings (
  id uuid primary key default gen_random_uuid(),
  box_id uuid not null references public.boxes(id) on delete cascade,
  temperature numeric,
  humidity numeric,
  recorded_at timestamptz default now()
);

-- ------------- triggers: keep updated_at fresh -------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_profiles_updated on public.profiles;
create trigger trg_profiles_updated
  before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists trg_schedules_updated on public.schedules;
create trigger trg_schedules_updated
  before update on public.schedules
  for each row execute function public.set_updated_at();

-- ------------- auto-create profile on signup -------------
-- The client cannot reliably insert the profile row right after
-- auth.signUp(): if email confirmation is enabled no session exists
-- yet, so RLS `auth.uid() = id` evaluates to NULL and the insert is
-- rejected (code 42501). This security-definer trigger runs as the
-- table owner, bypasses RLS, and creates the row from the values the
-- app passes in auth metadata. Runs for every signup regardless of
-- whether email confirmation is on or off.
create or replace function public.handle_new_user()
returns trigger language plpgsql
security definer set search_path = public as $$
begin
  insert into public.profiles (id, role, full_name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'role', 'patient'),
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
    new.email
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------- enable replication (Realtime) -------------
alter publication supabase_realtime add table public.dose_events;
alter publication supabase_realtime add table public.box_readings;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

-- Enable RLS on all tables
alter table public.profiles enable row level security;
alter table public.patient_caregiver_links enable row level security;
alter table public.boxes enable row level security;
alter table public.schedules enable row level security;
alter table public.dose_events enable row level security;
alter table public.box_readings enable row level security;

-- ---------- helper: current user's own patient id ----------
create or replace function public.is_caregiver(pid uuid)
returns boolean language sql stable as $$
  select exists (
    select 1 from public.patient_caregiver_links l
    where l.patient_id = pid
      and l.caregiver_id = auth.uid()
      and l.status = 'active'
  );
$$;

-- ---------- profiles ----------
-- Users can CRUD their own profile. Caregivers can read profiles of
-- patients they are actively linked to.
create policy "profiles own read" on public.profiles
  for select using (auth.uid() = id or public.is_caregiver(id));

create policy "profiles own insert" on public.profiles
  for insert with check (auth.uid() = id);

create policy "profiles own update" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- ---------- patient_caregiver_links ----------
create policy "links own read" on public.patient_caregiver_links
  for select using (auth.uid() = patient_id or auth.uid() = caregiver_id);

create policy "links patient insert" on public.patient_caregiver_links
  for insert with check (auth.uid() = patient_id or auth.uid() = caregiver_id);

create policy "links owner update" on public.patient_caregiver_links
  for update using (auth.uid() = patient_id or auth.uid() = caregiver_id);

create policy "links owner delete" on public.patient_caregiver_links
  for delete using (auth.uid() = patient_id or auth.uid() = caregiver_id);

-- ---------- boxes ----------
-- Owner patient, or a caregiver linked to that patient.
create policy "boxes read" on public.boxes
  for select using (auth.uid() = patient_id or public.is_caregiver(patient_id));

create policy "boxes insert" on public.boxes
  for insert with check (auth.uid() = patient_id);

create policy "boxes update owner" on public.boxes
  for update using (auth.uid() = patient_id) with check (auth.uid() = patient_id);

-- ---------- boxes: pair_box pairing RPC ----------
-- boxes.device_id is UNIQUE and only its owner may update a row, so a
-- device left over under a DIFFERENT patient (earlier account / re-pair
-- after a DB reset) would make the app's INSERT fail with a duplicate-key
-- error and be impossible to release from the app (RLS). This SECURITY
-- DEFINER function runs as the table owner and makes "whoever pairs the
-- device last owns it": re-points the caller's own box, adopts a stale
-- box row for the device, or creates a fresh one. Keep in sync with
-- supabase/migrations/<date>_pair_box_rpc.sql.
create or replace function public.pair_box(p_device_id text)
returns public.boxes
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_box public.boxes%rowtype;
begin
  if me is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  -- 1) Caller already owns a box: keep it, point it at the requested
  --    device. If some other box holds the device, that box is released
  --    (its schedules/readings cascade away) so the device id is free.
  select * into v_box from public.boxes where patient_id = me limit 1;
  if found then
    if v_box.device_id = p_device_id then
      return v_box;
    end if;
    delete from public.boxes where device_id = p_device_id and id <> v_box.id;
    update public.boxes
       set device_id = p_device_id,
           paired_at = now()
     where id = v_box.id
     returning * into v_box;
    return v_box;
  end if;

  -- 2) Device already exists under a different (stale) owner: adopt it
  --    by re-pointing patient_id to the current user.
  select * into v_box from public.boxes where device_id = p_device_id limit 1;
  if found then
    update public.boxes
       set patient_id = me,
           paired_at = now()
     where id = v_box.id
     returning * into v_box;
    return v_box;
  end if;

  -- 3) Brand-new pairing.
  insert into public.boxes (patient_id, device_id)
  values (me, p_device_id)
  returning * into v_box;
  return v_box;
end;
$$;

revoke execute on function public.pair_box(text) from public;
grant execute on function public.pair_box(text) to anon, authenticated;

-- ---------- schedules ----------
-- Patient (owner of box) and caregivers can read; the owner AND active
-- caregivers can write (add / edit / delete), matching the app UI which
-- exposes dose management to caregivers.
create policy "schedules read" on public.schedules
  for select using (
    exists (
      select 1 from public.boxes b
      where b.id = schedules.box_id
        and (b.patient_id = auth.uid() or public.is_caregiver(b.patient_id))
    )
  );

create policy "schedules write owner or caregiver" on public.schedules
  for all using (
    exists (
      select 1 from public.boxes b
      where b.id = schedules.box_id
        and (b.patient_id = auth.uid() or public.is_caregiver(b.patient_id))
    )
  ) with check (
    exists (
      select 1 from public.boxes b
      where b.id = schedules.box_id
        and (b.patient_id = auth.uid() or public.is_caregiver(b.patient_id))
    )
  );

-- ---------- dose_events ----------
-- Read: owner + caregivers. Write: owner + caregiver (e.g. stop-alarm events)
create policy "dose_events read" on public.dose_events
  for select using (
    exists (
      select 1 from public.boxes b
      where b.id = dose_events.box_id
        and (b.patient_id = auth.uid() or public.is_caregiver(b.patient_id))
    )
  );

create policy "dose_events write" on public.dose_events
  for insert with check (
    exists (
      select 1 from public.boxes b
      where b.id = dose_events.box_id
        and (b.patient_id = auth.uid() or public.is_caregiver(b.patient_id))
    )
  );

-- ---------- box_readings ----------
create policy "box_readings read" on public.box_readings
  for select using (
    exists (
      select 1 from public.boxes b
      where b.id = box_readings.box_id
        and (b.patient_id = auth.uid() or public.is_caregiver(b.patient_id))
    )
  );

create policy "box_readings write" on public.box_readings
  for insert with check (
    exists (
      select 1 from public.boxes b
      where b.id = box_readings.box_id
        and (b.patient_id = auth.uid() or public.is_caregiver(b.patient_id))
    )
  );



-- ============================================================
-- link_caregiver_to_device(p_device_id) â€” let a caregiver connect
-- to a patient's box by typing its device id.
--
-- Why: boxes are PATIENT-owned (patient_id = the user who paired it),
-- and a caregiver shares the same box through an ACTIVE row in
-- patient_caregiver_links. The plain RLS tables give a caregiver NO way
-- to claim or discover a box before they are linked to its patient, so
-- there was no "Pair box" button on the caregiver side.
--
-- This function (SECURITY DEFINER, bypasses RLS) does:
--   1. SELF-HEALS the caller's profile: if the caller has no profile row
--      (account created before the signup trigger existed) or it is
--      mislabeled as 'patient', upsert it as 'caregiver'. Performing the
--      caregiver-connect action IS the role declaration, and this keeps
--      the app's role-dependent UI consistent after the next reload.
--   2. Finds the patient who owns the box with that device id.
--   3. Upserts an ACTIVE patient-caretaker link (caregiver -> patient),
--      so the caregiver's app loads the same box (loadForCaregiver).
--
-- Errors (clear messages):
--   - "Authentication required"                       if not signed in
--   - "No patient owns a box with device id X yet..." if unknown device
--
-- Run this in the Supabase SQL Editor (idempotent, create or replace).
-- NOTE: this replaces the previous version that rejected callers whose
-- profile role was not strictly 'caregiver' (a common case for accounts
-- created before the auto-profile trigger was added).
-- ============================================================

-- Previous versions returned 	ext; change of return type needs a DROP first.
drop function if exists public.link_caregiver_to_device(text);

create or replace function public.link_caregiver_to_device(p_device_id text)
returns public.boxes -- the box the caller is now linked to
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_user auth.users%rowtype;
  v_box public.boxes%rowtype;
begin
  if me is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  -- Self-heal profile: a caller performing the caregiver-connect action
  -- IS a caregiver. Fix missing/mislabeled rows so role-dependent UI
  -- (isCaregiver) stays correct after reload.
  select * into v_profile from public.profiles where id = me;
  if not found or v_profile.role <> 'caregiver' then
    select * into v_user from auth.users where id = me;
    if not found then
      raise exception 'Account not found' using errcode = 'P0001';
    end if;
    insert into public.profiles (id, role, full_name, email)
    values (
      me,
      'caregiver',
      coalesce(nullif(v_user.raw_user_meta_data ->> 'full_name', ''), v_user.email),
      v_user.email
    )
    on conflict (id) do update set role = 'caregiver';
  end if;

  -- The patient must have paired the box from their own account first.
  select * into v_box from public.boxes where device_id = p_device_id limit 1;
  if not found then
    raise exception 'No patient owns a box with device id "%" yet. Pair it from the patient''s account first.', p_device_id
      using errcode = 'P0001';
  end if;

  -- Upsert an active link; caregiver = me, patient = box owner.
  insert into public.patient_caregiver_links (patient_id, caregiver_id, status)
  values (v_box.patient_id, me, 'active')
  on conflict (patient_id, caregiver_id)
  do update set status = 'active';

  return v_box;
end;
$$;

-- Only signed-in users may link; never anon/browser.
revoke execute on function public.link_caregiver_to_device(text) from public;
grant execute on function public.link_caregiver_to_device(text) to authenticated;




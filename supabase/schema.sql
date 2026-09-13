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
  event_type text not null check (event_type in ('reminder_started','taken','missed','emergency_taken','caregiver_stopped')),
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

-- ---------- schedules ----------
-- Patient (owner of box) and caregivers can read; only patient can write
-- unless you decide caregivers can manage schedules (see spec Â§5.4 / Â§8.3).
create policy "schedules read" on public.schedules
  for select using (
    exists (
      select 1 from public.boxes b
      where b.id = schedules.box_id
        and (b.patient_id = auth.uid() or public.is_caregiver(b.patient_id))
    )
  );

create policy "schedules write owner" on public.schedules
  for all using (
    exists (
      select 1 from public.boxes b
      where b.id = schedules.box_id and b.patient_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from public.boxes b
      where b.id = schedules.box_id and b.patient_id = auth.uid()
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


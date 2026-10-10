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



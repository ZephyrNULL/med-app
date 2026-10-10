-- ============================================================
-- pair_box(p_device_id) — idempotent, RLS-safe box pairing.
--
-- Why: boxes.device_id is UNIQUE and a device is only editable by
-- its owner (RLS 'boxes update owner' / no delete policy). If a device
-- id is left over under a DIFFERENT patient (e.g. earlier test account,
-- re-pairing after a DB reset), the current patient cannot release that
-- row, so the plain INSERT in the app fails with:
--   duplicate key value violates unique constraint "boxes_device_id_key"
--
-- This function runs as the table owner (bypasses RLS) and makes
-- "whoever pairs the device last owns it":
--   1. If the caller already owns a box, it re-points that box at the
--      new device (freeing the device from any other box first).
--   2. Else if the device is currently held by another (stale) box, it
--      adopts that box row (patient_id := caller).
--   3. Else it creates a brand-new box.
--
-- Run this in the Supabase SQL Editor (it is idempotent via
-- create or replace + random uuid rows everywhere).
-- ============================================================

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

-- Executable by anonymous (paired device before sign-in) and any
-- authenticated user. Revoke the blanket PUBLIC grant first.
revoke execute on function public.pair_box(text) from public;
grant execute on function public.pair_box(text) to anon, authenticated;
-- ============================================================
-- Allow active caregivers to manage a patient's schedules.
--
-- Why: the app already exposes the add / edit / delete dose UI to
-- caregivers, and the repository auto-removes a schedule on a
-- `caregiver_stopped` event. But the original RLS policy
-- "schedules write owner" only allowed the box OWNER (patient) to
-- write. A caregiver could therefore READ schedules (via the
-- separate "schedules read" policy + is_caregiver) yet every
-- INSERT / UPDATE / DELETE matched 0 rows and failed silently
-- (PostgREST returns success with no error when RLS filters the row),
-- so deleting a dose from the caregiver side appeared to do nothing.
--
-- Fix: extend the write policy to also allow a caregiver with an
-- ACTIVE link to the box's patient, mirroring "schedules read".
-- `public.is_caregiver(pid)` already returns true only for an active
-- link, so pending links get no write access.
--
-- Run this in the Supabase SQL Editor (idempotent).
-- Keep in sync with supabase/schema.sql.
-- ============================================================

drop policy if exists "schedules write owner" on public.schedules;

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

-- ============================================================
-- Allow `emergency_returned` in dose_events.
--
-- Why: the ESP32 firmware now keeps the emergency alarm ringing
-- until the emergency container is placed BACK in bay 7, at which
-- point it publishes `emergency_returned`. The app needs to persist
-- that resolution event, so the old CHECK constraint on
-- public.dose_events.event_type must accept it. Everything else in
-- the event lifecycle is unchanged.
--
-- Run this in the Supabase SQL Editor (idempotent).
-- Keep in sync with supabase/schema.sql.
-- ============================================================

alter table public.dose_events
  drop constraint if exists dose_events_event_type_check;

alter table public.dose_events
  add constraint dose_events_event_type_check
  check (event_type in (
    'reminder_started','taken','missed','emergency_taken',
    'emergency_returned','caregiver_stopped'
  ));
-- ============================================================
-- Allow `wrong_bay_taken` in dose_events.
--
-- Why: the ESP32 firmware now detects medicine being removed from a bay
-- that has no dose due. Two minutes after the unexpected removal it runs a
-- 10-second "WRONG BAY" warning (distinct buzzer/LCD) and publishes
-- `wrong_bay_taken` (sensor_number = the bay that was emptied). The app
-- persists it as an informational event so it appears in the alert feed.
--
-- It is NOT an alarm and never resolves one: it must not ring the phone,
-- silence a live reminder, or clear schedules. The old CHECK constraint
-- rejected it (23514), so the insert failed silently.
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
    'emergency_returned','caregiver_stopped','wrong_bay_taken'
  ));

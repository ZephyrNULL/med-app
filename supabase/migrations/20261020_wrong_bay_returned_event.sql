-- ============================================================
-- Allow `wrong_bay_returned` in dose_events.
--
-- Why: the ESP32 firmware now ends its "WRONG BAY" warning the moment the
-- container is put back (three consecutive "present" readings), publishing
-- `wrong_bay_returned` (sensor_number = the bay that was refilled). The app
-- uses it to clear the phone alarm and the wrong-bay banner instantly -
-- previously the warning only timed out, so the phone kept ringing after
-- the container was back. It is also published when the correct dose is
-- taken while the wrong-bay warning is outstanding, and by the firmware's
-- safety-timeout path keeps waiting for the return.
--
-- Like `wrong_bay_taken` it is informational: it never rings and never
-- resolves a reminder/emergency alarm; it only ends the wrong-bay warning
-- (tracked on its own channel in the app).
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
    'emergency_returned','caregiver_stopped','wrong_bay_taken',
    'wrong_bay_returned'
  ));

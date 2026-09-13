# Care Cube — Flutter app

Smart medicine box companion app for the Care Cube project. It talks to the
ESP32 firmware (`CareCube_ESP32_Firmware_v2.ino`) over MQTT and mirrors all
state into Supabase (the single source of truth for the UI).

## Tech stack

- **Flutter / Dart** — mobile app (Android, iOS; web for quick testing)
- **Supabase** — auth (email + password), Postgres, realtime
- **MQTT** — live hardware communication via the `mqtt_client` package

## Repo layout

```
lib/
  config/app_config.dart          → Supabase + MQTT credentials
  models/                         → Profile, Schedule, DoseEvent, BoxReading, CareBox, Link
  services/
    supabase_service.dart         → auth + DB + realtime helpers
    mqtt_service.dart             → ESP32 MQTT broker contract (app ⇄ box)
    care_cube_repository.dart     → bridges MQTT ⇄ Supabase, drives the UI
    app_state.dart                → current user profile + role (provider)
    notification_service.dart     → local alarm notifications
  screens/                        → Splash, Sign In/Up, Setup, Home, Medicine, Alert, Profile
supabase/schema.sql               → full schema + Row Level Security
```

## ESP32 ↔ App contract (must stay in sync with the firmware)

The app publishes/subscribes to exactly the topics the firmware uses:

| Topic | Direction | Payload |
|---|---|---|
| `carecube/{device_id}/schedule/set` | App → ESP32 | JSON array of `{"slot":0-5,"sensor_number":1-6,"hour","minute","enabled"}` |
| `carecube/{device_id}/status` | ESP32 → App | `{"device_id","temperature","humidity","timestamp"}` every ~30s |
| `carecube/{device_id}/event` | ESP32 → App | `{"device_id","type","sensor_number","timestamp"}` |
| `carecube/{device_id}/alarm/stop` | App → ESP32 | caregiver only; silences buzzer, does NOT mark taken |

- `device_id` must equal the firmware's `DEVICE_ID` (e.g. `carecube-001`) and
  the `boxes.device_id` row in Supabase.
- The **schedule sync is idempotent**: every add/edit/delete re-publishes the
  full 6-slot array (full replace), so the ESP32 never gets a partial diff.
- The patient cannot stop the alarm remotely. Only a caregiver's "Stop Alarm"
  writes to `alarm/stop`. The patient path is exclusively the physical
  sensor-confirmed removal (per the firmware's 3-reading >90 mm rule).

## Configure

1. **Supabase**
   - Create a project, run `supabase/schema.sql` in the SQL Editor.
   - Put your project URL and publishable (anon) key in
     `lib/config/app_config.dart`.
2. **MQTT broker**
   - Default in code is the public `broker.emqx.io:1883`, which matches the
     ESP32 firmware's non-TLS *fallback* broker, so the box and app connect to
     the same place out of the box.
   - For the firmware's HiveMQ Cloud (TLS) primary, set the host/port/creds in
     `lib/config/app_config.dart` and the firmware's `brokerPrimary`.
3. **Android manifest** already has `INTERNET` + `usesCleartextTraffic="true"`
   so plain-MQTT (port 1883) works. For production with a TLS-only broker you
   can remove cleartext and enable TLS in `MqttService`.

## Run

```bash
flutter pub get
flutter run                # pick a device
```

`flutter analyze` and `flutter test` should both pass.

## Notes on open decisions (from the build prompt)

- **MQTT in the app**: this build connects MQTT directly from the app and
  mirrors events into Supabase. A future bridge/Edge Function could do the same
  without holding a client in the app.
- **Caregiver schedule editing**: patients edit their own schedules; caregivers
  can view. (Make schedules writable by caregivers by extending the RLS
  `schedules write owner` policy if desired.)
- **Multi-patient**: a caregiver's Home/Alert currently show the first active
  linked patient. A patient switcher is future work.

"""Virtual Care Cube (ESP32) device for PC-side testing.

Mirrors firmware/CareCube_ESP32_Firmware_v2/CareCube_ESP32_Firmware_v2.ino as
closely as a PC can: the SAME MQTT topics, event payloads, schedule contract,
catch-up window, re-publish cadence, and - importantly - the SAME single
threaded state machine (MAIN_SCREEN / MEDICINE_REMINDER / MEDICINE_TAKEN /
EMERGENCY_TAKEN / WRONG_DOSE_ALERT) with the firmware's ToF rules:

  * a dose is "taken" only after 3 consecutive >90mm readings AND the bay was
    first seen holding a dose (or the 90s empty-bay grace expired);
  * the emergency bay (S7) learns its own resting distance and only fires on a
    debounced removal, and only resolves when the container is placed back;
  * a medicine removed from an unexpected bay warns with `wrong_bay_taken`
    only after it stays gone for 2 minutes.

Because the firmware is single-threaded, ALL state changes run on one
device_loop thread. MQTT messages and interactive commands are queued and
applied there, exactly like mqttClient.loop() running inside loop().
"""

import datetime
import json
import math
import os
import queue
import sys
import threading
import time

import paho.mqtt.client as mqtt

try:
    import winsound  # Windows-only; PC-simulated buzzer
except ImportError:
    winsound = None

# ======================================================
# MQTT BROKER (must match firmware + app config)
# ======================================================
BROKER = "15eb54ef85ce471890ec2a12019e88b4.s1.eu.hivemq.cloud"
PORT = 8883
USERNAME = "CareCube12"
PASSWORD = "CareCube@2006"
CLIENT_ID = "caregh-esp32"
DEVICE_ID = "caregh"

TOPIC_SCHEDULE_SET = f"carecube/{DEVICE_ID}/schedule/set"
TOPIC_STATUS = f"carecube/{DEVICE_ID}/status"
TOPIC_EVENT = f"carecube/{DEVICE_ID}/event"
TOPIC_ALARM_STOP = f"carecube/{DEVICE_ID}/alarm/stop"

# ======================================================
# FIRMWARE CONSTANTS (verbatim from the .ino)
# ======================================================
MEDICINE_THRESHOLD = 90           # MEDICINE_THRESHOLD
SENSOR_MIN_VALID_MM = 10          # SENSOR_MIN_VALID_MM
SENSOR_MAX_VALID_MM = 2000        # SENSOR_MAX_VALID_MM
TAKEN_MIN_ELAPSED_S = 0.0         # TAKEN_MIN_ELAPSED = 0UL
TAKEN_EMPTY_BAY_GRACE_S = 90.0    # TAKEN_EMPTY_BAY_GRACE = 90000UL
REQUIRED_TAKEN_READINGS = 3       # REQUIRED_TAKEN_READINGS
REMINDER_CATCHUP_MIN = 10         # REMINDER_CATCHUP_MS (10 min)
REMINDER_REPUBLISH_S = 30         # REMINDER_REPUBLISH_MS
REMINDER_REPUBLISH_UNTIL_S = 15 * 60  # REMINDER_REPUBLISH_UNTIL_MS
MQTT_HEARTBEAT_S = 15             # MQTT_HEARTBEAT_INTERVAL (DHT drives 2s here)
STATUS_INTERVAL_S = 2             # DHT_READ_INTERVAL - fresh sample cadence
MEDICINE_MESSAGE_S = 30           # MEDICINE_MESSAGE_TIME

EMERGENCY_REMOVE_MARGIN_MM = 20   # EMERGENCY_REMOVE_MARGIN_MM
EMERGENCY_CLOSER_HYST_MM = 12     # EMERGENCY_CLOSER_HYST_MM
EMERGENCY_CLOSER_CONFIRM = 3      # EMERGENCY_CLOSER_CONFIRM

WRONG_BAY_CONFIRM_READINGS = 2    # WRONG_BAY_CONFIRM_READINGS
WRONG_BAY_REMOVE_MARGIN_MM = 25   # WRONG_BAY_REMOVE_MARGIN_MM
WRONG_BAY_DELAY_S = 120           # WRONG_BAY_DELAY_MS (2 minutes)
WRONG_BAY_ALERT_S = 10            # WRONG_BAY_ALERT_TIME

LOOP_DELAY_S = 0.02               # delay(20) at the end of loop()

# Simulated ToF distances (mm). PRESENT = a medicine/compartment sits in the
# bay; EMPTY = bay reads far (medicine removed); OUT_OF_RANGE = the sensor
# reports no target at all (-1 on a real VL53L0X timeout).
PRESENT_MM = 40
EMPTY_MM = 150
OUT_OF_RANGE = -1

# Buzzer tone stand-ins (firmware is a passive piezo driven by LEDC tones).
BUZZER_NORMAL_HZ = 2200
BUZZER_EMERGENCY_HZ = 1200
BUZZER_WRONG_LOW_HZ = 700
BUZZER_WRONG_HIGH_HZ = 1500

# ======================================================
# DOSE SCHEDULE (6 slots) - firmware defaults
#   doseSensor[] is the bay number (1..6) each slot points at.
# ======================================================
dose_sensor = [1, 2, 3, 4, 5, 6]
dose_hour = [8, 10, 12, 14, 16, 20]
dose_minute = [0, 0, 0, 0, 0, 0]
dose_enabled = [True, True, True, True, True, True]
dose_triggered = [False, False, False, False, False, False]

# ======================================================
# STATE MACHINE + runtime state (mirrors the .ino globals)
# ======================================================
MAIN_SCREEN = "MAIN_SCREEN"
MEDICINE_REMINDER = "MEDICINE_REMINDER"
MEDICINE_TAKEN = "MEDICINE_TAKEN"
EMERGENCY_TAKEN = "EMERGENCY_TAKEN"
WRONG_DOSE_ALERT = "WRONG_DOSE_ALERT"

display_state = MAIN_SCREEN
wrong_alert_return_state = MAIN_SCREEN

active_reminder = -1          # activeReminder (slot index, -1 = idle)
current_day_stamp = -1        # currentDayStamp (yyyy*10000+mm*100+dd)

reminder_start = 0.0          # reminderStartTime
last_reminder_republish = 0.0  # lastReminderRepublish
taken_reading_count = 0       # takenReadingCount
bay_seen_occupied = False     # baySeenOccupied
message_start = 0.0           # messageStartTime

# Emergency (S7) learned-baseline detector.
emergency_triggered = False   # emergencyTriggered
emergency_rest_mm = -1        # emergencyRestMm
emergency_closer_readings = 0  # emergencyCloserReadings
emergency_remove_readings = 0  # emergencyRemoveReadings
emergency_return_readings = 0  # emergencyReturnReadings

# Wrong-bay detector, one set of state per bay (S1..S6 -> index 0..5).
wrong_bay_armed = [False] * 6
wrong_bay_occupied_mm = [-1] * 6
wrong_bay_remove_readings = [0] * 6
wrong_bay_pending = [False] * 6
wrong_bay_pending_start = [0.0] * 6
wrong_bay_sensor = -1
wrong_alert_start = 0.0

# Simulated ToF sensors. sensor_ok[] mirrors initSensor() success; the PC sim
# always has every bay online.
sensor_distance = {n: PRESENT_MM for n in range(1, 8)}
sensor_ok = {n: True for n in range(1, 8)}

temperature = 26.4
humidity = 55.0

# Buzzer: a separate thread watches this mode, like serviceBuzzer() does on
# the passive piezo. Values: "off" | "normal" | "emergency" | "wrong".
buzzer_mode = "off"
wrong_tone_cycle_start = 0.0

# Everything is applied on the single device_loop thread (firmware is
# single-threaded). MQTT + commands are queued here and drained in loop().
event_queue = queue.Queue()
shutdown = threading.Event()

CMDFILE = "virtual_device_cmd.txt"


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def is_valid_distance(mm):
    return SENSOR_MIN_VALID_MM <= mm <= SENSOR_MAX_VALID_MM


# ======================================================
# BUZZER (PC speaker stand-in for the ESP32 piezo)
# ======================================================
def beep(duration_ms, frequency):
    if winsound is None:
        return
    try:
        winsound.Beep(frequency, duration_ms)
    except Exception as e:
        log(f"beep failed: {e}")


def set_buzzer_mode(mode):
    global buzzer_mode, wrong_tone_cycle_start
    if buzzer_mode == mode:
        return
    buzzer_mode = mode
    if mode == "wrong":
        wrong_tone_cycle_start = time.time()


def buzzer_loop():
    """Mirrors setBuzzerMode()/serviceBuzzer(): a continuous tone for the
    normal/emergency modes, and the firmware's 1200ms warble
    (700Hz 250ms - silence 150ms - 1500Hz 250ms - silence 550ms) for a
    wrong-bay warning."""
    while not shutdown.is_set():
        mode = buzzer_mode
        if mode == "normal":
            beep(120, BUZZER_NORMAL_HZ)
            time.sleep(0.06)
        elif mode == "emergency":
            beep(120, BUZZER_EMERGENCY_HZ)
            time.sleep(0.06)
        elif mode == "wrong":
            phase = (time.time() - wrong_tone_cycle_start) % 1.2
            if phase < 0.25:
                beep(90, BUZZER_WRONG_LOW_HZ)
            elif 0.40 <= phase < 0.65:
                beep(90, BUZZER_WRONG_HIGH_HZ)
            else:
                time.sleep(0.05)
        else:
            time.sleep(0.1)


# ======================================================
# MQTT PUBLISH (publishStatus / publishEvent)
# ======================================================
def publish_status(client):
    t = time.time()
    payload = {
        "device_id": DEVICE_ID,
        "temperature": round(temperature + math.sin(t / 12.0) * 0.6, 1),
        "humidity": round(humidity + math.sin(t / 18.0) * 2.0, 1),
        "timestamp": int(t),
    }
    try:
        client.publish(TOPIC_STATUS, json.dumps(payload), qos=0, retain=True)
        log(f"MQTT -> [{TOPIC_STATUS}] {json.dumps(payload)}")
    except Exception as e:
        log(f"publish status failed: {e}")


def publish_event(client, event_type, sensor_number):
    payload = {
        "device_id": DEVICE_ID,
        "type": event_type,
        "sensor_number": sensor_number,
        "timestamp": int(time.time()),
    }
    try:
        client.publish(TOPIC_EVENT, json.dumps(payload), qos=0, retain=False)
        log(f"MQTT -> [{TOPIC_EVENT}] {json.dumps(payload)}")
    except Exception as e:
        log(f"publish event failed: {e}")


# ======================================================
# MQTT CALLBACK -> queued (firmware runs these inside loop())
# ======================================================
def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code == 0:
        log("MQTT connected!")
        client.subscribe(TOPIC_SCHEDULE_SET, qos=1)
        client.subscribe(TOPIC_ALARM_STOP, qos=1)
        log(f"Subscribed to: {TOPIC_SCHEDULE_SET}")
        log(f"Subscribed to: {TOPIC_ALARM_STOP}")
    else:
        log(f"MQTT connect failed, rc={reason_code}")


def on_disconnect(client, userdata, flags, reason_code, properties):
    log(f"MQTT disconnected (rc={reason_code}) - will auto-reconnect")


def on_message(client, userdata, message):
    topic = message.topic
    text = message.payload.decode("utf-8", errors="replace")
    event_queue.put(("mqtt", topic, text))


# ======================================================
# DAY ROLLOVER (rollOverDoseFlags)
# ======================================================
def roll_over_dose_flags(now):
    global current_day_stamp, dose_triggered
    stamp = now.year * 10000 + now.month * 100 + now.day
    if stamp == current_day_stamp:
        return
    # Guard against the clock stepping backwards wiping a day in progress.
    if stamp < current_day_stamp:
        return
    dose_triggered = [False] * 6
    current_day_stamp = stamp
    log(f"[ALARM] new day ({stamp}) - daily dose flags reset")


# ======================================================
# DOSE DUE (isDoseDue)
# ======================================================
def is_dose_due(i, now):
    if not dose_enabled[i]:
        return False
    if dose_triggered[i]:
        return False
    due_minutes = dose_hour[i] * 60 + dose_minute[i]
    now_minutes = now.hour * 60 + now.minute
    delta = now_minutes - due_minutes
    if delta < 0:
        return False
    if delta > REMINDER_CATCHUP_MIN:
        return False
    return True


# ======================================================
# WRONG-BAY DETECTOR (detectWrongBayRemoval)
# ======================================================
def disarm_wrong_bay(sensor_number):
    """Called on a confirmed correct pickup so the emptied bay is not later
    mistaken for a wrong-time pickup (firmware clears armed + baseline)."""
    bay = sensor_number - 1
    if 0 <= bay < 6:
        wrong_bay_armed[bay] = False
        wrong_bay_occupied_mm[bay] = -1
        wrong_bay_remove_readings[bay] = 0
        wrong_bay_pending[bay] = False


def detect_wrong_bay(client):
    """Returns the 0-based bay index that should raise a wrong-bay warning,
    or -1. A bay only counts once it has stayed removed for 2 minutes."""
    scheduled_bay = dose_sensor[active_reminder] if 0 <= active_reminder < 6 else -1

    for bay in range(6):
        sensor = bay + 1

        if not sensor_ok[sensor]:
            wrong_bay_remove_readings[bay] = 0
            wrong_bay_pending[bay] = False
            continue

        # Never classify the currently scheduled bay, or a bay while the
        # MEDICINE TAKEN screen is up, as a wrong bay.
        if bay == scheduled_bay or display_state == MEDICINE_TAKEN:
            wrong_bay_remove_readings[bay] = 0
            wrong_bay_pending[bay] = False
            continue

        d = sensor_distance[sensor]
        valid = is_valid_distance(d)

        # Learn this bay's occupied/resting distance independently.
        if valid and wrong_bay_occupied_mm[bay] < 0:
            wrong_bay_occupied_mm[bay] = d
            wrong_bay_armed[bay] = True
            wrong_bay_remove_readings[bay] = 0
            wrong_bay_pending[bay] = False
            continue

        # A clearly closer reading = compartment restored. Cancel a pending
        # warning and refresh the baseline.
        if (valid and wrong_bay_occupied_mm[bay] >= 0
                and d < wrong_bay_occupied_mm[bay] - WRONG_BAY_REMOVE_MARGIN_MM):
            wrong_bay_occupied_mm[bay] = d
            wrong_bay_armed[bay] = True
            wrong_bay_remove_readings[bay] = 0
            wrong_bay_pending[bay] = False
            continue

        looks_removed = (not valid) or (
            wrong_bay_occupied_mm[bay] >= 0
            and d > wrong_bay_occupied_mm[bay] + WRONG_BAY_REMOVE_MARGIN_MM)

        if wrong_bay_armed[bay] and looks_removed:
            wrong_bay_remove_readings[bay] += 1
            if wrong_bay_remove_readings[bay] >= WRONG_BAY_CONFIRM_READINGS:
                if not wrong_bay_pending[bay]:
                    wrong_bay_pending[bay] = True
                    wrong_bay_pending_start[bay] = time.time()
                    log(f"[WRONG] Unexpected removal on S{sensor}; "
                        f"waiting {WRONG_BAY_DELAY_S:.0f}s before warning.")
                if time.time() - wrong_bay_pending_start[bay] >= WRONG_BAY_DELAY_S:
                    wrong_bay_armed[bay] = False
                    wrong_bay_occupied_mm[bay] = -1
                    wrong_bay_remove_readings[bay] = 0
                    wrong_bay_pending[bay] = False
                    return bay
        else:
            wrong_bay_remove_readings[bay] = 0
            wrong_bay_pending[bay] = False
            # Track small downward drift only; never follow rising readings.
            if valid and wrong_bay_occupied_mm[bay] >= 0 and d < wrong_bay_occupied_mm[bay]:
                wrong_bay_occupied_mm[bay] = d
    return -1


def start_wrong_bay_alert(client, bay):
    global display_state, wrong_alert_return_state, wrong_bay_sensor, wrong_alert_start
    wrong_bay_sensor = bay
    wrong_alert_return_state = display_state
    wrong_alert_start = time.time()
    display_state = WRONG_DOSE_ALERT
    set_buzzer_mode("wrong")
    publish_event(client, "wrong_bay_taken", bay + 1)
    log(f"[BUZZER] WRONG BAY warning on S{bay + 1}")


# ======================================================
# EMERGENCY DETECTION (S7 learned baseline)
# ======================================================
def detect_emergency(client, now):
    global emergency_triggered, emergency_rest_mm, emergency_closer_readings
    global emergency_remove_readings, display_state, last_reminder_republish

    if active_reminder != -1 or display_state != MAIN_SCREEN or emergency_triggered:
        return

    d = sensor_distance[7]
    s7_valid = sensor_ok[7] and is_valid_distance(d)
    s7_no_target = sensor_ok[7] and not is_valid_distance(d)

    if s7_valid:
        if emergency_rest_mm < 0:
            # First time the bay is seen holding the compartment.
            emergency_rest_mm = d
            emergency_closer_readings = 0
        elif d < emergency_rest_mm - EMERGENCY_CLOSER_HYST_MM:
            # Clearly closer = compartment inserted; confirm before adopting.
            emergency_closer_readings += 1
            if emergency_closer_readings >= EMERGENCY_CLOSER_CONFIRM:
                emergency_rest_mm = d
                emergency_closer_readings = 0
        else:
            emergency_closer_readings = 0
            if d <= emergency_rest_mm + EMERGENCY_CLOSER_HYST_MM:
                emergency_rest_mm = (emergency_rest_mm * 7 + d) // 8

    if emergency_rest_mm >= 0:
        removed = s7_no_target or (s7_valid and d > emergency_rest_mm + EMERGENCY_REMOVE_MARGIN_MM)
        emergency_remove_readings = emergency_remove_readings + 1 if removed else 0
        if emergency_remove_readings >= REQUIRED_TAKEN_READINGS:
            emergency_triggered = True
            emergency_remove_readings = 0
            emergency_closer_readings = 0
            display_state = EMERGENCY_TAKEN
            last_reminder_republish = time.time()
            set_buzzer_mode("emergency")
            publish_event(client, "emergency_taken", 7)
            log("================================")
            log("ATTENTION! EMERGENCY DOSE TAKEN")
            log("================================")


def run_emergency_state(client, now):
    global display_state, emergency_triggered, emergency_return_readings
    global emergency_remove_readings, emergency_closer_readings
    global last_reminder_republish

    set_buzzer_mode("emergency")

    # Re-publish while still ringing so a phone that missed (or was killed
    # during) the first event rings again. No 15-minute cutoff here.
    if time.time() - last_reminder_republish >= REMINDER_REPUBLISH_S:
        last_reminder_republish = time.time()
        publish_event(client, "emergency_taken", 7)

    d = sensor_distance[7]
    if (sensor_ok[7] and is_valid_distance(d)
            and emergency_rest_mm >= 0
            and d <= emergency_rest_mm + EMERGENCY_REMOVE_MARGIN_MM):
        emergency_return_readings += 1
        if emergency_return_readings >= REQUIRED_TAKEN_READINGS:
            emergency_return_readings = 0
            emergency_remove_readings = 0
            emergency_closer_readings = 0
            set_buzzer_mode("off")
            emergency_triggered = False
            display_state = MAIN_SCREEN
            publish_event(client, "emergency_returned", 7)
            log("Emergency container returned - alarm cleared")
    else:
        emergency_return_readings = 0


# ======================================================
# REMINDER START + MEDICINE_REMINDER + MEDICINE_TAKEN
# ======================================================
def maybe_start_reminder(client, now):
    global active_reminder, display_state, reminder_start, last_reminder_republish
    global taken_reading_count, bay_seen_occupied

    if active_reminder != -1 or display_state != MAIN_SCREEN:
        return

    for i in range(6):
        if not is_dose_due(i, now):
            continue
        sensor = dose_sensor[i]
        active_reminder = i
        dose_triggered[i] = True
        display_state = MEDICINE_REMINDER
        taken_reading_count = 0
        bay_seen_occupied = False
        reminder_start = time.time()
        last_reminder_republish = time.time()
        set_buzzer_mode("normal")
        publish_event(client, "reminder_started", sensor)
        log(f"[ALARM] {now:%H:%M:%S} matches schedule: S{sensor} fired")
        break  # firmware rings just one alarm at a time


def run_medicine_reminder(client, now):
    global display_state, reminder_start, last_reminder_republish
    global taken_reading_count, bay_seen_occupied, message_start

    sensor = dose_sensor[active_reminder]
    dist = sensor_distance[sensor]
    elapsed = time.time() - reminder_start

    # Re-publish so a phone that missed (or was killed during) the first
    # event rings again.
    if (time.time() - last_reminder_republish >= REMINDER_REPUBLISH_S
            and elapsed < REMINDER_REPUBLISH_UNTIL_S):
        last_reminder_republish = time.time()
        publish_event(client, "reminder_started", sensor)

    reading_ok = sensor_ok[sensor] and is_valid_distance(dist)
    dose_removed = reading_ok and dist > MEDICINE_THRESHOLD

    if reading_ok and not dose_removed:
        bay_seen_occupied = True

    # Consecutive readings only.
    taken_reading_count = taken_reading_count + 1 if dose_removed else 0

    time_elapsed = elapsed >= TAKEN_MIN_ELAPSED_S
    # The bay must have been seen holding a dose first, otherwise an already
    # empty bay would clear itself the moment the alarm started. The grace
    # covers a dose taken before the sensor noticed.
    saw_pickup = bay_seen_occupied or elapsed >= TAKEN_EMPTY_BAY_GRACE_S

    if (reading_ok and time_elapsed and saw_pickup
            and taken_reading_count >= REQUIRED_TAKEN_READINGS):
        set_buzzer_mode("off")
        # The scheduled dose was correctly taken: disarm this bay's wrong-dose
        # detector so the emptied bay is not warned about afterwards.
        disarm_wrong_bay(sensor)
        display_state = MEDICINE_TAKEN
        message_start = time.time()
        taken_reading_count = 0
        publish_event(client, "taken", sensor)
        log(f"SENSOR {sensor} -> MEDICINE TAKEN")
    else:
        # Everything that is not a confirmed pickup keeps ringing.
        set_buzzer_mode("normal")


def run_medicine_taken(client, now):
    global display_state, active_reminder
    if time.time() - message_start < MEDICINE_MESSAGE_S:
        set_buzzer_mode("off")
    else:
        active_reminder = -1
        display_state = MAIN_SCREEN
        log("Medicine taken message finished.")


# ======================================================
# WRONG_DOSE_ALERT state (10s, then return)
# ======================================================
def run_wrong_bay_alert(client, now):
    global display_state, wrong_bay_sensor
    set_buzzer_mode("wrong")
    if time.time() - wrong_alert_start >= WRONG_BAY_ALERT_S:
        # Return to whatever was showing; re-enable the dose tone if a
        # reminder was ringing underneath.
        set_buzzer_mode("normal" if wrong_alert_return_state == MEDICINE_REMINDER else "off")
        display_state = wrong_alert_return_state
        wrong_bay_sensor = -1
        log("[WRONG] warning finished")


# ======================================================
# INBOUND HANDLERS (mqttCallback)
# ======================================================
def handle_schedule_set(client, text):
    global dose_sensor, dose_hour, dose_minute, dose_enabled, dose_triggered
    global display_state, active_reminder

    try:
        data = json.loads(text)
    except Exception as e:
        log(f"JSON parse error: {e}")
        return

    for i in range(6):
        slot = data[i] if i < len(data) else None
        if slot is None:
            dose_enabled[i] = False
            continue
        dose_sensor[i] = slot.get("sensor_number", i + 1)
        dose_hour[i] = slot.get("hour", 12)
        dose_minute[i] = slot.get("minute", 0)
        dose_enabled[i] = slot.get("enabled", False)
        # A slot whose time was moved must be allowed to fire again.
        dose_triggered[i] = False

    log("Schedule updated via MQTT")
    for i in range(6):
        log(f"  Slot {i}: S{dose_sensor[i]} "
            f"{dose_hour[i]:02d}:{dose_minute[i]:02d} "
            f"{'ON' if dose_enabled[i] else 'OFF'}")

    # If the slot the running reminder belongs to was disabled, stop it
    # (silently - the firmware publishes no event here).
    if 0 <= active_reminder < 6 and not dose_enabled[active_reminder]:
        log("Active slot disabled by schedule update - clearing alarm")
        set_buzzer_mode("off")
        display_state = MAIN_SCREEN
        active_reminder = -1

    try:
        with open("schedule_received.json", "w") as f:
            json.dump({"slots": [{"slot": i, **{k: (dose_sensor[i] if k == "sensor_number"
                                                      else dose_hour[i] if k == "hour"
                                                      else dose_minute[i] if k == "minute"
                                                      else dose_enabled[i])
                                                for k in ("sensor_number", "hour", "minute", "enabled")}}
                                 for i in range(6)]}, f, indent=2)
        log("Saved to schedule_received.json")
    except Exception as e:
        log(f"could not save schedule: {e}")


def handle_alarm_stop(client):
    global display_state, active_reminder, emergency_triggered
    global taken_reading_count, emergency_return_readings, bay_seen_occupied

    # The firmware only silences a REMINDER or an EMERGENCY. A wrong-bay
    # warning is untouched by alarm/stop.
    if display_state not in (MEDICINE_REMINDER, EMERGENCY_TAKEN):
        return

    stopped_bay = dose_sensor[active_reminder] if 0 <= active_reminder < 6 else 7
    log("Alarm stopped by caregiver")
    set_buzzer_mode("off")
    publish_event(client, "caregiver_stopped", stopped_bay)
    display_state = MAIN_SCREEN
    active_reminder = -1
    emergency_triggered = False
    taken_reading_count = 0
    emergency_return_readings = 0
    bay_seen_occupied = False


# ======================================================
# INTERACTIVE / FILE COMMANDS
# These are test affordances; they mutate the simulated *physics* (bay
# distances) or force a state transition, exactly as if a hand had moved the
# medicine. Detection still drives the published events.
# ======================================================
def handle_command(client, line):
    parts = line.split()
    if not parts:
        return True
    cmd = parts[0]

    if cmd in ("take", "taken") and len(parts) > 1:
        slot = int(parts[1])
        if 1 <= slot <= 6:
            log(f"[TOF] Medicine removed from bay S{slot}")
            sensor_distance[slot] = EMPTY_MM
        else:
            log("slot must be 1..6")
        return True

    if cmd == "fill" and len(parts) > 1:
        slot = int(parts[1])
        if 1 <= slot <= 6:
            log(f"[TOF] Medicine placed back in bay S{slot}")
            sensor_distance[slot] = PRESENT_MM
        else:
            log("slot must be 1..6")
        return True

    if cmd == "reminder" and len(parts) > 1:
        slot = int(parts[1])
        if 1 <= slot <= 6:
            # Force the slot's reminder now (test shortcut for the schedule).
            now = datetime.datetime.now()
            maybe_force_reminder(client, slot - 1, now)
        else:
            log("slot must be 1..6")
        return True

    if cmd == "emergency":
        # Physically remove the emergency container: S7 reports no target.
        # The learned-baseline detector then raises emergency_taken after the
        # debounced removal, exactly like the firmware.
        log("[TOF] Emergency container removed from S7 - detector armed")
        sensor_distance[7] = OUT_OF_RANGE
        return True

    if cmd == "putback":
        log("[TOF] Emergency container placed back in S7")
        sensor_distance[7] = PRESENT_MM
        return True

    if cmd == "status":
        publish_status(client)
        return True

    if cmd in ("quit", "exit"):
        shutdown.set()
        return False

    log("Unknown command. Use: take <1-6> | fill <1-6> | reminder <1-6> | "
        "emergency | putback | status | quit")
    return True


def maybe_force_reminder(client, slot, now):
    global active_reminder, display_state, reminder_start, last_reminder_republish
    global taken_reading_count, bay_seen_occupied
    if not (0 <= slot < 6):
        log("slot must be 1..6")
        return
    if active_reminder != -1 or display_state != MAIN_SCREEN:
        log("reminder ignored - another alarm/screen is active")
        return
    sensor = dose_sensor[slot]
    active_reminder = slot
    dose_triggered[slot] = True
    display_state = MEDICINE_REMINDER
    taken_reading_count = 0
    bay_seen_occupied = False
    reminder_start = time.time()
    last_reminder_republish = time.time()
    set_buzzer_mode("normal")
    publish_event(client, "reminder_started", sensor)
    log(f"[ALARM] manual reminder -> S{sensor}")


# ======================================================
# DEVICE LOOP - the firmware's loop(), single threaded
# ======================================================
def device_loop(client):
    last_status_publish = 0.0
    last_monitor = 0.0

    while not shutdown.is_set():
        now = datetime.datetime.now()

        # --- mqttClient.loop(): apply queued messages/commands -------------
        while True:
            try:
                item = event_queue.get_nowait()
            except queue.Empty:
                break
            if item[0] == "mqtt":
                _, topic, text = item
                log(f"MQTT <- [{topic}] {text}")
                if topic == TOPIC_SCHEDULE_SET:
                    handle_schedule_set(client, text)
                elif topic == TOPIC_ALARM_STOP:
                    handle_alarm_stop(client)
            else:
                _, line = item
                if not handle_command(client, line):
                    return

        # --- read sensors: the PC already has the simulated distances ------

        # --- roll over daily dose flags on a day change --------------------
        roll_over_dose_flags(now)

        # --- publish environment (fresh DHT sample every 2s) ---------------
        if time.time() - last_status_publish >= STATUS_INTERVAL_S:
            last_status_publish = time.time()
            publish_status(client)

        # --- wrong-bay detection (skips taken/emergency/wrong states) ------
        if (not emergency_triggered
                and display_state not in (MEDICINE_TAKEN, EMERGENCY_TAKEN, WRONG_DOSE_ALERT)):
            bay = detect_wrong_bay(client)
            if bay >= 0:
                start_wrong_bay_alert(client, bay)

        # --- emergency detection (idle main screen only) -------------------
        detect_emergency(client, now)

        # --- state machine -------------------------------------------------
        if display_state == EMERGENCY_TAKEN:
            run_emergency_state(client, now)
        elif display_state == MEDICINE_REMINDER:
            run_medicine_reminder(client, now)
        elif display_state == WRONG_DOSE_ALERT:
            run_wrong_bay_alert(client, now)
        elif display_state == MEDICINE_TAKEN:
            run_medicine_taken(client, now)
        elif display_state == MAIN_SCREEN:
            set_buzzer_mode("off")
            maybe_start_reminder(client, now)

        # --- periodic monitor line (firmware's Serial.print) ---------------
        if time.time() - last_monitor >= 5.0:
            last_monitor = time.time()
            dists = " ".join(f"S{n}:{sensor_distance[n]}" for n in range(1, 8))
            log(f"Time: {now:%H:%M:%S} | state:{display_state} "
                f"active:{active_reminder} | {dists}")

        time.sleep(LOOP_DELAY_S)


# ======================================================
# INPUT THREADS -> queue (never touch state directly)
# ======================================================
def interactive_loop():
    log("Commands: take <1-6> | fill <1-6> | reminder <1-6> | "
        "emergency | putback | status | quit")
    log(f"Tip: you can also put commands in {CMDFILE} (one per line) - auto-read.")
    while not shutdown.is_set():
        try:
            line = input("> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            log("Interactive input closed; staying alive in file mode.")
            return
        event_queue.put(("cmd", line))


def file_command_loop():
    while not shutdown.is_set():
        try:
            with open(CMDFILE) as f:
                lines = f.read().splitlines()
            os.remove(CMDFILE)
            for line in lines:
                line = line.strip().lower()
                if line:
                    log(f"cmd-file -> {line}")
                    event_queue.put(("cmd", line))
        except FileNotFoundError:
            pass
        time.sleep(1)


def main():
    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=CLIENT_ID,
        protocol=mqtt.MQTTv311,
    )
    client.username_pw_set(USERNAME, PASSWORD)
    client.tls_set()  # full CA validation; HiveMQ cert is valid
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=30)

    log(f"Connecting to MQTT: {BROKER}:{PORT} (TLS)")
    try:
        client.connect(BROKER, PORT, keepalive=60)
    except Exception as e:
        log(f"connect failed: {e}")
        sys.exit(1)

    client.loop_start()

    threading.Thread(target=buzzer_loop, daemon=True).start()
    threading.Thread(target=file_command_loop, daemon=True).start()
    threading.Thread(target=interactive_loop, daemon=True).start()

    log("====================")
    log(f"  CARE CUBE VIRTUAL DEVICE ({DEVICE_ID}) READY")
    log("====================")
    log(f"  Schedule: {TOPIC_SCHEDULE_SET}")
    log(f"  Status:   {TOPIC_STATUS}")
    log(f"  Event:    {TOPIC_EVENT}")
    log(f"  Alarm:    {TOPIC_ALARM_STOP}")
    log(f"Drop commands in {CMDFILE} (one per line) to fire events")

    try:
        device_loop(client)
    except KeyboardInterrupt:
        pass
    finally:
        shutdown.set()
        set_buzzer_mode("off")
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()

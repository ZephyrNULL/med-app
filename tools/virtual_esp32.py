"""Virtual Care Cube (ESP32) device for PC-side testing.

Mirrors firmware/CareCube_ESP32_Firmware_v2/CareCube_ESP32_Firmware_v2.ino as
closely as a PC can: the SAME MQTT topics, event payloads, schedule contract,
catch-up window, re-publish cadence, and - importantly - the SAME single
threaded state machine (MAIN_SCREEN / MEDICINE_REMINDER / MEDICINE_TAKEN /
EMERGENCY_TAKEN / WRONG_DOSE_ALERT) with the firmware's ToF rules:

  * a dose is "taken" only after 3 consecutive baseline-relative removals
    (or a sustained lost target) AND the bay was first seen holding a dose
    (or the 20s empty-bay grace expired);
  * the emergency bay (S7) learns its own resting distance and only fires on a
    removal debounced by count AND time, and only resolves when the container
    is placed back;
  * a medicine removed from an unexpected bay warns with `wrong_bay_taken`
    after 2.5s, unless that bay's dose is due (30min early/30min late) or still
    owed, and the warning clears the moment the container is returned.

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
TOPIC_TIME_SET = f"carecube/{DEVICE_ID}/time/set"

# ======================================================
# FIRMWARE CONSTANTS (verbatim from the .ino)
# ======================================================
MEDICINE_THRESHOLD = 90           # MEDICINE_THRESHOLD
SENSOR_MIN_VALID_MM = 10          # SENSOR_MIN_VALID_MM
SENSOR_MAX_VALID_MM = 2000        # SENSOR_MAX_VALID_MM
TAKEN_MIN_ELAPSED_S = 0.0         # TAKEN_MIN_ELAPSED = 0UL
TAKEN_EMPTY_BAY_GRACE_S = 20.0    # TAKEN_EMPTY_BAY_GRACE = 20000UL
REQUIRED_TAKEN_READINGS = 3       # REQUIRED_TAKEN_READINGS
PICKUP_INVALID_CONFIRM_S = 2.0    # PICKUP_INVALID_CONFIRM_MS = 2000UL
REMINDER_CATCHUP_MIN = 10         # REMINDER_CATCHUP_MS (10 min)
REMINDER_REPUBLISH_S = 30         # REMINDER_REPUBLISH_MS
REMINDER_REPUBLISH_UNTIL_S = 15 * 60  # REMINDER_REPUBLISH_UNTIL_MS
MQTT_HEARTBEAT_S = 15             # MQTT_HEARTBEAT_INTERVAL (DHT drives 2s here)
STATUS_INTERVAL_S = 2             # DHT_READ_INTERVAL - fresh sample cadence
MEDICINE_MESSAGE_S = 30           # MEDICINE_MESSAGE_TIME

EMERGENCY_REMOVE_MARGIN_MM = 20   # EMERGENCY_REMOVE_MARGIN_MM
EMERGENCY_CLOSER_HYST_MM = 12     # EMERGENCY_CLOSER_HYST_MM
EMERGENCY_CLOSER_CONFIRM = 3      # EMERGENCY_CLOSER_CONFIRM
EMERGENCY_REMOVE_CONFIRM_S = 3.0  # EMERGENCY_REMOVE_CONFIRM_MS = 3000UL

WRONG_BAY_CONFIRM_READINGS = 3    # WRONG_BAY_CONFIRM_READINGS (local to detector)
WRONG_BAY_REMOVE_MARGIN_MM = 25   # WRONG_BAY_REMOVE_MARGIN_MM
WRONG_BAY_DELAY_S = 2.5           # WRONG_BAY_DELAY_MS = 2500UL
WRONG_BAY_ALERT_S = 180           # WRONG_BAY_ALERT_TIME = 180000UL
WRONG_BAY_EARLY_TOLERANCE_MIN = 30  # WRONG_BAY_EARLY_TOLERANCE_MIN
WRONG_BAY_LATE_TOLERANCE_MIN = 30   # WRONG_BAY_LATE_TOLERANCE_MIN
WRONG_BAY_PRESENT_MAX_BASELINE_MM = 150  # WRONG_BAY_PRESENT_MAX_BASELINE_MM
WRONG_BAY_BASELINE_CONFIRM = 3    # WRONG_BAY_BASELINE_CONFIRM
WRONG_BAY_BASELINE_TOL_MM = 15    # WRONG_BAY_BASELINE_TOL_MM
WRONG_BAY_ARM_S = 10.0            # WRONG_BAY_ARM_MS = 10000UL
WRONG_BAY_OCC_CONFIRM = 3         # WRONG_BAY_OCC_CONFIRM
WRONG_BAY_RETURN_CONFIRM = 3      # WRONG_BAY_RETURN_CONFIRM

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
#   doseSensor[] is the 0-based bay index each slot points at (0..5 = S1..S6).
#   Bays ship DISABLED: the app pushes the full schedule on every connect.
# ======================================================
dose_sensor = [2, 4, 6, 1, 3, 5]  # Activation order: S2, S4, S6, S1, S3, S5
dose_hour = [8, 10, 12, 14, 16, 20]
dose_minute = [0, 0, 0, 0, 0, 0]
dose_enabled = [False, False, False, False, False, False]
dose_triggered = [False, False, False, False, False, False]
dose_taken_today = [False, False, False, False, False, False]

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
pickup_invalid_since = 0.0    # pickupInvalidSince
sched_rest_mm = -1            # schedRestMm
message_start = 0.0           # messageStartTime

# Emergency (S7) learned-baseline detector.
emergency_triggered = False   # emergencyTriggered
emergency_rest_mm = -1        # emergencyRestMm
emergency_closer_readings = 0  # emergencyCloserReadings
emergency_remove_readings = 0  # emergencyRemoveReadings
emergency_remove_start = 0.0   # emergencyRemoveStart
emergency_return_readings = 0  # emergencyReturnReadings

# Wrong-bay detector, one set of state per bay (S1..S6 -> index 0..5).
wrong_bay_armed = [False] * 6
wrong_bay_occupied_mm = [-1] * 6
wrong_bay_remove_readings = [0] * 6
wrong_bay_pending = [False] * 6
wrong_bay_pending_start = [0.0] * 6
wrong_bay_learn_readings = [0] * 6
wrong_bay_learn_value = [-1] * 6
wrong_bay_closer_readings = [0] * 6
wrong_bay_occupied_since = [0.0] * 6
wrong_bay_occupied_miss = [0] * 6
wrong_bay_sensor = -1
wrong_bay_rest_mm = -1
wrong_bay_return_readings = 0
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


# The firmware addresses bays 0..6; the simulator's physics tables are keyed
# 1..7 (S1..S7). These two helpers are the only translation points.
def get_sensor_distance(sensor_number):
    return sensor_distance.get(sensor_number + 1, -1)


def is_sensor_ok(sensor_number):
    return 0 <= sensor_number <= 6 and sensor_ok.get(sensor_number + 1, False)


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
    # Live alarm state, mirroring the firmware's publishStatus(): the phone
    # reconciles its alarm state from these fields on every heartbeat.
    reminder_sensor = 0
    if (0 <= active_reminder < 6
            and display_state != MEDICINE_TAKEN
            and display_state != EMERGENCY_TAKEN):
        reminder_sensor = dose_sensor[active_reminder] + 1  # 1-based on the wire
    dose_mask = 0
    for i, trig in enumerate(dose_triggered):
        if trig:
            dose_mask |= (1 << i)
    payload = {
        "device_id": DEVICE_ID,
        "temperature": round(temperature + math.sin(t / 12.0) * 0.6, 1),
        "humidity": round(humidity + math.sin(t / 18.0) * 2.0, 1),
        "timestamp": int(t),
        "reminder_sensor": reminder_sensor,
        "wrong_bay_sensor": wrong_bay_sensor + 1 if wrong_bay_sensor >= 0 else 0,
        "emergency": 1 if display_state == EMERGENCY_TAKEN else 0,
        "dose_triggered": dose_mask,
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


def publish_current_alarm_state(client):
    """Re-publish the alarm the box is showing right after (re)connect. A
    quiet box publishes nothing, which is exactly what the app needs."""
    if display_state == MEDICINE_REMINDER and 0 <= active_reminder < 6:
        publish_event(client, "reminder_started", dose_sensor[active_reminder] + 1)
    elif display_state == WRONG_DOSE_ALERT and wrong_bay_sensor >= 0:
        publish_event(client, "wrong_bay_taken", wrong_bay_sensor + 1)
    elif display_state == EMERGENCY_TAKEN:
        publish_event(client, "emergency_taken", 7)


# ======================================================
# MQTT CALLBACK -> queued (firmware runs these inside loop())
# ======================================================
def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code == 0:
        log("MQTT connected!")
        client.subscribe(TOPIC_SCHEDULE_SET, qos=1)
        client.subscribe(TOPIC_ALARM_STOP, qos=1)
        client.subscribe(TOPIC_TIME_SET, qos=1)
        log(f"Subscribed to: {TOPIC_SCHEDULE_SET}")
        log(f"Subscribed to: {TOPIC_ALARM_STOP}")
        log(f"Subscribed to: {TOPIC_TIME_SET}")
        # Tell the phone what the box is showing RIGHT NOW (publishCurrentAlarmState).
        publish_current_alarm_state(client)
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
    global current_day_stamp, dose_triggered, dose_taken_today
    stamp = now.year * 10000 + now.month * 100 + now.day
    if stamp == current_day_stamp:
        return
    # Guard against the clock stepping backwards wiping a day in progress.
    if stamp < current_day_stamp:
        return
    dose_triggered = [False] * 6
    dose_taken_today = [False] * 6
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
# WRONG-BAY STATE RESETS (clearWrongBayRemoval / resetWrongBayState)
# ======================================================
def clear_wrong_bay_removal(bay):
    if not (0 <= bay < 6):
        return
    wrong_bay_remove_readings[bay] = 0
    wrong_bay_pending[bay] = False
    wrong_bay_closer_readings[bay] = 0


def reset_wrong_bay_state(bay):
    if not (0 <= bay < 6):
        return
    wrong_bay_armed[bay] = False
    wrong_bay_occupied_mm[bay] = -1
    wrong_bay_learn_readings[bay] = 0
    wrong_bay_learn_value[bay] = -1
    wrong_bay_occupied_since[bay] = 0.0
    wrong_bay_occupied_miss[bay] = 0
    clear_wrong_bay_removal(bay)


# ======================================================
# BAY PRESENCE (bayLooksPresent / wrongBayLooksPresentNow)
# ======================================================
def bay_looks_present(bay, d, valid):
    if not valid:
        return False
    if d <= MEDICINE_THRESHOLD:
        return True
    base = wrong_bay_occupied_mm[bay] if 0 <= bay < 6 else -1
    if base <= 0 or base > WRONG_BAY_PRESENT_MAX_BASELINE_MM:
        return False
    return d <= base + WRONG_BAY_REMOVE_MARGIN_MM


def wrong_bay_looks_present_now():
    if not (0 <= wrong_bay_sensor < 6):
        return False
    if not is_sensor_ok(wrong_bay_sensor):
        return False
    d = get_sensor_distance(wrong_bay_sensor)
    if not is_valid_distance(d):
        return False
    if d <= MEDICINE_THRESHOLD:
        return True
    if wrong_bay_rest_mm <= 0 or wrong_bay_rest_mm > WRONG_BAY_PRESENT_MAX_BASELINE_MM:
        return False
    return d <= wrong_bay_rest_mm + WRONG_BAY_REMOVE_MARGIN_MM


def end_wrong_bay_alert():
    global display_state, wrong_bay_sensor, wrong_bay_rest_mm
    global wrong_bay_return_readings
    set_buzzer_mode("normal" if wrong_alert_return_state == MEDICINE_REMINDER else "off")
    display_state = wrong_alert_return_state
    wrong_bay_sensor = -1
    wrong_bay_rest_mm = -1
    wrong_bay_return_readings = 0
    log("Wrong-bay warning cleared")


# ======================================================
# IS THIS BAY'S DOSE STILL OWED? (bayDoseStillOwed)
# ======================================================
def bay_dose_still_owed(bay):
    for i in range(6):
        if not dose_enabled[i] or dose_sensor[i] != bay:
            continue
        if dose_triggered[i] and not dose_taken_today[i]:
            return True
    return False


# ======================================================
# IS PICKING THIS BAY UP EXPECTED? (bayHasDoseDueSoon)
# ======================================================
def bay_has_dose_due_soon(bay, now):
    now_minutes = now.hour * 60 + now.minute
    for i in range(6):
        if not dose_enabled[i] or dose_sensor[i] != bay:
            continue
        due = dose_hour[i] * 60 + dose_minute[i]
        delta = now_minutes - due
        if (-WRONG_BAY_EARLY_TOLERANCE_MIN <= delta
                <= WRONG_BAY_LATE_TOLERANCE_MIN):
            return True
    return False


# ======================================================
# SCHEDULED-BAY PICKUP STATE (updatePickupState)
# ======================================================
def update_pickup_state(sensor_number):
    global bay_seen_occupied, pickup_invalid_since, taken_reading_count

    d = get_sensor_distance(sensor_number)
    reading_ok = is_sensor_ok(sensor_number) and is_valid_distance(d)

    dose_removed = reading_ok and (
        d > sched_rest_mm + WRONG_BAY_REMOVE_MARGIN_MM
        if sched_rest_mm > 0
        else d > MEDICINE_THRESHOLD)

    lost_target = False
    if reading_ok:
        pickup_invalid_since = 0.0
    elif bay_seen_occupied:
        if pickup_invalid_since == 0.0:
            pickup_invalid_since = time.time()
        lost_target = (time.time() - pickup_invalid_since
                       >= PICKUP_INVALID_CONFIRM_S)
    else:
        pickup_invalid_since = 0.0

    if reading_ok and not dose_removed:
        bay_seen_occupied = True
    if dose_removed or lost_target:
        taken_reading_count += 1
    else:
        taken_reading_count = 0

    saw_pickup = (bay_seen_occupied
                  or time.time() - reminder_start >= TAKEN_EMPTY_BAY_GRACE_S)

    return ((dose_removed or lost_target) and saw_pickup
            and taken_reading_count >= REQUIRED_TAKEN_READINGS)


# ======================================================
# WRONG-BAY DETECTOR (detectWrongBayRemoval)
# ======================================================
def detect_wrong_bay(now):
    """Returns the 0-based bay index that should raise a wrong-bay warning,
    or -1."""
    global wrong_bay_rest_mm, wrong_bay_return_readings
    distances = [sensor_distance[n] for n in range(1, 7)]
    scheduled_bay = dose_sensor[active_reminder] if 0 <= active_reminder < 6 else -1
    clock = time.time()

    for bay in range(6):
        if not sensor_ok[bay + 1]:
            clear_wrong_bay_removal(bay)
            wrong_bay_occupied_since[bay] = 0.0
            wrong_bay_occupied_miss[bay] = 0
            continue

        d = distances[bay]
        valid = is_valid_distance(d)

        # Track how long this bay has CONTINUOUSLY looked occupied.
        if bay_looks_present(bay, d, valid):
            wrong_bay_occupied_miss[bay] = 0
            if wrong_bay_occupied_since[bay] == 0.0:
                wrong_bay_occupied_since[bay] = clock
        else:
            wrong_bay_occupied_miss[bay] += 1
            if wrong_bay_occupied_miss[bay] >= WRONG_BAY_OCC_CONFIRM:
                wrong_bay_occupied_miss[bay] = 0
                wrong_bay_occupied_since[bay] = 0.0

        # Sticky arming after sustained occupancy.
        if (not wrong_bay_armed[bay]
                and wrong_bay_occupied_mm[bay] >= 0
                and wrong_bay_occupied_since[bay] != 0.0
                and clock - wrong_bay_occupied_since[bay] >= WRONG_BAY_ARM_S):
            wrong_bay_armed[bay] = True
            log(f"S{bay + 1} armed for wrong-pickup detection")

        # Never classify the scheduled bay, a bay whose dose is due around
        # now, or a bay whose dose has fired and is not yet taken.
        if (bay == scheduled_bay or display_state == MEDICINE_TAKEN
                or bay_has_dose_due_soon(bay, now)
                or bay_dose_still_owed(bay)):
            clear_wrong_bay_removal(bay)
            continue

        # Learn the bay's resting distance from several agreeing samples.
        if wrong_bay_occupied_mm[bay] < 0:
            if not valid:
                wrong_bay_learn_readings[bay] = 0
                wrong_bay_learn_value[bay] = -1
            elif wrong_bay_learn_value[bay] < 0:
                wrong_bay_learn_value[bay] = d
                wrong_bay_learn_readings[bay] = 1
            elif d < wrong_bay_learn_value[bay] - WRONG_BAY_BASELINE_TOL_MM:
                wrong_bay_learn_value[bay] = d
                wrong_bay_learn_readings[bay] = 1
            elif d <= wrong_bay_learn_value[bay] + WRONG_BAY_BASELINE_TOL_MM:
                if d < wrong_bay_learn_value[bay]:
                    wrong_bay_learn_value[bay] = d
                wrong_bay_learn_readings[bay] += 1
                if wrong_bay_learn_readings[bay] >= WRONG_BAY_BASELINE_CONFIRM:
                    wrong_bay_occupied_mm[bay] = wrong_bay_learn_value[bay]
                    wrong_bay_learn_readings[bay] = 0
                    wrong_bay_learn_value[bay] = -1
                    clear_wrong_bay_removal(bay)
                    log(f"S{bay + 1} resting baseline learned at "
                        f"{wrong_bay_occupied_mm[bay]}mm")
            continue

        # A sustained closer reading means the compartment was restored or
        # the bay was freshly loaded.
        bay_looks_occupied_now = (valid and d <= MEDICINE_THRESHOLD
                                  and wrong_bay_occupied_mm[bay] > MEDICINE_THRESHOLD)
        if valid and (bay_looks_occupied_now or
                      d < wrong_bay_occupied_mm[bay] - WRONG_BAY_REMOVE_MARGIN_MM):
            wrong_bay_closer_readings[bay] += 1
            if wrong_bay_closer_readings[bay] >= WRONG_BAY_BASELINE_CONFIRM:
                wrong_bay_occupied_mm[bay] = d
                clear_wrong_bay_removal(bay)
                log(f"S{bay + 1} baseline re-learned at "
                    f"{wrong_bay_occupied_mm[bay]}mm")
            continue
        wrong_bay_closer_readings[bay] = 0

        # A lost target is NOT a removal; only a valid reading clearly past
        # the baseline AND past the 90mm floor counts.
        looks_removed = (valid
                         and d > wrong_bay_occupied_mm[bay] + WRONG_BAY_REMOVE_MARGIN_MM
                         and d > MEDICINE_THRESHOLD)

        if wrong_bay_armed[bay] and looks_removed:
            wrong_bay_remove_readings[bay] += 1
            if wrong_bay_remove_readings[bay] >= WRONG_BAY_CONFIRM_READINGS:
                if not wrong_bay_pending[bay]:
                    wrong_bay_pending[bay] = True
                    wrong_bay_pending_start[bay] = clock
                    log(f"Unexpected removal detected on S{bay + 1}; "
                        f"warning in {WRONG_BAY_DELAY_S:g}s if it stays out.")
                if clock - wrong_bay_pending_start[bay] >= WRONG_BAY_DELAY_S:
                    wrong_bay_rest_mm = wrong_bay_occupied_mm[bay]
                    wrong_bay_return_readings = 0
                    reset_wrong_bay_state(bay)
                    return bay
        else:
            clear_wrong_bay_removal(bay)
            if valid and d < wrong_bay_occupied_mm[bay]:
                wrong_bay_occupied_mm[bay] = (
                    wrong_bay_occupied_mm[bay] * 7 + d) // 8
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
    global emergency_remove_readings, emergency_remove_start, display_state
    global last_reminder_republish, message_start

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
        if removed:
            if emergency_remove_readings == 0:
                emergency_remove_start = time.time()
            emergency_remove_readings += 1
        else:
            emergency_remove_readings = 0

        if (emergency_remove_readings >= REQUIRED_TAKEN_READINGS
                and time.time() - emergency_remove_start >= EMERGENCY_REMOVE_CONFIRM_S):
            emergency_triggered = True
            emergency_remove_readings = 0
            emergency_closer_readings = 0
            display_state = EMERGENCY_TAKEN
            message_start = time.time()
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
def start_reminder(client, slot):
    global active_reminder, display_state, reminder_start, last_reminder_republish
    global taken_reading_count, bay_seen_occupied, pickup_invalid_since
    global sched_rest_mm

    sensor = dose_sensor[slot]
    active_reminder = slot
    dose_triggered[slot] = True
    display_state = MEDICINE_REMINDER
    taken_reading_count = 0

    # Snapshot the scheduled bay's learned baseline and seed occupancy from
    # the live reading (firmware does exactly this at reminder start).
    sched_rest_mm = (wrong_bay_occupied_mm[sensor]
                     if 0 <= sensor < 6 else -1)
    d_now = get_sensor_distance(sensor)
    bay_seen_occupied = (is_sensor_ok(sensor) and is_valid_distance(d_now)
                         and bay_looks_present(sensor, d_now, True))
    if bay_seen_occupied and (sched_rest_mm <= 0 or d_now < sched_rest_mm):
        sched_rest_mm = d_now
    pickup_invalid_since = 0.0

    reminder_start = time.time()
    last_reminder_republish = reminder_start
    set_buzzer_mode("normal")
    publish_event(client, "reminder_started", sensor + 1)
    log(f"[ALARM] REMINDER -> SENSOR {sensor + 1} TAKE MEDICINE")


def maybe_start_reminder(client, now):
    if active_reminder != -1 or display_state != MAIN_SCREEN:
        return

    for i in range(6):
        if not is_dose_due(i, now):
            continue
        start_reminder(client, i)
        break  # firmware rings just one alarm at a time


def run_medicine_reminder(client, now):
    global display_state, last_reminder_republish, taken_reading_count
    global message_start, wrong_bay_sensor, wrong_bay_rest_mm
    global wrong_bay_return_readings

    sensor = dose_sensor[active_reminder]
    elapsed = time.time() - reminder_start

    # Re-publish so a phone that missed (or was killed during) the first
    # event rings again.
    if (time.time() - last_reminder_republish >= REMINDER_REPUBLISH_S
            and elapsed < REMINDER_REPUBLISH_UNTIL_S):
        last_reminder_republish = time.time()
        publish_event(client, "reminder_started", sensor + 1)

    if update_pickup_state(sensor):
        set_buzzer_mode("off")

        # Disarm this bay's wrong-dose detector after a confirmed pickup.
        if 0 <= sensor < 6:
            reset_wrong_bay_state(sensor)

        # A wrong-bay warning outstanding for THIS bay is resolved by taking
        # the correct dose; tell the phone so it clears too.
        if wrong_bay_sensor == sensor:
            publish_event(client, "wrong_bay_returned", sensor + 1)
            wrong_bay_sensor = -1
            wrong_bay_rest_mm = -1
            wrong_bay_return_readings = 0

        dose_taken_today[active_reminder] = True
        display_state = MEDICINE_TAKEN
        message_start = time.time()
        taken_reading_count = 0
        publish_event(client, "taken", sensor + 1)
        log(f"SENSOR {sensor + 1} -> MEDICINE TAKEN")
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
# WRONG_DOSE_ALERT state
# ======================================================
def run_wrong_bay_alert(client, now):
    global display_state, wrong_bay_sensor, wrong_alert_return_state
    global taken_reading_count, message_start
    set_buzzer_mode("wrong")

    # Taking the RIGHT medicine must not be blocked by the warning: keep
    # evaluating the interrupted reminder's pickup with the shared helper.
    if 0 <= active_reminder < 6:
        sensor = dose_sensor[active_reminder]
        if update_pickup_state(sensor):
            returned_bay = wrong_bay_sensor
            if returned_bay >= 0:
                publish_event(client, "wrong_bay_returned", returned_bay + 1)
            end_wrong_bay_alert()
            set_buzzer_mode("off")
            if 0 <= sensor < 6:
                reset_wrong_bay_state(sensor)
            dose_taken_today[active_reminder] = True
            display_state = MEDICINE_TAKEN
            message_start = time.time()
            taken_reading_count = 0
            publish_event(client, "taken", sensor + 1)
            log(f"SENSOR {sensor + 1} -> MEDICINE TAKEN "
                "(during wrong-bay warning)")
            return

    # SAFETY timeout only. wrongBaySensor deliberately stays set so return
    # detection (and the phone alarm) keeps running until the container is
    # back or a caregiver stops it.
    if time.time() - wrong_alert_start >= WRONG_BAY_ALERT_S:
        set_buzzer_mode("normal" if wrong_alert_return_state == MEDICINE_REMINDER else "off")
        display_state = wrong_alert_return_state
        wrong_alert_return_state = MAIN_SCREEN
        log("Wrong-bay warning timed out - waiting for container return")


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
        prev_sensor = dose_sensor[i]
        prev_hour = dose_hour[i]
        prev_minute = dose_minute[i]
        prev_enabled = dose_enabled[i]

        slot = data[i] if i < len(data) else None
        if slot is None:
            dose_enabled[i] = False
        else:
            # App sends bay 1..6 -> store 0-based, exactly like the firmware.
            dose_sensor[i] = slot.get("sensor_number", i + 1) - 1
            dose_hour[i] = slot.get("hour", 12)
            dose_minute[i] = slot.get("minute", 0)
            dose_enabled[i] = slot.get("enabled", False)

        # Anything out of range would light no LED and can never confirm.
        if not (0 <= dose_sensor[i] <= 5):
            dose_sensor[i] = prev_sensor
        if not (0 <= dose_sensor[i] <= 5):
            dose_sensor[i] = i
        if not (0 <= dose_hour[i] <= 23):
            dose_hour[i] = prev_hour
        if not (0 <= dose_minute[i] <= 59):
            dose_minute[i] = prev_minute

        # Only a genuine edit re-arms the slot; a reconnect republishing the
        # same schedule must not make a taken/stopped dose ring again.
        changed = (dose_sensor[i] != prev_sensor
                   or dose_hour[i] != prev_hour
                   or dose_minute[i] != prev_minute
                   or dose_enabled[i] != prev_enabled)
        if changed:
            dose_triggered[i] = False

    log("Schedule updated via MQTT")
    for i in range(6):
        log(f"  Slot {i}: S{dose_sensor[i] + 1} "
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
            json.dump({"slots": [{"slot": i, **{k: (dose_sensor[i] + 1 if k == "sensor_number"
                                                      else dose_hour[i] if k == "hour"
                                                      else dose_minute[i] if k == "minute"
                                                      else dose_enabled[i])
                                                for k in ("sensor_number", "hour", "minute", "enabled")}}
                                 for i in range(6)]}, f, indent=2)
        log("Saved to schedule_received.json")
    except Exception as e:
        log(f"could not save schedule: {e}")


def handle_time_set(text):
    """The simulator runs on the PC's local wall clock, so the app's timezone
    offset has no effect on dosing here - validate/log it for parity."""
    try:
        data = json.loads(text)
    except Exception as e:
        log(f"JSON parse error: {e}")
        return
    new_offset = data.get("tz_offset_minutes")
    if new_offset is None:
        return
    try:
        new_offset = int(new_offset)
    except (TypeError, ValueError):
        return
    if not (-12 * 60 <= new_offset <= 14 * 60):
        log(f"Ignoring implausible tz offset: {new_offset}")
        return
    log(f"Timezone offset set by app -> UTC{new_offset / 60:+.1f} "
        "(simulator clock is PC local time)")


def handle_alarm_stop(client):
    global display_state, active_reminder, emergency_triggered
    global taken_reading_count, emergency_return_readings, bay_seen_occupied
    global wrong_bay_sensor, wrong_bay_rest_mm, wrong_bay_return_readings

    if display_state == WRONG_DOSE_ALERT:
        log("Wrong-bay warning stopped by caregiver")
        stopped_bay = wrong_bay_sensor
        set_buzzer_mode("off")
        if stopped_bay >= 0:
            publish_event(client, "caregiver_stopped", stopped_bay + 1)
        wrong_bay_sensor = -1
        wrong_bay_rest_mm = -1
        wrong_bay_return_readings = 0
        # A reminder the warning interrupted stays stopped too.
        display_state = MAIN_SCREEN
        active_reminder = -1
        return

    if display_state not in (MEDICINE_REMINDER, EMERGENCY_TAKEN):
        return

    # activeReminder is -1 during an emergency, so never index with it.
    stopped_bay = (dose_sensor[active_reminder] + 1
                   if 0 <= active_reminder < 6 else 7)
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
    if not (0 <= slot < 6):
        log("slot must be 1..6")
        return
    if active_reminder != -1 or display_state != MAIN_SCREEN:
        log("reminder ignored - another alarm/screen is active")
        return
    sensor = dose_sensor[slot]
    start_reminder(client, slot)
    log(f"[ALARM] manual reminder -> S{sensor + 1}")


# ======================================================
# DEVICE LOOP - the firmware's loop(), single threaded
# ======================================================
def device_loop(client):
    global wrong_bay_sensor, wrong_bay_rest_mm, wrong_bay_return_readings
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
                elif topic == TOPIC_TIME_SET:
                    handle_time_set(text)
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
            bay = detect_wrong_bay(now)
            if bay >= 0:
                start_wrong_bay_alert(client, bay)

        # --- wrong-bay container returned (runs in EVERY state) ------------
        # Including after the safety timeout silenced the buzzer: the phone
        # alarm keeps ringing until the container is back.
        if wrong_bay_sensor >= 0:
            if wrong_bay_looks_present_now():
                wrong_bay_return_readings += 1
                if wrong_bay_return_readings >= WRONG_BAY_RETURN_CONFIRM:
                    publish_event(client, "wrong_bay_returned",
                                  wrong_bay_sensor + 1)
                    log(f"Wrong-bay container returned to S{wrong_bay_sensor + 1}")
                    if display_state == WRONG_DOSE_ALERT:
                        end_wrong_bay_alert()
                    else:
                        wrong_bay_sensor = -1
                        wrong_bay_rest_mm = -1
                        wrong_bay_return_readings = 0
            else:
                wrong_bay_return_readings = 0

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

import datetime
import json
import os
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

STATUS_INTERVAL_S = 30

# ======================================================
# DOSE SCHEDULE (6 slots, mirrors firmware defaults)
# ======================================================
dose = [
    {"sensor_number": 1, "hour": 8, "minute": 0, "enabled": True},
    {"sensor_number": 2, "hour": 10, "minute": 0, "enabled": True},
    {"sensor_number": 3, "hour": 12, "minute": 0, "enabled": True},
    {"sensor_number": 4, "hour": 14, "minute": 0, "enabled": True},
    {"sensor_number": 5, "hour": 16, "minute": 0, "enabled": True},
    {"sensor_number": 6, "hour": 20, "minute": 0, "enabled": True},
]

temperature = 26.4
humidity = 55.0
connected = threading.Event()

active_alarm = None  # {"sensor_number": int} while buzzer is ringing
fired_keys = set()  # (slot_index, "HH:MM") already fired today


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ======================================================
# BUZZER (PC speaker stand-in for the ESP32 piezo)
# ======================================================
def beep(duration_ms=600, frequency=880):
    if winsound is None:
        return
    try:
        winsound.Beep(frequency, duration_ms)
    except Exception as e:
        log(f"beep failed: {e}")


def ring_alarm():
    for _ in range(3):
        beep(350, 1046)
        time.sleep(0.08)
    beep(900, 880)


def beep_tick():
    beep(150, 1320)


def stop_alarm_if_any(reason):
    global active_alarm
    if active_alarm is not None:
        log(f"Alarm stopped ({reason})")
        active_alarm = None


def publish_status(client):
    payload = {
        "device_id": DEVICE_ID,
        "temperature": round(temperature + (time.time() % 3) / 10, 1),
        "humidity": round(humidity + (time.time() % 5) / 10, 1),
        "timestamp": int(time.time()),
    }
    try:
        client.publish(TOPIC_STATUS, json.dumps(payload), qos=0, retain=False)
        log(f"MQTT -> [{TOPIC_STATUS}] {json.dumps(payload)}")
    except Exception as e:
        log(f"publish status failed: {e}")


def publish_event(client, event_type, sensor_number, ring=False):
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
    if ring:
        ring_alarm()
        log(f"[BUZZER] ALARM ringing for sensor {sensor_number}")


def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code == 0:
        log("MQTT connected!")
        client.subscribe(TOPIC_SCHEDULE_SET, qos=1)
        client.subscribe(TOPIC_ALARM_STOP, qos=1)
        log(f"Subscribed to: {TOPIC_SCHEDULE_SET}")
        log(f"Subscribed to: {TOPIC_ALARM_STOP}")
        connected.set()
    else:
        log(f"MQTT connect failed, rc={reason_code}")


def on_disconnect(client, userdata, flags, reason_code, properties):
    log(f"MQTT disconnected (rc={reason_code}) - will auto-reconnect")


def on_message(client, userdata, message):
    topic = message.topic
    text = message.payload.decode("utf-8", errors="replace")
    log(f"MQTT <- [{topic}] {text}")

    if topic == TOPIC_SCHEDULE_SET:
        try:
            data = json.loads(text)
            if isinstance(data, list):
                for i in range(6):
                    slot = data[i] if i < len(data) else None
                    if slot is None:
                        dose[i]["enabled"] = False
                        continue
                    dose[i]["sensor_number"] = slot.get("sensor_number", i + 1)
                    dose[i]["hour"] = slot.get("hour", 12)
                    dose[i]["minute"] = slot.get("minute", 0)
                    dose[i]["enabled"] = slot.get("enabled", False)
                log("Schedule updated via MQTT")
                for i, s in enumerate(dose):
                    log(
                        f"  Slot {i}: S{s['sensor_number']} "
                        f"{s['hour']:02d}:{s['minute']:02d} "
                        f"{'ON' if s['enabled'] else 'OFF'}"
                    )
                with open("schedule_received.json", "w") as f:
                    json.dump({"slots": [dict(s, slot=i) for i, s in enumerate(dose)]}, f, indent=2)
                log("Saved to schedule_received.json")
                fired_keys.clear()  # allow re-test: a fresh schedule can re-trigger
        except Exception as e:
            log(f"JSON parse error: {e}")
    elif topic == TOPIC_ALARM_STOP:
        stop_alarm_if_any("alarm/stop received")


def status_loop(client):
    while True:
        connected.wait()
        publish_status(client)
        time.sleep(STATUS_INTERVAL_S)


def alarm_loop(client):
    """Firmware behavior: when local time matches an enabled slot,
    sound the buzzer and publish reminder_started until 'taken' or alarm/stop."""
    global active_alarm
    while True:
        connected.wait()
        now = datetime.datetime.now()

        for i, s in enumerate(dose):
            if not s["enabled"]:
                continue
            key = (i, f"{s['hour']:02d}:{s['minute']:02d}")
            if (now.hour, now.minute) == (s["hour"], s["minute"]) and key not in fired_keys:
                fired_keys.add(key)
                sensor = s["sensor_number"]
                active_alarm = {"sensor_number": sensor}
                log(f"[ALARM] {now:%H:%M:%S} matches schedule: S{sensor} fired")
                publish_event(client, "reminder_started", sensor, ring=True)

        if active_alarm is not None:
            beep_tick()

        time.sleep(5)


CMDFILE = "virtual_device_cmd.txt"


def handle_command(client, line):
    parts = line.split()
    if not parts:
        return True
    cmd = parts[0]
    if cmd == "reminder" and len(parts) > 1:
        slot = int(parts[1])
        if 1 <= slot <= 6:
            active_alarm = {"sensor_number": dose[slot - 1]["sensor_number"]}
            publish_event(client, "reminder_started", active_alarm["sensor_number"], ring=True)
        else:
            log("slot must be 1..6")
        return True
    if cmd == "taken" and len(parts) > 1:
        slot = int(parts[1])
        if 1 <= slot <= 6:
            stop_alarm_if_any(f"taken {slot}")
            publish_event(client, "taken", dose[slot - 1]["sensor_number"])
        else:
            log("slot must be 1..6")
        return True
    if cmd == "emergency":
        stop_alarm_if_any("emergency")
        publish_event(client, "emergency_taken", 7, ring=True)
        return True
    if cmd == "status":
        publish_status(client)
        return True
    if cmd in ("quit", "exit"):
        return False
    log("Unknown command. Use: reminder <1-6> | taken <1-6> | emergency | status | quit")
    return True


def interactive_loop(client):
    log("Commands: reminder <1-6> | taken <1-6> | emergency | status | quit")
    log(f"Tip: you can also put commands in {CMDFILE} (one per line) - auto-read.")
    while True:
        try:
            line = input("> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            log("Interactive input closed; staying alive in file mode.")
            return
        if not handle_command(client, line):
            return


def file_command_loop(client):
    while True:
        try:
            with open(CMDFILE) as f:
                lines = f.read().splitlines()
            os.remove(CMDFILE)
            for line in lines:
                line = line.strip().lower()
                if line:
                    log(f"cmd-file -> {line}")
                    if not handle_command(client, line):
                        return
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

    t = threading.Thread(target=status_loop, args=(client,), daemon=True)
    t.start()
    at = threading.Thread(target=alarm_loop, args=(client,), daemon=True)
    at.start()
    ft = threading.Thread(target=file_command_loop, args=(client,), daemon=True)
    ft.start()

    log("====================")
    log(f"  CARE CUBE VIRTUAL DEVICE ({DEVICE_ID}) READY")
    log("====================")
    log(f"  Schedule: {TOPIC_SCHEDULE_SET}")
    log(f"  Status:   {TOPIC_STATUS}")
    log(f"  Event:    {TOPIC_EVENT}")
    log(f"  Alarm:    {TOPIC_ALARM_STOP}")

    try:
        il = threading.Thread(target=interactive_loop, args=(client,), daemon=True)
        il.start()
        log(f"Drop commands in {CMDFILE} (one per line) to fire events")
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
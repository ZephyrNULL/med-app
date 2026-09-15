import json
import math
import time

import paho.mqtt.client as mqtt

BROKER = "15eb54ef85ce471890ec2a12019e88b4.s1.eu.hivemq.cloud"
PORT = 8883
USER = "CareCube12"
PASS = "CareCube@2006"
DEVICE_IDS = ["carecube-001", "caregh"]

client = mqtt.Client()
client.username_pw_set(USER, PASS)
client.tls_set()
client.connect(BROKER, PORT, 60)
client.loop_start()

n = 0
while True:
    t = time.time()
    temp = 24.0 + 2.5 * math.sin(t / 40.0) + 0.3 * math.sin(t / 6.0)
    hum = 40.0 + 6.0 * math.sin(t / 55.0 + 1.2) + 0.8 * math.sin(t / 9.0)
    payload = json.dumps(
        {
            "device_id": "carecube-001",
            "temperature": round(temp, 1),
            "humidity": round(hum, 1),
            "timestamp": int(t),
        }
    )
    for d in DEVICE_IDS:
        topic = f"carecube/{d}/status"
        client.publish(topic, payload, qos=1)
        print(f"{time.strftime('%H:%M:%S')} {topic} {payload}", flush=True)
    n += 1
    time.sleep(5)
    if n % 120 == 0:
        client.loop_stop()
        client.connect(BROKER, PORT, 60)
        client.loop_start()
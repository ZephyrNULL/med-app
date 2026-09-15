import paho.mqtt.client as mqtt
import sys
import json
import time

BROKER = "15eb54ef85ce471890ec2a12019e88b4.s1.eu.hivemq.cloud"
PORT = 8883
USER = "CareCube12"
PASS = "CareCube@2006"
TOPICS = ["carecube/carecube-001/status", "carecube/caregh/status", "carecube/carecube-001/event", "carecube/caregh/event"]

seen = []

def on_connect(client, userdata, flags, rc):
    print(f"subscriber connected rc={rc}", flush=True)
    for t in TOPICS:
        client.subscribe(t)

def on_message(client, userdata, msg):
    line = f"{time.strftime('%H:%M:%S')} {msg.topic} {msg.payload.decode()}"
    print(line, flush=True)
    seen.append(line)

client = mqtt.Client()
client.username_pw_set(USER, PASS)
client.tls_set()
client.on_connect = on_connect
client.on_message = on_message
client.connect(BROKER, PORT, 60)
client.loop_start()
time.sleep(int(sys.argv[1]))
client.loop_stop()
print(f"TOTAL={len(seen)}")
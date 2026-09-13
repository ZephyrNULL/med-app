# Care Cube — Velxio simulation project

`care-cube.vlx` is a ready-to-import project for [velxio.dev](https://velxio.dev)
(Wokwi-based free browser simulator). Open it and the **full Care Cube circuit
arrives already wired and with the sketch loaded — no manual assembly needed.**

## How to use

1. Go to https://velxio.dev (free, no account needed).
2. Use **Import** in the toolbar and pick `care-cube.vlx`.
3. Hit **Run**. The board compiles as `esp32:esp32:esp32` (ESP32 DevKit C V4).

## What's in the circuit

| Part | Role |
| --- | --- |
| ESP32 DevKit C V4 (`esp32-devkit-c-v4`) | Main board, `esp32:esp32:esp32` FQBN |
| LCD 20x4 I2C (`lcd2004-i2c`) | Care Cube display, PCF8574 backpack @ `0x27`, on GPIO21/22 |
| DS1307 (`ds1307`) | RTC on the same I2C bus (sim reports browser time) |
| DHT22 (`dht22`) | Temp/humidity on GPIO16 |
| Buzzer (`buzzer`) | Alarm on GPIO2 |
| 7x resistor 330 Ω (`resistor`) | Series LED current limiters, GPIO → LED anode |
| 7x LED (`led`) | Dose slots + emergency on GPIO4/12/19/18/23/13/15 |

Plus all 34 wires (I2C bus, GPIO lines, power `3V3`/`5V`/`GND.1`). Each LED is
fed through its own 330 Ω resistor — without those, Velxio's SPICE solver reports
an LED over-current error (the diode model computes an unbounded current from a
raw GPIO drive).

## Wiring (matches the production firmware)

- I2C SDA=GPIO21, SCL=GPIO22 → LCD (0x27) + DS1307 (0x68)
- DHT22 data → GPIO16
- Buzzer → GPIO2
- LEDs → GPIO4, 12, 19, 18, 23, 13, 15

## Known limitations (because Velxio has no VL53L0X or RFID)

- The 7x VL53L0X distance sensors **cannot be simulated** — the sketch skips them
  gracefully (`Sensor N NOT FOUND`). Dose reminders still fire on schedule and the
  LCD/LED/buzzer all animate, but "medicine taken" detection (needs a distance
  reading above the threshold) and the emergency trigger won't complete remotely.
- MQTT connects to Velxio's emulated WiFi (the compiler rewrites the SSID), but a
  real HiveMQ TLS connection (port 8883) is not available inside the simulator, so
  `M:` shows `N`. The rest of the box runs normally on the sim clock.
- The `cirkit/sketch.ino` WiFi/MQTT code is embedded as `sketch.ino`; edit it in
  the Velxio editor and re-Run to experiment.

## Regenerating

`care-cube.vlx` was generated from `wokwi/diagram.json` + `cirkit/sketch.ino`
(Velxio board pins use bare GPIO names, so `D21`→`21`, `D16`→`16`, etc.; the LCD
is the `lcd2004-i2c` part so the PCF8574 @ 0x27 protocol is simulated). The seven
330 Ω LED resistors were added because Velxio runs a SPICE over-current check on
LEDs, and the source `wokwi/diagram.json` drives them straight from GPIO.
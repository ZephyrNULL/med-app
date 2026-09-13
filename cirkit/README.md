# Care Cube in Cirkit Designer (ESP32-S3)

Full-care-cube circuit simulated in Cirkit Designer, publishing to the **same
HiveMQ Cloud broker** the mobile app subscribes to. When the simulator runs,
open the app on your phone -> Home tab and the temperature/humidity cards
update every ~30 seconds.

- Sketch: `cirkit/sketch.ino` (paste into Cirkit's Code tab)
- Ported from the existing Wokwi demo (`wokwi/`), which connects to the same
  broker. The only changes: WiFi AP is Cirkit's `CirkitWifi`, MQTT client id is
  `carecube-001-cirkit` (so it won't collide with the Wokwi sim).

> **Note: no file-import in Cirkit.** Cirkit projects are stored in the cloud
> (id: `app.cirkitdesigner.com/project/<uuid>`) and there is currently no way to
> import a circuit from a local file or an API. The circuit parts + wiring below
> must be assembled once, manually, on the canvas (about 5 minutes — everything
> shares 2 nets). The sketch is the only file "pasted in'; it goes into the
> Code tab. Afterwards you can copy the whole project (menu: Share -> copy) to
> reuse it anywhere.

---

## 1. Create the project

1. Open https://app.cirkitdesigner.com (browser, desktop recommended).
2. New circuit -> pick the **ESP32-S3** dev board (only S3 is simulated).

## 2. Place these parts

| Part | Qty | Cirkit component |
|---|---|---|
| ESP32-S3 Dev Board | 1 | `ESP32-S3` |
| DHT22 temp/humidity | 1 | `DHT22` |
| LCD 20x4 (I2C) | 1 | LCD 2004 with I2C interface |
| DS1307 RTC | 1 | `DS1307` |
| Buzzer | 1 | Buzzer (PWM) |
| LEDs | 7 | any color LEDs |
| VL53L0X distance | 7 | `VL53L0X` |

## 3. Wiring

All I2C parts share the same SDA/SCL bus. GPIO numbers are straight from the
production firmware (`firmware/CareCube_ESP32_Firmware_v2`).

**Power:**
| Part pin | ESP32-S3 pin |
|---|---|
| DHT22 VCC / all VL53L0X VIN / LCD VCC / DS1307 VCC | 3V3 |
| All GND | GND |

**I2C bus (shared):**
| Part pin | ESP32-S3 pin |
|---|---|
| LCD SDA, DS1307 SDA, VL53L0X SDA (x7) | GPIO21 (SDA) |
| LCD SCL, DS1307 SCL, VL53L0X SCL (x7) | GPIO22 (SCL) |

**DHT22:**
| DHT22 | GPIO16 |

**VL53L0X XSHUT (1 pin each, enables the 7-way I2C addressing):**
| Sensor | XSHUT -> GPIO |
|---|---|
| VL53L0X #1 | 25 |
| VL53L0X #2 | 26 |
| VL53L0X #3 | 27 |
| VL53L0X #4 | 32 |
| VL53L0X #5 | 33 |
| VL53L0X #6 | 14 |
| VL53L0X #7 (emergency) | 5 |

**LEDs (anode -> GPIO, cathode -> GND):**
| LED | GPIO |
|---|---|
| LED 1 (red) | 4 |
| LED 2 (orange) | 12 |
| LED 3 (yellow) | 19 |
| LED 4 (green) | 18 |
| LED 5 (blue) | 23 |
| LED 6 (purple) | 13 |
| LED 7 (red) | 15 |

**Buzzer:**
| Buzzer + | GPIO2 |
| Buzzer - | GND |

## 4. Load the code

1. Open the **Code** tab (it targets the ESP32-S3).
2. Delete the default sketch and paste the full contents of
   `cirkit/sketch.ino`.
3. Hit **Run / Start simulation**.

## 5. What should happen

- Serial console: `WiFi connected!` then `Connecting to MQTT... connected!`.
- LCD shows time, `W:Y M:Y`, and live `T:` / `H:` values.
- Every 30 seconds the console prints:
  `MQTT -> [carecube/carecube-001/status] {"device_id":"carecube-001","temperature":...,"humidity":...,"timestamp":...}`
- Drag the DHT22 value slider in the simulator; the next status publish carries
  the new temperature/humidity.

## 6. Verify in the mobile app

1. Run the app on your phone (or emulator).
2. Sign in as an elder/caregiver -> Home tab.
3. The **Connection status card** should flip to connected.
4. The **Temperature** and **Humidity** cards update within ~30s and when the
   DHT22 slider moves.
5. Edit a dose time in the Medicine tab -> the app publishes
   `carecube/carecube-001/schedule/set`; watch the sketch's console log the
   updated schedule.

## 7. Troubleshooting

- **MQTT connect fails (`failed, rc=...`)**: HiveMQ Cloud needs TLS on 8883.
  `setInsecure()` is already used. If Cirkit's TLS handling has trouble,
  first confirm the project still has internet by trying Cirkit's official
  "MQTT Temperature Monitor" example. The broker account, topics and device id
  must match `lib/config/app_config.dart`.
- **Client id collision**: only one client can use `carecube-001-cirkit`. Stop
  the Wokwi sim (or this sim) if messages stop arriving. Change
  `MQTT_CLIENT_ID` in the sketch to a new suffix if needed.
- **VL53L0X sensors show `NOT FOUND - skipping`**: fine. Cirkit's distance
  values may not be interactive; the sim still streams temp/humidity and dose
  schedule updates. The distance sensors are only needed to demo "medicine
  taken" / emergency detection.
- **RTC NOT FOUND**: the sketch falls back to the sim clock, so dose timers
  still work.
- **No temperature change in app**: confirm the MQTT status topic prints in the
  console, and that the app is connected to the same broker/device
  (`carecube-001`). Check the app's Home tab connection card.
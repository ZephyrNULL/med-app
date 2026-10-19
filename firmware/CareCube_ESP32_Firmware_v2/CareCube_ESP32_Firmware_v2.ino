#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <WiFiManager.h>
#include <Preferences.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <VL53L0X.h>
#include <RTClib.h>
#include <DHT.h>
#include <ArduinoJson.h>
#include <time.h>

// ======================================================
// WIFI PROVISIONING - NO HARDCODED CREDENTIALS
// ======================================================
// Every box leaves the factory with the SAME firmware, so end users
// never need a PC to flash in their WiFi. Instead:
//
//   1. First boot (or factory reset) -> the box starts its own WiFi
//      access point named "CareCube-Setup".
//   2. Join that WiFi from your phone and open http://192.168.4.1 .
//   3. Enter your WiFi SSID + password and this unit's device id
//      (printed on the bottom of the box).
//   4. All settings are stored in NVS (Preferences). The box reboots,
//      joins your WiFi and connects to the MQTT broker by itself.
//
// FACTORY RESET: hold the SETUP button (GPIO0) while powering on and
// keep it held ~3 seconds. The box clears all settings and re-enters
// the setup portal on the next boot.
#define SETUP_BUTTON 0
#define DEFAULT_DEVICE_ID "carecube-001"

String wifiSsid = "";   // loaded from Preferences
String wifiPass = "";   // loaded from Preferences
String deviceId = DEFAULT_DEVICE_ID; // set via the setup portal
Preferences prefs;

// ======================================================
// MQTT BROKER (HiveMQ Cloud)
// ======================================================
const char* MQTT_BROKER   = "15eb54ef85ce471890ec2a12019e88b4.s1.eu.hivemq.cloud";
const int   MQTT_PORT     = 8883;
const char* MQTT_USERNAME = "CareCube12";
const char* MQTT_PASSWORD = "CareCube@2006";

// ======================================================
// MQTT TOPICS
// ======================================================
String topicScheduleSet;
String topicStatus;
String topicEvent;
String topicAlarmStop;

// ======================================================
// OBJECTS
// ======================================================
WiFiClientSecure wifiClient;
PubSubClient     mqttClient(wifiClient);
LiquidCrystal_I2C lcd(0x27, 20, 4);
RTC_DS3231   rtc;
DHT          dht(16, DHT22);

VL53L0X sensor1;
VL53L0X sensor2;
VL53L0X sensor3;
VL53L0X sensor4;
VL53L0X sensor5;
VL53L0X sensor6;
VL53L0X sensor7;

// ======================================================
// XSHUT PINS
// ======================================================
#define XSHUT_1 25
#define XSHUT_2 26
#define XSHUT_3 27
#define XSHUT_4 32
#define XSHUT_5 33
#define XSHUT_6 14
#define XSHUT_7 5

// ======================================================
// LED PINS
// ======================================================
#define LED_1 4
#define LED_2 12
#define LED_3 19
#define LED_4 18
#define LED_5 23
#define LED_6 13
#define LED_7 15

// ======================================================
// BUZZER
// ======================================================
// GPIO2 is a boot-strapping pin: it MUST be low while the chip resets.
// Leave the wire alone unless your board drives the buzzer through a
// transistor. Flip the two switches below to match your hardware:
//   BUZZER_ACTIVE_LOW  1 = transistor / active-low module (HIGH = off)
//   BUZZER_PASSIVE     1 = self-driving piezo element needs a tone, not DC
#define BUZZER 2
#define BUZZER_ACTIVE_LOW 0
#define BUZZER_PASSIVE 1
#define BUZZER_TONE_HZ 2200

// ======================================================
// MEDICINE DISTANCE THRESHOLD
// ======================================================
// A dose counts as "taken" only when the bay reads FARTHER than this.
#define MEDICINE_THRESHOLD 90

// VL53L0X returns -1 on timeout and saturates at 8190mm. Anything outside
// this range is a glitch, NOT a real measurement - treating it as a real
// one is what made the box report "MEDICINE TAKEN" on its own.
#define SENSOR_MIN_VALID_MM 10
#define SENSOR_MAX_VALID_MM 2000

// ======================================================
// REMINDER CONFIRMATION TIMING
// ======================================================
// The buzzer must ring for this long before a pickup can be confirmed, and
// the bay must have been seen holding a dose first - otherwise a single
// bad sample silences the alarm on its own.
const unsigned long TAKEN_MIN_ELAPSED      = 0UL; // Stop the reminder as soon as the scheduled bay pickup is confirmed
const unsigned long TAKEN_EMPTY_BAY_GRACE  = 90000UL;
const int           REQUIRED_TAKEN_READINGS = 3;

// How late a dose may still fire. Absorbs loop jitter (the full sensor
// sweep can take seconds) and a reboot/boot inside the dose window.
const unsigned long REMINDER_CATCHUP_MS = 10UL * 60UL * 1000UL;

// Re-publish the reminder while it is still ringing so the phone rings
// again even if it missed (or was killed during) the first event.
const unsigned long REMINDER_REPUBLISH_MS = 30000UL;
const unsigned long REMINDER_REPUBLISH_UNTIL_MS = 15UL * 60UL * 1000UL;

// ======================================================
// DOSE SCHEDULE (6 slots)
// ======================================================
int doseSensor[6]  = {2, 4, 6, 1, 3, 5}; // Activation order: S2, S4, S6, S1, S3, S5
int doseHour[6]    = {8, 10, 12, 14, 16, 20};
int doseMinute[6]  = {0, 0, 0, 0, 0, 0};
bool doseEnabled[6] = {true, true, true, true, true, true};
bool doseTriggered[6] = {false, false, false, false, false, false};

// ======================================================
// EMERGENCY SLOT
// ======================================================
const int EMERGENCY_SLOT = 6;

// ======================================================
// EMERGENCY BAY PRESENCE (S7)
// ======================================================
// The emergency compartment is detected as "removed" by comparing S7 to the
// bay's OWN learned resting distance, not to a fixed millimetre value. This
// is what makes it work regardless of how the compartment is mounted: a bay
// resting at 40mm and one resting at 120mm are both handled, because only the
// CHANGE matters. The old rule ("previous <= 90 AND current > 90") also broke
// whenever lifting the compartment made the sensor lose its target entirely
// and report out-of-range (-1 / 8190), which is not a "valid" reading at all.
//
//   removed  = S7 reports no target in range (out-of-range / timeout) OR a
//              valid reading has risen more than EMERGENCY_REMOVE_MARGIN_MM
//              above the resting distance
//   present  = a valid reading within EMERGENCY_REMOVE_MARGIN_MM of rest
//
// The resting distance is learned as the closest sustained reading, so
// booting with the compartment already out, then inserting it, still arms the
// detector. A single bad sample can neither move the baseline nor fire the
// alarm: both need consecutive readings.
#define EMERGENCY_REMOVE_MARGIN_MM 20  // mm above rest before "removed"
#define EMERGENCY_CLOSER_HYST_MM   12  // mm closer before a new baseline
#define EMERGENCY_CLOSER_CONFIRM   3   // consecutive reads to accept it

// ======================================================
// DAILY DOSE FLAGS
// ======================================================
int activeReminder = -1;

// Monotonic day stamp (yyyy*10000 + mm*100 + dd) of the day the
// doseTriggered[] flags belong to. Rolling over on a *change* of day
// (rather than at exactly 00:00:00) means one slow loop iteration can no
// longer disable every reminder for the rest of the day.
int currentDayStamp = -1;

// Tracking state for the running reminder.
unsigned long reminderStartTime = 0;
unsigned long lastReminderRepublish = 0;
int takenReadingCount = 0;
bool baySeenOccupied = false;

// Debounce counter for the emergency container being placed back (S7 <=
// threshold). An emergency alarm is only cleared by that, never by a timer.
int emergencyReturnReadings = 0;

// ======================================================
// BUZZER STATE
// ======================================================
bool buzzerActive = false;
unsigned long lastBuzzerToggle = 0;
enum BuzzerMode { BUZZER_MODE_OFF, BUZZER_MODE_NORMAL_DOSE, BUZZER_MODE_EMERGENCY, BUZZER_MODE_WRONG_BAY };
BuzzerMode buzzerMode = BUZZER_MODE_OFF;
unsigned long wrongToneCycleStart = 0;
bool wrongBayArmed[6] = {false, false, false, false, false, false};
int wrongBayOccupiedDistance[6] = {-1, -1, -1, -1, -1, -1};
int wrongBayRemoveReadings[6] = {0, 0, 0, 0, 0, 0};
bool wrongBayRemovalPending[6] = {false, false, false, false, false, false};
unsigned long wrongBayRemovalStart[6] = {0, 0, 0, 0, 0, 0};
const unsigned long WRONG_BAY_DELAY_MS = 120000UL; // Wait 2 minutes before warning for an unexpected removal
int wrongBaySensor = -1;
unsigned long wrongAlertStartTime = 0;
const unsigned long WRONG_BAY_ALERT_TIME = 10000UL;

// ======================================================
// DISPLAY STATES
// ======================================================
enum DisplayState {
  MAIN_SCREEN,
  MEDICINE_REMINDER,
  MEDICINE_TAKEN,
  EMERGENCY_TAKEN,
  WRONG_DOSE_ALERT
};

DisplayState displayState = MAIN_SCREEN;
DisplayState wrongAlertReturnState = MAIN_SCREEN;

// ======================================================
// MESSAGE TIMER
// ======================================================
unsigned long messageStartTime = 0;
const unsigned long MEDICINE_MESSAGE_TIME = 30000UL; // Keep MEDICINE TAKEN on screen for 30 seconds

// ======================================================
// SENSOR DISTANCES
// ======================================================
int distance1 = 0;
int distance2 = 0;
int distance3 = 0;
int distance4 = 0;
int distance5 = 0;
int distance6 = 0;
int distance7 = 0;

// A missing/flaky bay must degrade to "never taken", never take the whole
// box offline the way the old `while(1)` did.
bool sensorOk[7] = {false, false, false, false, false, false, false};
bool rtcOk = false;

// ======================================================
// ENVIRONMENT
// ======================================================
float temperature = 0.0;
float humidity = 0.0;
unsigned long lastDHTRead = 0;

// ======================================================
// MQTT PUBLISH TIMER
// ======================================================
unsigned long lastMQTTPublish = 0;
// Heartbeat only: the environment is published every time a fresh DHT sample
// lands (every 2s), so the app and the LCD agree. This slower timer just
// proves the box is alive if the DHT stops producing samples.
//
// Must stay comfortably BELOW the app's box-online window (20s). At 30s a
// DHT hiccup left a >20s gap with no status, so the app flipped the whole
// box to "offline" (hiding readings and silencing the alarm). 15s keeps a
// live box looking online even when the sensor misbehaves.
const unsigned long MQTT_HEARTBEAT_INTERVAL = 15000UL;

// A drifting RTC eventually lands a dose in the wrong minute, which reads
// as a reminder that "never rang". Re-sync every few hours when online.
unsigned long lastClockSync = 0;
const unsigned long CLOCK_SYNC_INTERVAL = 6UL * 60UL * 60UL * 1000UL;

// Local UTC offset used when syncing the clock from NTP.
//
// The app lets the caregiver enter a dose at, say, 08:00 LOCAL time and the
// box fires when its own wall clock reaches 08:00. If the RTC runs on UTC
// the dose fires offset by this many hours, which is exactly the "the box
// rings at the wrong time" symptom on real hardware (the PC simulator uses
// the PC's local clock, so the two only agree when this offset is set).
//
// Default 5*3600 + 30*60 = UTC+05:30 (Sri Lanka). Change for your region.
#define TIMEZONE_OFFSET_SEC (5 * 3600 + 30 * 60)

// ======================================================
// EMERGENCY DETECTION STATE
// ======================================================
bool emergencyTriggered = false;

// Learned resting distance (mm) of the emergency bay while the compartment is
// in place. -1 means "not learned yet" (bay booted empty).
int emergencyRestMm = -1;
// Consecutive confirmations for adopting a CLOSER resting distance and for
// confirming a removal. Kept consecutive so a lone glitch is always ignored.
int emergencyCloserReadings = 0;
int emergencyRemoveReadings = 0;

// ======================================================
// LCD UPDATE TIMER
// ======================================================
unsigned long lastLCDUpdate = 0;

// ======================================================
// BUZZER DRIVER
// ======================================================
// A steady DC level is inaudible on a passive element and easy to miss on
// an active one, so the buzzer is pulsed. This also keeps the GPIO toggling
// so a marginal module gets a clean signal instead of one long level.
// ======================================================
void writeBuzzerLevel(bool on) {
#if BUZZER_ACTIVE_LOW
  digitalWrite(BUZZER, on ? LOW : HIGH);
#else
  digitalWrite(BUZZER, on ? HIGH : LOW);
#endif
}

void buzzerSetup() {
  pinMode(BUZZER, OUTPUT);
  writeBuzzerLevel(false);
  buzzerActive = false;
  buzzerMode = BUZZER_MODE_OFF;
#if BUZZER_PASSIVE
  // ESP32 Arduino Core 3.x uses pin-based LEDC functions.
  ledcAttach(BUZZER, BUZZER_TONE_HZ, 10);
  ledcWrite(BUZZER, 0);
#endif
}

void setBuzzerMode(BuzzerMode mode) {
  if (buzzerMode == mode) return;
  buzzerMode = mode;
  buzzerActive = (mode != BUZZER_MODE_OFF);
  lastBuzzerToggle = millis();
  wrongToneCycleStart = millis();
#if BUZZER_PASSIVE
  if (mode == BUZZER_MODE_OFF) {
    ledcWrite(BUZZER, 0);
    writeBuzzerLevel(false);
  } else if (mode == BUZZER_MODE_NORMAL_DOSE) {
    ledcWriteTone(BUZZER, 2200); ledcWrite(BUZZER, 512);
  } else if (mode == BUZZER_MODE_EMERGENCY) {
    ledcWriteTone(BUZZER, 1200); ledcWrite(BUZZER, 512);
  } else {
    ledcWriteTone(BUZZER, 700); ledcWrite(BUZZER, 512);
  }
#else
  writeBuzzerLevel(mode != BUZZER_MODE_OFF);
#endif
}

void setBuzzer(bool on) {
  setBuzzerMode(on ? BUZZER_MODE_NORMAL_DOSE : BUZZER_MODE_OFF);
}

void serviceBuzzer() {
  if (!buzzerActive || buzzerMode != BUZZER_MODE_WRONG_BAY) return;
  unsigned long phase = (millis() - wrongToneCycleStart) % 1200UL;
#if BUZZER_PASSIVE
  if (phase < 250UL) { ledcWriteTone(BUZZER, 700); ledcWrite(BUZZER, 512); }
  else if (phase < 400UL) { ledcWrite(BUZZER, 0); }
  else if (phase < 650UL) { ledcWriteTone(BUZZER, 1500); ledcWrite(BUZZER, 512); }
  else { ledcWrite(BUZZER, 0); }
#else
  if (phase < 250UL || (phase >= 400UL && phase < 650UL)) writeBuzzerLevel(true);
  else writeBuzzerLevel(false);
#endif
}

// ======================================================
// READING VALIDITY
// ======================================================
bool isValidDistance(int mm) {
  return mm >= SENSOR_MIN_VALID_MM && mm <= SENSOR_MAX_VALID_MM;
}

bool isSensorOk(int sensorNumber) {
  if (sensorNumber < 0 || sensorNumber > 6) return false;
  return sensorOk[sensorNumber];
}

// ======================================================
// CLOCK SOURCE (RTC, falling back to NTP/millis if the RTC is missing)
// ======================================================
DateTime currentDateTime() {
  if (rtcOk) return rtc.now();
  time_t t = time(nullptr);
  if (t > 1700000000UL) {
    return DateTime((uint32_t)t);
  }
  return DateTime(2024, 1, 1, 0, 0, 0);
}

int dayStampOf(const DateTime& dt) {
  return dt.year() * 10000 + dt.month() * 100 + dt.day();
}

// ======================================================
// TURN OFF ALL LEDs
// ======================================================
void turnOffAllLEDs() {
  digitalWrite(LED_1, LOW);
  digitalWrite(LED_2, LOW);
  digitalWrite(LED_3, LOW);
  digitalWrite(LED_4, LOW);
  digitalWrite(LED_5, LOW);
  digitalWrite(LED_6, LOW);
  digitalWrite(LED_7, LOW);
}

// ======================================================
// TURN ON ONE LED
// ======================================================
void turnOnLED(int sensorNumber) {
  turnOffAllLEDs();
  if      (sensorNumber == 0) digitalWrite(LED_1, HIGH);
  else if (sensorNumber == 1) digitalWrite(LED_2, HIGH);
  else if (sensorNumber == 2) digitalWrite(LED_3, HIGH);
  else if (sensorNumber == 3) digitalWrite(LED_4, HIGH);
  else if (sensorNumber == 4) digitalWrite(LED_5, HIGH);
  else if (sensorNumber == 5) digitalWrite(LED_6, HIGH);
  else if (sensorNumber == 6) digitalWrite(LED_7, HIGH);
}

// ======================================================
// GET SENSOR DISTANCE
// ======================================================
int getSensorDistance(int sensorNumber) {
  if      (sensorNumber == 0) return distance1;
  else if (sensorNumber == 1) return distance2;
  else if (sensorNumber == 2) return distance3;
  else if (sensorNumber == 3) return distance4;
  else if (sensorNumber == 4) return distance5;
  else if (sensorNumber == 5) return distance6;
  else if (sensorNumber == 6) return distance7;
  return -1; // unknown bay: never report a usable distance
}

// ======================================================
// FORMAT TIME AS 12-HOUR FORMAT
// ======================================================
void print12HourTime(int hour, int minute) {
  int displayHour = hour;
  if (displayHour == 0) displayHour = 12;
  else if (displayHour > 12) displayHour -= 12;

  if (displayHour < 10) lcd.print("0");
  lcd.print(displayHour);
  lcd.print(":");
  if (minute < 10) lcd.print("0");
  lcd.print(minute);
  if (hour < 12) lcd.print("AM");
  else lcd.print("PM");
}

// ======================================================
// FIND NEXT DOSE
// ======================================================
int getNextDoseIndex(DateTime now) {
  int currentMinutes = now.hour() * 60 + now.minute();
  for (int i = 0; i < 6; i++) {
    if (!doseEnabled[i]) continue;
    int doseMinutes = doseHour[i] * 60 + doseMinute[i];
    if (doseMinutes > currentMinutes) return i;
  }
  for (int i = 0; i < 6; i++) {
    if (!doseEnabled[i]) continue;
    return i;
  }
  return 0;
}

// ======================================================
// IS A DOSE DUE?
// ======================================================
// Compares "has the dose time passed" instead of "is the clock exactly on
// the dose time". One loop iteration can take several seconds (a full
// sensor sweep plus the LCD redraw), so an exact hour==doseHour &&
// minute==doseMinute test silently skipped the dose whenever a sweep
// straddled the minute boundary. A missed dose then never fired at all,
// which is exactly the "buzzer does not ring" symptom.
//
// [lateByMs] is how long past its dose time this is; the caller only fires
// while that stays inside REMINDER_CATCHUP_MS so an old dose from earlier
// today is not resurrected on boot.
bool isDoseDue(int i, const DateTime& now, unsigned long* lateByMs) {
  if (!doseEnabled[i]) return false;
  if (doseTriggered[i]) return false;

  long dueMinutes = (long)doseHour[i] * 60L + doseMinute[i];
  long nowMinutes = (long)now.hour() * 60L + now.minute();

  long delta = nowMinutes - dueMinutes;
  if (delta < 0) return false; // not yet

  // Same minute, or up to the catch-up window late.
  if (delta > (long)(REMINDER_CATCHUP_MS / 60000UL)) return false;

  if (lateByMs != NULL) *lateByMs = (unsigned long)(delta * 60000UL);
  return true;
}

// ======================================================
// ROLL OVER DAILY DOSE FLAGS
// ======================================================
void rollOverDoseFlags(const DateTime& now) {
  int stamp = dayStampOf(now);
  if (stamp == currentDayStamp) return;

  // Guard against the RTC stepping backwards (a bad NTP sync) wiping a
  // day that is already in progress.
  if (stamp < currentDayStamp) return;

  for (int i = 0; i < 6; i++) doseTriggered[i] = false;
  currentDayStamp = stamp;

  Serial.print("New day (");
  Serial.print(stamp);
  Serial.println(") - daily dose flags reset");
}

// ======================================================
// INIT ONE BAY SENSOR
// ======================================================
// Powers a single bay, re-addresses it, and starts continuous ranging.
// Returns false instead of halting, so one bad bay costs you that bay's
// dose confirmation rather than the whole device.
bool initSensor(int index, VL53L0X& sensor, int xshutPin, uint8_t address) {
  digitalWrite(xshutPin, LOW);
  delay(20);
  digitalWrite(xshutPin, HIGH);
  delay(100); // front-end power-up

  if (!sensor.init()) {
    Serial.print("Bay ");
    Serial.print(index + 1);
    Serial.println(" NOT FOUND - bay disabled");
    sensorOk[index] = false;
    digitalWrite(xshutPin, LOW); // keep it off so it cannot disturb the bus
    return false;
  }

  sensor.setAddress(address);
  // 300ms keeps a full sweep fast enough that the alarm loop stays tight;
  // the old 500ms let one sweep stall the whole loop for seconds.
  sensor.setTimeout(300);
  sensor.startContinuous();
  sensorOk[index] = true;

  Serial.print("Bay ");
  Serial.print(index + 1);
  Serial.print(" online @ 0x");
  Serial.println(address, HEX);
  return true;
}

// ======================================================
// READ ALL VL53L0X SENSORS
// ======================================================
// Only bays that initialised are polled. A dead bay is skipped rather than
// blocking the loop on its I2C timeout, which keeps the alarm loop tight.
void readAllSensors() {
  if (sensorOk[0]) distance1 = sensor1.readRangeContinuousMillimeters();
  if (sensorOk[1]) distance2 = sensor2.readRangeContinuousMillimeters();
  if (sensorOk[2]) distance3 = sensor3.readRangeContinuousMillimeters();
  if (sensorOk[3]) distance4 = sensor4.readRangeContinuousMillimeters();
  if (sensorOk[4]) distance5 = sensor5.readRangeContinuousMillimeters();
  if (sensorOk[5]) distance6 = sensor6.readRangeContinuousMillimeters();
  if (sensorOk[6]) distance7 = sensor7.readRangeContinuousMillimeters();
}

// ======================================================
// DHT22
// ======================================================
// The DHT22 refuses to be read faster than every 2s. Returning true only
// when a fresh sample landed lets the loop publish the exact value the LCD
// is showing, instead of republishing a stale one.
const unsigned long DHT_READ_INTERVAL = 2000UL;

bool readDHT22() {
  if (millis() - lastDHTRead < DHT_READ_INTERVAL) return false;
  lastDHTRead = millis();

  float newHumidity = dht.readHumidity();
  float newTemperature = dht.readTemperature();
  if (isnan(newHumidity) || isnan(newTemperature)) return false;

humidity = newHumidity;
  temperature = newTemperature;
  return true;
}

// ======================================================
// WIFI PROVISIONING
// ======================================================
// Factory reset: SETUP_BUTTON held while powering on (~3s).
bool factoryResetRequested() {
  pinMode(SETUP_BUTTON, INPUT_PULLUP);
  if (digitalRead(SETUP_BUTTON) != LOW) return false;
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("Hold SETUP btn");
  lcd.setCursor(0, 1);
  lcd.print("to factory reset");
  delay(3000);
  if (digitalRead(SETUP_BUTTON) == LOW) {
    return true; // still held after 3s -> confirmed reset
  }
  lcd.clear();
  return false;
}

void wipeSettings() {
  Serial.println("FACTORY RESET - clearing all settings");
  WiFiManager wm;
  wm.resetSettings();
  prefs.clear();
  deviceId = DEFAULT_DEVICE_ID;
}

void loadSettings() {
  wifiSsid = prefs.getString("ssid", "");
  wifiPass = prefs.getString("pass", "");
  deviceId = prefs.getString("device_id", DEFAULT_DEVICE_ID);
  Serial.print("Loaded settings -> SSID: \"");
  Serial.print(wifiSsid);
  Serial.print("\" device: ");
  Serial.println(deviceId);
}

void saveSettingsAndReboot(const char* ssid, const char* pass, const char* newDeviceId) {
  deviceId = (newDeviceId[0] == 0) ? DEFAULT_DEVICE_ID : String(newDeviceId);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.putString("device_id", deviceId.c_str());
  Serial.println("Settings saved - rebooting into normal mode");
  ESP.restart();
}

// Start the "CareCube-Setup" captive portal so the user can enter their
// WiFi + this unit's device id from their phone. No PC needed.
void startSetupPortal() {
  Serial.println("STARTING SETUP PORTAL (CareCube-Setup)");

  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("  SETUP MODE");
  lcd.setCursor(0, 1);
  lcd.print("Join WiFi:");
  lcd.setCursor(0, 2);
  lcd.print("  CareCube-Setup");
  lcd.setCursor(0, 3);
  lcd.print("Open 192.168.4.1");

  WiFiManager wm;
  wm.setTimeout(240);

  WiFiManagerParameter deviceParam(
      "device_id", "Device ID (printed on the box)", DEFAULT_DEVICE_ID, 32);
  wm.addParameter(&deviceParam);

  if (wm.startConfigPortal("CareCube-Setup")) {
    // WiFiManagerParameter::getValue() already returns a const char*, so it
    // must not be dereferenced again (older WiFiManager returned a String).
    saveSettingsAndReboot(wm.getWiFiSSID().c_str(), wm.getWiFiPass().c_str(),
                          deviceParam.getValue());
  } else {
    Serial.println("Setup portal timed out - no config, staying unconfigured");
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("NO WiFi SETUP");
    lcd.setCursor(0, 1);
    lcd.print("Hold SETUP btn +");
    lcd.setCursor(0, 2);
    lcd.print("power on to retry");
    delay(3000);
  }
}

// Tries to join the saved network. If none is stored (or the join
// fails) it falls back to the setup portal.
void connectWiFi() {
  if (wifiSsid.length() == 0) {
    startSetupPortal();
    loadSettings(); // only returns if the portal timed out
    if (wifiSsid.length() == 0) {
      Serial.println("No WiFi config yet on this boot.");
      return;
    }
  }

  Serial.print("Connecting to WiFi: ");
  Serial.println(wifiSsid);

  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("WiFi Connecting...");
  lcd.setCursor(0, 1);
  lcd.print(wifiSsid);

  WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());

  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 40) {
    delay(500);
    Serial.print(".");
    lcd.setCursor(attempts % 20, 2);
    lcd.print(".");
    attempts++;
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\nWiFi connected!");
    Serial.print("IP: ");
    Serial.println(WiFi.localIP());

    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("WiFi Connected!");
    lcd.setCursor(0, 1);
    lcd.print(WiFi.localIP().toString());
    delay(1500);
  } else {
    Serial.println("\nWiFi connection failed - opening setup portal");
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("WiFi FAILED!");
    lcd.setCursor(0, 1);
    lcd.print("Opening setup...");
    delay(1500);
    startSetupPortal();
    loadSettings();
  }
}

// Called from loop(): reconnects to the saved network in the background
// and only opens the portal once (a factory reset re-arms it).
void ensureWiFi() {
  static bool portalAttempted = false;
  static unsigned long lastRetry = 0;

  if (WiFi.status() == WL_CONNECTED) return;

  if (wifiSsid.length() == 0) {
    if (!portalAttempted) {
      portalAttempted = true;
      startSetupPortal();
      loadSettings();
      if (wifiSsid.length() > 0) {
        WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
      }
    }
    return;
  }

  if (millis() - lastRetry > 30000) {
    lastRetry = millis();
    WiFi.disconnect(false);
    WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
    Serial.println("Retrying WiFi connection...");
  }
}

// ======================================================
// MQTT RECONNECT
// ======================================================
void reconnectMQTT() {
  if (mqttClient.connected()) return;

  Serial.print("Connecting to MQTT...");

  String mqttClientId = deviceId + "-esp32";
  if (mqttClient.connect(mqttClientId.c_str(), MQTT_USERNAME, MQTT_PASSWORD)) {
    Serial.println("connected!");

    mqttClient.subscribe(topicScheduleSet.c_str());
    mqttClient.subscribe(topicAlarmStop.c_str());

    Serial.print("Subscribed to: ");
    Serial.println(topicScheduleSet);
    Serial.print("Subscribed to: ");
    Serial.println(topicAlarmStop);
  } else {
    Serial.print("failed, rc=");
    Serial.println(mqttClient.state());
  }
}

// ======================================================
// MQTT CALLBACK
// ======================================================
void mqttCallback(char* topic, byte* payload, unsigned int length) {
  String message;
  for (unsigned int i = 0; i < length; i++) {
    message += (char)payload[i];
  }

  Serial.print("MQTT <- [");
  Serial.print(topic);
  Serial.print("] ");
  Serial.println(message);

  String topicStr = String(topic);

  // ==================================================
  // SCHEDULE UPDATE
  // ==================================================
  if (topicStr == topicScheduleSet) {
    StaticJsonDocument<1024> doc;
    DeserializationError error = deserializeJson(doc, message);

    if (error) {
      Serial.print("JSON parse error: ");
      Serial.println(error.c_str());
      return;
    }

    for (int i = 0; i < 6; i++) {
      if (doc[i].isNull()) {
        doseEnabled[i] = false;
        continue;
      }

      doseSensor[i]  = (doc[i]["sensor_number"] | (i + 1)) - 1; // app sends bay 1..6 -> store 0-based
      doseHour[i]    = doc[i]["hour"] | 12;
      doseMinute[i]  = doc[i]["minute"] | 0;
      doseEnabled[i] = doc[i]["enabled"] | false;
    }

    Serial.println("Schedule updated via MQTT");
    for (int i = 0; i < 6; i++) {
      Serial.print("  Slot ");
      Serial.print(i);
      Serial.print(": S");
      Serial.print(doseSensor[i] + 1);
      Serial.print(" ");
      if (doseHour[i] < 10) Serial.print("0");
      Serial.print(doseHour[i]);
      Serial.print(":");
      if (doseMinute[i] < 10) Serial.print("0");
      Serial.print(doseMinute[i]);
      Serial.print(" ");
      Serial.println(doseEnabled[i] ? "ON" : "OFF");

      // A slot whose time was moved must be allowed to fire again at its
      // new time, otherwise an edit silently disables that dose for today.
      doseTriggered[i] = false;
    }

    // If the slot the running reminder belongs to was disabled, stop it
    // rather than leaving the buzzer on for a dose that no longer exists.
    if (activeReminder >= 0 && activeReminder < 6 && !doseEnabled[activeReminder]) {
      Serial.println("Active slot disabled by schedule update - clearing alarm");
      setBuzzer(false);
      turnOffAllLEDs();
      displayState = MAIN_SCREEN;
      activeReminder = -1;
      lcd.clear();
    }
  }

  // ==================================================
  // ALARM STOP (caregiver only)
  // ==================================================
  if (topicStr == topicAlarmStop) {
    if (displayState == MEDICINE_REMINDER || displayState == EMERGENCY_TAKEN) {
      Serial.println("Alarm stopped by caregiver");

      // activeReminder is -1 during an emergency, so doseSensor[-1] would
      // read out of bounds and report a nonsense bay.
      int stoppedBay = (activeReminder >= 0 && activeReminder < 6)
                           ? doseSensor[activeReminder] + 1
                           : 7;

      setBuzzer(false);
      turnOffAllLEDs();

      publishEvent("caregiver_stopped", stoppedBay);

      displayState = MAIN_SCREEN;
      activeReminder = -1;
      emergencyTriggered = false;
      takenReadingCount = 0;
      emergencyReturnReadings = 0;
      baySeenOccupied = false;
      lcd.clear();
    }
  }
}

// ======================================================
// PUBLISH STATUS (temp/humidity)
// ======================================================
void publishStatus() {
  if (!mqttClient.connected()) return;

  StaticJsonDocument<256> doc;
  doc["device_id"]   = deviceId;
  doc["temperature"] = temperature;
  doc["humidity"]    = humidity;
  doc["timestamp"]   = (uint32_t)nowUnix();

  char buffer[256];
  serializeJson(doc, buffer);

  mqttClient.publish(topicStatus.c_str(), buffer, true);

  Serial.print("MQTT -> [");
  Serial.print(topicStatus);
  Serial.print("] ");
  Serial.println(buffer);
}

// ======================================================
// PUBLISH EVENT
// ======================================================
void publishEvent(const char* eventType, int sensorNumber) {
  if (!mqttClient.connected()) return;

  StaticJsonDocument<256> doc;
  doc["device_id"]     = deviceId;
  doc["type"]          = eventType;
  doc["sensor_number"] = sensorNumber;
  doc["timestamp"]     = (uint32_t)nowUnix();

  char buffer[256];
  serializeJson(doc, buffer);

  mqttClient.publish(topicEvent.c_str(), buffer);

  Serial.print("MQTT -> [");
  Serial.print(topicEvent);
  Serial.print("] ");
  Serial.println(buffer);
}

// ======================================================
// UNIX TIME
// Real wall-clock epoch so the app stores correct event dates.
// Falls back to NTP/millis time if NTP has not synced yet.
// ======================================================
time_t nowUnix() {
  time_t t = time(nullptr);
  if (t < 1700000000UL) {
    if (rtcOk) return rtc.now().unixtime();
    return (time_t)0;
  }
  return t;
}

void syncRtcFromNtp() {
  // Sync on LOCAL time (see TIMEZONE_OFFSET_SEC) so dose times entered in the
  // app line up with the box's wall clock.
  configTime(TIMEZONE_OFFSET_SEC, 0, "pool.ntp.org", "time.google.com");
  struct tm tmv;
  if (getLocalTime(&tmv, 5000)) {
    if (rtcOk) {
      rtc.adjust(DateTime(tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                          tmv.tm_hour, tmv.tm_min, tmv.tm_sec));
    }
    Serial.println("Clock synced from NTP");
  } else {
    Serial.println("NTP sync failed - keeping RTC time");
  }
}

// ======================================================
// DISPLAY: MAIN SCREEN
// ======================================================
void displayMainScreen(DateTime now) {
  lcd.clear();

  // LINE 1 - TIME
  lcd.setCursor(0, 0);
  if (now.hour() < 10) lcd.print("0");
  lcd.print(now.hour());
  lcd.print(":");
  if (now.minute() < 10) lcd.print("0");
  lcd.print(now.minute());
  lcd.print(":");
  if (now.second() < 10) lcd.print("0");
  lcd.print(now.second());

  // WiFi + MQTT status
  lcd.setCursor(13, 0);
  lcd.print("W:");
  lcd.print(WiFi.status() == WL_CONNECTED ? "Y" : "N");
  lcd.print(" M:");
  lcd.print(mqttClient.connected() ? "Y" : "N");

  // LINE 2 - DATE
  lcd.setCursor(0, 1);
  if (now.day() < 10) lcd.print("0");
  lcd.print(now.day());
  lcd.print("/");
  if (now.month() < 10) lcd.print("0");
  lcd.print(now.month());
  lcd.print("/");
  lcd.print(now.year());

  // LINE 3 - TEMPERATURE + HUMIDITY
  lcd.setCursor(0, 2);
  lcd.print("T:");
  lcd.print(temperature, 1);
  lcd.print((char)223);
  lcd.print("C H:");
  lcd.print(humidity, 1);
  lcd.print("%");

  // LINE 4 - NEXT DOSE
  lcd.setCursor(0, 3);
  lcd.print("Next: ");
  int nextDose = getNextDoseIndex(now);
  print12HourTime(doseHour[nextDose], doseMinute[nextDose]);
}

// ======================================================
// DISPLAY: MEDICINE REMINDER
// ======================================================
void displayMedicineReminder() {
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("   !! REMINDER !!");
  lcd.setCursor(0, 1);
  lcd.print("   TAKE MEDICINE");
  lcd.setCursor(0, 2);
  lcd.print("     SENSOR ");
  lcd.print(doseSensor[activeReminder] + 1);
  lcd.setCursor(0, 3);
  lcd.print("Next: ");
  int nextDose = (activeReminder + 1) % 6;
  while (!doseEnabled[nextDose] && nextDose != activeReminder) {
    nextDose = (nextDose + 1) % 6;
  }
  print12HourTime(doseHour[nextDose], doseMinute[nextDose]);
}

// ======================================================
// DISPLAY: MEDICINE TAKEN
// ======================================================
void displayMedicineTaken() {
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("  MEDICINE TAKEN");
  lcd.setCursor(0, 1);
  lcd.print("     SENSOR ");
  lcd.print(doseSensor[activeReminder] + 1);
  lcd.setCursor(0, 2);
  lcd.print("     WELL DONE!");
  lcd.setCursor(0, 3);
  lcd.print("Next: ");
  int nextDose = (activeReminder + 1) % 6;
  while (!doseEnabled[nextDose] && nextDose != activeReminder) {
    nextDose = (nextDose + 1) % 6;
  }
  print12HourTime(doseHour[nextDose], doseMinute[nextDose]);
}

int detectWrongBayRemoval() {
  int distances[6] = {distance1, distance2, distance3, distance4, distance5, distance6};
  int scheduledBay = (activeReminder >= 0 && activeReminder < 6) ? doseSensor[activeReminder] : -1;

  // A bay is only called a wrong-time pickup if it stays removed for 2 minutes.
  // This gives the scheduled pickup logic time to confirm a correct dose and
  // prevents a correct pickup from causing a second warning after the LCD returns.
  const int WRONG_BAY_CONFIRM_READINGS = 2;
  const int WRONG_BAY_REMOVE_MARGIN_MM = 25;

  for (int bay = 0; bay < 6; bay++) {
    if (!isSensorOk(bay)) {
      wrongBayRemoveReadings[bay] = 0;
      wrongBayRemovalPending[bay] = false;
      continue;
    }

    // Never classify the currently scheduled compartment as a wrong bay.
    if (bay == scheduledBay || displayState == MEDICINE_TAKEN) {
      wrongBayRemoveReadings[bay] = 0;
      wrongBayRemovalPending[bay] = false;
      continue;
    }

    int d = distances[bay];
    bool valid = isValidDistance(d);

    // Learn each bay's occupied/resting distance independently (important for S6).
    if (valid && wrongBayOccupiedDistance[bay] < 0) {
      wrongBayOccupiedDistance[bay] = d;
      wrongBayArmed[bay] = true;
      wrongBayRemoveReadings[bay] = 0;
      wrongBayRemovalPending[bay] = false;
      continue;
    }

    // A closer reading means the compartment has been restored / occupied.
    // Cancel the two-minute pending warning and refresh its baseline.
    if (valid && wrongBayOccupiedDistance[bay] >= 0 &&
        d < wrongBayOccupiedDistance[bay] - WRONG_BAY_REMOVE_MARGIN_MM) {
      wrongBayOccupiedDistance[bay] = d;
      wrongBayArmed[bay] = true;
      wrongBayRemoveReadings[bay] = 0;
      wrongBayRemovalPending[bay] = false;
      continue;
    }

    bool looksRemoved = !valid ||
        (wrongBayOccupiedDistance[bay] >= 0 &&
         d > wrongBayOccupiedDistance[bay] + WRONG_BAY_REMOVE_MARGIN_MM);

    if (wrongBayArmed[bay] && looksRemoved) {
      wrongBayRemoveReadings[bay]++;
      if (wrongBayRemoveReadings[bay] >= WRONG_BAY_CONFIRM_READINGS) {
        if (!wrongBayRemovalPending[bay]) {
          wrongBayRemovalPending[bay] = true;
          wrongBayRemovalStart[bay] = millis();
          Serial.print("Unexpected removal detected on S");
          Serial.print(bay + 1);
          Serial.println("; waiting 2 minutes before warning.");
        }
        if (millis() - wrongBayRemovalStart[bay] >= WRONG_BAY_DELAY_MS) {
          wrongBayArmed[bay] = false;
          wrongBayOccupiedDistance[bay] = -1;
          wrongBayRemoveReadings[bay] = 0;
          wrongBayRemovalPending[bay] = false;
          return bay;
        }
      }
    } else {
      wrongBayRemoveReadings[bay] = 0;
      wrongBayRemovalPending[bay] = false;
      // Track small downward drift only; never follow rising readings.
      if (valid && wrongBayOccupiedDistance[bay] >= 0 &&
          d < wrongBayOccupiedDistance[bay]) {
        wrongBayOccupiedDistance[bay] = d;
      }
    }
  }
  return -1;
}

void startWrongBayAlert(int bay) {
  wrongBaySensor = bay;
  wrongAlertReturnState = displayState;
  wrongAlertStartTime = millis();
  displayState = WRONG_DOSE_ALERT;
  setBuzzerMode(BUZZER_MODE_WRONG_BAY);
  turnOnLED(bay);
  lcd.clear();
  lcd.setCursor(0, 0); lcd.print(" WARNING: WRONG BAY ");
  lcd.setCursor(0, 1); lcd.print("Medicine removed from");
  lcd.setCursor(0, 2); lcd.print("Sensor "); lcd.print(bay + 1);
  lcd.setCursor(0, 3); lcd.print("Check dose schedule!");
  publishEvent("wrong_bay_taken", bay + 1);
  Serial.print("WARNING: medicine removed from unexpected sensor ");
  Serial.println(bay + 1);
}

// ======================================================
// DISPLAY: EMERGENCY
// ======================================================
void displayEmergencyTaken() {
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("   ATTENTION!");
  lcd.setCursor(0, 1);
  lcd.print(" EMERGENCY DOSE");
  lcd.setCursor(0, 2);
  lcd.print("      TAKEN!");
  lcd.setCursor(0, 3);
  lcd.print("    PLEASE CHECK");
}

// ======================================================
// SETUP
// ======================================================
void setup() {
  Serial.begin(115200);
  prefs.begin("carecube", false);

  // ====================================================
  // I2C + LCD (needed for the setup / provisioning screens)
  // ====================================================
  Wire.begin(21, 22);
  lcd.init();
  lcd.backlight();
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("     CARE CUBE");
  lcd.setCursor(0, 1);
  lcd.print("  MEDICINE SYSTEM");

  // ====================================================
  // WIFI PROVISIONING
  // Runs BEFORE sensor init on purpose: a missing/faulty sensor must
  // never block a user from configuring their new box.
  // ====================================================
  if (factoryResetRequested()) wipeSettings();
  loadSettings();

  // ====================================================
  // BUILD MQTT TOPICS (from the provisioned device id)
  // ====================================================
  topicScheduleSet = String("carecube/") + deviceId + "/schedule/set";
  topicStatus      = String("carecube/") + deviceId + "/status";
  topicEvent       = String("carecube/") + deviceId + "/event";
  topicAlarmStop   = String("carecube/") + deviceId + "/alarm/stop";

  connectWiFi();

  // ====================================================
  // MQTT (broker account is compiled in; per-box identity comes from
  // the device id the user entered in the setup portal)
  // ====================================================
  wifiClient.setInsecure();
  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
  mqttClient.setCallback(mqttCallback);
  mqttClient.setBufferSize(1024);
  if (WiFi.status() == WL_CONNECTED) {
    reconnectMQTT();
  }

  // ====================================================
  // BUZZER + LEDs
  // Set up before anything else can sound an alarm.
  // ====================================================
  pinMode(LED_1, OUTPUT);
  pinMode(LED_2, OUTPUT);
  pinMode(LED_3, OUTPUT);
  pinMode(LED_4, OUTPUT);
  pinMode(LED_5, OUTPUT);
  pinMode(LED_6, OUTPUT);
  pinMode(LED_7, OUTPUT);
  turnOffAllLEDs();
  buzzerSetup();

  // ====================================================
  // DHT22
  // ====================================================
  dht.begin();

  // ====================================================
  // XSHUT PINS
  // ====================================================
  pinMode(XSHUT_1, OUTPUT);
  pinMode(XSHUT_2, OUTPUT);
  pinMode(XSHUT_3, OUTPUT);
  pinMode(XSHUT_4, OUTPUT);
  pinMode(XSHUT_5, OUTPUT);
  pinMode(XSHUT_6, OUTPUT);
  pinMode(XSHUT_7, OUTPUT);

  digitalWrite(XSHUT_1, LOW);
  digitalWrite(XSHUT_2, LOW);
  digitalWrite(XSHUT_3, LOW);
  digitalWrite(XSHUT_4, LOW);
  digitalWrite(XSHUT_5, LOW);
  digitalWrite(XSHUT_6, LOW);
  digitalWrite(XSHUT_7, LOW);
  delay(100);

  // ====================================================
  // SENSOR INIT (fault tolerant)
  // ====================================================
  // A bay that fails to answer is marked unavailable and skipped from then
  // on. The previous `while (1)` here meant a single flaky VL53L0X froze
  // the entire box at the boot screen: no buzzer, no reminders, no MQTT -
  // for the rest of the day, with no way to recover without a reflash.
  //
  // Bays are powered one at a time on purpose: they all answer on 0x29
  // until re-addressed, so leaving several enabled at once would make
  // setAddress() hit all of them together.
  initSensor(0, sensor1, XSHUT_1, 0x30);
  initSensor(1, sensor2, XSHUT_2, 0x31);
  initSensor(2, sensor3, XSHUT_3, 0x32);
  initSensor(3, sensor4, XSHUT_4, 0x33);
  initSensor(4, sensor5, XSHUT_5, 0x34);
  initSensor(5, sensor6, XSHUT_6, 0x35);
  initSensor(6, sensor7, XSHUT_7, 0x36); // bay 7 = emergency

  // Give the ranging engines time to settle; the first samples out of
  // continuous mode are garbage and must not be treated as a pickup.
  delay(300);

  // ====================================================
  // RTC
  // ====================================================
  rtcOk = rtc.begin();
  if (!rtcOk) {
    // No RTC: keep running on NTP/millis time rather than halting. Dose
    // times are then only as good as the network, which is strictly
    // better than a box that never rings again.
    Serial.println("RTC NOT FOUND - continuing on NTP time");
  } else if (rtc.lostPower()) {
    Serial.println("RTC lost power!");
    rtc.adjust(DateTime(F(__DATE__), F(__TIME__)));
    Serial.println("RTC time updated.");
  }

  // ====================================================
  // KEEP THE CLOCK ACCURATE (dose times + event timestamps)
  // ====================================================
  // Runs after the RTC exists so the adjust actually lands. An RTC that
  // drifts makes a dose fire at the wrong minute - which is one of the
  // reasons reminders seemed to be skipped.
  if (WiFi.status() == WL_CONNECTED) {
    syncRtcFromNtp();
  }

  // ====================================================
  // LCD BOOT SCREEN (WiFi/MQTT already configured above)
  // ====================================================
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("     CARE CUBE");
  lcd.setCursor(0, 1);
  lcd.print("  MEDICINE SYSTEM");

  int missing = 0;
  for (int i = 0; i < 7; i++) if (!sensorOk[i]) missing++;

  if (missing > 0) {
    lcd.setCursor(0, 2);
    lcd.print("  BAY SENSOR FAULT");
    lcd.setCursor(0, 3);
    lcd.print("   CHECK ");
    lcd.print(missing);
    lcd.print(" OF 7 BAYS");
    delay(3000);
  }

  lcd.setCursor(0, 2);
  lcd.print("   SYSTEM READY");
  lcd.setCursor(0, 3);
  lcd.print("  Initializing...");
  delay(2000);

  // ====================================================
  // INITIAL EMERGENCY SENSOR READING
  // ====================================================
  // Seed the resting distance with a real reading so the "removed"
  // comparison works from the very first loop. An invalid reading is not a
  // usable baseline; it just means the bay boots empty and the detector will
  // arm itself as soon as the compartment is seen.
  emergencyRestMm = -1;
  emergencyCloserReadings = 0;
  emergencyRemoveReadings = 0;
  if (sensorOk[6]) {
    int first = sensor7.readRangeContinuousMillimeters();
    if (isValidDistance(first)) emergencyRestMm = first;
  }

  rollOverDoseFlags(currentDateTime());

  Serial.println("==============================");
  Serial.println("      CARE CUBE READY");
  Serial.println("==============================");
  if (missing > 0) {
    Serial.print("WARNING: ");
    Serial.print(missing);
    Serial.println(" bay sensor(s) unavailable - those bays cannot confirm a dose");
  }
  if (!rtcOk) Serial.println("WARNING: no RTC - running on NTP time");
  Serial.println("MQTT Topics:");
  Serial.print("  Schedule: ");
  Serial.println(topicScheduleSet);
  Serial.print("  Status:   ");
  Serial.println(topicStatus);
  Serial.print("  Event:    ");
  Serial.println(topicEvent);
  Serial.print("  Alarm:    ");
  Serial.println(topicAlarmStop);
}

// ======================================================
// LOOP
// ======================================================
void loop() {
  DateTime now = currentDateTime();

  // ====================================================
  // MQTT LOOP
  // ====================================================
  mqttClient.loop();

  // ====================================================
  // WIFI RECONNECT (background retry; portal opens only once)
  // ====================================================
  ensureWiFi();

  // ====================================================
  // MQTT RECONNECT
  // ====================================================
  if (!mqttClient.connected()) {
    reconnectMQTT();
  }

  // ====================================================
  // KEEP THE CLOCK HONEST
  // ====================================================
  if (rtcOk && WiFi.status() == WL_CONNECTED &&
      millis() - lastClockSync >= CLOCK_SYNC_INTERVAL) {
    lastClockSync = millis();
    syncRtcFromNtp();
  }

  // ====================================================
  // READ ALL VL53L0X SENSORS
  // ====================================================
  readAllSensors();

  // ====================================================
  // READ DHT22
  // ====================================================
  bool freshEnvironment = readDHT22();

  // ====================================================
  // RESET DAILY DOSE FLAGS WHEN THE DAY CHANGES
  // ====================================================
  // Keyed off a day stamp instead of second==0: with a full sensor sweep
  // in the loop the midnight second is easy to step straight over, and a
  // missed reset means no dose fires at all for the rest of the day.
  rollOverDoseFlags(now);

  // ====================================================
  // PUBLISH ENVIRONMENT
  // ====================================================
  // Publish the moment a new sample arrives, in the same loop iteration that
  // redraws the LCD, so both always show the same numbers. Publishing on a
  // fixed 30s timer is what made the app look frozen and drift a few tenths
  // behind the LCD.
  if (freshEnvironment ||
      millis() - lastMQTTPublish >= MQTT_HEARTBEAT_INTERVAL) {
    lastMQTTPublish = millis();
    publishStatus();
  }

  // ====================================================
  // Detect an unexpected pickup from a different medicine bay.
  if (!emergencyTriggered && displayState != MEDICINE_TAKEN &&
      displayState != EMERGENCY_TAKEN && displayState != WRONG_DOSE_ALERT) {
    int wrongBay = detectWrongBayRemoval();
    if (wrongBay >= 0) {
      startWrongBayAlert(wrongBay);
      serviceBuzzer();
      return;
    }
  }

  // EMERGENCY SENSOR S7 (PRESENCE)
  // ====================================================
  // Runs only while idle on the main screen. The compartment being taken out
  // is a sustained move away from the learned resting distance, or the sensor
  // losing its target entirely (out-of-range); a return is a sustained
  // reading back at the resting distance. Everything is debounced, and the
  // resting distance is learned, so neither an absolute millimetre value nor
  // an out-of-range report can defeat the detector the way the old rule did.
  if (activeReminder == -1 &&
      displayState == MAIN_SCREEN &&
      !emergencyTriggered)
  {
    bool s7Valid = isSensorOk(6) && isValidDistance(distance7);
    // "No target": a genuine out-of-range report or a timeout. Either means
    // nothing is sitting in front of S7, i.e. the compartment is gone.
    bool s7NoTarget = isSensorOk(6) && !isValidDistance(distance7);

    if (s7Valid) {
      if (emergencyRestMm < 0) {
        // First time the bay is seen holding the compartment.
        emergencyRestMm = distance7;
        emergencyCloserReadings = 0;
      } else if (distance7 < emergencyRestMm - EMERGENCY_CLOSER_HYST_MM) {
        // Clearly closer than the current baseline - a new resting position
        // (compartment inserted). Confirm before adopting so a one-off
        // downward glitch cannot drag the baseline to it.
        emergencyCloserReadings++;
        if (emergencyCloserReadings >= EMERGENCY_CLOSER_CONFIRM) {
          emergencyRestMm = distance7;
          emergencyCloserReadings = 0;
        }
      } else {
        emergencyCloserReadings = 0;
        // Small drift within the accepted band tracks the real resting
        // distance without ever chasing a removal.
        if (distance7 <= emergencyRestMm + EMERGENCY_CLOSER_HYST_MM) {
          emergencyRestMm = (emergencyRestMm * 7 + distance7) / 8;
        }
      }
    }

    // Removal = lost the target, or a valid reading clearly past the resting
    // distance. Debounced so one stray sample cannot fire the alarm.
    if (emergencyRestMm >= 0) {
      bool removed = s7NoTarget ||
                     (s7Valid && distance7 > emergencyRestMm + EMERGENCY_REMOVE_MARGIN_MM);
      emergencyRemoveReadings = removed ? emergencyRemoveReadings + 1 : 0;

      if (emergencyRemoveReadings >= REQUIRED_TAKEN_READINGS) {
        emergencyTriggered = true;
        emergencyRemoveReadings = 0;
        emergencyCloserReadings = 0;
        displayState = EMERGENCY_TAKEN;
        messageStartTime = millis();
        lastReminderRepublish = millis();
        turnOnLED(6);
        setBuzzerMode(BUZZER_MODE_EMERGENCY);

        publishEvent("emergency_taken", 7);

        lcd.clear();
        Serial.println("================================");
        Serial.println("ATTENTION! EMERGENCY DOSE TAKEN");
        Serial.println("================================");
      }
    }
  }

  // ====================================================
  // EMERGENCY STATE
  // ====================================================
  // An emergency alarm is NOT timer-based: the buzzer (and the phone alarms
  // it drives via the published event) keeps ringing until the emergency
  // container is placed BACK in bay 7 (S7 returns to its resting distance).
  // Only that, or a caregiver's alarm/stop, may silence it.
  if (displayState == EMERGENCY_TAKEN) {
    setBuzzerMode(BUZZER_MODE_EMERGENCY);
    turnOnLED(6);

    // Re-publish while still ringing so a phone that missed (or was killed
    // during) the first event rings again - mirrors the reminder path.
    if (millis() - lastReminderRepublish >= REMINDER_REPUBLISH_MS) {
      lastReminderRepublish = millis();
      publishEvent("emergency_taken", 7);
    }

    // Container back -> resolve. Debounced like a normal pickup so one
    // flaky sample cannot clear an active emergency.
    if (isSensorOk(6) && isValidDistance(distance7) &&
        distance7 <= emergencyRestMm + EMERGENCY_REMOVE_MARGIN_MM) {
      emergencyReturnReadings++;
      if (emergencyReturnReadings >= REQUIRED_TAKEN_READINGS) {
        emergencyReturnReadings = 0;
        emergencyRemoveReadings = 0;
        emergencyCloserReadings = 0;
        setBuzzer(false);
        turnOffAllLEDs();
        emergencyTriggered = false;
        displayState = MAIN_SCREEN;
        publishEvent("emergency_returned", 7);
        lcd.clear();
        Serial.println("Emergency container returned - alarm cleared");
      }
    } else {
      emergencyReturnReadings = 0;
    }

    if (millis() - lastLCDUpdate >= 500) {
      lastLCDUpdate = millis();
      displayEmergencyTaken();
    }
    serviceBuzzer();
    return;
  }

  // ====================================================
  // CHECK NORMAL DOSE REMINDERS
  // ====================================================
  if (activeReminder == -1 && displayState == MAIN_SCREEN) {
    for (int i = 0; i < 6; i++) {
      if (!isDoseDue(i, now, NULL)) continue;

      activeReminder = i;
      doseTriggered[i] = true;
      displayState = MEDICINE_REMINDER;
      takenReadingCount = 0;
      baySeenOccupied = false;
      reminderStartTime = millis();
      lastReminderRepublish = millis();

      turnOnLED(doseSensor[i]);
      setBuzzerMode(BUZZER_MODE_NORMAL_DOSE);

      publishEvent("reminder_started", doseSensor[i] + 1);

      lcd.clear();
      Serial.print("REMINDER -> SENSOR ");
      Serial.print(doseSensor[i] + 1);
      Serial.println(" TAKE MEDICINE");
      break;
    }
  }

  // ====================================================
  // NORMAL MEDICINE REMINDER
  // ====================================================
  if (displayState == MEDICINE_REMINDER) {
    int sensorNumber = doseSensor[activeReminder];
    int activeDistance = getSensorDistance(sensorNumber);
    unsigned long elapsed = millis() - reminderStartTime;

    // Re-publish so a phone that missed (or was killed during) the first
    // event rings again instead of staying silent for the whole dose.
    if (millis() - lastReminderRepublish >= REMINDER_REPUBLISH_MS &&
        elapsed < REMINDER_REPUBLISH_UNTIL_MS) {
      lastReminderRepublish = millis();
      publishEvent("reminder_started", sensorNumber + 1);
    }

    // A pickup must be a real, consecutive, plausible pickup. Counting
    // raw samples is what let the box declare "MEDICINE TAKEN" on its own
    // and switch the buzzer off while the dose was still in the bay.
    bool readingOk = isSensorOk(sensorNumber) && isValidDistance(activeDistance);
    bool doseRemoved = readingOk && activeDistance > MEDICINE_THRESHOLD;

    if (readingOk && !doseRemoved) baySeenOccupied = true;

    if (doseRemoved) takenReadingCount++;
    else takenReadingCount = 0; // must be consecutive

    bool timeElapsed = elapsed >= TAKEN_MIN_ELAPSED;
    // The bay has to have been seen holding a dose first, otherwise an
    // already-empty bay would clear itself the moment the alarm started.
    // The grace period covers a dose taken before the sensor noticed.
    bool sawPickup = baySeenOccupied || elapsed >= TAKEN_EMPTY_BAY_GRACE;

    if (readingOk && timeElapsed && sawPickup &&
        takenReadingCount >= REQUIRED_TAKEN_READINGS) {
      setBuzzerMode(BUZZER_MODE_OFF); // Silence immediately on confirmed correct pickup
      turnOnLED(sensorNumber);

      // The scheduled dose was correctly taken: disarm this bay's wrong-dose
      // detector and clear its old occupied baseline. Otherwise, when the
      // 30-second MEDICINE TAKEN screen ends, the empty bay could be mistaken
      // for a wrong-time pickup and trigger a second warning.
      if (sensorNumber >= 0 && sensorNumber < 6) {
        wrongBayArmed[sensorNumber] = false;
        wrongBayOccupiedDistance[sensorNumber] = -1;
        wrongBayRemoveReadings[sensorNumber] = 0;
        wrongBayRemovalPending[sensorNumber] = false;
      }

      displayState = MEDICINE_TAKEN;
      messageStartTime = millis();
      takenReadingCount = 0;

      publishEvent("taken", sensorNumber + 1);

      lcd.clear();
      Serial.print("SENSOR ");
      Serial.print(sensorNumber + 1);
      Serial.println(" -> MEDICINE TAKEN");
    } else {
      // Everything that is not a confirmed pickup keeps ringing.
      setBuzzerMode(BUZZER_MODE_NORMAL_DOSE);
      turnOnLED(sensorNumber);

      if (millis() - lastLCDUpdate >= 500) {
        lastLCDUpdate = millis();
        displayMedicineReminder();
      }
    }
    serviceBuzzer();
    return;
  }

  // ====================================================
  // WRONG-BAY WARNING: play its distinct pattern for 10 seconds, then
  // return to the screen/state that was active before the warning. This state
  // is entered only after an unexpected bay has remained removed for 2 minutes.
  if (displayState == WRONG_DOSE_ALERT) {
    setBuzzerMode(BUZZER_MODE_WRONG_BAY);
    if (millis() - lastLCDUpdate >= 500) {
      lastLCDUpdate = millis();
      lcd.setCursor(0, 0); lcd.print(" WARNING: WRONG BAY ");
      lcd.setCursor(0, 1); lcd.print("Medicine removed from");
      lcd.setCursor(0, 2); lcd.print("Sensor "); lcd.print(wrongBaySensor + 1); lcd.print("           ");
      lcd.setCursor(0, 3); lcd.print("Check dose schedule!");
    }
    serviceBuzzer();
    if (millis() - wrongAlertStartTime >= WRONG_BAY_ALERT_TIME) {
      setBuzzerMode(wrongAlertReturnState == MEDICINE_REMINDER ? BUZZER_MODE_NORMAL_DOSE : BUZZER_MODE_OFF);
      turnOffAllLEDs();
      displayState = wrongAlertReturnState;
      wrongBaySensor = -1;
      lcd.clear();
      lastLCDUpdate = 0;
    }
    return;
  }

  // MEDICINE TAKEN STATE
  // ====================================================
  if (displayState == MEDICINE_TAKEN) {
    setBuzzer(false);
    turnOnLED(doseSensor[activeReminder]);

    if (millis() - messageStartTime < MEDICINE_MESSAGE_TIME) {
      if (millis() - lastLCDUpdate >= 500) {
        lastLCDUpdate = millis();
        displayMedicineTaken();
      }
    } else {
      turnOffAllLEDs();
      activeReminder = -1;
      displayState = MAIN_SCREEN;
      lcd.clear();
      Serial.println("Medicine taken message finished.");
    }
    return;
  }

  // ====================================================
  // MAIN SCREEN
  // ====================================================
  if (displayState == MAIN_SCREEN) {
    setBuzzer(false);
    turnOffAllLEDs();

    if (millis() - lastLCDUpdate >= 500) {
      lastLCDUpdate = millis();
      displayMainScreen(now);
    }
  }

  // ====================================================
  // SERIAL MONITOR
  // ====================================================
  Serial.print("Time: ");
  if (now.hour() < 10) Serial.print("0");
  Serial.print(now.hour());
  Serial.print(":");
  if (now.minute() < 10) Serial.print("0");
  Serial.print(now.minute());
  Serial.print(":");
  if (now.second() < 10) Serial.print("0");
  Serial.print(now.second());
  Serial.print(" | T:");
  Serial.print(temperature, 1);
  Serial.print("C H:");
  Serial.print(humidity, 1);
  Serial.print("% | MQTT:");
  Serial.print(mqttClient.connected() ? "Y" : "N");
  Serial.print(" | ");
  Serial.print("S1:"); Serial.print(distance1);
  Serial.print(" S2:"); Serial.print(distance2);
  Serial.print(" S3:"); Serial.print(distance3);
  Serial.print(" S4:"); Serial.print(distance4);
  Serial.print(" S5:"); Serial.print(distance5);
  Serial.print(" S6:"); Serial.print(distance6);
  Serial.print(" S7:"); Serial.println(distance7);

  delay(20);
}

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
#define BUZZER 2

// ======================================================
// MEDICINE DISTANCE THRESHOLD
// ======================================================
#define MEDICINE_THRESHOLD 90

// ======================================================
// DOSE SCHEDULE (6 slots)
// ======================================================
int doseSensor[6]  = {0, 1, 2, 3, 4, 5};
int doseHour[6]    = {8, 10, 12, 14, 16, 20};
int doseMinute[6]  = {0, 0, 0, 0, 0, 0};
bool doseEnabled[6] = {true, true, true, true, true, true};
bool doseTriggered[6] = {false, false, false, false, false, false};

// ======================================================
// EMERGENCY SLOT
// ======================================================
const int EMERGENCY_SLOT = 6;

// ======================================================
// DAILY DOSE FLAGS
// ======================================================
int activeReminder = -1;

// ======================================================
// DISPLAY STATES
// ======================================================
enum DisplayState {
  MAIN_SCREEN,
  MEDICINE_REMINDER,
  MEDICINE_TAKEN,
  EMERGENCY_TAKEN
};

DisplayState displayState = MAIN_SCREEN;

// ======================================================
// MESSAGE TIMER
// ======================================================
unsigned long messageStartTime = 0;
const unsigned long MEDICINE_MESSAGE_TIME = 30000UL;
const unsigned long EMERGENCY_MESSAGE_TIME = 60000UL;

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
const unsigned long MQTT_PUBLISH_INTERVAL = 30000UL;

// ======================================================
// PREVIOUS S7 DISTANCE
// ======================================================
int previousDistance7 = 0;

// ======================================================
// EMERGENCY DETECTION
// ======================================================
bool emergencyTriggered = false;

// ======================================================
// LCD UPDATE TIMER
// ======================================================
unsigned long lastLCDUpdate = 0;

// ======================================================
// MEDICINE TAKEN CONFIRMATION
// ======================================================
int medicineTakenCount = 0;
const int REQUIRED_TAKEN_READINGS = 3;

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
  return 0;
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
// READ ALL VL53L0X SENSORS
// ======================================================
void readAllSensors() {
  distance1 = sensor1.readRangeContinuousMillimeters();
  distance2 = sensor2.readRangeContinuousMillimeters();
  distance3 = sensor3.readRangeContinuousMillimeters();
  distance4 = sensor4.readRangeContinuousMillimeters();
  distance5 = sensor5.readRangeContinuousMillimeters();
  distance6 = sensor6.readRangeContinuousMillimeters();
  distance7 = sensor7.readRangeContinuousMillimeters();
}

// ======================================================
// READ DHT22
// ======================================================
void readDHT22() {
  if (millis() - lastDHTRead >= 2000) {
    lastDHTRead = millis();
    float newHumidity = dht.readHumidity();
    float newTemperature = dht.readTemperature();
    if (!isnan(newHumidity) && !isnan(newTemperature)) {
      humidity = newHumidity;
      temperature = newTemperature;
    }
  }
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
  prefs.putString("device_id", deviceId);
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
      Serial.print(doseSensor[i]);
      Serial.print(" ");
      if (doseHour[i] < 10) Serial.print("0");
      Serial.print(doseHour[i]);
      Serial.print(":");
      if (doseMinute[i] < 10) Serial.print("0");
      Serial.print(doseMinute[i]);
      Serial.print(" ");
      Serial.println(doseEnabled[i] ? "ON" : "OFF");
    }
  }

  // ==================================================
  // ALARM STOP (caregiver only)
  // ==================================================
  if (topicStr == topicAlarmStop) {
    if (displayState == MEDICINE_REMINDER || displayState == EMERGENCY_TAKEN) {
      Serial.println("Alarm stopped by caregiver");

      digitalWrite(BUZZER, LOW);
      turnOffAllLEDs();

      publishEvent("caregiver_stopped", doseSensor[activeReminder] + 1);

      displayState = MAIN_SCREEN;
      activeReminder = -1;
      emergencyTriggered = false;
      medicineTakenCount = 0;
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
// Fallbacks to the DS1307 if NTP has not synced yet.
// ======================================================
time_t nowUnix() {
  time_t t = time(nullptr);
  if (t < 1700000000UL) {
    return rtc.now().unixtime();
  }
  return t;
}

void syncRtcFromNtp() {
  configTime(0, 0, "pool.ntp.org", "time.google.com");
  struct tm tmv;
  if (getLocalTime(&tmv, 5000)) {
    rtc.adjust(DateTime(tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                        tmv.tm_hour, tmv.tm_min, tmv.tm_sec));
    Serial.println("RTC synced from NTP");
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
  // KEEP RTC ACCURATE (dose times + event timestamps)
  // ====================================================
  if (WiFi.status() == WL_CONNECTED) {
    syncRtcFromNtp();
  }

  // ====================================================
  // LEDs
  // ====================================================
  pinMode(LED_1, OUTPUT);
  pinMode(LED_2, OUTPUT);
  pinMode(LED_3, OUTPUT);
  pinMode(LED_4, OUTPUT);
  pinMode(LED_5, OUTPUT);
  pinMode(LED_6, OUTPUT);
  pinMode(LED_7, OUTPUT);
  turnOffAllLEDs();

  // ====================================================
  // BUZZER
  // ====================================================
  pinMode(BUZZER, OUTPUT);
  digitalWrite(BUZZER, LOW);

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
  // SENSOR 1
  // ====================================================
  digitalWrite(XSHUT_1, HIGH);
  delay(100);
  if (!sensor1.init()) { Serial.println("Sensor 1 NOT FOUND!"); while (1); }
  sensor1.setAddress(0x30);
  sensor1.setTimeout(500);
  sensor1.startContinuous();

  // ====================================================
  // SENSOR 2
  // ====================================================
  digitalWrite(XSHUT_2, HIGH);
  delay(100);
  if (!sensor2.init()) { Serial.println("Sensor 2 NOT FOUND!"); while (1); }
  sensor2.setAddress(0x31);
  sensor2.setTimeout(500);
  sensor2.startContinuous();

  // ====================================================
  // SENSOR 3
  // ====================================================
  digitalWrite(XSHUT_3, HIGH);
  delay(100);
  if (!sensor3.init()) { Serial.println("Sensor 3 NOT FOUND!"); while (1); }
  sensor3.setAddress(0x32);
  sensor3.setTimeout(500);
  sensor3.startContinuous();

  // ====================================================
  // SENSOR 4
  // ====================================================
  digitalWrite(XSHUT_4, HIGH);
  delay(100);
  if (!sensor4.init()) { Serial.println("Sensor 4 NOT FOUND!"); while (1); }
  sensor4.setAddress(0x33);
  sensor4.setTimeout(500);
  sensor4.startContinuous();

  // ====================================================
  // SENSOR 5
  // ====================================================
  digitalWrite(XSHUT_5, HIGH);
  delay(100);
  if (!sensor5.init()) { Serial.println("Sensor 5 NOT FOUND!"); while (1); }
  sensor5.setAddress(0x34);
  sensor5.setTimeout(500);
  sensor5.startContinuous();

  // ====================================================
  // SENSOR 6
  // ====================================================
  digitalWrite(XSHUT_6, HIGH);
  delay(100);
  if (!sensor6.init()) { Serial.println("Sensor 6 NOT FOUND!"); while (1); }
  sensor6.setAddress(0x35);
  sensor6.setTimeout(500);
  sensor6.startContinuous();

  // ====================================================
  // SENSOR 7 - EMERGENCY
  // ====================================================
  digitalWrite(XSHUT_7, HIGH);
  delay(100);
  if (!sensor7.init()) { Serial.println("Sensor 7 NOT FOUND!"); while (1); }
  sensor7.setAddress(0x36);
  sensor7.setTimeout(500);
  sensor7.startContinuous();

  // ====================================================
  // RTC
  // ====================================================
  if (!rtc.begin()) {
    Serial.println("RTC NOT FOUND!");
    lcd.init();
    lcd.backlight();
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("RTC NOT FOUND!");
    while (1);
  }

  if (rtc.lostPower()) {
    Serial.println("RTC lost power!");
    rtc.adjust(DateTime(F(__DATE__), F(__TIME__)));
    Serial.println("RTC time updated.");
  }

  // ====================================================
  // LCD BOOT SCREEN (WiFi/MQTT already configured above)
  // ====================================================
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("     CARE CUBE");
  lcd.setCursor(0, 1);
  lcd.print("  MEDICINE SYSTEM");
  lcd.setCursor(0, 2);
  lcd.print("   SYSTEM READY");
  lcd.setCursor(0, 3);
  lcd.print("  Initializing...");
  delay(2000);

  // ====================================================
  // INITIAL EMERGENCY SENSOR READING
  // ====================================================
  previousDistance7 = sensor7.readRangeContinuousMillimeters();

  Serial.println("==============================");
  Serial.println("      CARE CUBE READY");
  Serial.println("==============================");
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
  DateTime now = rtc.now();

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
  // READ ALL VL53L0X SENSORS
  // ====================================================
  readAllSensors();

  // ====================================================
  // READ DHT22
  // ====================================================
  readDHT22();

  // ====================================================
  // RESET DAILY DOSE FLAGS AT MIDNIGHT
  // ====================================================
  if (now.hour() == 0 && now.minute() == 0 && now.second() == 0) {
    for (int i = 0; i < 6; i++) {
      doseTriggered[i] = false;
    }
  }

  // ====================================================
  // PUBLISH STATUS EVERY 30 SECONDS
  // ====================================================
  if (millis() - lastMQTTPublish >= MQTT_PUBLISH_INTERVAL) {
    lastMQTTPublish = millis();
    publishStatus();
  }

  // ====================================================
  // EMERGENCY SENSOR S7
  // ====================================================
  if (activeReminder == -1 &&
      displayState == MAIN_SCREEN &&
      !emergencyTriggered)
  {
    if (previousDistance7 <= MEDICINE_THRESHOLD &&
        distance7 > MEDICINE_THRESHOLD)
    {
      emergencyTriggered = true;
      displayState = EMERGENCY_TAKEN;
      messageStartTime = millis();
      turnOnLED(6);
      digitalWrite(BUZZER, HIGH);

      publishEvent("emergency_taken", 7);

      lcd.clear();
      Serial.println("================================");
      Serial.println("ATTENTION! EMERGENCY DOSE TAKEN");
      Serial.println("================================");
    }
  }

  previousDistance7 = distance7;

  // ====================================================
  // EMERGENCY STATE
  // ====================================================
  if (displayState == EMERGENCY_TAKEN) {
    if (millis() - messageStartTime < EMERGENCY_MESSAGE_TIME) {
      digitalWrite(BUZZER, HIGH);
      turnOnLED(6);
      if (millis() - lastLCDUpdate >= 500) {
        lastLCDUpdate = millis();
        displayEmergencyTaken();
      }
    } else {
      digitalWrite(BUZZER, LOW);
      turnOffAllLEDs();
      displayState = MAIN_SCREEN;
      emergencyTriggered = false;
      lcd.clear();
    }
    return;
  }

  // ====================================================
  // CHECK NORMAL DOSE REMINDERS
  // ====================================================
  if (activeReminder == -1 && displayState == MAIN_SCREEN) {
    for (int i = 0; i < 6; i++) {
      if (!doseEnabled[i]) continue;

      if (now.hour() == doseHour[i] &&
          now.minute() == doseMinute[i] &&
          !doseTriggered[i])
      {
        activeReminder = i;
        doseTriggered[i] = true;
        displayState = MEDICINE_REMINDER;
        medicineTakenCount = 0;

        turnOnLED(doseSensor[i]);
        digitalWrite(BUZZER, HIGH);

        publishEvent("reminder_started", doseSensor[i] + 1);

        lcd.clear();
        Serial.print("REMINDER -> SENSOR ");
        Serial.print(doseSensor[i] + 1);
        Serial.println(" TAKE MEDICINE");
        break;
      }
    }
  }

  // ====================================================
  // NORMAL MEDICINE REMINDER
  // ====================================================
  if (displayState == MEDICINE_REMINDER) {
    int sensorNumber = doseSensor[activeReminder];
    int activeDistance = getSensorDistance(sensorNumber);

    if (activeDistance > MEDICINE_THRESHOLD) {
      medicineTakenCount++;

      Serial.print("Taken confirmation: ");
      Serial.print(medicineTakenCount);
      Serial.print("/");
      Serial.println(REQUIRED_TAKEN_READINGS);

      if (medicineTakenCount >= REQUIRED_TAKEN_READINGS) {
        digitalWrite(BUZZER, LOW);
        turnOnLED(sensorNumber);
        displayState = MEDICINE_TAKEN;
        messageStartTime = millis();
        medicineTakenCount = 0;

        publishEvent("taken", sensorNumber + 1);

        lcd.clear();
        Serial.print("SENSOR ");
        Serial.print(sensorNumber + 1);
        Serial.println(" -> MEDICINE TAKEN");
      }
    } else {
      medicineTakenCount = 0;
      digitalWrite(BUZZER, HIGH);
      turnOnLED(sensorNumber);

      if (millis() - lastLCDUpdate >= 500) {
        lastLCDUpdate = millis();
        displayMedicineReminder();
      }
    }
    return;
  }

  // ====================================================
  // MEDICINE TAKEN STATE
  // ====================================================
  if (displayState == MEDICINE_TAKEN) {
    digitalWrite(BUZZER, LOW);
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
    digitalWrite(BUZZER, LOW);
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

  delay(500);
}

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <VL53L0X.h>
#include <RTClib.h>
#include <DHT.h>
#include <ArduinoJson.h>

// ======================================================
// CIRKIT DESIGNER PORT (ESP32-S3)
// ======================================================
// Runs the full Care Cube circuit inside Cirkit Designer's
// ESP32-S3 simulator and streams temperature/humidity (and any
// dose/emergency events) to the SAME HiveMQ Cloud broker the
// mobile app subscribes to.
//
// Differences from the production firmware:
//   1. WiFi is the simulator's open "CirkitWifi" AP (no password,
//      no WiFiManager/Preferences provisioning).
//   2. Uses RTC_DS1307 (the part Cirkit simulates) and falls back
//      to the sim clock if the RTC is missing.
//   3. VL53L0X sensors are initialized gracefully (skipped, not a
//      hard loop) so the sim runs without every distance sensor.
//   4. Device id is fixed to "carecube-001" so the app sees the box.
//
// Pinout mirrors the real box (see firmware/CareCube_ESP32_Firmware_v2):
//   DHT22   -> GPIO16
//   I2C     -> SDA GPIO21, SCL GPIO22  (LCD 0x27, DS1307, 7x VL53L0X)
//   XSHUT   -> GPIO25,26,27,32,33,14,5
//   LEDs    -> GPIO4,12,19,18,23,13,15
//   BUZZER  -> GPIO2

// ======================================================
// WIFI (Cirkit virtual access point)
// ======================================================
const char* WIFI_SSID     = "CirkitWifi";
const char* WIFI_PASSWORD = "";

// ======================================================
// MQTT BROKER (HiveMQ Cloud - matches the mobile app)
// ======================================================
const char* MQTT_BROKER   = "15eb54ef85ce471890ec2a12019e88b4.s1.eu.hivemq.cloud";
const int   MQTT_PORT     = 8883;
const char* MQTT_USERNAME = "CareCube12";
const char* MQTT_PASSWORD = "CareCube@2006";
const char* MQTT_CLIENT_ID = "carecube-001-cirkit";

// ======================================================
// DEVICE ID (must match app config)
// ======================================================
const char* DEVICE_ID = "carecube-001";

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
RTC_DS1307   rtc;
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
// A dose counts as "taken" only when the bay reads FARTHER than this.
#define MEDICINE_THRESHOLD 90

// A reading outside this range is a glitch, NOT a real measurement.
// Treating a glitch as a real one is what made the box report
// "MEDICINE TAKEN" on its own and stop ringing.
#define SENSOR_MIN_VALID_MM 10
#define SENSOR_MAX_VALID_MM 2000

// The buzzer must ring for this long before a pickup can be confirmed, and
// the bay must have been seen holding a dose first.
const unsigned long TAKEN_MIN_ELAPSED      = 5000UL;
const unsigned long TAKEN_EMPTY_BAY_GRACE  = 90000UL;
const int           REQUIRED_TAKEN_READINGS = 3;

// How late a dose may still fire. Absorbs loop jitter.
const unsigned long REMINDER_CATCHUP_MS = 10UL * 60UL * 1000UL;

// Re-publish the reminder while it still rings so the phone rings again
// even if it missed the first event.
const unsigned long REMINDER_REPUBLISH_MS = 30000UL;
const unsigned long REMINDER_REPUBLISH_UNTIL_MS = 15UL * 60UL * 1000UL;

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
// Heartbeat only: the environment is published every time a fresh DHT sample
// lands (every 2s), so the app and the LCD agree.
const unsigned long MQTT_HEARTBEAT_INTERVAL = 30000UL;

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
// ======================================================
// READING VALIDITY + DOSE DUE HELPERS
// ======================================================
bool isValidDistance(int mm) {
  return mm >= SENSOR_MIN_VALID_MM && mm <= SENSOR_MAX_VALID_MM;
}

int dayStampOf(const DateTime& dt) {
  return dt.year() * 10000 + dt.month() * 100 + dt.day();
}

// Compares "has the dose time passed" instead of "is the clock exactly on
// the dose time". One loop iteration can take several seconds, so the exact
// hour/minute test silently skipped the dose whenever a sweep straddled the
// minute boundary - the buzzer then never rang at all.
bool isDoseDue(int i, const DateTime& now, unsigned long* lateByMs) {
  if (!doseEnabled[i]) return false;
  if (doseTriggered[i]) return false;

  long dueMinutes = (long)doseHour[i] * 60L + doseMinute[i];
  long nowMinutes = (long)now.hour() * 60L + now.minute();

  long delta = nowMinutes - dueMinutes;
  if (delta < 0) return false;
  if (delta > (long)(REMINDER_CATCHUP_MS / 60000UL)) return false;

  if (lateByMs != NULL) *lateByMs = (unsigned long)(delta * 60000UL);
  return true;
}

void rollOverDoseFlags(const DateTime& now) {
  int stamp = dayStampOf(now);
  if (stamp == currentDayStamp) return;
  if (stamp < currentDayStamp) return; // clock stepped backwards

  for (int i = 0; i < 6; i++) doseTriggered[i] = false;
  currentDayStamp = stamp;
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
// WIFI CONNECT (Cirkit virtual AP)
// ======================================================
void connectWiFi() {
  Serial.print("Connecting to WiFi: ");
  Serial.println(WIFI_SSID);

  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("WiFi Connecting...");
  lcd.setCursor(0, 1);
  lcd.print(WIFI_SSID);

  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

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
    Serial.println("\nWiFi connection failed!");
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("WiFi FAILED!");
    lcd.setCursor(0, 1);
    lcd.print("Retrying in loop");
    delay(2000);
  }
}

// ======================================================
// MQTT RECONNECT
// ======================================================
void reconnectMQTT() {
  if (mqttClient.connected()) return;

  Serial.print("Connecting to MQTT...");

  if (mqttClient.connect(MQTT_CLIENT_ID, MQTT_USERNAME, MQTT_PASSWORD)) {
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

      doseSensor[i]  = doc[i]["sensor_number"] | (i + 1);
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
      takenReadingCount = 0;
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
  doc["device_id"]   = DEVICE_ID;
  doc["temperature"] = temperature;
  doc["humidity"]    = humidity;
  doc["timestamp"]   = millis() / 1000;

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
  doc["device_id"]     = DEVICE_ID;
  doc["type"]          = eventType;
  doc["sensor_number"] = sensorNumber;
  doc["timestamp"]     = millis() / 1000;

  char buffer[256];
  serializeJson(doc, buffer);

  mqttClient.publish(topicEvent.c_str(), buffer);

  Serial.print("MQTT -> [");
  Serial.print(topicEvent);
  Serial.print("] ");
  Serial.println(buffer);
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

  // ====================================================
  // BUILD MQTT TOPICS (fixed device id)
  // ====================================================
  topicScheduleSet = String("carecube/") + DEVICE_ID + "/schedule/set";
  topicStatus      = String("carecube/") + DEVICE_ID + "/status";
  topicEvent       = String("carecube/") + DEVICE_ID + "/event";
  topicAlarmStop   = String("carecube/") + DEVICE_ID + "/alarm/stop";

  // ====================================================
  // I2C
  // ====================================================
  Wire.begin(21, 22);

  // ====================================================
  // LCD (needed for the boot screen)
  // ====================================================
  lcd.init();
  lcd.backlight();
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("     CARE CUBE");
  lcd.setCursor(0, 1);
  lcd.print("  MEDICINE SYSTEM");

  // ====================================================
  // WIFI
  // ====================================================
  connectWiFi();

  // ====================================================
  // MQTT
  // ====================================================
  wifiClient.setInsecure();
  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
  mqttClient.setCallback(mqttCallback);
  mqttClient.setBufferSize(1024);
  reconnectMQTT();

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
  if (!sensor1.init()) { Serial.println("Sensor 1 NOT FOUND - skipping"); }
  sensor1.setAddress(0x30);
  sensor1.setTimeout(500);
  sensor1.startContinuous();

  // ====================================================
  // SENSOR 2
  // ====================================================
  digitalWrite(XSHUT_2, HIGH);
  delay(100);
  if (!sensor2.init()) { Serial.println("Sensor 2 NOT FOUND - skipping"); }
  sensor2.setAddress(0x31);
  sensor2.setTimeout(500);
  sensor2.startContinuous();

  // ====================================================
  // SENSOR 3
  // ====================================================
  digitalWrite(XSHUT_3, HIGH);
  delay(100);
  if (!sensor3.init()) { Serial.println("Sensor 3 NOT FOUND - skipping"); }
  sensor3.setAddress(0x32);
  sensor3.setTimeout(500);
  sensor3.startContinuous();

  // ====================================================
  // SENSOR 4
  // ====================================================
  digitalWrite(XSHUT_4, HIGH);
  delay(100);
  if (!sensor4.init()) { Serial.println("Sensor 4 NOT FOUND - skipping"); }
  sensor4.setAddress(0x33);
  sensor4.setTimeout(500);
  sensor4.startContinuous();

  // ====================================================
  // SENSOR 5
  // ====================================================
  digitalWrite(XSHUT_5, HIGH);
  delay(100);
  if (!sensor5.init()) { Serial.println("Sensor 5 NOT FOUND - skipping"); }
  sensor5.setAddress(0x34);
  sensor5.setTimeout(500);
  sensor5.startContinuous();

  // ====================================================
  // SENSOR 6
  // ====================================================
  digitalWrite(XSHUT_6, HIGH);
  delay(100);
  if (!sensor6.init()) { Serial.println("Sensor 6 NOT FOUND - skipping"); }
  sensor6.setAddress(0x35);
  sensor6.setTimeout(500);
  sensor6.startContinuous();

  // ====================================================
  // SENSOR 7 - EMERGENCY
  // ====================================================
  digitalWrite(XSHUT_7, HIGH);
  delay(100);
  if (!sensor7.init()) { Serial.println("Sensor 7 NOT FOUND - skipping"); }
  sensor7.setAddress(0x36);
  sensor7.setTimeout(500);
  sensor7.startContinuous();

  // ====================================================
  // RTC
  // ====================================================
  if (!rtc.begin()) {
    Serial.println("RTC NOT FOUND - continuing with sim clock");
  } else {
    Serial.println("RTC found");
  }

  // ====================================================
  // LCD BOOT SCREEN
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
  // WIFI RECONNECT
  // ====================================================
  if (WiFi.status() != WL_CONNECTED) {
    connectWiFi();
  }

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
  bool freshEnvironment = readDHT22();

  // ====================================================
  // RESET DAILY DOSE FLAGS WHEN THE DAY CHANGES
  // ====================================================
  // Keyed off a day stamp instead of second==0: a missed midnight second
  // used to mean no dose fired for the rest of the day.
  rollOverDoseFlags(now);

  // ====================================================
  // PUBLISH STATUS EVERY 30 SECONDS
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
  // EMERGENCY SENSOR S7
  // ====================================================
  if (activeReminder == -1 &&
      displayState == MAIN_SCREEN &&
      !emergencyTriggered)
  {
    if (isValidDistance(previousDistance7) &&
        isValidDistance(distance7) &&
        previousDistance7 <= MEDICINE_THRESHOLD &&
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

  if (isValidDistance(distance7)) previousDistance7 = distance7;

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
      if (!isDoseDue(i, now, NULL)) continue;

      activeReminder = i;
      doseTriggered[i] = true;
      displayState = MEDICINE_REMINDER;
      takenReadingCount = 0;
      baySeenOccupied = false;
      reminderStartTime = millis();
      lastReminderRepublish = millis();

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

  // ====================================================
  // NORMAL MEDICINE REMINDER
  // ====================================================
  if (displayState == MEDICINE_REMINDER) {
    int sensorNumber = doseSensor[activeReminder];
    int activeDistance = getSensorDistance(sensorNumber);

    unsigned long elapsed = millis() - reminderStartTime;

    // Re-publish so a phone that missed the first event rings again.
    if (millis() - lastReminderRepublish >= REMINDER_REPUBLISH_MS &&
        elapsed < REMINDER_REPUBLISH_UNTIL_MS) {
      lastReminderRepublish = millis();
      publishEvent("reminder_started", sensorNumber + 1);
    }

    // A pickup must be a real, consecutive, plausible pickup. Counting raw
    // samples is what let the box declare "MEDICINE TAKEN" on its own and
    // switch the buzzer off while the dose was still in the bay.
    bool readingOk = isValidDistance(activeDistance);
    bool doseRemoved = readingOk && activeDistance > MEDICINE_THRESHOLD;

    if (readingOk && !doseRemoved) baySeenOccupied = true;

    if (doseRemoved) takenReadingCount++;
    else takenReadingCount = 0; // must be consecutive

    bool timeElapsed = elapsed >= TAKEN_MIN_ELAPSED;
    bool sawPickup = baySeenOccupied || elapsed >= TAKEN_EMPTY_BAY_GRACE;

    if (readingOk && timeElapsed && sawPickup &&
        takenReadingCount >= REQUIRED_TAKEN_READINGS) {
        digitalWrite(BUZZER, LOW);
        turnOnLED(sensorNumber);
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
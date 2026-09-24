/*
 * Node 2 — Water-leak node (battery + deep sleep)
 * Target board: ESP32-C3   [Arduino board: "ESP32C3 Dev Module"]
 *
 * Behaviour:
 *   - Sleeps in deep sleep (~uA) until either:
 *       (a) the leak comparator pulls WAKE_PIN high  -> leak event, or
 *       (b) the heartbeat timer fires                -> status report.
 *   - On a leak: alarm locally FIRST (buzzer + optional valve close),
 *     THEN connect Wi-Fi and publish. Stays awake until dry, then sleeps.
 *
 * Pins (matches the hardware design doc):
 *   - Leak wake input (comparator) -> GPIO2  (deep-sleep wake capable: GPIO0-5)
 *   - Battery sense (ADC, divider)  -> GPIO3  (ADC1)
 *   - I2C SHT40 (optional)          -> SDA=GPIO6 SCL=GPIO7
 *   - Buzzer (via transistor)       -> GPIO5
 *   - Status LED                    -> GPIO8
 *   - Valve driver (optional)       -> GPIO10 (relay + flyback)
 *
 * Required libraries:
 *   PubSubClient, ArduinoJson v7, Adafruit SHT4x + Adafruit Unified Sensor
 *
 * VALVE NOTE: when ENABLE_VALVE=1 and VALVE_FAILSAFE_CLOSED=1, the valve
 * closes on leak detection and does NOT reopen automatically after clearing —
 * manual intervention is required. Set VALVE_FAILSAFE_CLOSED=0 if you want
 * the valve to reopen automatically once the sensor reads dry.
 */

#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include "Adafruit_SHT4x.h"
#include "esp_sleep.h"
#include "driver/gpio.h"

// ----------------------------- CONFIG ---------------------------------------
#define WIFI_SSID      "YOUR_SSID"
#define WIFI_PASSWORD  "YOUR_PASSWORD"
#define MQTT_HOST      "192.168.1.10"
#define MQTT_PORT      1883
#define MQTT_USER      "node2"
#define MQTT_PASS      "changeme"

#define BUILDING_ID    "bldg-01"
#define DEVICE_ID      "node2-kitchen-sink"

#define ENABLE_VALVE          0   // set 1 if a shutoff valve driver is fitted
#define VALVE_FAILSAFE_CLOSED 1   // 1 = close on leak, manual reopen required
                                  // 0 = close on leak, reopen automatically when clear

// Pins
#define WAKE_PIN       GPIO_NUM_2
#define BATT_ADC_PIN   3
#define I2C_SDA        6
#define I2C_SCL        7
#define BUZZER_PIN     5
#define LED_PIN        8
#define VALVE_PIN      10

// Heartbeat interval (status report when no leak). Tune for battery life.
#define HEARTBEAT_SECONDS   (15 * 60)

// Leak monitoring while awake
#define LEAK_RECHECK_MS     2000UL
#define LEAK_MAX_AWAKE_MS   (10 * 60 * 1000UL)  // safety cap

// Battery ADC divider ratio: Vbatt = adc_voltage * BATT_DIV
// Matches the 10kΩ/10kΩ divider on the schematic (Vout = Vbatt / 2)
#define BATT_DIV       2.0f

// ----------------------------- GLOBALS --------------------------------------
WiFiClient   net;
PubSubClient mqtt(net);
Adafruit_SHT4x sht4;
bool shtOk = false;

String topic(const char *leaf) {
  return String("building/") + BUILDING_ID + "/node2/" + DEVICE_ID + "/" + leaf;
}

void setBuzzer(bool on) { digitalWrite(BUZZER_PIN, on ? HIGH : LOW); }
void setLed(bool on)    { digitalWrite(LED_PIN, on ? HIGH : LOW); }

bool leakPresent() { return digitalRead(WAKE_PIN) == HIGH; }

void setValveClosed(bool closed) {
#if ENABLE_VALVE
  digitalWrite(VALVE_PIN, closed ? HIGH : LOW);
#endif
}

float readBatteryVolts() {
  analogReadResolution(12);
  // FIX: ADC_11db is deprecated in Arduino ESP32 3.x — use ADC_ATTEN_DB_12
  analogSetPinAttenuation(BATT_ADC_PIN, ADC_ATTEN_DB_12);
  long acc = 0;
  for (int i = 0; i < 16; i++) { acc += analogRead(BATT_ADC_PIN); delay(2); }
  float v = (acc / 16) * (3.3f / 4095.0f);   // approx; calibrate per board
  return v * BATT_DIV;
}

// --------------------------- CONNECTIVITY -----------------------------------
bool connectNetwork(uint32_t timeoutMs = 12000) {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < timeoutMs) delay(150);
  if (WiFi.status() != WL_CONNECTED) return false;

  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setBufferSize(384);
  t0 = millis();
  while (!mqtt.connected() && millis() - t0 < 5000) {
    if (mqtt.connect(DEVICE_ID, MQTT_USER, MQTT_PASS,
                     topic("status").c_str(), 1, true, "offline")) {
      mqtt.publish(topic("status").c_str(), "online", true);
      break;
    }
    delay(300);
  }
  return mqtt.connected();
}

void publishStatus(const char *event) {
  if (!mqtt.connected()) return;
  float t = NAN, h = NAN;
  if (shtOk) {
    sensors_event_t hum, tmp;
    sht4.getEvent(&hum, &tmp);
    t = tmp.temperature;
    h = hum.relative_humidity;
  }
  JsonDocument doc;
  doc["device"]   = DEVICE_ID;
  doc["event"]    = event;
  doc["leak"]     = leakPresent();
  doc["batt_v"]   = readBatteryVolts();
  if (!isnan(t)) doc["temp_c"]   = t;
  if (!isnan(h)) doc["humidity"] = h;
  char out[384];
  serializeJson(doc, out);
  bool retain = (strcmp(event, "leak") == 0);
  mqtt.publish(topic("status").c_str(), out, retain);
  mqtt.loop();
  delay(50);
}

// --------------------------- WAKE HANDLERS ----------------------------------
void handleLeak() {
  // LOCAL-FIRST: alarm and fail-safe BEFORE touching the network.
  setLed(true);
  setBuzzer(true);
#if ENABLE_VALVE && VALVE_FAILSAFE_CLOSED
  setValveClosed(true);
#endif

  connectNetwork();
  publishStatus("leak");

  unsigned long start   = millis();
  unsigned long lastBeat = 0;

  while (leakPresent() && (millis() - start < LEAK_MAX_AWAKE_MS)) {
    unsigned long now = millis();

    if (mqtt.connected()) mqtt.loop();

    if (now - lastBeat >= 30000UL) {
      lastBeat = now;
      publishStatus("leak");
    }

    // FIX: original code called setBuzzer once then blocked on delay(2000),
    // so the buzzer state was frozen for 2 seconds at a time — effectively
    // pulsing at LEAK_RECHECK_MS intervals, not 500ms as intended.
    // Fixed by running a short-delay inner loop so the buzzer actually
    // toggles every 500ms while still rechecking the sensor every 2 seconds.
    unsigned long windowStart = millis();
    while (millis() - windowStart < LEAK_RECHECK_MS) {
      setBuzzer((millis() / 500) % 2);
      delay(20);
    }
  }

  setBuzzer(false);
  if (!leakPresent()) {
    publishStatus("cleared");
#if ENABLE_VALVE && !VALVE_FAILSAFE_CLOSED
    // Only reopens if VALVE_FAILSAFE_CLOSED=0.
    // If VALVE_FAILSAFE_CLOSED=1, valve stays closed until manual reset.
    setValveClosed(false);
#endif
  }
  setLed(false);
}

void handleHeartbeat() {
  setLed(true);
  if (connectNetwork()) publishStatus("heartbeat");
  setLed(false);
}

// --------------------------- DEEP SLEEP -------------------------------------
void goToSleep() {
  if (mqtt.connected()) mqtt.disconnect();
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);

  // Wake on leak (WAKE_PIN goes HIGH) ...
  esp_deep_sleep_enable_gpio_wakeup(BIT(WAKE_PIN), ESP_GPIO_WAKEUP_GPIO_HIGH);
  // ... and on the heartbeat timer.
  esp_sleep_enable_timer_wakeup((uint64_t)HEARTBEAT_SECONDS * 1000000ULL);

  esp_deep_sleep_start();   // never returns; reboots into setup()
}

// ----------------------------- SETUP/LOOP -----------------------------------
void setup() {
  Serial.begin(115200);

  pinMode(WAKE_PIN, INPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(LED_PIN, OUTPUT);
#if ENABLE_VALVE
  pinMode(VALVE_PIN, OUTPUT);
#endif
  setBuzzer(false);
  setLed(false);

  Wire.begin(I2C_SDA, I2C_SCL);
  shtOk = sht4.begin();
  if (shtOk) {
    sht4.setPrecision(SHT4X_HIGH_PRECISION);
    sht4.setHeater(SHT4X_NO_HEATER);
  }

  esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();

  if (cause == ESP_SLEEP_WAKEUP_GPIO || leakPresent()) {
    handleLeak();
  } else {
    handleHeartbeat();
  }

  goToSleep();
}

void loop() {
  // unused: all work happens in setup() before deep sleep
}
/*
 * Node 1 — Multi-criteria fire/gas + presence node
 * Target board: ESP32-S3 (N16R8)   [Arduino board: "ESP32S3 Dev Module"]
 *
 * Sensors / interfaces (matches the hardware design doc):
 *   - Combustible gas (MQ-x analog)  -> ADC1 on GPIO4 (through a 10k/20k divider)
 *   - CO (Winsen ZE15-CO, UART)      -> UART1  RX=GPIO18  TX=GPIO17  @9600
 *   - Smoke/particulate (SPS30, I2C) -> SDA=GPIO8 SCL=GPIO9
 *   - Temp/humidity (BME280, I2C)    -> same I2C bus
 *   - mmWave presence (LD2410, UART) -> UART2  RX=GPIO15 TX=GPIO16 @256000
 *   - Wi-Fi CSI presence             -> built into the ESP32-S3 radio
 *   - Buzzer (via transistor)        -> GPIO10
 *   - WS2812 status LED              -> GPIO48
 *
 * Required libraries (Library Manager):
 *   PubSubClient (Nick O'Leary), ArduinoJson v7 (Benoit Blanchon),
 *   Adafruit BME280 + Adafruit Unified Sensor, sps30 (paulvha),
 *   ld2410 (ncmreynolds), Adafruit NeoPixel
 *
 * NOTE: thresholds below are STARTING POINTS and MUST be calibrated against
 * your sensors and environment. This is prototype code, not a certified
 * life-safety product.
 *
 * SCHEMATIC NOTE: ZE15-CO connects to GPIO17 (ESP TX) and GPIO18 (ESP RX)
 * on the RIGHT side of the ESP32-S3. Do NOT wire it to GPIO8/GPIO9 which
 * are reserved for I2C (BME280 + SPS30).
 */

#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BME280.h>
#include <Adafruit_NeoPixel.h>
#include <ld2410.h>
#include "sps30.h"
#include "esp_wifi.h"   // for CSI

// ----------------------------- CONFIG ---------------------------------------
#define WIFI_SSID      "YOUR_SSID"
#define WIFI_PASSWORD  "YOUR_PASSWORD"
#define MQTT_HOST      "192.168.1.10"
#define MQTT_PORT      1883
#define MQTT_USER      "node1"
#define MQTT_PASS      "changeme"

#define BUILDING_ID    "bldg-01"
#define DEVICE_ID      "node1-floor2-a"

#define ENABLE_CSI     1   // set 0 to disable Wi-Fi CSI presence heuristic

// Pins
#define I2C_SDA        8
#define I2C_SCL        9
#define MQ_ADC_PIN     4    // ADC1_CH3
#define CO_RX          18
#define CO_TX          17
#define RADAR_RX       15
#define RADAR_TX       16
#define BUZZER_PIN     10
#define LED_PIN        48

// Timing (ms)
#define SENSOR_PERIOD     2000UL
#define TELEMETRY_PERIOD  10000UL
#define TEMP_HIST_PERIOD  10000UL   // rate-of-rise sampling

// ---- Hazard thresholds (CALIBRATE THESE) ----
#define CO_WARN_PPM        35       // ppm, sustained
#define CO_ALARM_PPM       100
#define GAS_WARN_ADC       1200     // raw ADC counts (0-4095) above baseline
#define GAS_ALARM_ADC      2000
#define PM25_WARN          150.0f   // ug/m3 (smoke)
#define PM25_ALARM         300.0f
#define TEMP_ROR_ALARM     8.0f     // deg C per minute -> fire
#define TEMP_ABS_ALARM     58.0f    // deg C absolute

// ----------------------------- GLOBALS --------------------------------------
WiFiClient   net;
PubSubClient mqtt(net);

Adafruit_BME280 bme;
bool bmeOk = false;

Adafruit_NeoPixel pixel(1, LED_PIN, NEO_GRB + NEO_KHZ800);

ld2410 radar;
HardwareSerial radarSerial(2);
HardwareSerial coSerial(1);

bool sps30Ok = false;

struct Readings {
  float tempC = NAN, humidity = NAN, pressure = NAN;
  float pm25 = NAN, pm10 = NAN;
  int   gasRaw = 0;
  int   coPpm = -1;
  bool  presenceRadar = false;
  bool  presenceCsi = false;
} r;

enum HazardLevel { OK = 0, WARNING = 1, ALARM = 2 };
HazardLevel hazard = OK;
String hazardReason = "";

// temperature rate-of-rise
float lastTemp = NAN;
unsigned long lastTempMs = 0;
float tempRoR = 0.0f;  // deg C / min

unsigned long tSensor = 0, tTelemetry = 0;

// CSI heuristic state
volatile float csiMetric = 0.0f;
volatile bool  csiMotion = false;
float csiBaseline = 0.0f;
bool  csiBaselineSet = false;

// ----------------------------- CSI ------------------------------------------
#if ENABLE_CSI
static void csiCallback(void *ctx, wifi_csi_info_t *info) {
  if (!info || !info->buf || info->len <= 0) return;

  // FIX: skip packets flagged as invalid by the hardware
  if (info->rx_ctrl.first_word_invalid) return;

  const int8_t *buf = info->buf;
  int pairs = info->len / 2;          // buf is interleaved I/Q (int8)
  if (pairs <= 0) return;
  double sumAmp = 0.0;
  for (int i = 0; i < pairs; i++) {
    int8_t I = buf[2 * i];
    int8_t Q = buf[2 * i + 1];
    sumAmp += sqrt((double)(I * I + Q * Q));
  }
  float avgAmp = (float)(sumAmp / pairs);

  if (!csiBaselineSet) { csiBaseline = avgAmp; csiBaselineSet = true; }
  csiBaseline = 0.99f * csiBaseline + 0.01f * avgAmp;
  float dev = fabsf(avgAmp - csiBaseline);
  csiMetric = 0.7f * csiMetric + 0.3f * dev;
  csiMotion = (csiMetric > 1.5f);   // CALIBRATE threshold
}

static void setupCSI() {
  wifi_csi_config_t cfg = {};
  cfg.lltf_en = true;
  cfg.htltf_en = true;
  cfg.stbc_htltf2_en = true;
  cfg.ltf_merge_en = true;
  cfg.channel_filter_en = true;
  cfg.manu_scale = false;
  esp_wifi_set_csi_config(&cfg);
  esp_wifi_set_csi_rx_cb(&csiCallback, NULL);
  esp_wifi_set_csi(true);
}
#endif

// ----------------------------- ALARM I/O ------------------------------------
void setLed(HazardLevel lvl) {
  switch (lvl) {
    case OK:      pixel.setPixelColor(0, pixel.Color(0, 30, 0));   break; // green
    case WARNING: pixel.setPixelColor(0, pixel.Color(60, 40, 0));  break; // amber
    case ALARM:   pixel.setPixelColor(0, pixel.Color(80, 0, 0));   break; // red
  }
  pixel.show();
}

void setBuzzer(bool on) { digitalWrite(BUZZER_PIN, on ? HIGH : LOW); }

// ----------------------------- SENSORS --------------------------------------
void initSensors() {
  Wire.begin(I2C_SDA, I2C_SCL);

  bmeOk = bme.begin(0x76) || bme.begin(0x77);

  // FIX: probe() and start() return ERR_OK (0) on success, not a truthy value.
  // Original code evaluated them as booleans — 0 == false — so sps30Ok was
  // always set to false and the sensor was never read. Fixed with == ERR_OK.
  sps30.begin(&Wire);
  if (sps30.probe() == ERR_OK && sps30.start() == ERR_OK) {
    sps30Ok = true;
  }

  coSerial.begin(9600, SERIAL_8N1, CO_RX, CO_TX);

  radarSerial.begin(256000, SERIAL_8N1, RADAR_RX, RADAR_TX);
  radar.begin(radarSerial);

  analogReadResolution(12);
  // FIX: ADC_11db is deprecated in Arduino ESP32 3.x — use ADC_ATTEN_DB_12
  analogSetPinAttenuation(MQ_ADC_PIN, ADC_ATTEN_DB_12);
}

void readBME() {
  if (!bmeOk) return;
  r.tempC    = bme.readTemperature();
  r.humidity = bme.readHumidity();
  r.pressure = bme.readPressure() / 100.0f;
}

void readSPS30() {
  if (!sps30Ok) return;
  struct sps_values v;
  if (sps30.GetValues(&v) == ERR_OK) {
    r.pm25 = v.MassPM2;
    r.pm10 = v.MassPM10;
  }
}

void readGas() {
  long acc = 0;
  for (int i = 0; i < 8; i++) { acc += analogRead(MQ_ADC_PIN); delay(2); }
  r.gasRaw = acc / 8;
}

// Winsen ZE15-CO active-upload frame: 9 bytes.
// [0]=0xFF start, [4]=conc HIGH, [5]=conc LOW,
// [8]=checksum = (~(sum bytes 1..7) + 1) & 0xFF.
// FIX: added timestamp-based resync — if a partial frame stalls for >2s
// (e.g. after a glitch), idx resets so we don't stay stuck indefinitely.
void readCO() {
  static uint8_t buf[9];
  static int idx = 0;
  static unsigned long lastByteMs = 0;

  // Reset parser if no byte has arrived for 2 seconds mid-frame
  if (idx > 0 && (millis() - lastByteMs) > 2000UL) {
    idx = 0;
  }

  while (coSerial.available()) {
    uint8_t b = coSerial.read();
    lastByteMs = millis();
    if (idx == 0 && b != 0xFF) continue;   // resync on start byte
    buf[idx++] = b;
    if (idx == 9) {
      idx = 0;
      uint8_t sum = 0;
      for (int i = 1; i <= 7; i++) sum += buf[i];
      uint8_t chk = (uint8_t)(~sum + 1);
      if (chk == buf[8]) {
        r.coPpm = (buf[4] << 8) | buf[5];
      }
    }
  }
}

void readRadar() {
  radar.read();
  if (radar.isConnected()) {
    r.presenceRadar = radar.presenceDetected();
  }
}

// --------------------------- HAZARD FUSION ----------------------------------
void updateRateOfRise() {
  unsigned long now = millis();
  if (isnan(r.tempC)) return;
  if (!isnan(lastTemp) && (now - lastTempMs) >= TEMP_HIST_PERIOD) {
    float dtMin = (now - lastTempMs) / 60000.0f;
    tempRoR = (r.tempC - lastTemp) / dtMin;
    lastTemp = r.tempC;
    lastTempMs = now;
  } else if (isnan(lastTemp)) {
    lastTemp = r.tempC;
    lastTempMs = now;
  }
}

void evaluateHazard() {
  HazardLevel lvl = OK;
  String reason = "";

  bool coAlarm  = (r.coPpm >= CO_ALARM_PPM);
  bool gasAlarm = (r.gasRaw >= GAS_ALARM_ADC);
  bool smkAlarm = (!isnan(r.pm25) && r.pm25 >= PM25_ALARM);
  bool fireHeat = (tempRoR >= TEMP_ROR_ALARM) ||
                  (!isnan(r.tempC) && r.tempC >= TEMP_ABS_ALARM);

  bool gasWarn  = (r.gasRaw >= GAS_WARN_ADC);
  bool coWarn   = (r.coPpm  >= CO_WARN_PPM);
  bool smkWarn  = (!isnan(r.pm25) && r.pm25 >= PM25_WARN);

  // ALARM: any single critical threshold, or two corroborating fire signals.
  int fireSignals = (smkAlarm ? 1 : 0) + (coAlarm ? 1 : 0) + (fireHeat ? 1 : 0);

  if (gasAlarm) {
    lvl = ALARM; reason = "combustible_gas";
  } else if (coAlarm) {
    lvl = ALARM; reason = "carbon_monoxide";
  } else if (fireSignals >= 2) {
    // FIX: removed the dead-code "else if (smkAlarm && fireHeat)" branch that
    // followed — it was a strict subset of fireSignals >= 2 and was unreachable.
    lvl = ALARM; reason = "fire_multi";
  } else if (gasWarn || coWarn || smkWarn) {
    lvl = WARNING;
    reason = gasWarn ? "gas_rising" : (coWarn ? "co_rising" : "smoke_rising");
  }

  hazard = lvl;
  hazardReason = reason;

  // LOCAL-FIRST: act immediately, independent of network.
  setLed(lvl);
  setBuzzer(lvl == ALARM);
}

// ----------------------------- MQTT -----------------------------------------
String topic(const char *leaf) {
  return String("building/") + BUILDING_ID + "/node1/" + DEVICE_ID + "/" + leaf;
}

void publishTelemetry() {
  if (!mqtt.connected()) return;
  JsonDocument doc;
  doc["device"]   = DEVICE_ID;
  doc["ts"]       = millis();
  doc["temp_c"]   = r.tempC;
  doc["humidity"] = r.humidity;
  doc["pm25"]     = r.pm25;
  doc["pm10"]     = r.pm10;
  doc["gas_raw"]  = r.gasRaw;
  doc["co_ppm"]   = r.coPpm;
  doc["temp_ror"] = tempRoR;
  doc["presence_radar"] = r.presenceRadar;
  doc["presence_csi"]   = csiMotion;
  doc["hazard"]   = (int)hazard;
  char out[512];
  serializeJson(doc, out);
  mqtt.publish(topic("telemetry").c_str(), out);
}

void publishAlert() {
  if (!mqtt.connected()) return;
  JsonDocument doc;
  doc["device"]   = DEVICE_ID;
  doc["level"]    = (int)hazard;
  doc["reason"]   = hazardReason;
  doc["co_ppm"]   = r.coPpm;
  doc["pm25"]     = r.pm25;
  doc["gas_raw"]  = r.gasRaw;
  doc["temp_c"]   = r.tempC;
  doc["temp_ror"] = tempRoR;
  char out[512];
  serializeJson(doc, out);
  mqtt.publish(topic("alert").c_str(), out, true); // retained
}

void mqttReconnect() {
  if (mqtt.connected()) return;
  if (mqtt.connect(DEVICE_ID, MQTT_USER, MQTT_PASS,
                   topic("status").c_str(), 1, true, "offline")) {
    mqtt.publish(topic("status").c_str(), "online", true);
  }
}

// ----------------------------- SETUP/LOOP -----------------------------------
void setup() {
  Serial.begin(115200);
  pinMode(BUZZER_PIN, OUTPUT);
  setBuzzer(false);
  pixel.begin();
  pixel.setBrightness(40);
  setLed(OK);

  initSensors();

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 15000) delay(200);

#if ENABLE_CSI
  if (WiFi.status() == WL_CONNECTED) setupCSI();
#endif

  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setBufferSize(512);
}

void loop() {
  if (WiFi.status() == WL_CONNECTED) {
    mqttReconnect();
    mqtt.loop();
  }

  readRadar();  // keep radar serial drained continuously
  readCO();     // drain CO frames continuously

  unsigned long now = millis();
  if (now - tSensor >= SENSOR_PERIOD) {
    tSensor = now;
    readBME();
    readSPS30();
    readGas();
    updateRateOfRise();

    HazardLevel prev = hazard;
    evaluateHazard();
    if (hazard != prev && hazard != OK) publishAlert(); // edge-triggered alert
  }

  if (now - tTelemetry >= TELEMETRY_PERIOD) {
    tTelemetry = now;
    publishTelemetry();
  }
}
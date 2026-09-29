#include "AirController.h"
#include "ConfigStore.h"
#include "DeviceConfig.h"
#include "HardwareConfig.h"
#include "HttpApi.h"
#include "Ld2410Reader.h"
#include "MqttService.h"
#include "NetworkConfig.h"
#include "Pms5003Reader.h"
#include "SensorReadings.h"
#include "Ze03Reader.h"

#include <Arduino.h>
#include <WiFi.h>

#include <memory>

// Status serialization and the JSON parser both build their documents on the
// stack, and three UART readers run in the same loop. The default 8 KB loop
// task is too tight for that.
SET_LOOP_TASK_STACK_SIZE(16 * 1024);

namespace {

std::unique_ptr<ConfigStore> configStore;
std::unique_ptr<AirController> controller;
std::unique_ptr<NetworkConfig> networkConfig;
std::unique_ptr<HttpApi> httpApi;
std::unique_ptr<MqttService> mqttService;
DeviceConfig deviceConfig{};
DeviceConfig pendingDeviceConfig{};

HardwareSerial coSerial(Hardware::CO_UART);
HardwareSerial presenceSerial(Hardware::PRESENCE_UART);
HardwareSerial particulateSerial(Hardware::PARTICULATE_UART);

Ze03Reader coReader;
Ld2410Reader presenceReader;
Pms5003Reader particulateReader;

uint32_t lastGasSampleMs = 0;
uint32_t gasSampleSum = 0;
uint8_t gasSampleCount = 0;
uint16_t latestGasAdc = 0;
uint32_t lastCoRecoveryMs = 0;

ClimateReading latestClimate{0, 0};
uint32_t climateUpdatedMs = 0;
bool climateSampled = false;

PresenceReading latestPresence{false, false, false, 0, 0, 0, 0, 0};
uint32_t presenceUpdatedMs = 0;
bool presenceSampled = false;

bool configSavePending = false;
bool configSaveImmediate = false;
uint32_t lastConfigSaveAttemptMs = 0;
bool rebootScheduled = false;
uint32_t rebootScheduledAtMs = 0;
bool networkServicesStarted = false;
bool configButtonWasPressed = false;
uint32_t configButtonPressedAtMs = 0;

// Survives ESP.restart() but not a power cycle, so a runtime button hold can
// ask the next boot to open the setup portal.
constexpr uint32_t PORTAL_REQUEST_MARKER = 0x504F5254;  // "PORT"
RTC_NOINIT_ATTR uint32_t portalRequestMarker;

bool elapsed(uint32_t nowMs, uint32_t sinceMs, uint32_t intervalMs) {
  return static_cast<uint32_t>(nowMs - sinceMs) >= intervalMs;
}

template <typename Reading>
Sampled<Reading> sampled(const Reading& value, bool everSampled,
                         uint32_t updatedMs, uint32_t nowMs,
                         uint32_t timeoutMs) {
  const uint32_t ageMs =
      everSampled ? static_cast<uint32_t>(nowMs - updatedMs) : 0;
  return Sampled<Reading>{value, everSampled && ageMs < timeoutMs, ageMs};
}

RuntimeStatus runtimeStatus() {
  const uint32_t nowMs = millis();
  const bool wifiConnected = networkConfig && networkConfig->wifiConnected();
  return RuntimeStatus{
      nowMs,
      sampled(latestClimate, climateSampled, climateUpdatedMs, nowMs,
              Hardware::SENSOR_TIMEOUT_MS),
      sampled(latestPresence, presenceSampled, presenceUpdatedMs, nowMs,
              Hardware::PRESENCE_TIMEOUT_MS),
      wifiConnected,
      wifiConnected ? WiFi.RSSI() : 0,
      mqttService && mqttService->connected(),
      httpApi && httpApi->otaInProgress(),
  };
}

void notifyStateChanged() {
  if (mqttService) {
    mqttService->requestStatusPublish();
  }
}

void applyLedOutput(uint32_t nowMs) {
  const LedRgb rgb = ledRgbFor(controller->ledColor(nowMs));
  const uint8_t brightness =
      controller->ledOn(nowMs) ? controller->ledBrightness(nowMs) : 0;
  analogWrite(Hardware::LED_RED_PIN,
              ledDutyFor(rgb.red, brightness, Hardware::LED_COMMON_ANODE));
  analogWrite(Hardware::LED_GREEN_PIN,
              ledDutyFor(rgb.green, brightness, Hardware::LED_COMMON_ANODE));
  analogWrite(Hardware::LED_BLUE_PIN,
              ledDutyFor(rgb.blue, brightness, Hardware::LED_COMMON_ANODE));
}

void applyBuzzerOutput(uint32_t nowMs) {
  const bool active = controller && controller->buzzerOutput(nowMs);
  digitalWrite(Hardware::BUZZER_PIN,
               Hardware::outputLevel(active, Hardware::BUZZER_ACTIVE_HIGH));
}

void applyOutputs(uint32_t nowMs) {
  applyBuzzerOutput(nowMs);
  if (controller) {
    applyLedOutput(nowMs);
  }
}

void pumpCoSensor(uint32_t nowMs) {
  for (size_t bytesRead = 0;
       bytesRead < Hardware::UART_BYTES_PER_LOOP && coSerial.available() > 0;
       ++bytesRead) {
    const int input = coSerial.read();
    if (input < 0) {
      break;
    }
    if (coReader.consume(static_cast<uint8_t>(input))) {
      controller->updateCo(coReader.reading(), nowMs);
    }
  }

  if (!Hardware::CO_SEND_RECOVERY_COMMAND || controller->coFresh(nowMs) ||
      !elapsed(nowMs, lastCoRecoveryMs, Hardware::CO_RECOVERY_INTERVAL_MS)) {
    return;
  }
  lastCoRecoveryMs = nowMs;
  size_t length = 0;
  const uint8_t* command = Ze03Reader::activeUploadRequest(length);
  coSerial.write(command, length);
}

ClimateReading calibratedClimate(const ClimateReading& raw) {
  ClimateReading corrected = raw;
  corrected.temperatureTenthsC = static_cast<int16_t>(
      raw.temperatureTenthsC + Hardware::CLIMATE_TEMPERATURE_OFFSET_TENTHS_C);
  const int32_t humidity =
      static_cast<int32_t>(raw.humidityTenthsPercent) +
      Hardware::CLIMATE_HUMIDITY_OFFSET_TENTHS_PERCENT;
  corrected.humidityTenthsPercent =
      static_cast<uint16_t>(humidity < 0 ? 0 : humidity > 1000 ? 1000 : humidity);
  return corrected;
}

void pumpParticulateSensor(uint32_t nowMs) {
  for (size_t bytesRead = 0; bytesRead < Hardware::UART_BYTES_PER_LOOP &&
                             particulateSerial.available() > 0;
       ++bytesRead) {
    const int input = particulateSerial.read();
    if (input < 0) {
      break;
    }
    if (!particulateReader.consume(static_cast<uint8_t>(input))) {
      continue;
    }
    controller->updateParticulate(particulateReader.particulate(), nowMs);
    latestClimate = calibratedClimate(particulateReader.climate());
    climateUpdatedMs = nowMs;
    climateSampled = true;
  }
}

void pumpPresenceSensor(uint32_t nowMs) {
  for (size_t bytesRead = 0; bytesRead < Hardware::UART_BYTES_PER_LOOP &&
                             presenceSerial.available() > 0;
       ++bytesRead) {
    const int input = presenceSerial.read();
    if (input < 0) {
      break;
    }
    if (!presenceReader.consume(static_cast<uint8_t>(input))) {
      continue;
    }
    latestPresence = presenceReader.reading();
    presenceUpdatedMs = nowMs;
    presenceSampled = true;
  }
}

void sampleGasSensor(uint32_t nowMs) {
  if (!elapsed(nowMs, lastGasSampleMs, Hardware::GAS_SAMPLE_INTERVAL_MS)) {
    return;
  }
  lastGasSampleMs = nowMs;
  gasSampleSum += analogRead(Hardware::GAS_ADC_PIN);
  if (++gasSampleCount < Hardware::GAS_AVERAGE_SAMPLES) {
    return;
  }
  latestGasAdc = static_cast<uint16_t>(gasSampleSum / gasSampleCount);
  controller->updateGas(latestGasAdc, nowMs);
  gasSampleSum = 0;
  gasSampleCount = 0;
}

void queueConfigurationSave(const DeviceConfig& config) {
  pendingDeviceConfig = config;
  configSavePending = true;
  configSaveImmediate = true;
  rebootScheduled = false;
}

void processConfigurationSave(uint32_t nowMs) {
  if (!configSavePending ||
      (!configSaveImmediate &&
       !elapsed(nowMs, lastConfigSaveAttemptMs, Hardware::CONFIG_SAVE_RETRY_MS))) {
    return;
  }

  if (configStore->saveConfig(pendingDeviceConfig)) {
    Serial.println("[config] saved; restarting to apply");
    deviceConfig = pendingDeviceConfig;
    configSavePending = false;
    configSaveImmediate = false;
    rebootScheduled = true;
    rebootScheduledAtMs = nowMs;
    return;
  }

  Serial.println("[config] save failed; retrying");
  configSaveImmediate = false;
  lastConfigSaveAttemptMs = nowMs;
}

void restartWhenSafe(uint32_t nowMs) {
  if (!rebootScheduled || configSavePending ||
      !elapsed(nowMs, rebootScheduledAtMs, Hardware::CONFIG_REBOOT_DELAY_MS)) {
    return;
  }
  applyOutputs(nowMs);
  ESP.restart();
}

bool configButtonPressed() {
  const int level = digitalRead(Hardware::CONFIG_BUTTON_PIN);
  return Hardware::CONFIG_BUTTON_ACTIVE_LOW ? level == LOW : level == HIGH;
}

// GPIO0 is a boot strapping pin, so holding it through reset enters the ROM
// download mode instead of this firmware. The portal is therefore requested by
// holding the button while the firmware runs (see pollConfigButton), which
// restarts with a marker, or by a hold already in progress when setup() runs.
bool configPortalRequested() {
  if (portalRequestMarker == PORTAL_REQUEST_MARKER) {
    portalRequestMarker = 0;
    return true;
  }
  portalRequestMarker = 0;
  if (!configButtonPressed()) {
    return false;
  }
  const uint32_t startedMs = millis();
  while (!elapsed(millis(), startedMs, Hardware::CONFIG_BUTTON_HOLD_MS)) {
    if (!configButtonPressed()) {
      return false;
    }
    delay(10);
  }
  return true;
}

void pollConfigButton(uint32_t nowMs) {
  if (!configButtonPressed()) {
    configButtonWasPressed = false;
    return;
  }
  if (!configButtonWasPressed) {
    configButtonWasPressed = true;
    configButtonPressedAtMs = nowMs;
    return;
  }
  if (!elapsed(nowMs, configButtonPressedAtMs, Hardware::CONFIG_BUTTON_HOLD_MS) ||
      configSavePending ||
      (networkServicesStarted && httpApi->otaInProgress())) {
    return;
  }
  Serial.println("[config] button held; restarting into setup portal");
  portalRequestMarker = PORTAL_REQUEST_MARKER;
  applyOutputs(nowMs);
  ESP.restart();
}

void configureLedPin(uint8_t pin) {
  pinMode(pin, OUTPUT);
  analogWriteResolution(pin, Hardware::LED_PWM_RESOLUTION_BITS);
  analogWriteFrequency(pin, Hardware::LED_PWM_FREQUENCY_HZ);
}

}  // namespace

void setup() {
  digitalWrite(Hardware::BUZZER_PIN,
               Hardware::outputLevel(false, Hardware::BUZZER_ACTIVE_HIGH));
  pinMode(Hardware::BUZZER_PIN, OUTPUT);
  configureLedPin(Hardware::LED_RED_PIN);
  configureLedPin(Hardware::LED_GREEN_PIN);
  configureLedPin(Hardware::LED_BLUE_PIN);
  pinMode(Hardware::CONFIG_BUTTON_PIN, INPUT_PULLUP);

  Serial.begin(115200);
  // Every begin() passes explicit pins. Serial2 defaults to GPIO19/20 on this
  // chip, which are USB_D-/USB_D+: letting it use its defaults would detach
  // the USB console mid-sketch with no error.
  coSerial.setRxBufferSize(Hardware::UART_RX_BUFFER_BYTES);
  coSerial.begin(Hardware::CO_BAUD, SERIAL_8N1, Hardware::CO_RX_PIN,
                 Hardware::CO_TX_PIN);
  presenceSerial.setRxBufferSize(Hardware::UART_RX_BUFFER_BYTES);
  presenceSerial.begin(Hardware::PRESENCE_BAUD, SERIAL_8N1,
                       Hardware::PRESENCE_RX_PIN, Hardware::PRESENCE_TX_PIN);
  particulateSerial.setRxBufferSize(Hardware::UART_RX_BUFFER_BYTES);
  particulateSerial.begin(Hardware::PARTICULATE_BAUD, SERIAL_8N1,
                          Hardware::PARTICULATE_RX_PIN,
                          Hardware::PARTICULATE_TX_PIN);

  analogReadResolution(12);
  analogSetPinAttenuation(Hardware::GAS_ADC_PIN, ADC_11db);

  configStore = std::make_unique<ConfigStore>();
  configStore->begin();
  deviceConfig = configStore->loadConfig();

  const AirConfig airConfig{
      deviceConfig.coWarnPpm,
      deviceConfig.coDangerPpm,
      deviceConfig.gasWarnAdc,
      deviceConfig.gasDangerAdc,
      deviceConfig.pm25WarnUgm3,
      deviceConfig.pm25DangerUgm3,
      deviceConfig.pm10WarnUgm3,
      deviceConfig.pm10DangerUgm3,
      deviceConfig.sensorWarmupSeconds * 1000UL,
      Hardware::ALARM_TRIGGER_HOLD_MS,
      Hardware::ALARM_CLEAR_HOLD_MS,
      Hardware::SENSOR_TIMEOUT_MS,
      deviceConfig.alarmSilenceSeconds * 1000UL,
      Hardware::SELF_TEST_MS,
  };
  controller = std::make_unique<AirController>(airConfig);
  controller->begin(millis());
  lastCoRecoveryMs = millis();
  applyOutputs(millis());

  const bool forcePortal = configPortalRequested();
  Serial.printf("[boot] air-sensor firmware %s, stored api_token length=%u%s\n",
                Hardware::FIRMWARE_VERSION,
                static_cast<unsigned>(
                    strnlen(deviceConfig.apiToken, sizeof(deviceConfig.apiToken))),
                forcePortal ? ", opening setup portal" : "");
  networkConfig = std::make_unique<NetworkConfig>();
  httpApi = std::make_unique<HttpApi>(deviceConfig, *controller, runtimeStatus,
                                      notifyStateChanged);
  mqttService = std::make_unique<MqttService>(deviceConfig, *controller,
                                              runtimeStatus);
  networkConfig->begin(deviceConfig, forcePortal);
}

void loop() {
  const uint32_t nowMs = millis();
  pumpCoSensor(nowMs);
  pumpParticulateSensor(nowMs);
  pumpPresenceSensor(nowMs);
  sampleGasSensor(nowMs);
  if (controller->tick(nowMs)) {
    notifyStateChanged();
  }
  applyOutputs(nowMs);
  pollConfigButton(nowMs);

  networkConfig->process();
  if (!networkServicesStarted && networkConfig->ready()) {
    httpApi->begin();
    mqttService->begin();
    networkServicesStarted = true;
  }
  if (networkServicesStarted) {
    httpApi->handleClient();
  }

  const uint32_t serviceNowMs = millis();
  DeviceConfig changedConfig{};
  if (networkConfig->takeConfigChanged(changedConfig)) {
    queueConfigurationSave(changedConfig);
  }

  if (networkServicesStarted) {
    mqttService->process(serviceNowMs);
  }
  // MQTT commands are applied above by the safety-loop owner; reflect a
  // silence or a self-test without waiting for the next pass through loop().
  applyOutputs(serviceNowMs);
  processConfigurationSave(serviceNowMs);
  restartWhenSafe(millis());

  if (networkServicesStarted && httpApi->rebootDue(millis())) {
    applyOutputs(millis());
    ESP.restart();
  }
}

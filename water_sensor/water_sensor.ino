#include "ConfigStore.h"
#include "DeviceConfig.h"
#include "HardwareConfig.h"
#include "HttpApi.h"
#include "LeakController.h"
#include "MqttService.h"
#include "NetworkConfig.h"
#include "PersistenceRetry.h"

#include <Arduino.h>
#include <WiFi.h>

#include <memory>

namespace {

std::unique_ptr<ConfigStore> configStore;
std::unique_ptr<LeakController> controller;
std::unique_ptr<NetworkConfig> networkConfig;
std::unique_ptr<HttpApi> httpApi;
std::unique_ptr<MqttService> mqttService;
DeviceConfig deviceConfig{};
DeviceConfig pendingDeviceConfig{};
uint32_t lastSampleMs = 0;
uint32_t sampleSum = 0;
uint8_t sampleCount = 0;
uint16_t latestAdc = 0;
PersistenceRetry pendingPersistence;
bool configSavePending = false;
bool configSaveImmediate = false;
uint32_t lastConfigSaveAttemptMs = 0;
bool configRebootPending = false;
bool closeStateSavedForReboot = false;
bool rebootScheduled = false;
uint32_t rebootScheduledAtMs = 0;

RuntimeStatus runtimeStatus() {
  const bool wifiConnected = networkConfig && networkConfig->wifiConnected();
  return RuntimeStatus{
      millis(),
      latestAdc,
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

void applyValveOutput() {
  const bool valveClosed = !controller || controller->valveState() == ValveState::Closed;
  digitalWrite(Hardware::RELAY_PIN,
               Hardware::outputLevel(valveClosed, Hardware::RELAY_ACTIVE_HIGH));
}

void applyBuzzerOutput(uint32_t nowMs) {
  const bool buzzerActive = controller && controller->buzzerOutput(nowMs);
  digitalWrite(Hardware::BUZZER_PIN,
               Hardware::outputLevel(buzzerActive, Hardware::BUZZER_ACTIVE_HIGH));
}

void applyOutputs(uint32_t nowMs) {
  applyValveOutput();
  applyBuzzerOutput(nowMs);
}

void sampleSensor(uint32_t nowMs) {
  if (static_cast<uint32_t>(nowMs - lastSampleMs) <
      Hardware::SENSOR_SAMPLE_INTERVAL_MS) {
    return;
  }
  lastSampleMs = nowMs;
  sampleSum += analogRead(Hardware::SENSOR_ADC_PIN);
  if (++sampleCount == Hardware::SENSOR_AVERAGE_SAMPLES) {
    latestAdc = static_cast<uint16_t>(sampleSum / sampleCount);
    if (controller->updateSensor(latestAdc, nowMs)) {
      notifyStateChanged();
    }
    sampleSum = 0;
    sampleCount = 0;
  }
}

bool elapsed(uint32_t nowMs, uint32_t sinceMs, uint32_t intervalMs) {
  return static_cast<uint32_t>(nowMs - sinceMs) >= intervalMs;
}

void queueConfigurationSave(const DeviceConfig& config, uint32_t nowMs) {
  pendingDeviceConfig = config;
  configSavePending = true;
  configSaveImmediate = true;
  configRebootPending = true;
  closeStateSavedForReboot = false;
  rebootScheduled = false;

  controller->requestValve(ValveState::Closed, nowMs);
  pendingPersistence.update(controller->persistentState());
  applyOutputs(nowMs);
}

void collectControllerPersistence() {
  if (!controller->takePersistentDirty()) {
    return;
  }
  pendingPersistence.update(controller->persistentState());
  if (configRebootPending) {
    closeStateSavedForReboot = false;
    rebootScheduled = false;
  }
}

void processConfigurationSave(uint32_t nowMs) {
  if (!configSavePending ||
      (!configSaveImmediate &&
       !elapsed(nowMs, lastConfigSaveAttemptMs,
                PersistenceRetry::RETRY_INTERVAL_MS))) {
    return;
  }

  if (configStore->saveConfig(pendingDeviceConfig)) {
    deviceConfig = pendingDeviceConfig;
    configSavePending = false;
    configSaveImmediate = false;
    return;
  }

  configSaveImmediate = false;
  lastConfigSaveAttemptMs = nowMs;
}

void processStateSave(uint32_t nowMs) {
  if (!pendingPersistence.due(nowMs)) {
    return;
  }

  const PersistentState attemptedState = pendingPersistence.state();
  const bool saved = configStore->saveState(attemptedState);
  pendingPersistence.recordResult(saved, nowMs);
  if (configRebootPending) {
    closeStateSavedForReboot =
        saved && attemptedState.requestedValve == ValveState::Closed;
    if (!saved) {
      rebootScheduled = false;
    }
  }
}

void updateRebootSchedule(uint32_t nowMs) {
  if (!configRebootPending || configSavePending ||
      !closeStateSavedForReboot || rebootScheduled) {
    return;
  }
  rebootScheduled = true;
  rebootScheduledAtMs = nowMs;
}

void restartWhenSafe(uint32_t nowMs) {
  if (!rebootScheduled || configSavePending ||
      !closeStateSavedForReboot ||
      !elapsed(nowMs, rebootScheduledAtMs, 500)) {
    return;
  }

  controller->requestValve(ValveState::Closed, nowMs);
  if (controller->takePersistentDirty()) {
    pendingPersistence.update(controller->persistentState());
    closeStateSavedForReboot = false;
    rebootScheduled = false;
    return;
  }
  applyOutputs(nowMs);
  ESP.restart();
}

}  // namespace

void setup() {
  digitalWrite(Hardware::RELAY_PIN,
               Hardware::outputLevel(true, Hardware::RELAY_ACTIVE_HIGH));
  pinMode(Hardware::RELAY_PIN, OUTPUT);
  digitalWrite(Hardware::BUZZER_PIN,
               Hardware::outputLevel(false, Hardware::BUZZER_ACTIVE_HIGH));
  pinMode(Hardware::BUZZER_PIN, OUTPUT);
  pinMode(Hardware::CONFIG_BUTTON_PIN, INPUT_PULLUP);

  Serial.begin(115200);

  configStore = std::make_unique<ConfigStore>();
  configStore->begin();
  deviceConfig = configStore->loadConfig();

  const LeakConfig leakConfig{
      deviceConfig.wetThreshold,
      deviceConfig.dryThreshold,
      deviceConfig.debounceMs,
      deviceConfig.alarmDurationSeconds * 1000UL,
      Hardware::BUZZER_BEEP_ON_MS,
      Hardware::BUZZER_BEEP_OFF_MS,
  };
  controller = std::make_unique<LeakController>(leakConfig);
  controller->restore(configStore->loadState(), millis());
  analogReadResolution(12);
  pinMode(Hardware::SENSOR_ADC_PIN, INPUT);
  applyOutputs(millis());

  const int configButtonLevel = digitalRead(Hardware::CONFIG_BUTTON_PIN);
  const bool forcePortal = Hardware::CONFIG_BUTTON_ACTIVE_LOW
                               ? configButtonLevel == LOW
                               : configButtonLevel == HIGH;
  networkConfig = std::make_unique<NetworkConfig>();
  networkConfig->begin(deviceConfig, forcePortal);
  httpApi = std::make_unique<HttpApi>(deviceConfig, *controller, *configStore,
                                      runtimeStatus, notifyStateChanged);
  httpApi->begin();
  mqttService = std::make_unique<MqttService>(deviceConfig, *controller,
                                              *configStore, runtimeStatus);
  mqttService->begin();
}

void loop() {
  const uint32_t nowMs = millis();
  sampleSensor(nowMs);
  if (controller->tick(nowMs)) {
    notifyStateChanged();
  }
  applyOutputs(nowMs);
  httpApi->handleClient();

  networkConfig->process();
  const uint32_t persistenceNowMs = millis();
  DeviceConfig changedConfig{};
  if (networkConfig->takeConfigChanged(changedConfig)) {
    queueConfigurationSave(changedConfig, persistenceNowMs);
  }

  mqttService->process(persistenceNowMs);
  // MQTT commands are applied above by the safety-loop owner; reflect a
  // commanded closure/opening before persistence and without waiting for the
  // next pass through loop().
  applyOutputs(persistenceNowMs);
  collectControllerPersistence();
  processConfigurationSave(persistenceNowMs);
  processStateSave(persistenceNowMs);
  updateRebootSchedule(persistenceNowMs);
  restartWhenSafe(millis());

  if (httpApi->rebootDue(millis())) {
    controller->requestValve(ValveState::Closed, millis());
    applyOutputs(millis());
    ESP.restart();
  }
}

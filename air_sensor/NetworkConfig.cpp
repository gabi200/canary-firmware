#include "NetworkConfig.h"

#include "HardwareConfig.h"
#include "Hostname.h"

#include <ESPmDNS.h>
#include <WiFi.h>
#include <esp_wifi.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

constexpr char PASSWORD_ATTRIBUTES[] =
    "type=\"password\" autocomplete=\"new-password\"";
constexpr char BOOLEAN_ATTRIBUTES[] =
    "type=\"number\" min=\"0\" max=\"1\" step=\"1\"";
constexpr char PORT_ATTRIBUTES[] =
    "type=\"number\" min=\"1\" max=\"65535\" step=\"1\"";
constexpr char ADC_ATTRIBUTES[] =
    "type=\"number\" min=\"1\" max=\"4095\" step=\"1\"";
constexpr char PPM_ATTRIBUTES[] =
    "type=\"number\" min=\"1\" max=\"2000\" step=\"1\"";
constexpr char UGM3_ATTRIBUTES[] =
    "type=\"number\" min=\"1\" max=\"1000\" step=\"1\"";
constexpr char SECONDS_ATTRIBUTES[] =
    "type=\"number\" min=\"10\" max=\"3600\" step=\"1\"";
constexpr uint32_t NETWORK_TASK_STACK_BYTES = 8192;
constexpr UBaseType_t NETWORK_TASK_PRIORITY = tskIDLE_PRIORITY;
// Wi-Fi outage before the ESP-NOW fallback holds the channel, and how often
// Wi-Fi is retried while it does.
constexpr uint32_t MESH_FALLBACK_AFTER_MS = 20000;
constexpr uint32_t WIFI_RETRY_INTERVAL_MS = 30000;
constexpr uint32_t WIFI_RETRY_WINDOW_MS = 10000;

bool elapsed(uint32_t nowMs, uint32_t sinceMs, uint32_t intervalMs) {
  return static_cast<uint32_t>(nowMs - sinceMs) >= intervalMs;
}

template <size_t Capacity>
bool copyText(char (&destination)[Capacity], const char* source) {
  if (source == nullptr) {
    return false;
  }
  const size_t length = strnlen(source, Capacity);
  if (length >= Capacity) {
    return false;
  }
  std::memcpy(destination, source, length + 1);
  return true;
}

bool parseUnsigned(const char* text, uint32_t maximum, uint32_t& output) {
  if (text == nullptr || text[0] < '0' || text[0] > '9') {
    return false;
  }

  errno = 0;
  char* end = nullptr;
  const unsigned long value = std::strtoul(text, &end, 10);
  if (errno == ERANGE || end == text || *end != '\0' || value > maximum) {
    return false;
  }
  output = static_cast<uint32_t>(value);
  return true;
}

void setUnsignedValue(WiFiManagerParameter& parameter,
                      uint32_t value,
                      int maximumLength) {
  char buffer[11];
  std::snprintf(buffer, sizeof(buffer), "%lu", static_cast<unsigned long>(value));
  parameter.setValue(buffer, maximumLength);
}

}  // namespace

NetworkConfig* NetworkConfig::callbackOwner_ = nullptr;

NetworkConfig::NetworkConfig()
    : deviceNameParam_("device_name", "Device name", "", 32),
      mqttEnabledParam_(
          "mqtt_enabled", "MQTT enabled (0 or 1)", "0", 1, BOOLEAN_ATTRIBUTES),
      gasDetectorEnabledParam_(
          "gas_detector_enabled", "External gas detector connected (0 or 1)", "0", 1, BOOLEAN_ATTRIBUTES),
      mqttHostParam_("mqtt_host", "MQTT host", "", 64),
      mqttPortParam_("mqtt_port", "MQTT port", "1883", 5, PORT_ATTRIBUTES),
      mqttUserParam_("mqtt_user", "MQTT user", "", 32),
      mqttPasswordParam_(
          "mqtt_password", "MQTT password (leave blank to keep)", "", 64,
          PASSWORD_ATTRIBUTES),
      mqttTopicParam_("mqtt_topic", "MQTT base topic", "", 64),
      apiTokenParam_(
          "api_token", "API token (12-64 chars; blank keeps existing)", "", 64,
          PASSWORD_ATTRIBUTES),
      coWarnParam_("co_warn_ppm", "CO warning ppm", "50", 4, PPM_ATTRIBUTES),
      coDangerParam_(
          "co_danger_ppm", "CO danger ppm", "100", 4, PPM_ATTRIBUTES),
      gasWarnParam_(
          "gas_warn_adc", "MQ5 warning ADC", "1200", 4, ADC_ATTRIBUTES),
      gasDangerParam_(
          "gas_danger_adc", "MQ5 danger ADC", "1760", 4, ADC_ATTRIBUTES),
      warmupParam_(
          "warmup_seconds", "Sensor warm-up seconds", "300", 4,
          SECONDS_ATTRIBUTES),
      pm25WarnParam_(
          "pm25_warn", "PM2.5 warning ug/m3", "35", 4, UGM3_ATTRIBUTES),
      pm25DangerParam_(
          "pm25_danger", "PM2.5 danger ug/m3", "150", 4, UGM3_ATTRIBUTES),
      pm10WarnParam_(
          "pm10_warn", "PM10 warning ug/m3", "100", 4, UGM3_ATTRIBUTES),
      pm10DangerParam_(
          "pm10_danger", "PM10 danger ug/m3", "250", 4, UGM3_ATTRIBUTES),
      silenceParam_(
          "silence_seconds", "Alarm silence seconds", "300", 4,
          SECONDS_ATTRIBUTES),
      currentConfig_{},
      handoffConfig_{},
      pendingConfig_{},
      submissionPolicy_(false),
      savedWifiSsid_(),
      savedWifiPassword_(),
      handoffMutex_(nullptr),
      taskHandle_(nullptr),
      wifiConnected_(false),
      portalActive_(false),
      ready_(false),
      taskStarted_(false),
      forcePortal_(false),
      handoffChanged_(false),
      configChanged_(false),
      recoveryPending_(false),
      captureCredentialsPending_(false),
      recoveryAction_(PortalSubmissionAction::ClearCredentialsAndRestart),
      apName_{},
      hostname_{},
      discoveryStarted_(false),
      meshFallback_(false),
      meshChannel_(0),
      lastConnectedMs_(0),
      wifiRetryMs_(0) {}

void NetworkConfig::begin(DeviceConfig& config, bool forcePortal) {
  if (taskStarted_) {
    return;
  }
  taskStarted_ = true;
  currentConfig_ = config;
  handoffConfig_ = config;
  pendingConfig_ = config;
  submissionPolicy_ = PortalSubmissionPolicy(validateDeviceConfig(config).valid);
  forcePortal_ = submissionPolicy_.shouldForcePortal(forcePortal);
  std::snprintf(apName_, sizeof(apName_), "%s-setup", config.deviceName);
  makeHostname(config.deviceName, "canary-air", hostname_, sizeof(hostname_));
  handoffMutex_ = xSemaphoreCreateMutex();
  if (handoffMutex_ == nullptr) {
    return;
  }

  xTaskCreate(networkTaskStatic,
              "network-config",
              NETWORK_TASK_STACK_BYTES,
              this,
              NETWORK_TASK_PRIORITY,
              &taskHandle_);
}

void NetworkConfig::process() {
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return;
  }
  if (handoffChanged_) {
    pendingConfig_ = handoffConfig_;
    configChanged_ = true;
    handoffChanged_ = false;
  }
  xSemaphoreGive(handoffMutex_);
}

bool NetworkConfig::wifiConnected() const {
  return wifiConnected_.load(std::memory_order_acquire);
}

bool NetworkConfig::ready() const {
  return ready_.load(std::memory_order_acquire);
}

bool NetworkConfig::portalActive() const {
  return portalActive_.load(std::memory_order_acquire);
}

bool NetworkConfig::takeConfigChanged(DeviceConfig& output) {
  if (!configChanged_) {
    return false;
  }
  output = pendingConfig_;
  configChanged_ = false;
  return true;
}

void NetworkConfig::onSaveStatic() {
  if (callbackOwner_ != nullptr) {
    callbackOwner_->onSave();
  }
}

void NetworkConfig::networkTaskStatic(void* context) {
  static_cast<NetworkConfig*>(context)->networkTask();
}

void NetworkConfig::networkTask() {
  copyConfigToBuffers(currentConfig_);

  callbackOwner_ = this;
  wifiManager_.setDebugOutput(false);
  wifiManager_.setConfigPortalBlocking(false);
  wifiManager_.setConfigPortalTimeout(300);
  wifiManager_.setSaveParamsCallback(onSaveStatic);

  wifiManager_.addParameter(&deviceNameParam_);
  wifiManager_.addParameter(&mqttEnabledParam_);
  wifiManager_.addParameter(&gasDetectorEnabledParam_);
  wifiManager_.addParameter(&mqttHostParam_);
  wifiManager_.addParameter(&mqttPortParam_);
  wifiManager_.addParameter(&mqttUserParam_);
  wifiManager_.addParameter(&mqttPasswordParam_);
  wifiManager_.addParameter(&mqttTopicParam_);
  wifiManager_.addParameter(&apiTokenParam_);
  wifiManager_.addParameter(&coWarnParam_);
  wifiManager_.addParameter(&coDangerParam_);
  wifiManager_.addParameter(&gasWarnParam_);
  wifiManager_.addParameter(&gasDangerParam_);
  wifiManager_.addParameter(&warmupParam_);
  wifiManager_.addParameter(&pm25WarnParam_);
  wifiManager_.addParameter(&pm25DangerParam_);
  wifiManager_.addParameter(&pm10WarnParam_);
  wifiManager_.addParameter(&pm10DangerParam_);
  wifiManager_.addParameter(&silenceParam_);

  // Set before the STA interface starts so DHCP registers the name too.
  WiFi.setHostname(hostname_);
  WiFi.mode(WIFI_STA);
  // Modem sleep turns the receiver off between beacons and would miss
  // neighbours' ESP-NOW frames.
  WiFi.setSleep(false);
  captureStoredWiFiCredentials();
  if (forcePortal_) {
    Serial.printf("[network] starting setup portal: %s\n", apName_);
    wifiManager_.startConfigPortal(apName_);
  } else {
    wifiManager_.autoConnect(apName_);
  }
  publishNetworkStatus();
  ready_.store(true, std::memory_order_release);

  for (;;) {
    wifiManager_.process();
    handleSubmissionRecovery();
    // The parameter callback runs before WiFiManager handles any submitted
    // Wi-Fi network. Publish once process() has returned, so the main loop
    // cannot restart while WiFiManager is still saving credentials.
    if (captureCredentialsPending_ && submissionPolicy_.takePublishReady()) {
      captureStoredWiFiCredentials();
      captureCredentialsPending_ = false;
      if (xSemaphoreTake(handoffMutex_, portMAX_DELAY) == pdTRUE) {
        handoffConfig_ = currentConfig_;
        handoffChanged_ = true;
        Serial.println("[config] portal settings handed to main loop");
        xSemaphoreGive(handoffMutex_);
      }
    }
    publishNetworkStatus();
    manageMeshFallback();
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void NetworkConfig::onSave() {
  // Log only the token's length: the value itself must never reach the console.
  const size_t submittedTokenLength =
      strnlen(apiTokenParam_.getValue(), sizeof(currentConfig_.apiToken));
  if (submittedTokenLength == 0) {
    Serial.println("[config] portal save: api_token blank, keeping stored token");
  } else {
    Serial.printf("[config] portal save: api_token submitted, length=%u\n",
                  static_cast<unsigned>(submittedTokenLength));
  }
  DeviceConfig candidate{};
  const bool valid = copyBuffersToConfig(candidate);

  // WiFiManager keeps submitted values in its parameter buffers. Clear secrets
  // before the portal can render another page, regardless of validation result.
  mqttPasswordParam_.setValue("", sizeof(currentConfig_.mqttPassword) - 1);
  apiTokenParam_.setValue("", sizeof(currentConfig_.apiToken) - 1);
  const PortalSubmissionAction action = submissionPolicy_.evaluate(valid);
  if (action != PortalSubmissionAction::PublishConfig) {
    Serial.println(
        "[config] rejected; correct the reported field and submit again");
    recoveryAction_ = action;
    recoveryPending_ = true;
    return;
  }

  Serial.println("[config] accepted; applying settings");
  currentConfig_ = candidate;
  captureCredentialsPending_ = true;
}

void NetworkConfig::publishNetworkStatus() {
  const bool connected = WiFi.status() == WL_CONNECTED;
  const bool portalActive = wifiManager_.getConfigPortalActive();
  wifiConnected_.store(connected, std::memory_order_release);
  portalActive_.store(portalActive, std::memory_order_release);
  if (connected && !portalActive) {
    startDiscovery();
  }
}

void NetworkConfig::startDiscovery() {
  if (discoveryStarted_) {
    return;
  }
  // Started once: the ESP-IDF responder follows later DHCP address changes
  // and reconnects on its own, so clients can keep using <hostname>.local.
  if (!MDNS.begin(hostname_)) {
    Serial.println("[network] ERROR: could not start mDNS responder");
    return;
  }
  discoveryStarted_ = true;
  MDNS.setInstanceName(hostname_);
  MDNS.addService("http", "tcp", 80);
  MDNS.addService("canary", "tcp", 80);
  MDNS.addServiceTxt("canary", "tcp", "type", "air");
  MDNS.addServiceTxt("canary", "tcp", "fw", Hardware::FIRMWARE_VERSION);
  MDNS.addServiceTxt("canary", "tcp", "api", "/api/status");
  Serial.printf("[network] mDNS: http://%s.local (_canary._tcp type=air)\n",
                hostname_);
}

// ESP-NOW only reaches neighbours on the radio's current channel, but the
// core's auto-reconnect rescans every channel back to back while the access
// point is gone. After a grace period, stop it, hold the access point's last
// channel (the one the neighbours are on) and retry Wi-Fi on a slower cadence.
// ponytail: needs one Wi-Fi join since boot to learn the channel; persist it
// if nodes must mesh after booting into an outage.
void NetworkConfig::manageMeshFallback() {
  const uint32_t nowMs = millis();
  if (WiFi.status() == WL_CONNECTED) {
    meshChannel_ = static_cast<uint8_t>(WiFi.channel());
    lastConnectedMs_ = nowMs;
    if (meshFallback_) {
      meshFallback_ = false;
      WiFi.setAutoReconnect(true);
      Serial.println("[network] Wi-Fi back; mesh fallback off");
    }
    return;
  }
  if (!meshFallback_) {
    if (meshChannel_ == 0 || !currentConfig_.mqttEnabled ||
        savedWifiPassword_.isEmpty() || wifiManager_.getConfigPortalActive() ||
        !elapsed(nowMs, lastConnectedMs_, MESH_FALLBACK_AFTER_MS)) {
      return;
    }
    meshFallback_ = true;
    wifiRetryMs_ = nowMs;
    WiFi.setAutoReconnect(false);
    WiFi.disconnect();
    esp_wifi_set_channel(meshChannel_, WIFI_SECOND_CHAN_NONE);
    Serial.printf("[network] Wi-Fi lost; mesh fallback on channel %u\n",
                  static_cast<unsigned>(meshChannel_));
    return;
  }
  if (elapsed(nowMs, wifiRetryMs_, WIFI_RETRY_INTERVAL_MS)) {
    wifiRetryMs_ = nowMs;
    WiFi.begin();  // one scan and join attempt with the saved network
    return;
  }
  // Setting the channel mid-scan would break the attempt, so wait it out.
  if (elapsed(nowMs, wifiRetryMs_, WIFI_RETRY_WINDOW_MS) &&
      WiFi.channel() != meshChannel_) {
    esp_wifi_set_channel(meshChannel_, WIFI_SECOND_CHAN_NONE);
  }
}

void NetworkConfig::handleSubmissionRecovery() {
  if (!recoveryPending_) {
    return;
  }
  const PortalSubmissionAction action = recoveryAction_;
  recoveryPending_ = false;

  if (wifiManager_.getConfigPortalActive()) {
    wifiManager_.stopConfigPortal();
  }
  wifiManager_.resetSettings();
  if (action == PortalSubmissionAction::RestoreCredentialsAndRestart) {
    restoreStoredWiFiCredentials();
  }
  wifiManager_.startConfigPortal(apName_);
}

void NetworkConfig::captureStoredWiFiCredentials() {
  savedWifiSsid_ = wifiManager_.getWiFiSSID(true);
  savedWifiPassword_ = wifiManager_.getWiFiPass(true);
}

void NetworkConfig::restoreStoredWiFiCredentials() {
  if (savedWifiSsid_.isEmpty()) {
    return;
  }
  WiFi.mode(WIFI_STA);
  WiFi.persistent(true);
  WiFi.begin(savedWifiSsid_.c_str(),
             savedWifiPassword_.c_str(),
             0,
             nullptr,
             false);
  WiFi.persistent(false);
}

void NetworkConfig::copyConfigToBuffers(const DeviceConfig& config) {
  deviceNameParam_.setValue(config.deviceName, sizeof(config.deviceName) - 1);
  mqttEnabledParam_.setValue(config.mqttEnabled ? "1" : "0", 1);
  gasDetectorEnabledParam_.setValue(config.gasDetectorEnabled ? "1" : "0", 1);
  mqttHostParam_.setValue(config.mqttHost, sizeof(config.mqttHost) - 1);
  setUnsignedValue(mqttPortParam_, config.mqttPort, 5);
  mqttUserParam_.setValue(config.mqttUser, sizeof(config.mqttUser) - 1);

  // Never render stored secrets back into the captive-portal HTML.
  mqttPasswordParam_.setValue("", sizeof(config.mqttPassword) - 1);
  mqttTopicParam_.setValue(config.mqttBaseTopic,
                           sizeof(config.mqttBaseTopic) - 1);
  apiTokenParam_.setValue("", sizeof(config.apiToken) - 1);
  setUnsignedValue(coWarnParam_, config.coWarnPpm, 4);
  setUnsignedValue(coDangerParam_, config.coDangerPpm, 4);
  setUnsignedValue(gasWarnParam_, config.gasWarnAdc, 4);
  setUnsignedValue(gasDangerParam_, config.gasDangerAdc, 4);
  setUnsignedValue(warmupParam_, config.sensorWarmupSeconds, 4);
  setUnsignedValue(pm25WarnParam_, config.pm25WarnUgm3, 4);
  setUnsignedValue(pm25DangerParam_, config.pm25DangerUgm3, 4);
  setUnsignedValue(pm10WarnParam_, config.pm10WarnUgm3, 4);
  setUnsignedValue(pm10DangerParam_, config.pm10DangerUgm3, 4);
  setUnsignedValue(silenceParam_, config.alarmSilenceSeconds, 4);
}

bool NetworkConfig::copyBuffersToConfig(DeviceConfig& output) const {
  DeviceConfig candidate = currentConfig_;
  if (!copyText(candidate.deviceName, deviceNameParam_.getValue()) ||
      !copyText(candidate.mqttHost, mqttHostParam_.getValue()) ||
      !copyText(candidate.mqttUser, mqttUserParam_.getValue()) ||
      !copyText(candidate.mqttBaseTopic, mqttTopicParam_.getValue())) {
    return false;
  }

  if (mqttPasswordParam_.getValue()[0] != '\0' &&
      !copyText(candidate.mqttPassword, mqttPasswordParam_.getValue())) {
    return false;
  }
  if (apiTokenParam_.getValue()[0] != '\0' &&
      !copyText(candidate.apiToken, apiTokenParam_.getValue())) {
    Serial.println("[config] invalid field: apiToken");
    return false;
  }

  uint32_t mqttEnabled = 0;
  uint32_t gasDetectorEnabled = 0;
  uint32_t mqttPort = 0;
  uint32_t coWarn = 0;
  uint32_t coDanger = 0;
  uint32_t gasWarn = 0;
  uint32_t gasDanger = 0;
  uint32_t warmupSeconds = 0;
  uint32_t pm25Warn = 0;
  uint32_t pm25Danger = 0;
  uint32_t pm10Warn = 0;
  uint32_t pm10Danger = 0;
  uint32_t silenceSeconds = 0;
  if (!parseUnsigned(gasDetectorEnabledParam_.getValue(), 1, gasDetectorEnabled) ||
      !parseUnsigned(mqttEnabledParam_.getValue(), 1, mqttEnabled) ||
      !parseUnsigned(mqttPortParam_.getValue(), UINT16_MAX, mqttPort) ||
      !parseUnsigned(coWarnParam_.getValue(), UINT16_MAX, coWarn) ||
      !parseUnsigned(coDangerParam_.getValue(), UINT16_MAX, coDanger) ||
      !parseUnsigned(gasWarnParam_.getValue(), UINT16_MAX, gasWarn) ||
      !parseUnsigned(gasDangerParam_.getValue(), UINT16_MAX, gasDanger) ||
      !parseUnsigned(warmupParam_.getValue(), UINT16_MAX, warmupSeconds) ||
      !parseUnsigned(pm25WarnParam_.getValue(), UINT16_MAX, pm25Warn) ||
      !parseUnsigned(pm25DangerParam_.getValue(), UINT16_MAX, pm25Danger) ||
      !parseUnsigned(pm10WarnParam_.getValue(), UINT16_MAX, pm10Warn) ||
      !parseUnsigned(pm10DangerParam_.getValue(), UINT16_MAX, pm10Danger) ||
      !parseUnsigned(silenceParam_.getValue(), UINT32_MAX, silenceSeconds)) {
    return false;
  }

  candidate.mqttEnabled = mqttEnabled != 0;
  candidate.gasDetectorEnabled = gasDetectorEnabled != 0;
  candidate.mqttPort = static_cast<uint16_t>(mqttPort);
  candidate.coWarnPpm = static_cast<uint16_t>(coWarn);
  candidate.coDangerPpm = static_cast<uint16_t>(coDanger);
  candidate.gasWarnAdc = static_cast<uint16_t>(gasWarn);
  candidate.gasDangerAdc = static_cast<uint16_t>(gasDanger);
  candidate.sensorWarmupSeconds = static_cast<uint16_t>(warmupSeconds);
  candidate.pm25WarnUgm3 = static_cast<uint16_t>(pm25Warn);
  candidate.pm25DangerUgm3 = static_cast<uint16_t>(pm25Danger);
  candidate.pm10WarnUgm3 = static_cast<uint16_t>(pm10Warn);
  candidate.pm10DangerUgm3 = static_cast<uint16_t>(pm10Danger);
  candidate.alarmSilenceSeconds = silenceSeconds;
  const ConfigValidation validation = validateDeviceConfig(candidate);
  if (!validation.valid) {
    Serial.printf("[config] invalid field: %s\n", validation.field);
    return false;
  }

  output = candidate;
  return true;
}

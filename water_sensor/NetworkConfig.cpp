#include "NetworkConfig.h"

#include <WiFi.h>

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
    "type=\"number\" min=\"0\" max=\"4095\" step=\"1\"";
constexpr char DEBOUNCE_ATTRIBUTES[] =
    "type=\"number\" min=\"100\" max=\"60000\" step=\"1\"";
constexpr char ALARM_ATTRIBUTES[] =
    "type=\"number\" min=\"10\" max=\"3600\" step=\"1\"";
constexpr uint32_t NETWORK_TASK_STACK_BYTES = 8192;
constexpr UBaseType_t NETWORK_TASK_PRIORITY = tskIDLE_PRIORITY;

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
      wetThresholdParam_(
          "wet_threshold", "Wet threshold", "1200", 4, ADC_ATTRIBUTES),
      dryThresholdParam_(
          "dry_threshold", "Dry threshold", "600", 4, ADC_ATTRIBUTES),
      debounceParam_(
          "debounce_ms", "Debounce milliseconds", "1000", 5,
          DEBOUNCE_ATTRIBUTES),
      alarmDurationParam_(
          "alarm_seconds", "Alarm seconds", "180", 4, ALARM_ATTRIBUTES),
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
      taskStarted_(false),
      forcePortal_(false),
      handoffChanged_(false),
      configChanged_(false),
      recoveryPending_(false),
      captureCredentialsPending_(false),
      recoveryAction_(PortalSubmissionAction::ClearCredentialsAndRestart),
      apName_{} {}

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
  wifiManager_.addParameter(&mqttHostParam_);
  wifiManager_.addParameter(&mqttPortParam_);
  wifiManager_.addParameter(&mqttUserParam_);
  wifiManager_.addParameter(&mqttPasswordParam_);
  wifiManager_.addParameter(&mqttTopicParam_);
  wifiManager_.addParameter(&apiTokenParam_);
  wifiManager_.addParameter(&wetThresholdParam_);
  wifiManager_.addParameter(&dryThresholdParam_);
  wifiManager_.addParameter(&debounceParam_);
  wifiManager_.addParameter(&alarmDurationParam_);

  WiFi.mode(WIFI_STA);
  captureStoredWiFiCredentials();
  if (forcePortal_) {
    wifiManager_.startConfigPortal(apName_);
  } else {
    wifiManager_.autoConnect(apName_);
  }
  publishNetworkStatus();

  for (;;) {
    wifiManager_.process();
    handleSubmissionRecovery();
    if (captureCredentialsPending_) {
      captureStoredWiFiCredentials();
      captureCredentialsPending_ = false;
    }
    publishNetworkStatus();
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void NetworkConfig::onSave() {
  DeviceConfig candidate{};
  const bool valid = copyBuffersToConfig(candidate);

  // WiFiManager keeps submitted values in its parameter buffers. Clear secrets
  // before the portal can render another page, regardless of validation result.
  mqttPasswordParam_.setValue("", sizeof(currentConfig_.mqttPassword) - 1);
  apiTokenParam_.setValue("", sizeof(currentConfig_.apiToken) - 1);
  const PortalSubmissionAction action = submissionPolicy_.evaluate(valid);
  if (action != PortalSubmissionAction::PublishConfig) {
    recoveryAction_ = action;
    recoveryPending_ = true;
    return;
  }

  currentConfig_ = candidate;
  captureCredentialsPending_ = true;
  if (xSemaphoreTake(handoffMutex_, portMAX_DELAY) == pdTRUE) {
    handoffConfig_ = candidate;
    handoffChanged_ = true;
    xSemaphoreGive(handoffMutex_);
  }
}

void NetworkConfig::publishNetworkStatus() {
  wifiConnected_.store(WiFi.status() == WL_CONNECTED,
                       std::memory_order_release);
  portalActive_.store(wifiManager_.getConfigPortalActive(),
                      std::memory_order_release);
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
  mqttHostParam_.setValue(config.mqttHost, sizeof(config.mqttHost) - 1);
  setUnsignedValue(mqttPortParam_, config.mqttPort, 5);
  mqttUserParam_.setValue(config.mqttUser, sizeof(config.mqttUser) - 1);

  // Never render stored secrets back into the captive-portal HTML.
  mqttPasswordParam_.setValue("", sizeof(config.mqttPassword) - 1);
  mqttTopicParam_.setValue(config.mqttBaseTopic,
                           sizeof(config.mqttBaseTopic) - 1);
  apiTokenParam_.setValue("", sizeof(config.apiToken) - 1);
  setUnsignedValue(wetThresholdParam_, config.wetThreshold, 4);
  setUnsignedValue(dryThresholdParam_, config.dryThreshold, 4);
  setUnsignedValue(debounceParam_, config.debounceMs, 5);
  setUnsignedValue(alarmDurationParam_, config.alarmDurationSeconds, 4);
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
    return false;
  }

  uint32_t mqttEnabled = 0;
  uint32_t mqttPort = 0;
  uint32_t wetThreshold = 0;
  uint32_t dryThreshold = 0;
  uint32_t debounceMs = 0;
  uint32_t alarmDurationSeconds = 0;
  if (!parseUnsigned(mqttEnabledParam_.getValue(), 1, mqttEnabled) ||
      !parseUnsigned(mqttPortParam_.getValue(), UINT16_MAX, mqttPort) ||
      !parseUnsigned(wetThresholdParam_.getValue(), UINT16_MAX, wetThreshold) ||
      !parseUnsigned(dryThresholdParam_.getValue(), UINT16_MAX, dryThreshold) ||
      !parseUnsigned(debounceParam_.getValue(), UINT32_MAX, debounceMs) ||
      !parseUnsigned(
          alarmDurationParam_.getValue(), UINT32_MAX, alarmDurationSeconds)) {
    return false;
  }

  candidate.mqttEnabled = mqttEnabled != 0;
  candidate.mqttPort = static_cast<uint16_t>(mqttPort);
  candidate.wetThreshold = static_cast<uint16_t>(wetThreshold);
  candidate.dryThreshold = static_cast<uint16_t>(dryThreshold);
  candidate.debounceMs = debounceMs;
  candidate.alarmDurationSeconds = alarmDurationSeconds;
  if (!validateDeviceConfig(candidate).valid) {
    return false;
  }

  output = candidate;
  return true;
}

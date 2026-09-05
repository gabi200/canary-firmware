#include "DeviceConfig.h"

#include <cstring>

namespace {

bool hasContent(const char* value, size_t capacity) {
  return value[0] != '\0' && strnlen(value, capacity) < capacity;
}

ConfigValidation invalid(const char* field) {
  return ConfigValidation{false, field};
}

}  // namespace

DeviceConfig defaultDeviceConfig() {
  DeviceConfig config{};
  std::strcpy(config.deviceName, "water-sensor");
  config.mqttEnabled = false;
  config.mqttPort = 1883;
  std::strcpy(config.mqttBaseTopic, "water-sensor");
  config.wetThreshold = 1200;
  config.dryThreshold = 600;
  config.debounceMs = 1000;
  config.alarmDurationSeconds = 180;
  return config;
}

ConfigValidation validateDeviceConfig(const DeviceConfig& config) {
  if (!hasContent(config.deviceName, sizeof(config.deviceName))) {
    return invalid("deviceName");
  }
  if (!hasContent(config.mqttBaseTopic, sizeof(config.mqttBaseTopic))) {
    return invalid("mqttBaseTopic");
  }
  if (config.wetThreshold > 4095 || config.dryThreshold > 4095 ||
      config.wetThreshold <= config.dryThreshold) {
    return invalid("thresholds");
  }
  if (config.debounceMs < 100 || config.debounceMs > 60000) {
    return invalid("debounceMs");
  }
  if (config.alarmDurationSeconds < 10 || config.alarmDurationSeconds > 3600) {
    return invalid("alarmDurationSeconds");
  }
  if (config.mqttPort == 0) {
    return invalid("mqttPort");
  }
  const size_t tokenLength = strnlen(config.apiToken, sizeof(config.apiToken));
  if (tokenLength < 12 || tokenLength >= sizeof(config.apiToken)) {
    return invalid("apiToken");
  }
  if (config.mqttEnabled && !hasContent(config.mqttHost, sizeof(config.mqttHost))) {
    return invalid("mqttHost");
  }
  return ConfigValidation{true, nullptr};
}

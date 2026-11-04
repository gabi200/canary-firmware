#include "DeviceConfig.h"

#include <cstring>

namespace {

bool hasContent(const char* value, size_t capacity) {
  return value[0] != '\0' && strnlen(value, capacity) < capacity;
}

ConfigValidation invalid(const char* field) {
  return ConfigValidation{false, field};
}

// Every hazard channel uses the same shape: a warning level strictly below a
// danger level, both inside the sensor's representable range.
bool orderedThresholds(uint16_t warn, uint16_t danger, uint16_t maximum) {
  return warn > 0 && warn < danger && danger <= maximum;
}

}  // namespace

DeviceConfig defaultDeviceConfig() {
  DeviceConfig config{};
  std::strcpy(config.deviceName, "canary");
  config.mqttEnabled = false;
  config.gasDetectorEnabled = false;
  config.mqttPort = 1883;
  std::strcpy(config.mqttBaseTopic, "canary");
  config.coWarnPpm = 50;
  config.coDangerPpm = 100;
  // Sized for the 15k/10k MQ5 divider (0.4 x AO, 2.0 V at full scale).
  config.gasWarnAdc = 1200;
  config.gasDangerAdc = 1760;
  config.sensorWarmupSeconds = 300;
  config.pm25WarnUgm3 = 35;
  config.pm25DangerUgm3 = 150;
  config.pm10WarnUgm3 = 100;
  config.pm10DangerUgm3 = 250;
  config.alarmSilenceSeconds = 300;
  return config;
}

ConfigValidation validateDeviceConfig(const DeviceConfig& config) {
  if (!hasContent(config.deviceName, sizeof(config.deviceName))) {
    return invalid("deviceName");
  }
  if (!hasContent(config.mqttBaseTopic, sizeof(config.mqttBaseTopic))) {
    return invalid("mqttBaseTopic");
  }
  if (!orderedThresholds(config.coWarnPpm, config.coDangerPpm, CO_PPM_MAX)) {
    return invalid("coThresholds");
  }
  if (!orderedThresholds(config.gasWarnAdc, config.gasDangerAdc, GAS_ADC_MAX)) {
    return invalid("gasThresholds");
  }
  if (config.sensorWarmupSeconds < 10 || config.sensorWarmupSeconds > 3600) {
    return invalid("sensorWarmupSeconds");
  }
  if (!orderedThresholds(config.pm25WarnUgm3, config.pm25DangerUgm3, PM_UGM3_MAX)) {
    return invalid("pm25Thresholds");
  }
  if (!orderedThresholds(config.pm10WarnUgm3, config.pm10DangerUgm3, PM_UGM3_MAX)) {
    return invalid("pm10Thresholds");
  }
  if (config.alarmSilenceSeconds < 30 || config.alarmSilenceSeconds > 3600) {
    return invalid("alarmSilenceSeconds");
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

#pragma once

#include <stdint.h>

struct DeviceConfig {
  char deviceName[33];
  bool mqttEnabled;
  char mqttHost[65];
  uint16_t mqttPort;
  char mqttUser[33];
  char mqttPassword[65];
  char mqttBaseTopic[65];
  char apiToken[65];
  uint16_t wetThreshold;
  uint16_t dryThreshold;
  uint32_t debounceMs;
  uint32_t alarmDurationSeconds;
};

struct ConfigValidation {
  bool valid;
  const char* field;
};

DeviceConfig defaultDeviceConfig();
ConfigValidation validateDeviceConfig(const DeviceConfig& config);

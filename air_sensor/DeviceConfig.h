#pragma once

#include <stdint.h>

struct DeviceConfig {
  char deviceName[33];
  bool mqttEnabled;
  bool gasDetectorEnabled;
  char mqttHost[65];
  uint16_t mqttPort;
  char mqttUser[33];
  char mqttPassword[65];
  char mqttBaseTopic[65];
  char apiToken[65];
  uint16_t coWarnPpm;
  uint16_t coDangerPpm;
  uint16_t gasWarnAdc;
  uint16_t gasDangerAdc;
  uint16_t sensorWarmupSeconds;
  uint16_t pm25WarnUgm3;
  uint16_t pm25DangerUgm3;
  uint16_t pm10WarnUgm3;
  uint16_t pm10DangerUgm3;
  uint32_t alarmSilenceSeconds;
};

struct ConfigValidation {
  bool valid;
  const char* field;
};

constexpr uint16_t CO_PPM_MAX = 2000;
constexpr uint16_t GAS_ADC_MAX = 4095;
constexpr uint16_t PM_UGM3_MAX = 1000;

DeviceConfig defaultDeviceConfig();
ConfigValidation validateDeviceConfig(const DeviceConfig& config);

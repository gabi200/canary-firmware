#pragma once

#include "DeviceConfig.h"
#include "LeakController.h"

#include <Arduino.h>

#include <functional>

struct RuntimeStatus {
  uint32_t uptimeMs;
  uint16_t sensorAdc;
  bool wifiConnected;
  int32_t wifiRssi;
  bool mqttConnected;
  bool otaInProgress;
  uint32_t wifiIp;  // IPv4 as IPAddress stores it (first octet in the low byte); 0 = none
};

using RuntimeStatusProvider = std::function<RuntimeStatus()>;
using StateChangeCallback = std::function<void()>;

constexpr size_t STATUS_JSON_MAX_BYTES = 768;

String buildStatusJson(const DeviceConfig& config,
                       const LeakController& controller,
                       const RuntimeStatus& runtime,
                       uint32_t nowMs);

bool buildStatusJson(const DeviceConfig& config,
                     const LeakController& controller,
                     const RuntimeStatus& runtime,
                     uint32_t nowMs,
                     char* output,
                     size_t outputSize);

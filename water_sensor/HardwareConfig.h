#pragma once

#include "OutputLogic.h"

#include <Arduino.h>

namespace Hardware {
constexpr uint8_t SENSOR_ADC_PIN = 0;
constexpr uint8_t RELAY_PIN = 4;
constexpr uint8_t BUZZER_PIN = 5;
constexpr uint8_t CONFIG_BUTTON_PIN = 10;
constexpr bool RELAY_ACTIVE_HIGH = true;
constexpr bool BUZZER_ACTIVE_HIGH = true;
constexpr bool CONFIG_BUTTON_ACTIVE_LOW = true;
constexpr uint32_t SENSOR_SAMPLE_INTERVAL_MS = 50;
constexpr uint8_t SENSOR_AVERAGE_SAMPLES = 8;
constexpr uint32_t BUZZER_BEEP_ON_MS = 500;
constexpr uint32_t BUZZER_BEEP_OFF_MS = 500;
// One short beep at every boot, so a dead buzzer is noticed at install or after a power cut.
constexpr uint32_t STARTUP_BEEP_MS = 150;
constexpr char FIRMWARE_VERSION[] = "1.1.0";

inline uint8_t outputLevel(bool active, bool activeHigh) {
  return activeLevelFor(active, activeHigh) ? HIGH : LOW;
}
}  // namespace Hardware

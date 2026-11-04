#pragma once

#include "DeviceConfig.h"

#include <Preferences.h>

// Configuration only. The alarm is level-based rather than latched, so there
// is no safety state worth surviving a reboot: every channel is re-evaluated
// from live sensor data after the warm-up window.
class ConfigStore {
 public:
  bool begin();
  DeviceConfig loadConfig() const;
  bool saveConfig(const DeviceConfig& config);
  bool saveGasDetectorEnabled(bool enabled);

 private:
  mutable Preferences preferences_;
};

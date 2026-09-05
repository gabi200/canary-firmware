#pragma once

#include "DeviceConfig.h"
#include "LeakController.h"

#include <Preferences.h>

class ConfigStore {
 public:
  bool begin();
  DeviceConfig loadConfig() const;
  bool saveConfig(const DeviceConfig& config);
  PersistentState loadState() const;
  bool saveState(const PersistentState& state);

 private:
  mutable Preferences preferences_;
};

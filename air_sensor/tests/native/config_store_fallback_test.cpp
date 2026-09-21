#include "ConfigStore.h"

#include <Preferences.h>

#include <cstdlib>
#include <cstring>
#include <iostream>

namespace {

DeviceConfig validDeviceConfig() {
  DeviceConfig cfg = defaultDeviceConfig();
  std::strcpy(cfg.apiToken, "0123456789abcdef");
  std::strcpy(cfg.deviceName, "hallway");
  cfg.coWarnPpm = 40;
  cfg.coDangerPpm = 90;
  return cfg;
}

bool isDefaults(const DeviceConfig& config) {
  const DeviceConfig defaults = defaultDeviceConfig();
  return std::strcmp(config.deviceName, defaults.deviceName) == 0 &&
         config.coWarnPpm == defaults.coWarnPpm &&
         config.coDangerPpm == defaults.coDangerPpm &&
         config.apiToken[0] == '\0';
}

}  // namespace

int main() {
  Preferences::resetForTest();
  ConfigStore store;
  if (!store.begin()) {
    std::cerr << "ConfigStore setup failed\n";
    return EXIT_FAILURE;
  }

  // No saved record at all: the defaults have no API token, so the sketch is
  // pushed into the provisioning portal rather than onto an open API.
  if (!isDefaults(store.loadConfig())) {
    std::cerr << "Missing config record did not fall back to defaults\n";
    return EXIT_FAILURE;
  }

  // A schema marker without the rest of the record is not a usable record.
  Preferences partial;
  partial.begin("canarycfg", false);
  partial.putUChar("version", 1);
  partial.putString("deviceName", "hallway");
  partial.end();
  if (!isDefaults(store.loadConfig())) {
    std::cerr << "Partial config record did not fall back to defaults\n";
    return EXIT_FAILURE;
  }

  // A complete record that fails validation is also rejected wholesale: a
  // warning threshold at or above the danger threshold would never warn.
  Preferences::resetForTest();
  if (!store.saveConfig(validDeviceConfig())) {
    std::cerr << "Saving a valid config record failed\n";
    return EXIT_FAILURE;
  }
  Preferences corrupt;
  corrupt.begin("canarycfg", false);
  corrupt.putUShort("coWarn", 500);
  corrupt.end();
  if (!isDefaults(store.loadConfig())) {
    std::cerr << "Invalid thresholds did not fall back to defaults\n";
    return EXIT_FAILURE;
  }

  // Saving an invalid record must not be possible in the first place.
  Preferences::resetForTest();
  DeviceConfig invalid = validDeviceConfig();
  invalid.pm25DangerUgm3 = 1;
  if (store.saveConfig(invalid)) {
    std::cerr << "ConfigStore saved an invalid record\n";
    return EXIT_FAILURE;
  }

  Preferences::resetForTest();
  if (!store.saveConfig(validDeviceConfig())) {
    std::cerr << "Saving a valid config record failed\n";
    return EXIT_FAILURE;
  }
  const DeviceConfig roundTrip = store.loadConfig();
  if (std::strcmp(roundTrip.deviceName, "hallway") != 0 ||
      roundTrip.coWarnPpm != 40 || roundTrip.coDangerPpm != 90 ||
      std::strcmp(roundTrip.apiToken, "0123456789abcdef") != 0) {
    std::cerr << "Valid config record did not round trip\n";
    return EXIT_FAILURE;
  }
  std::cout << "ConfigStore fallback keeps the device unprovisioned\n";
  return EXIT_SUCCESS;
}

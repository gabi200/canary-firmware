#include "ConfigStore.h"

namespace {

constexpr char CONFIG_NAMESPACE[] = "watercfg";
constexpr char STATE_NAMESPACE[] = "waterstate";
constexpr char VERSION_KEY[] = "version";
constexpr uint8_t SCHEMA_VERSION = 1;

bool stored(size_t result) {
  return result > 0;
}

bool storeString(Preferences& preferences, const char* key, const char* value) {
  preferences.putString(key, value);
  return preferences.getString(key) == value;
}

}  // namespace

bool ConfigStore::begin() {
  if (!preferences_.begin(CONFIG_NAMESPACE, false)) {
    return false;
  }
  preferences_.end();
  if (!preferences_.begin(STATE_NAMESPACE, false)) {
    return false;
  }
  preferences_.end();
  return true;
}

DeviceConfig ConfigStore::loadConfig() const {
  DeviceConfig config = defaultDeviceConfig();
  if (!preferences_.begin(CONFIG_NAMESPACE, true)) {
    return config;
  }
  if (preferences_.getUChar(VERSION_KEY, 0) != SCHEMA_VERSION) {
    preferences_.end();
    return config;
  }

  preferences_.getString("deviceName", config.deviceName).toCharArray(
      config.deviceName, sizeof(config.deviceName));
  config.mqttEnabled = preferences_.getBool("mqttEnabled", config.mqttEnabled);
  preferences_.getString("mqttHost", config.mqttHost).toCharArray(
      config.mqttHost, sizeof(config.mqttHost));
  config.mqttPort = preferences_.getUShort("mqttPort", config.mqttPort);
  preferences_.getString("mqttUser", config.mqttUser).toCharArray(
      config.mqttUser, sizeof(config.mqttUser));
  preferences_.getString("mqttPassword", config.mqttPassword).toCharArray(
      config.mqttPassword, sizeof(config.mqttPassword));
  preferences_.getString("mqttBaseTopic", config.mqttBaseTopic).toCharArray(
      config.mqttBaseTopic, sizeof(config.mqttBaseTopic));
  preferences_.getString("apiToken", config.apiToken).toCharArray(
      config.apiToken, sizeof(config.apiToken));
  config.wetThreshold = preferences_.getUShort("wetThreshold", config.wetThreshold);
  config.dryThreshold = preferences_.getUShort("dryThreshold", config.dryThreshold);
  config.debounceMs = preferences_.getULong("debounceMs", config.debounceMs);
  config.alarmDurationSeconds =
      preferences_.getULong("alarmSeconds", config.alarmDurationSeconds);
  preferences_.end();
  if (!validateDeviceConfig(config).valid) {
    return defaultDeviceConfig();
  }
  return config;
}

bool ConfigStore::saveConfig(const DeviceConfig& config) {
  if (!validateDeviceConfig(config).valid ||
      !preferences_.begin(CONFIG_NAMESPACE, false)) {
    return false;
  }

  if (preferences_.isKey(VERSION_KEY) && !preferences_.remove(VERSION_KEY)) {
    preferences_.end();
    return false;
  }
  bool success = true;
  success = storeString(preferences_, "deviceName", config.deviceName) && success;
  success = stored(preferences_.putBool("mqttEnabled", config.mqttEnabled)) && success;
  success = storeString(preferences_, "mqttHost", config.mqttHost) && success;
  success = stored(preferences_.putUShort("mqttPort", config.mqttPort)) && success;
  success = storeString(preferences_, "mqttUser", config.mqttUser) && success;
  success = storeString(preferences_, "mqttPassword", config.mqttPassword) && success;
  success = storeString(preferences_, "mqttBaseTopic", config.mqttBaseTopic) && success;
  success = storeString(preferences_, "apiToken", config.apiToken) && success;
  success = stored(preferences_.putUShort("wetThreshold", config.wetThreshold)) && success;
  success = stored(preferences_.putUShort("dryThreshold", config.dryThreshold)) && success;
  success = stored(preferences_.putULong("debounceMs", config.debounceMs)) && success;
  success = stored(preferences_.putULong("alarmSeconds", config.alarmDurationSeconds)) && success;
  if (success) {
    success = stored(preferences_.putUChar(VERSION_KEY, SCHEMA_VERSION));
  }
  preferences_.end();
  return success;
}

PersistentState ConfigStore::loadState() const {
  constexpr PersistentState defaultState{false, ValveState::Closed};
  if (!preferences_.begin(STATE_NAMESPACE, true)) {
    return defaultState;
  }
  if (preferences_.getUChar(VERSION_KEY, 0) != SCHEMA_VERSION) {
    preferences_.end();
    return defaultState;
  }
  if (!preferences_.isKey("leakLatched") || !preferences_.isKey("valve")) {
    preferences_.end();
    return defaultState;
  }

  constexpr uint8_t INVALID_LATCH = 0xFF;
  const uint8_t storedLatch = preferences_.getUChar("leakLatched", INVALID_LATCH);
  const uint8_t storedValve = preferences_.getUChar(
      "valve", static_cast<uint8_t>(ValveState::Closed));
  preferences_.end();
  if (storedLatch != 0 && storedLatch != 1) {
    return defaultState;
  }
  if (storedValve != static_cast<uint8_t>(ValveState::Open) &&
      storedValve != static_cast<uint8_t>(ValveState::Closed)) {
    return defaultState;
  }
  const ValveState requestedValve = storedValve == static_cast<uint8_t>(ValveState::Open)
                                        ? ValveState::Open
                                        : ValveState::Closed;
  return PersistentState{storedLatch == 1, requestedValve};
}

bool ConfigStore::saveState(const PersistentState& state) {
  if (!preferences_.begin(STATE_NAMESPACE, false)) {
    return false;
  }

  if (preferences_.isKey(VERSION_KEY) && !preferences_.remove(VERSION_KEY)) {
    preferences_.end();
    return false;
  }
  bool success = stored(preferences_.putBool("leakLatched", state.leakLatched));
  success = stored(preferences_.putUChar(
                "valve", static_cast<uint8_t>(state.requestedValve))) &&
            success;
  if (success) {
    success = stored(preferences_.putUChar(VERSION_KEY, SCHEMA_VERSION));
  }
  preferences_.end();
  return success;
}

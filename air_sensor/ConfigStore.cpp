#include "ConfigStore.h"

namespace {

constexpr char CONFIG_NAMESPACE[] = "canarycfg";
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
  // Schema 1 deployments monitored the detector before this setting existed.
  config.gasDetectorEnabled = preferences_.getBool("gasDetEnabled", true);
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
  config.coWarnPpm = preferences_.getUShort("coWarn", config.coWarnPpm);
  config.coDangerPpm = preferences_.getUShort("coDanger", config.coDangerPpm);
  config.gasWarnAdc = preferences_.getUShort("gasWarn", config.gasWarnAdc);
  config.gasDangerAdc = preferences_.getUShort("gasDanger", config.gasDangerAdc);
  config.sensorWarmupSeconds =
      preferences_.getUShort("warmupSec", config.sensorWarmupSeconds);
  config.pm25WarnUgm3 = preferences_.getUShort("pm25Warn", config.pm25WarnUgm3);
  config.pm25DangerUgm3 =
      preferences_.getUShort("pm25Danger", config.pm25DangerUgm3);
  config.pm10WarnUgm3 = preferences_.getUShort("pm10Warn", config.pm10WarnUgm3);
  config.pm10DangerUgm3 =
      preferences_.getUShort("pm10Danger", config.pm10DangerUgm3);
  config.alarmSilenceSeconds =
      preferences_.getULong("silenceSec", config.alarmSilenceSeconds);
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

  // Clearing the version first means a partially written record is read back
  // as "no usable configuration" rather than as a mix of old and new values.
  if (preferences_.isKey(VERSION_KEY) && !preferences_.remove(VERSION_KEY)) {
    preferences_.end();
    return false;
  }
  bool success = stored(preferences_.putBool("gasDetEnabled", config.gasDetectorEnabled));
  success = storeString(preferences_, "deviceName", config.deviceName) && success;
  success = stored(preferences_.putBool("mqttEnabled", config.mqttEnabled)) && success;
  success = storeString(preferences_, "mqttHost", config.mqttHost) && success;
  success = stored(preferences_.putUShort("mqttPort", config.mqttPort)) && success;
  success = storeString(preferences_, "mqttUser", config.mqttUser) && success;
  success = storeString(preferences_, "mqttPassword", config.mqttPassword) && success;
  success = storeString(preferences_, "mqttBaseTopic", config.mqttBaseTopic) && success;
  success = storeString(preferences_, "apiToken", config.apiToken) && success;
  success = stored(preferences_.putUShort("coWarn", config.coWarnPpm)) && success;
  success = stored(preferences_.putUShort("coDanger", config.coDangerPpm)) && success;
  success = stored(preferences_.putUShort("gasWarn", config.gasWarnAdc)) && success;
  success = stored(preferences_.putUShort("gasDanger", config.gasDangerAdc)) && success;
  success = stored(preferences_.putUShort("warmupSec", config.sensorWarmupSeconds)) && success;
  success = stored(preferences_.putUShort("pm25Warn", config.pm25WarnUgm3)) && success;
  success = stored(preferences_.putUShort("pm25Danger", config.pm25DangerUgm3)) && success;
  success = stored(preferences_.putUShort("pm10Warn", config.pm10WarnUgm3)) && success;
  success = stored(preferences_.putUShort("pm10Danger", config.pm10DangerUgm3)) && success;
  success = stored(preferences_.putULong("silenceSec", config.alarmSilenceSeconds)) && success;
  if (success) {
    success = stored(preferences_.putUChar(VERSION_KEY, SCHEMA_VERSION));
  }
  preferences_.end();
  return success;
}

bool ConfigStore::saveGasDetectorEnabled(bool enabled) {
  if (!preferences_.begin(CONFIG_NAMESPACE, false)) return false;
  if (preferences_.getUChar(VERSION_KEY, 0) != SCHEMA_VERSION) {
    preferences_.end();
    return false;
  }
  // One NVS key is atomic; do not rewrite the provisioning record for a toggle.
  const bool success = stored(preferences_.putBool("gasDetEnabled", enabled));
  preferences_.end();
  return success;
}

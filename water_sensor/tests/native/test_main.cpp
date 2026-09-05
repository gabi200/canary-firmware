#include "Auth.h"
#include "DeviceConfig.h"
#include "LeakController.h"
#include "MqttService.h"
#include "MqttServiceTestSupport.h"
#include "OutputLogic.h"
#include "PersistenceRetry.h"
#include "PortalSubmissionPolicy.h"
#include "PubSubClient.h"

#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <iostream>

static int failures = 0;
#define CHECK(expr) do { if (!(expr)) { std::cerr << __func__ << ":" << __LINE__ << " CHECK(" #expr ") failed\n"; ++failures; } } while (0)

static LeakConfig config() {
  return LeakConfig{1200, 600, 1000, 180000, 500, 500};
}

static DeviceConfig validDeviceConfig() {
  DeviceConfig cfg = defaultDeviceConfig();
  std::strcpy(cfg.apiToken, "0123456789abcdef");
  return cfg;
}

static void establishDry(LeakController& controller, uint32_t start = 0) {
  controller.updateSensor(200, start);
  controller.updateSensor(200, start + 1000);
}

static void establishWet(LeakController& controller, uint32_t start = 0) {
  controller.updateSensor(1600, start);
  controller.updateSensor(1600, start + 1000);
}

static void testStartupIsSafeAndClean() {
  LeakController controller(config());
  CHECK(controller.sensorState() == SensorState::Uninitialized);
  CHECK(controller.valveState() == ValveState::Closed);
  CHECK(!controller.leakLatched());
  CHECK(!controller.otaActive());
  CHECK(controller.alarmState(0) == AlarmState::Inactive);
  CHECK(controller.persistentState().requestedValve == ValveState::Closed);
  CHECK(!controller.takePersistentDirty());
}

static void testOutputPolarityMapping() {
  CHECK(activeLevelFor(true, true));
  CHECK(!activeLevelFor(false, true));
  CHECK(!activeLevelFor(true, false));
  CHECK(activeLevelFor(false, false));
}

static void testPersistenceRetryWaitsAfterFailure() {
  PersistenceRetry retry;
  const PersistentState state{true, ValveState::Closed};
  CHECK(!retry.due(100));
  retry.update(state);
  CHECK(retry.due(100));
  CHECK(retry.state().leakLatched);
  CHECK(retry.state().requestedValve == ValveState::Closed);
  retry.recordResult(false, 100);
  CHECK(!retry.due(1099));
  CHECK(retry.due(1100));
  retry.recordResult(true, 1100);
  CHECK(!retry.due(2100));
}

static void testPersistenceRetryUsesNewestSnapshotImmediately() {
  PersistenceRetry retry;
  retry.update(PersistentState{false, ValveState::Open});
  retry.recordResult(false, 100);
  retry.update(PersistentState{true, ValveState::Closed});
  CHECK(retry.due(101));
  CHECK(retry.state().leakLatched);
  CHECK(retry.state().requestedValve == ValveState::Closed);
}

static void testInvalidFirstRunClearsNewCredentialsAndRestartsPortal() {
  PortalSubmissionPolicy policy(false);
  CHECK(policy.evaluate(false) ==
        PortalSubmissionAction::ClearCredentialsAndRestart);
}

static void testInvalidExistingConfigRestoresCredentialsAndRestartsPortal() {
  PortalSubmissionPolicy policy(true);
  CHECK(policy.evaluate(false) ==
        PortalSubmissionAction::RestoreCredentialsAndRestart);
}

static void testValidFirstRunPublishesAndProtectsLaterCredentials() {
  PortalSubmissionPolicy policy(false);
  CHECK(policy.evaluate(true) == PortalSubmissionAction::PublishConfig);
  CHECK(policy.evaluate(false) ==
        PortalSubmissionAction::RestoreCredentialsAndRestart);
}

static void testInvalidStartingConfigAlwaysForcesPortal() {
  PortalSubmissionPolicy firstRun(false);
  PortalSubmissionPolicy existing(true);
  CHECK(firstRun.shouldForcePortal(false));
  CHECK(!existing.shouldForcePortal(false));
  CHECK(existing.shouldForcePortal(true));
}

static void testWetLatchesAndCloses() {
  LeakController controller(config());
  controller.restore(PersistentState{false, ValveState::Open}, 0);
  establishDry(controller);
  CHECK(controller.requestValve(ValveState::Open, 1001) == CommandResult::Accepted);
  controller.updateSensor(1600, 2000);
  controller.updateSensor(1600, 3000);
  CHECK(controller.sensorState() == SensorState::Wet);
  CHECK(controller.leakLatched());
  CHECK(controller.valveState() == ValveState::Closed);
  CHECK(controller.alarmState(3000) == AlarmState::Sounding);
}

static void testDryDoesNotClearLatch() {
  LeakController controller(config());
  establishWet(controller);
  establishDry(controller, 2000);
  CHECK(controller.sensorState() == SensorState::Dry);
  CHECK(controller.leakLatched());
  CHECK(controller.valveState() == ValveState::Closed);
}

static void testWetOpenIsRejected() {
  LeakController controller(config());
  establishWet(controller);
  CHECK(controller.requestValve(ValveState::Open, 1001) == CommandResult::RejectedWet);
}

static void testUninitializedOpenIsRejected() {
  LeakController controller(config());
  CHECK(controller.requestValve(ValveState::Open, 0) == CommandResult::RejectedUninitialized);
  CHECK(controller.valveState() == ValveState::Closed);
}

static void testStartupRestoresOpenOnlyAfterDry() {
  LeakController controller(config());
  controller.restore(PersistentState{false, ValveState::Open}, 0);
  CHECK(controller.valveState() == ValveState::Closed);
  establishDry(controller);
  CHECK(controller.valveState() == ValveState::Open);
  CHECK(!controller.takePersistentDirty());
}

static void testHysteresisAndDebounceRejectNoise() {
  LeakController controller(config());
  controller.updateSensor(1600, 0);
  controller.updateSensor(200, 500);
  controller.updateSensor(1600, 1000);
  CHECK(controller.sensorState() == SensorState::Uninitialized);
  controller.updateSensor(1600, 2000);
  CHECK(controller.sensorState() == SensorState::Wet);
  controller.updateSensor(900, 3000);
  CHECK(controller.sensorState() == SensorState::Wet);
}

static void testDryOpenClearsLatch() {
  LeakController controller(config());
  establishWet(controller);
  establishDry(controller, 2000);
  CHECK(controller.requestValve(ValveState::Open, 3001) == CommandResult::Accepted);
  CHECK(!controller.leakLatched());
  CHECK(controller.valveState() == ValveState::Open);
}

static void testOtaRejectsOpen() {
  LeakController controller(config());
  establishDry(controller);
  controller.setOtaActive(true);
  CHECK(controller.requestValve(ValveState::Open, 1001) == CommandResult::RejectedOta);
  CHECK(controller.valveState() == ValveState::Closed);
}

static void testAlarmCadence() {
  LeakController controller(config());
  establishWet(controller);
  CHECK(controller.buzzerOutput(1000));
  CHECK(!controller.buzzerOutput(1500));
  CHECK(controller.buzzerOutput(2000));
}

static void testSilenceStopsOnlyAlarm() {
  LeakController controller(config());
  establishWet(controller);
  CHECK(controller.silenceAlarm());
  CHECK(controller.alarmState(1001) == AlarmState::Silenced);
  CHECK(!controller.buzzerOutput(1001));
  CHECK(controller.leakLatched());
  CHECK(controller.valveState() == ValveState::Closed);
}

static void testAlarmTimeoutStopsOnlyAlarm() {
  LeakController controller(config());
  establishWet(controller);
  controller.tick(181000);
  CHECK(controller.alarmState(181000) == AlarmState::TimedOut);
  CHECK(!controller.buzzerOutput(181000));
  CHECK(controller.alarmRemainingMs(181000) == 0);
  CHECK(controller.leakLatched());
  CHECK(controller.valveState() == ValveState::Closed);
}

static void testAlarmTimeoutSignalsExactlyOnce() {
  // Returning no edge when timeout is committed would leave MQTT without the
  // retained status update that reports the alarm has stopped.
  LeakController controller(config());
  establishWet(controller);
  CHECK(!controller.tick(180999));
  CHECK(controller.tick(181000));
  CHECK(!controller.tick(181001));
}

static void testRepeatWetRestartsSilencedAlarm() {
  LeakController controller(config());
  establishWet(controller);
  CHECK(controller.silenceAlarm());
  establishDry(controller, 2000);
  establishWet(controller, 4000);
  CHECK(controller.alarmState(5000) == AlarmState::Sounding);
  CHECK(controller.alarmRemainingMs(5000) == 180000);
}

static void testRestoredLatchStartsFreshAlarm() {
  LeakController controller(config());
  controller.restore(PersistentState{true, ValveState::Closed}, 7000);
  CHECK(controller.leakLatched());
  CHECK(controller.valveState() == ValveState::Closed);
  CHECK(controller.alarmState(7000) == AlarmState::Sounding);
  CHECK(controller.alarmRemainingMs(7000) == 180000);
}

static void testPersistenceDirtyOnlyOnPersistentChange() {
  LeakController controller(config());
  CHECK(!controller.takePersistentDirty());
  controller.requestValve(ValveState::Closed, 0);
  CHECK(!controller.takePersistentDirty());
  establishDry(controller);
  controller.requestValve(ValveState::Open, 1001);
  CHECK(controller.takePersistentDirty());
  CHECK(!controller.takePersistentDirty());
}

static void testMillisWraparound() {
  LeakController controller(config());
  const uint32_t start = UINT32_MAX - 499;
  controller.updateSensor(1600, start);
  controller.updateSensor(1600, 500);
  CHECK(controller.sensorState() == SensorState::Wet);
}

static void testConfigValidation() {
  DeviceConfig cfg = defaultDeviceConfig();
  CHECK(std::strcmp(cfg.deviceName, "water-sensor") == 0);
  CHECK(!cfg.mqttEnabled);
  CHECK(cfg.mqttHost[0] == '\0');
  CHECK(cfg.mqttPort == 1883);
  CHECK(cfg.mqttUser[0] == '\0');
  CHECK(cfg.mqttPassword[0] == '\0');
  CHECK(std::strcmp(cfg.mqttBaseTopic, "water-sensor") == 0);
  CHECK(cfg.apiToken[0] == '\0');
  CHECK(cfg.wetThreshold == 1200);
  CHECK(cfg.dryThreshold == 600);
  CHECK(cfg.debounceMs == 1000);
  CHECK(cfg.alarmDurationSeconds == 180);
  CHECK(!validateDeviceConfig(cfg).valid); // Default token is intentionally unset.

  std::strcpy(cfg.apiToken, "0123456789abcdef");
  CHECK(validateDeviceConfig(cfg).valid);
  cfg.dryThreshold = cfg.wetThreshold;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "thresholds") == 0);

  cfg = defaultDeviceConfig();
  std::strcpy(cfg.apiToken, "0123456789abcdef");
  cfg.mqttEnabled = true;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "mqttHost") == 0);

  cfg.mqttHost[0] = 'm';
  cfg.mqttHost[1] = '\0';
  cfg.wetThreshold = 4095;
  cfg.dryThreshold = 0;
  cfg.debounceMs = 100;
  cfg.alarmDurationSeconds = 3600;
  cfg.mqttPort = 65535;
  CHECK(validateDeviceConfig(cfg).valid);

  cfg.debounceMs = 99;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "debounceMs") == 0);
  cfg.debounceMs = 1000;
  cfg.alarmDurationSeconds = 3601;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "alarmDurationSeconds") == 0);
  cfg.alarmDurationSeconds = 180;
  std::strcpy(cfg.apiToken, "01234567890");
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "apiToken") == 0);
}

static void testConfigValidationBoundaries() {
  DeviceConfig cfg = validDeviceConfig();
  cfg.deviceName[0] = '\0';
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "deviceName") == 0);

  cfg = validDeviceConfig();
  cfg.mqttBaseTopic[0] = '\0';
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "mqttBaseTopic") == 0);

  cfg = validDeviceConfig();
  cfg.mqttPort = 0;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "mqttPort") == 0);

  cfg = validDeviceConfig();
  cfg.wetThreshold = 4096;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "thresholds") == 0);
  cfg = validDeviceConfig();
  cfg.dryThreshold = 4096;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "thresholds") == 0);

  cfg = validDeviceConfig();
  cfg.debounceMs = 60001;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "debounceMs") == 0);

  cfg = validDeviceConfig();
  cfg.alarmDurationSeconds = 10;
  CHECK(validateDeviceConfig(cfg).valid);
  cfg.alarmDurationSeconds = 9;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "alarmDurationSeconds") == 0);

  cfg = validDeviceConfig();
  std::strcpy(cfg.apiToken, "012345678901");
  CHECK(validateDeviceConfig(cfg).valid);
  std::memset(cfg.apiToken, 'x', 64);
  cfg.apiToken[64] = '\0';
  CHECK(validateDeviceConfig(cfg).valid);
  std::memset(cfg.apiToken, 'x', sizeof(cfg.apiToken));
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "apiToken") == 0);
}

static void testBearerAuthentication() {
  CHECK(authorizeBearer("Bearer 0123456789abcdef", "0123456789abcdef"));
  CHECK(!authorizeBearer("bearer 0123456789abcdef", "0123456789abcdef"));
  CHECK(!authorizeBearer("Bearer wrong", "0123456789abcdef"));
  CHECK(!authorizeBearer(nullptr, "0123456789abcdef"));
  CHECK(!authorizeBearer("Bearer 0123456789abcdef", nullptr));
  CHECK(!authorizeBearer("Bearer 0123456789abcdef", ""));
  CHECK(!authorizeBearer("0123456789abcdef", "0123456789abcdef"));
  CHECK(!authorizeBearer("Bearer ", "0123456789abcdef"));

  char token64[65];
  std::memset(token64, 'x', 64);
  token64[64] = '\0';
  char header64[72];
  std::strcpy(header64, "Bearer ");
  std::strcat(header64, token64);
  CHECK(authorizeBearer(header64, token64));

  char overlongToken[66];
  std::memset(overlongToken, 'x', 65);
  overlongToken[65] = '\0';
  char overlongHeader[73];
  std::strcpy(overlongHeader, "Bearer ");
  std::strcat(overlongHeader, overlongToken);
  CHECK(!authorizeBearer(overlongHeader, overlongToken));

  char unterminatedToken[65];
  std::memset(unterminatedToken, 'x', sizeof(unterminatedToken));
  CHECK(!authorizeBearer(header64, unterminatedToken));
  char unterminatedHeader[72];
  std::memcpy(unterminatedHeader, "Bearer ", 7);
  std::memset(unterminatedHeader + 7, 'x', 65);
  CHECK(!authorizeBearer(unterminatedHeader, token64));
}

static RuntimeStatus mqttRuntimeStatus() {
  return RuntimeStatus{100, 200, true, -42, true, false};
}

static DeviceConfig mqttConfig() {
  DeviceConfig cfg = validDeviceConfig();
  cfg.mqttEnabled = true;
  std::strcpy(cfg.mqttHost, "broker.local");
  std::strcpy(cfg.mqttBaseTopic, "water-sensor");
  return cfg;
}

static void testMqttSafetyProcessNeverConnectsOnMainLoop() {
  // Moving socket work back into process() would block the safety loop and
  // must fail this test before a fake network task gets a chance to run.
  resetFakeMqtt();
  LeakController controller(config());
  ConfigStore store;
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, store, mqttRuntimeStatus);
  mqtt.begin();
  mqtt.process(0);
  CHECK(fakeMqttConnectCalls == 0);
  CHECK(fakeMqttLoopCalls == 0);
}

static void testMqttWorkerUsesImmutableNetworkConfigSnapshot() {
  // Reading the mutable sketch configuration from the worker would race a
  // portal save; the worker must retain its boot-time broker settings.
  resetFakeMqtt();
  LeakController controller(config());
  ConfigStore store;
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, store, mqttRuntimeStatus);
  mqtt.begin();
  std::strcpy(cfg.mqttHost, "changed-after-begin");
  runFakeMqttTaskAt(0);
  CHECK(fakeMqttHost == "broker.local");
}

static void testMqttConnectUsesBoundedSettingsTopicsAndHeartbeat() {
  // A regression in topic construction, broker setup, or initial retained
  // publication must make this test fail.
  resetFakeMqtt();
  fakeWifiConnected = true;
  fakeEfuseMac = 0x123456ULL;
  LeakController controller(config());
  ConfigStore store;
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, store, mqttRuntimeStatus);
  mqtt.begin();
  mqtt.process(0);
  runFakeMqttTaskAt(0);
  mqtt.process(0);
  runFakeMqttTaskAt(1);

  CHECK(mqtt.connected());
  CHECK(fakeMqttBufferSize == 1024);
  CHECK(fakeMqttKeepAlive == 30);
  CHECK(fakeMqttSocketTimeout == 2);
  CHECK(fakeWifiConnectionTimeoutMs == 2000);
  CHECK(fakeMqttHost == "broker.local");
  CHECK(fakeMqttPort == 1883);
  CHECK(fakeMqttClientId == "water-sensor-123456");
  CHECK(fakeMqttWillTopic == "water-sensor/availability");
  CHECK(fakeMqttWillMessage == "offline");
  CHECK(fakeMqttWillRetained);
  CHECK(fakeMqttSubscriptions.size() == 2);
  CHECK(fakeMqttSubscriptions[0] == "water-sensor/valve/set");
  CHECK(fakeMqttSubscriptions[1] == "water-sensor/buzzer/set");
  CHECK(fakeMqttPublishes.size() == 2);
  CHECK(fakeMqttPublishes[0].topic == "water-sensor/availability");
  CHECK(fakeMqttPublishes[0].payload == "online");
  CHECK(fakeMqttPublishes[0].retained);
  CHECK(fakeMqttPublishes[1].topic == "water-sensor/status");
  CHECK(fakeMqttPublishes[1].payload == "{\"safe\":true}");
  CHECK(fakeMqttPublishes[1].retained);
  runFakeMqttTaskAt(60000);
  mqtt.process(60000);
  runFakeMqttTaskAt(60001);
  CHECK(fakeMqttLoopCalls == 3);
  CHECK(fakeMqttPublishes.size() == 3);
  CHECK(fakeMqttPublishes[2].topic == "water-sensor/status");
}

static void testMqttReconnectBackoffMakesOneAttemptWhenDue() {
  // A tight reconnect loop or an incorrect first two retry intervals must
  // make this test fail.
  resetFakeMqtt();
  fakeMqttConnectResult = false;
  LeakController controller(config());
  ConfigStore store;
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, store, mqttRuntimeStatus);
  mqtt.begin();
  runFakeMqttTaskAt(0);
  runFakeMqttTaskAt(999);
  runFakeMqttTaskAt(1000);
  runFakeMqttTaskAt(2999);
  runFakeMqttTaskAt(3000);
  CHECK(fakeMqttConnectCalls == 3);
}

static void testMqttValveCommandPersistsImmediatelyAndRejectsWetOpen() {
  // Changing command normalization, controller routing, or persistence would
  // leave the observable valve/result behavior below incorrect.
  resetFakeMqtt();
  fakeConfigStoreSaveResult = true;
  fakeConfigStoreSaveCalls = 0;
  LeakController controller(config());
  establishDry(controller);
  ConfigStore store;
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, store, mqttRuntimeStatus);
  mqtt.begin();
  runFakeMqttTaskAt(0);
  mqtt.process(0);
  runFakeMqttTaskAt(1);
  fakeMqttDeliver("water-sensor/valve/set", "  close\t");
  CHECK(fakeConfigStoreSaveCalls == 0);
  mqtt.process(1);
  CHECK(controller.valveState() == ValveState::Closed);
  CHECK(fakeConfigStoreSaveCalls == 1);
  runFakeMqttTaskAt(2);
  CHECK(fakeMqttPublishes[2].topic == "water-sensor/command/result");
  CHECK(fakeMqttPublishes[2].payload ==
        "{\"command\":\"CLOSE\",\"accepted\":true,\"state\":\"closed\"}");
  CHECK(fakeMqttPublishes.back().topic == "water-sensor/status");

  establishWet(controller, 2000);
  fakeMqttDeliver("water-sensor/valve/set", "OPEN");
  mqtt.process(3);
  CHECK(controller.valveState() == ValveState::Closed);
  CHECK(fakeConfigStoreSaveCalls == 1);
  runFakeMqttTaskAt(4);
  CHECK(fakeMqttPublishes[4].payload ==
        "{\"command\":\"OPEN\",\"accepted\":false,\"error\":\"sensor_wet\"}");
}

static void testMqttStatusSerializationRetriesWithoutErrorFlooding() {
  // Replacing retained-dirty retry with a busy-loop of result errors must
  // fail this test.
  resetFakeMqtt();
  fakeStatusSerializationResult = false;
  LeakController controller(config());
  ConfigStore store;
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, store, mqttRuntimeStatus);
  mqtt.begin();
  runFakeMqttTaskAt(0);
  mqtt.process(0);
  runFakeMqttTaskAt(1);
  CHECK(fakeMqttPublishes.size() == 2);
  CHECK(fakeMqttPublishes[1].payload ==
        "{\"command\":\"STATUS\",\"accepted\":false,\"error\":\"status_serialization_failed\"}");
  mqtt.process(2);
  runFakeMqttTaskAt(3);
  CHECK(fakeMqttPublishes.size() == 2);

  fakeStatusSerializationResult = true;
  mqtt.process(1000);
  runFakeMqttTaskAt(1001);
  CHECK(fakeMqttPublishes.size() == 3);
  CHECK(fakeMqttPublishes[2].topic == "water-sensor/status");
}

static void testMqttPersistenceFailureKeepsMainLoopRetryState() {
  // Clearing the controller dirty bit after an unsuccessful immediate write
  // would silently lose an accepted OPEN across restart.
  resetFakeMqtt();
  fakeConfigStoreSaveResult = false;
  fakeConfigStoreSaveCalls = 0;
  LeakController controller(config());
  establishDry(controller);
  ConfigStore store;
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, store, mqttRuntimeStatus);
  mqtt.begin();
  runFakeMqttTaskAt(0);
  mqtt.process(0);
  runFakeMqttTaskAt(1);
  fakeMqttDeliver("water-sensor/valve/set", "OPEN");
  mqtt.process(2);
  CHECK(controller.valveState() == ValveState::Open);
  CHECK(fakeConfigStoreSaveCalls == 1);
  CHECK(controller.takePersistentDirty());
  runFakeMqttTaskAt(3);
  CHECK(fakeMqttPublishes[2].payload ==
        "{\"command\":\"OPEN\",\"accepted\":false,\"error\":\"persistence_failed\"}");
}

int main() {
  testStartupIsSafeAndClean();
  testOutputPolarityMapping();
  testPersistenceRetryWaitsAfterFailure();
  testPersistenceRetryUsesNewestSnapshotImmediately();
  testInvalidFirstRunClearsNewCredentialsAndRestartsPortal();
  testInvalidExistingConfigRestoresCredentialsAndRestartsPortal();
  testValidFirstRunPublishesAndProtectsLaterCredentials();
  testInvalidStartingConfigAlwaysForcesPortal();
  testWetLatchesAndCloses();
  testDryDoesNotClearLatch();
  testWetOpenIsRejected();
  testUninitializedOpenIsRejected();
  testStartupRestoresOpenOnlyAfterDry();
  testHysteresisAndDebounceRejectNoise();
  testDryOpenClearsLatch();
  testOtaRejectsOpen();
  testAlarmCadence();
  testSilenceStopsOnlyAlarm();
  testAlarmTimeoutStopsOnlyAlarm();
  testAlarmTimeoutSignalsExactlyOnce();
  testRepeatWetRestartsSilencedAlarm();
  testRestoredLatchStartsFreshAlarm();
  testPersistenceDirtyOnlyOnPersistentChange();
  testMillisWraparound();
  testConfigValidation();
  testConfigValidationBoundaries();
  testBearerAuthentication();
  testMqttSafetyProcessNeverConnectsOnMainLoop();
  testMqttWorkerUsesImmutableNetworkConfigSnapshot();
  testMqttConnectUsesBoundedSettingsTopicsAndHeartbeat();
  testMqttReconnectBackoffMakesOneAttemptWhenDue();
  testMqttValveCommandPersistsImmediatelyAndRejectsWetOpen();
  testMqttStatusSerializationRetriesWithoutErrorFlooding();
  testMqttPersistenceFailureKeepsMainLoopRetryState();
  if (failures) return EXIT_FAILURE;
  std::cout << "All native tests passed\n";
  return EXIT_SUCCESS;
}

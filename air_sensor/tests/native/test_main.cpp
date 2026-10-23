#include "AirController.h"
#include "Auth.h"
#include "DeviceConfig.h"
#include "Hostname.h"
#include "MqttService.h"
#include "MqttServiceTestSupport.h"
#include "OutputLogic.h"
#include "PortalSubmissionPolicy.h"
#include "PubSubClient.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>

static int failures = 0;
#define CHECK(expr) do { if (!(expr)) { std::cerr << __func__ << ":" << __LINE__ << " CHECK(" #expr ") failed\n"; ++failures; } } while (0)

namespace {

constexpr uint32_t WARMUP_MS = 60000;
constexpr uint32_t TRIGGER_HOLD_MS = 3000;
constexpr uint32_t CLEAR_HOLD_MS = 30000;
constexpr uint32_t SENSOR_TIMEOUT_MS = 15000;
constexpr uint32_t SILENCE_MS = 300000;
constexpr uint32_t SELF_TEST_MS = 4000;

AirConfig config() {
  return AirConfig{50,   100,  1500,             2200,
                   35,   150,  100,              250,
                   WARMUP_MS,  TRIGGER_HOLD_MS,  CLEAR_HOLD_MS,
                   SENSOR_TIMEOUT_MS, SILENCE_MS, SELF_TEST_MS};
}

ParticulateReading particulate(uint16_t pm25, uint16_t pm10) {
  return ParticulateReading{pm25, pm25, pm10, 1500, 400, 80, 10};
}

void feedAll(AirController& controller, uint16_t coPpm, uint16_t gasAdc,
             uint16_t pm25, uint16_t pm10, uint32_t nowMs) {
  controller.updateCo(CoReading{coPpm, 0x04, 0x00}, nowMs);
  controller.updateGas(gasAdc, nowMs);
  controller.updateParticulate(particulate(pm25, pm10), nowMs);
}

// Feeds clean air until every channel has left warm-up, and returns the time
// reached. Sensors must keep reporting or they would go stale instead.
uint32_t settleClean(AirController& controller, uint32_t startMs = 0) {
  controller.begin(startMs);
  for (uint32_t nowMs = startMs; nowMs <= startMs + WARMUP_MS; nowMs += 1000) {
    feedAll(controller, 0, 100, 5, 8, nowMs);
    controller.tick(nowMs);
  }
  return startMs + WARMUP_MS + 1000;
}

// Holds one reading steady across a span so the trigger/clear timers run.
uint32_t hold(AirController& controller, uint16_t coPpm, uint16_t gasAdc,
              uint16_t pm25, uint16_t pm10, uint32_t fromMs, uint32_t durationMs) {
  for (uint32_t nowMs = fromMs; nowMs <= fromMs + durationMs; nowMs += 500) {
    feedAll(controller, coPpm, gasAdc, pm25, pm10, nowMs);
    controller.tick(nowMs);
  }
  return fromMs + durationMs;
}

// ------------------------------------------------------------ air safety

void testStartupIsWarmupAndSilent() {
  AirController controller(config());
  controller.begin(0);
  controller.tick(0);
  CHECK(controller.coState() == ChannelState::Warmup);
  CHECK(controller.gasState() == ChannelState::Warmup);
  CHECK(controller.particulateState() == ChannelState::Warmup);
  CHECK(controller.alarmState() == AlarmState::Inactive);
  CHECK(controller.alarmHazard() == Hazard::None);
  CHECK(!controller.buzzerOutput(0));
  CHECK(controller.ledColor(0) == LedColor::Blue);
  CHECK(!controller.otaActive());
}

void testWarmupSuppressesAlarmsAndPeaks() {
  // An unheated MQ5 and a cold electrochemical cell both read high. Alarming
  // on that would train the owner to ignore the device.
  AirController controller(config());
  controller.begin(0);
  hold(controller, 900, 4000, 900, 900, 0, WARMUP_MS / 2);
  CHECK(controller.alarmState() == AlarmState::Inactive);
  CHECK(!controller.buzzerOutput(WARMUP_MS / 2));
  CHECK(controller.coPeakPpm() == 0);
  CHECK(controller.gasPeakAdc() == 0);
  CHECK(controller.pm25PeakUgm3() == 0);
  CHECK(controller.warmupRemainingMs(WARMUP_MS / 2) > 0);
  CHECK(controller.warmupRemainingMs(WARMUP_MS) == 0);
}

void testDangerNeedsTriggerHoldThenSounds() {
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  CHECK(controller.coState() == ChannelState::Ok);
  CHECK(controller.ledColor(nowMs) == LedColor::Green);

  // A single spike must not raise the alarm.
  feedAll(controller, 900, 100, 5, 8, nowMs);
  controller.tick(nowMs);
  CHECK(controller.coState() == ChannelState::Ok);

  nowMs = hold(controller, 900, 100, 5, 8, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.coState() == ChannelState::Danger);
  CHECK(controller.alarmState() == AlarmState::Sounding);
  CHECK(controller.alarmHazard() == Hazard::CarbonMonoxide);
  CHECK(controller.ledColor(nowMs) == LedColor::Red);
  CHECK(controller.coPeakPpm() == 900);
}

void testClearNeedsClearHold() {
  // Air moves. Dropping the alarm the instant a reading dips would chatter.
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.alarmState() == AlarmState::Sounding);

  nowMs = hold(controller, 0, 100, 5, 8, nowMs, CLEAR_HOLD_MS / 2);
  CHECK(controller.alarmState() == AlarmState::Sounding);

  nowMs = hold(controller, 0, 100, 5, 8, nowMs, CLEAR_HOLD_MS);
  CHECK(controller.coState() == ChannelState::Ok);
  CHECK(controller.alarmState() == AlarmState::Inactive);
  CHECK(controller.ledColor(nowMs) == LedColor::Green);
  CHECK(controller.coPeakPpm() == 900);
}

void testHazardPriorityIsCoThenGasThenParticulate() {
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  nowMs = hold(controller, 900, 4000, 900, 900, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.alarmHazard() == Hazard::CarbonMonoxide);
  CHECK(controller.ledColor(nowMs) == LedColor::Red);

  nowMs = hold(controller, 0, 4000, 900, 900, nowMs, CLEAR_HOLD_MS + 500);
  CHECK(controller.alarmHazard() == Hazard::Gas);
  CHECK(controller.ledColor(nowMs) == LedColor::Orange);

  nowMs = hold(controller, 0, 100, 900, 900, nowMs, CLEAR_HOLD_MS + 500);
  CHECK(controller.alarmHazard() == Hazard::Particulate);
  CHECK(controller.ledColor(nowMs) == LedColor::Magenta);
}

void testWarningIsVisibleButSilent() {
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  nowMs = hold(controller, 0, 100, 60, 8, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.particulateState() == ChannelState::Warning);
  CHECK(controller.alarmState() == AlarmState::Warning);
  CHECK(controller.alarmHazard() == Hazard::Particulate);
  CHECK(controller.ledColor(nowMs) == LedColor::Magenta);
  bool sounded = false;
  for (uint32_t offset = 0; offset < 5000; offset += 50) {
    sounded = sounded || controller.buzzerOutput(nowMs + offset);
  }
  CHECK(!sounded);
}

void testPm10AloneCanRaiseTheParticulateChannel() {
  // The two limits are independent standards; only reading PM2.5 would miss a
  // coarse-dust event entirely.
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  nowMs = hold(controller, 0, 100, 5, 900, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.particulateState() == ChannelState::Danger);
  CHECK(controller.alarmHazard() == Hazard::Particulate);
}

void testSilenceMutesOnlyTheBuzzer() {
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.silenceAlarm(nowMs) == CommandResult::Accepted);
  CHECK(controller.alarmState() == AlarmState::Silenced);
  CHECK(!controller.buzzerOutput(nowMs));
  // The visual alarm is not silenceable.
  CHECK(controller.ledColor(nowMs) == LedColor::Red);
  CHECK(controller.ledBrightness(nowMs) == 255);
  CHECK(controller.silenceRemainingMs(nowMs) == SILENCE_MS);

  AirController quiet(config());
  const uint32_t settledMs = settleClean(quiet);
  CHECK(quiet.silenceAlarm(settledMs) == CommandResult::RejectedInactive);
}

void testSilenceExpiresAndResumesSounding() {
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, TRIGGER_HOLD_MS + 500);
  controller.silenceAlarm(nowMs);
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, SILENCE_MS + 1000);
  CHECK(controller.alarmState() == AlarmState::Sounding);
  CHECK(controller.silenceRemainingMs(nowMs) == 0);
}

void testSilenceDoesNotCoverADifferentHazard() {
  // Muting a dust alarm must not also mute the carbon monoxide behind it.
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  nowMs = hold(controller, 0, 100, 900, 900, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.alarmHazard() == Hazard::Particulate);
  CHECK(controller.silenceAlarm(nowMs) == CommandResult::Accepted);

  nowMs = hold(controller, 900, 100, 900, 900, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.alarmHazard() == Hazard::CarbonMonoxide);
  CHECK(controller.alarmState() == AlarmState::Sounding);
}

void testStaleSensorFaultsWithoutSoundingTheBuzzer() {
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  // Keep the other two channels alive so only carbon monoxide goes stale.
  for (uint32_t offset = 0; offset <= SENSOR_TIMEOUT_MS + 1000; offset += 500) {
    controller.updateGas(100, nowMs + offset);
    controller.updateParticulate(particulate(5, 8), nowMs + offset);
    controller.tick(nowMs + offset);
  }
  nowMs += SENSOR_TIMEOUT_MS + 1000;
  CHECK(controller.coState() == ChannelState::Fault);
  CHECK(!controller.coFresh(nowMs));
  CHECK(controller.coAgeMs(nowMs) >= SENSOR_TIMEOUT_MS);
  CHECK(controller.alarmState() == AlarmState::Inactive);
  CHECK(controller.ledColor(nowMs) == LedColor::Cyan);
  bool sounded = false;
  for (uint32_t offset = 0; offset < 5000; offset += 50) {
    sounded = sounded || controller.buzzerOutput(nowMs + offset);
  }
  CHECK(!sounded);

  // Recovery is immediate; a returning sensor should not wait out a clear hold.
  feedAll(controller, 0, 100, 5, 8, nowMs);
  controller.tick(nowMs);
  CHECK(controller.coState() == ChannelState::Ok);
}

void testFaultNeverOutranksARealHazard() {
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  for (uint32_t offset = 0; offset <= SENSOR_TIMEOUT_MS + TRIGGER_HOLD_MS + 1000;
       offset += 500) {
    controller.updateGas(4000, nowMs + offset);
    controller.updateParticulate(particulate(5, 8), nowMs + offset);
    controller.tick(nowMs + offset);
  }
  nowMs += SENSOR_TIMEOUT_MS + TRIGGER_HOLD_MS + 1000;
  CHECK(controller.coState() == ChannelState::Fault);
  CHECK(controller.gasState() == ChannelState::Danger);
  CHECK(controller.ledColor(nowMs) == LedColor::Orange);
  CHECK(controller.alarmState() == AlarmState::Sounding);
}

void testBuzzerCadenceDiffersPerHazard() {
  // The colour tells an installer standing in front of the unit; the cadence
  // tells someone in the next room.
  // Gap between two consecutive rising edges, so the answer does not depend on
  // where in the cadence the measurement starts.
  const auto periodOf = [](AirController& controller, uint32_t fromMs) {
    bool previous = controller.buzzerOutput(fromMs);
    uint32_t firstEdge = 0;
    bool haveFirstEdge = false;
    for (uint32_t offset = 1; offset < 20000; ++offset) {
      const bool current = controller.buzzerOutput(fromMs + offset);
      if (!previous && current) {
        if (!haveFirstEdge) {
          firstEdge = offset;
          haveFirstEdge = true;
        } else {
          return offset - firstEdge;
        }
      }
      previous = current;
    }
    return 0u;
  };

  AirController co(config());
  uint32_t coMs = settleClean(co);
  coMs = hold(co, 900, 100, 5, 8, coMs, TRIGGER_HOLD_MS + 500);
  CHECK(periodOf(co, coMs) == 300);

  AirController gas(config());
  uint32_t gasMs = settleClean(gas);
  gasMs = hold(gas, 0, 4000, 5, 8, gasMs, TRIGGER_HOLD_MS + 500);
  CHECK(periodOf(gas, gasMs) == 600);

  AirController dust(config());
  uint32_t dustMs = settleClean(dust);
  dustMs = hold(dust, 0, 100, 900, 900, dustMs, TRIGGER_HOLD_MS + 500);
  CHECK(periodOf(dust, dustMs) == 2500);
}

void testSelfTestIsBlockedByAlarmsAndOta() {
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  CHECK(controller.startSelfTest(nowMs) == CommandResult::Accepted);
  CHECK(controller.selfTestActive(nowMs));
  CHECK(controller.ledColor(nowMs) == LedColor::Red);
  CHECK(controller.ledColor(nowMs + SELF_TEST_MS - 1) == LedColor::White);
  CHECK(controller.buzzerOutput(nowMs));
  CHECK(controller.startSelfTest(nowMs) == CommandResult::RejectedBusy);
  controller.tick(nowMs + SELF_TEST_MS + 1);
  CHECK(!controller.selfTestActive(nowMs + SELF_TEST_MS + 1));

  controller.setOtaActive(true);
  CHECK(controller.startSelfTest(nowMs + SELF_TEST_MS + 2) ==
        CommandResult::RejectedOta);
  controller.setOtaActive(false);

  nowMs = hold(controller, 900, 100, 5, 8, nowMs + SELF_TEST_MS + 2,
               TRIGGER_HOLD_MS + 500);
  CHECK(controller.startSelfTest(nowMs) == CommandResult::RejectedBusy);
}

void testDangerAbortsAnInFlightSelfTest() {
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  // Build the danger up to one tick short of raising it, then start the test.
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, TRIGGER_HOLD_MS - 1000);
  CHECK(controller.startSelfTest(nowMs) == CommandResult::Accepted);
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, 2000);
  CHECK(controller.alarmState() == AlarmState::Sounding);
  CHECK(!controller.selfTestActive(nowMs));
  CHECK(controller.ledColor(nowMs) == LedColor::Red);
}

void testOtaDoesNotMuteALiveAlarm() {
  // An update must never be a way to make a carbon monoxide alarm stop.
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, TRIGGER_HOLD_MS + 500);
  controller.setOtaActive(true);
  CHECK(controller.otaActive());
  CHECK(controller.alarmState() == AlarmState::Sounding);
  bool sounded = false;
  for (uint32_t offset = 0; offset < 1000; offset += 25) {
    sounded = sounded || controller.buzzerOutput(nowMs + offset);
  }
  CHECK(sounded);
  CHECK(controller.ledColor(nowMs) == LedColor::Red);
}

void testTickReportsObservableChangesOnly() {
  AirController controller(config());
  const uint32_t nowMs = settleClean(controller);
  feedAll(controller, 0, 100, 5, 8, nowMs);
  CHECK(!controller.tick(nowMs));
  CHECK(!controller.tick(nowMs + 10));
}

void testMillisWraparound() {
  const uint32_t nearWrap = 0xFFFFF000UL;
  AirController controller(config());
  uint32_t nowMs = settleClean(controller, nearWrap);
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.alarmState() == AlarmState::Sounding);
  controller.silenceAlarm(nowMs);
  CHECK(controller.silenceRemainingMs(nowMs) == SILENCE_MS);
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, SILENCE_MS + 1000);
  CHECK(controller.alarmState() == AlarmState::Sounding);
}

// --------------------------------------------------------- output mapping

void testOutputPolarityMapping() {
  CHECK(activeLevelFor(true, true));
  CHECK(!activeLevelFor(false, true));
  CHECK(!activeLevelFor(true, false));
  CHECK(activeLevelFor(false, false));
}

void testLedDutyRespectsWiringPolarity() {
  // A common-anode LED sinks current, so full brightness is duty zero.
  CHECK(ledDutyFor(255, 255, false) == 255);
  CHECK(ledDutyFor(255, 255, true) == 0);
  CHECK(ledDutyFor(255, 0, false) == 0);
  CHECK(ledDutyFor(255, 0, true) == 255);
  CHECK(ledDutyFor(0, 255, false) == 0);
  CHECK(ledRgbFor(LedColor::Red).red == 255);
  CHECK(ledRgbFor(LedColor::Off).red == 0);
  CHECK(std::strcmp(ledColorName(LedColor::Magenta), "magenta") == 0);
}

// ------------------------------------------------------------ portal glue

void testPortalSubmissionPolicy() {
  PortalSubmissionPolicy firstRun(false);
  CHECK(firstRun.shouldForcePortal(false));
  CHECK(firstRun.evaluate(false) ==
        PortalSubmissionAction::ClearCredentialsAndRestart);
  CHECK(firstRun.evaluate(true) == PortalSubmissionAction::PublishConfig);
  CHECK(firstRun.takePublishReady());
  CHECK(!firstRun.takePublishReady());
  CHECK(firstRun.evaluate(false) ==
        PortalSubmissionAction::RestoreCredentialsAndRestart);
  CHECK(!firstRun.takePublishReady());

  PortalSubmissionPolicy configured(true);
  CHECK(!configured.shouldForcePortal(false));
  CHECK(configured.shouldForcePortal(true));
  CHECK(configured.evaluate(true) == PortalSubmissionAction::PublishConfig);
  CHECK(configured.evaluate(false) ==
        PortalSubmissionAction::RestoreCredentialsAndRestart);
  CHECK(!configured.takePublishReady());
}

DeviceConfig validDeviceConfig() {
  DeviceConfig cfg = defaultDeviceConfig();
  std::strcpy(cfg.apiToken, "0123456789abcdef");
  return cfg;
}

void testConfigValidation() {
  DeviceConfig cfg = defaultDeviceConfig();
  CHECK(!validateDeviceConfig(cfg).valid);  // no token yet
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "apiToken") == 0);

  cfg = validDeviceConfig();
  CHECK(validateDeviceConfig(cfg).valid);

  cfg = validDeviceConfig();
  cfg.coWarnPpm = cfg.coDangerPpm;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "coThresholds") == 0);

  cfg = validDeviceConfig();
  cfg.coWarnPpm = 0;
  CHECK(!validateDeviceConfig(cfg).valid);

  cfg = validDeviceConfig();
  cfg.gasDangerAdc = GAS_ADC_MAX + 1;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "gasThresholds") == 0);

  cfg = validDeviceConfig();
  cfg.pm25DangerUgm3 = 10;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "pm25Thresholds") == 0);

  cfg = validDeviceConfig();
  cfg.pm10WarnUgm3 = 400;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "pm10Thresholds") == 0);

  cfg = validDeviceConfig();
  cfg.sensorWarmupSeconds = 5;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "sensorWarmupSeconds") == 0);

  cfg = validDeviceConfig();
  cfg.alarmSilenceSeconds = 10;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "alarmSilenceSeconds") == 0);

  cfg = validDeviceConfig();
  cfg.mqttPort = 0;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "mqttPort") == 0);

  // MQTT without a broker host is not a usable configuration.
  cfg = validDeviceConfig();
  cfg.mqttEnabled = true;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "mqttHost") == 0);

  cfg = validDeviceConfig();
  std::strcpy(cfg.apiToken, "short");
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "apiToken") == 0);

  cfg = validDeviceConfig();
  cfg.deviceName[0] = '\0';
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "deviceName") == 0);
}

void testBearerAuthentication() {
  CHECK(authorizeBearer("Bearer 0123456789abcdef", "0123456789abcdef"));
  CHECK(!authorizeBearer("Bearer 0123456789abcde", "0123456789abcdef"));
  CHECK(!authorizeBearer("Bearer 0123456789abcdefg", "0123456789abcdef"));
  CHECK(!authorizeBearer("bearer 0123456789abcdef", "0123456789abcdef"));
  CHECK(!authorizeBearer("0123456789abcdef", "0123456789abcdef"));
  CHECK(!authorizeBearer(nullptr, "0123456789abcdef"));
  CHECK(!authorizeBearer("Bearer ", ""));
}

// ------------------------------------------------------------------ MQTT

RuntimeStatus mqttRuntimeStatus() {
  return RuntimeStatus{0,
                       SampledClimate{ClimateReading{220, 450}, true, 0},
                       SampledPresence{PresenceReading{}, true, 0},
                       true,
                       -50,
                       true,
                       false,
                       0};
}

DeviceConfig mqttConfig() {
  DeviceConfig cfg = validDeviceConfig();
  cfg.mqttEnabled = true;
  std::strcpy(cfg.mqttHost, "broker.local");
  std::strcpy(cfg.mqttBaseTopic, "canary");
  return cfg;
}

void testMqttSafetyProcessNeverConnectsOnMainLoop() {
  // Moving socket work back into process() would block the safety loop and
  // must fail this test before a fake network task gets a chance to run.
  resetFakeMqtt();
  AirController controller(config());
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, mqttRuntimeStatus, fakeMeshLink);
  mqtt.begin();
  mqtt.process(0);
  CHECK(fakeMqttConnectCalls == 0);
  CHECK(fakeMqttLoopCalls == 0);
}

void testMqttWorkerUsesImmutableNetworkConfigSnapshot() {
  // Reading the mutable sketch configuration from the worker would race a
  // portal save; the worker must retain its boot-time broker settings.
  resetFakeMqtt();
  AirController controller(config());
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, mqttRuntimeStatus, fakeMeshLink);
  mqtt.begin();
  std::strcpy(cfg.mqttHost, "changed-after-begin");
  runFakeMqttTaskAt(0);
  CHECK(fakeMqttHost == "broker.local");
}

void testMqttConnectUsesBoundedSettingsTopicsAndHeartbeat() {
  resetFakeMqtt();
  fakeWifiConnected = true;
  fakeEfuseMac = 0x123456ULL;
  AirController controller(config());
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, mqttRuntimeStatus, fakeMeshLink);
  mqtt.begin();
  mqtt.process(0);
  runFakeMqttTaskAt(0);
  mqtt.process(0);
  runFakeMqttTaskAt(1);

  CHECK(mqtt.connected());
  CHECK(fakeMqttBufferSize == 2048);
  CHECK(fakeMqttKeepAlive == 30);
  CHECK(fakeMqttSocketTimeout == 2);
  CHECK(fakeWifiConnectionTimeoutMs == 2000);
  CHECK(fakeMqttHost == "broker.local");
  CHECK(fakeMqttPort == 1883);
  CHECK(fakeMqttClientId == "canary-123456");
  CHECK(fakeMqttWillTopic == "canary/availability");
  CHECK(fakeMqttWillMessage == "offline");
  CHECK(fakeMqttWillRetained);
  // Only the buzzer topic is subscribed: this device has no actuator.
  CHECK(fakeMqttSubscriptions.size() == 1);
  CHECK(fakeMqttSubscriptions[0] == "canary/buzzer/set");
  CHECK(fakeMqttPublishes.size() == 2);
  CHECK(fakeMqttPublishes[0].topic == "canary/availability");
  CHECK(fakeMqttPublishes[0].payload == "online");
  CHECK(fakeMqttPublishes[0].retained);
  CHECK(fakeMqttPublishes[1].topic == "canary/status");
  CHECK(fakeMqttPublishes[1].retained);

  // A monitoring device republishes on a tighter heartbeat than an actuator.
  runFakeMqttTaskAt(15000);
  mqtt.process(15000);
  runFakeMqttTaskAt(15001);
  CHECK(fakeMqttPublishes.size() == 3);
  CHECK(fakeMqttPublishes[2].topic == "canary/status");
}

void testMqttReconnectBackoffMakesOneAttemptWhenDue() {
  resetFakeMqtt();
  fakeMqttConnectResult = false;
  AirController controller(config());
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, mqttRuntimeStatus, fakeMeshLink);
  mqtt.begin();
  runFakeMqttTaskAt(0);
  runFakeMqttTaskAt(999);
  runFakeMqttTaskAt(1000);
  runFakeMqttTaskAt(2999);
  runFakeMqttTaskAt(3000);
  CHECK(fakeMqttConnectCalls == 3);
}

void testMqttSilenceIsAppliedOnTheSafetyLoop() {
  // Applying a command inside the MQTT callback would mutate controller state
  // from the network task.
  resetFakeMqtt();
  AirController controller(config());
  uint32_t nowMs = settleClean(controller);
  nowMs = hold(controller, 900, 100, 5, 8, nowMs, TRIGGER_HOLD_MS + 500);
  CHECK(controller.alarmState() == AlarmState::Sounding);

  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, mqttRuntimeStatus, fakeMeshLink);
  mqtt.begin();
  runFakeMqttTaskAt(0);
  mqtt.process(nowMs);
  runFakeMqttTaskAt(1);

  fakeMqttDeliver("canary/buzzer/set", "  silence\t");
  CHECK(controller.alarmState() == AlarmState::Sounding);
  mqtt.process(nowMs);
  CHECK(controller.alarmState() == AlarmState::Silenced);
  runFakeMqttTaskAt(2);
  CHECK(fakeMqttPublishes[2].topic == "canary/command/result");
  CHECK(fakeMqttPublishes[2].payload ==
        "{\"command\":\"SILENCE\",\"accepted\":true,\"state\":\"silenced\"}");
  CHECK(fakeMqttPublishes.back().topic == "canary/status");
}

void testMqttReportsRejectedAndUnknownCommands() {
  resetFakeMqtt();
  AirController controller(config());
  const uint32_t nowMs = settleClean(controller);
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, mqttRuntimeStatus, fakeMeshLink);
  mqtt.begin();
  runFakeMqttTaskAt(0);
  mqtt.process(nowMs);
  runFakeMqttTaskAt(1);

  fakeMqttDeliver("canary/buzzer/set", "SILENCE");
  mqtt.process(nowMs);
  runFakeMqttTaskAt(2);
  CHECK(fakeMqttPublishes[2].payload ==
        "{\"command\":\"SILENCE\",\"accepted\":false,\"error\":\"alarm_inactive\"}");

  fakeMqttDeliver("canary/buzzer/set", "TEST");
  mqtt.process(nowMs);
  runFakeMqttTaskAt(3);
  CHECK(controller.selfTestActive(nowMs));
  CHECK(fakeMqttPublishes[4].payload ==
        "{\"command\":\"TEST\",\"accepted\":true,\"state\":\"self_test\"}");

  const size_t before = fakeMqttPublishes.size();
  fakeMqttDeliver("canary/buzzer/set", "OPEN");
  CHECK(fakeMqttPublishes.size() == before + 1);
  CHECK(fakeMqttPublishes.back().payload ==
        "{\"command\":\"UNKNOWN\",\"accepted\":false,\"error\":\"invalid_command\"}");
  CHECK(!fakeMqttPublishes.back().retained);
}

void testMqttStatusSerializationRetriesWithoutErrorFlooding() {
  resetFakeMqtt();
  fakeStatusSerializationResult = false;
  AirController controller(config());
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, mqttRuntimeStatus, fakeMeshLink);
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
  CHECK(fakeMqttPublishes[2].topic == "canary/status");
}

void testMqttFallsBackToMeshWhileWifiIsDown() {
  // An outage must not silence the node: its status and heartbeat go to the
  // mesh, neighbours' frames are passed on, and the socket is left alone.
  resetFakeMqtt();
  fakeWifiConnected = false;
  AirController controller(config());
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, mqttRuntimeStatus, fakeMeshLink);
  mqtt.begin();
  mqtt.process(0);
  fakeMeshInbox.push_back(FakeMeshFrame{"water-sensor", "{}"});
  runFakeMqttTaskAt(0);
  CHECK(fakeMqttConnectCalls == 0);
  CHECK(fakeMqttPublishes.empty());
  CHECK(fakeMeshForwards == 1);
  CHECK(fakeMeshSends.size() == 1);
  CHECK(fakeMeshSends[0].topic == "canary");
  CHECK(fakeMeshSends[0].payload == "{\"safe\":true}");
  runFakeMqttTaskAt(1);
  CHECK(fakeMeshSends.size() == 1);
  runFakeMqttTaskAt(15000);
  mqtt.process(15000);
  runFakeMqttTaskAt(15001);
  CHECK(fakeMeshSends.size() == 2);
}

void testMqttRelaysMeshStatusToItsOriginTopic() {
  // Dropping a neighbour's status, publishing it under the relay's topic, or
  // letting a frame overwrite the relay's own status breaks the backup path.
  resetFakeMqtt();
  AirController controller(config());
  DeviceConfig cfg = mqttConfig();
  MqttService mqtt(cfg, controller, mqttRuntimeStatus, fakeMeshLink);
  mqtt.begin();
  mqtt.process(0);
  runFakeMqttTaskAt(0);
  runFakeMqttTaskAt(1);
  CHECK(mqtt.connected());
  const size_t published = fakeMqttPublishes.size();
  fakeMeshInbox.push_back(FakeMeshFrame{"water-sensor", "{\"valve\":{}}"});
  fakeMeshInbox.push_back(FakeMeshFrame{"canary", "{\"spoof\":true}"});
  runFakeMqttTaskAt(2);
  CHECK(fakeMqttPublishes.size() == published + 1);
  CHECK(fakeMqttPublishes.back().topic == "water-sensor/status");
  CHECK(fakeMqttPublishes.back().payload == "{\"valve\":{}}");
  CHECK(fakeMqttPublishes.back().retained);
  CHECK(fakeMeshForwards == 0);
}

}  // namespace

static void testHostnameSanitizesDeviceName() {
  char host[33];
  makeHostname("Kitchen Sink #2", "fallback", host, sizeof(host));
  CHECK(std::strcmp(host, "kitchen-sink-2") == 0);
  makeHostname("--Water__Sensor--", "fallback", host, sizeof(host));
  CHECK(std::strcmp(host, "water-sensor") == 0);
  makeHostname("!!!", "fallback", host, sizeof(host));
  CHECK(std::strcmp(host, "fallback") == 0);
  makeHostname("", "fallback", host, sizeof(host));
  CHECK(std::strcmp(host, "fallback") == 0);
  char small[6];
  makeHostname("ab cd ef", "fallback", small, sizeof(small));
  CHECK(std::strcmp(small, "ab-cd") == 0);
  makeHostname("abcd efgh", "fallback", small, sizeof(small));
  CHECK(std::strcmp(small, "abcd") == 0);
}

int main() {
  testStartupIsWarmupAndSilent();
  testWarmupSuppressesAlarmsAndPeaks();
  testDangerNeedsTriggerHoldThenSounds();
  testClearNeedsClearHold();
  testHazardPriorityIsCoThenGasThenParticulate();
  testWarningIsVisibleButSilent();
  testPm10AloneCanRaiseTheParticulateChannel();
  testSilenceMutesOnlyTheBuzzer();
  testSilenceExpiresAndResumesSounding();
  testSilenceDoesNotCoverADifferentHazard();
  testStaleSensorFaultsWithoutSoundingTheBuzzer();
  testFaultNeverOutranksARealHazard();
  testBuzzerCadenceDiffersPerHazard();
  testSelfTestIsBlockedByAlarmsAndOta();
  testDangerAbortsAnInFlightSelfTest();
  testOtaDoesNotMuteALiveAlarm();
  testTickReportsObservableChangesOnly();
  testMillisWraparound();
  testOutputPolarityMapping();
  testLedDutyRespectsWiringPolarity();
  testPortalSubmissionPolicy();
  testConfigValidation();
  testBearerAuthentication();
  testMqttSafetyProcessNeverConnectsOnMainLoop();
  testMqttWorkerUsesImmutableNetworkConfigSnapshot();
  testMqttConnectUsesBoundedSettingsTopicsAndHeartbeat();
  testMqttReconnectBackoffMakesOneAttemptWhenDue();
  testMqttSilenceIsAppliedOnTheSafetyLoop();
  testMqttReportsRejectedAndUnknownCommands();
  testMqttStatusSerializationRetriesWithoutErrorFlooding();
  testMqttFallsBackToMeshWhileWifiIsDown();
  testMqttRelaysMeshStatusToItsOriginTopic();
  testHostnameSanitizesDeviceName();
  if (failures) return EXIT_FAILURE;
  std::cout << "All native tests passed\n";
  return EXIT_SUCCESS;
}

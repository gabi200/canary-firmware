#pragma once

#include "OutputLogic.h"
#include "SensorReadings.h"

#include <stdint.h>

enum class ChannelState : uint8_t { Warmup, Fault, Ok, Warning, Danger };

// Ordered by escalation priority: a higher value wins the LED and the buzzer.
enum class Hazard : uint8_t { None, Particulate, Gas, CarbonMonoxide };

enum class AlarmState : uint8_t { Inactive, Warning, Sounding, Silenced };

enum class CommandResult : uint8_t {
  Accepted,
  RejectedInactive,
  RejectedBusy,
  RejectedOta,
};

struct AirConfig {
  uint16_t coWarnPpm;
  uint16_t coDangerPpm;
  uint16_t gasWarnAdc;
  uint16_t gasDangerAdc;
  uint16_t pm25WarnUgm3;
  uint16_t pm25DangerUgm3;
  uint16_t pm10WarnUgm3;
  uint16_t pm10DangerUgm3;
  uint32_t warmupMs;
  uint32_t triggerHoldMs;
  uint32_t clearHoldMs;
  uint32_t sensorTimeoutMs;
  uint32_t silenceMs;
  uint32_t selfTestMs;
};

// Platform-neutral hazard evaluation and alarm state machine. Holds no Arduino
// types so the native tests drive it directly.
//
// Safety contract: alarms are level-based, not latched. Air that clears really
// is safe again, unlike a water leak whose valve must stay shut. Silencing and
// OTA suppress neither the LED nor a fresh escalation.
class AirController {
 public:
  explicit AirController(const AirConfig& config);

  void begin(uint32_t nowMs);
  // Caps the warm-up window, still measured from begin(). Never lengthens it,
  // and ends warm-up at the next tick() when the cap has already passed.
  void shortenWarmup(uint32_t warmupMs);

  void updateCo(const CoReading& reading, uint32_t nowMs);
  void updateGas(uint16_t adc, uint32_t nowMs);
  void updateParticulate(const ParticulateReading& reading, uint32_t nowMs);

  // Recomputes every channel and the alarm. Returns true when an
  // externally-visible state changed and status should be republished.
  bool tick(uint32_t nowMs);

  CommandResult silenceAlarm(uint32_t nowMs);
  CommandResult startSelfTest(uint32_t nowMs);
  void setOtaActive(bool active);
  bool otaActive() const;

  ChannelState coState() const;
  ChannelState gasState() const;
  ChannelState particulateState() const;
  const CoReading& co() const;
  uint16_t gasAdc() const;
  const ParticulateReading& particulate() const;
  uint16_t coPeakPpm() const;
  uint16_t gasPeakAdc() const;
  uint16_t pm25PeakUgm3() const;
  uint16_t pm10PeakUgm3() const;
  bool coFresh(uint32_t nowMs) const;
  bool particulateFresh(uint32_t nowMs) const;
  uint32_t coAgeMs(uint32_t nowMs) const;
  uint32_t particulateAgeMs(uint32_t nowMs) const;

  AlarmState alarmState() const;
  Hazard alarmHazard() const;
  bool selfTestActive(uint32_t nowMs) const;
  uint32_t silenceRemainingMs(uint32_t nowMs) const;
  uint32_t warmupRemainingMs(uint32_t nowMs) const;

  LedColor ledColor(uint32_t nowMs) const;
  bool ledOn(uint32_t nowMs) const;
  uint8_t ledBrightness(uint32_t nowMs) const;
  bool buzzerOutput(uint32_t nowMs) const;

 private:
  struct Channel {
    ChannelState state;
    ChannelState candidate;
    uint32_t candidateSinceMs;
    bool candidateValid;
    uint32_t lastSampleMs;
    bool sampled;
  };

  struct Pattern {
    uint32_t onMs;
    uint32_t offMs;
  };

  static Channel idleChannel();
  static ChannelState levelFor(uint16_t value, uint16_t warn, uint16_t danger);
  static uint8_t severityRank(ChannelState state);
  static LedColor hazardColor(Hazard hazard);
  static bool elapsed(uint32_t nowMs, uint32_t sinceMs, uint32_t intervalMs);
  static bool phaseOn(uint32_t nowMs, uint32_t epochMs, const Pattern& pattern);

  bool warmingUp(uint32_t nowMs) const;
  bool stale(const Channel& channel, uint32_t nowMs) const;
  bool applyObservation(Channel& channel, ChannelState observed, uint32_t nowMs);
  ChannelState observeCo(uint32_t nowMs) const;
  ChannelState observeGas(uint32_t nowMs) const;
  ChannelState observeParticulate(uint32_t nowMs) const;
  Hazard worstAt(ChannelState level) const;
  bool anyChannelAt(ChannelState level) const;
  Pattern ledPattern(uint32_t nowMs) const;
  Pattern buzzerPattern() const;
  uint8_t selfTestStep(uint32_t nowMs) const;

  AirConfig config_;
  Channel coChannel_;
  Channel gasChannel_;
  Channel particulateChannel_;
  CoReading co_;
  uint16_t gasAdc_;
  ParticulateReading particulate_;
  uint16_t coPeakPpm_;
  uint16_t gasPeakAdc_;
  uint16_t pm25PeakUgm3_;
  uint16_t pm10PeakUgm3_;
  uint32_t bootMs_;
  AlarmState alarmState_;
  Hazard alarmHazard_;
  uint32_t patternEpochMs_;
  uint32_t silencedUntilMs_;
  Hazard silencedHazard_;
  bool silenceActive_;
  uint32_t selfTestStartedMs_;
  bool selfTestRunning_;
  bool otaActive_;
};

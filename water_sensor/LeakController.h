#pragma once

#include <stdint.h>

enum class SensorState : uint8_t { Uninitialized, Dry, Wet };
enum class ValveState : uint8_t { Open, Closed };
enum class AlarmState : uint8_t { Inactive, Sounding, Silenced, TimedOut };
enum class CommandResult : uint8_t { Accepted, RejectedWet, RejectedUninitialized, RejectedOta };

struct LeakConfig {
  uint16_t wetThreshold;
  uint16_t dryThreshold;
  uint32_t debounceMs;
  uint32_t alarmDurationMs;
  uint32_t beepOnMs;
  uint32_t beepOffMs;
};

struct PersistentState {
  bool leakLatched;
  ValveState requestedValve;
};

class LeakController {
 public:
  explicit LeakController(const LeakConfig& config);
  void restore(const PersistentState& state, uint32_t nowMs);
  bool updateSensor(uint16_t adcValue, uint32_t nowMs);
  CommandResult requestValve(ValveState requested, uint32_t nowMs);
  bool silenceAlarm();
  void setOtaActive(bool active);
  bool tick(uint32_t nowMs);
  SensorState sensorState() const;
  ValveState valveState() const;
  bool leakLatched() const;
  bool otaActive() const;
  AlarmState alarmState(uint32_t nowMs) const;
  bool buzzerOutput(uint32_t nowMs) const;
  uint32_t alarmRemainingMs(uint32_t nowMs) const;
  PersistentState persistentState() const;
  bool takePersistentDirty();

 private:
  void enterWet(uint32_t nowMs);
  void startAlarm(uint32_t nowMs);
  static bool elapsed(uint32_t nowMs, uint32_t sinceMs, uint32_t intervalMs);
  LeakConfig config_;
  SensorState sensorState_;
  SensorState candidateState_;
  uint32_t candidateSinceMs_;
  bool candidateValid_;
  bool leakLatched_;
  ValveState requestedValve_;
  ValveState valveState_;
  bool otaActive_;
  uint32_t alarmStartedMs_;
  bool alarmActive_;
  bool alarmSilenced_;
  bool alarmTimedOut_;
  bool persistenceDirty_;
};

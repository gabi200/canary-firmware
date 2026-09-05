#include "LeakController.h"

LeakController::LeakController(const LeakConfig& config)
    : config_(config),
      sensorState_(SensorState::Uninitialized),
      candidateState_(SensorState::Uninitialized),
      candidateSinceMs_(0),
      candidateValid_(false),
      leakLatched_(false),
      requestedValve_(ValveState::Closed),
      valveState_(ValveState::Closed),
      otaActive_(false),
      alarmStartedMs_(0),
      alarmActive_(false),
      alarmSilenced_(false),
      alarmTimedOut_(false),
      persistenceDirty_(false) {}

void LeakController::restore(const PersistentState& state, uint32_t nowMs) {
  sensorState_ = SensorState::Uninitialized;
  candidateState_ = SensorState::Uninitialized;
  candidateSinceMs_ = nowMs;
  candidateValid_ = false;
  leakLatched_ = state.leakLatched;
  requestedValve_ = state.requestedValve;
  valveState_ = ValveState::Closed;
  alarmActive_ = false;
  alarmSilenced_ = false;
  alarmTimedOut_ = false;
  if (leakLatched_) {
    startAlarm(nowMs);
  }
  persistenceDirty_ = false;
}

bool LeakController::updateSensor(uint16_t adcValue, uint32_t nowMs) {
  SensorState observed = SensorState::Uninitialized;
  if (adcValue >= config_.wetThreshold) {
    observed = SensorState::Wet;
  } else if (adcValue <= config_.dryThreshold) {
    observed = SensorState::Dry;
  } else if (candidateValid_) {
    observed = candidateState_;
  } else {
    observed = sensorState_;
  }

  if (observed == SensorState::Uninitialized) {
    return false;
  }

  if (!candidateValid_ || candidateState_ != observed) {
    candidateState_ = observed;
    candidateSinceMs_ = nowMs;
    candidateValid_ = true;
    return false;
  }

  if (sensorState_ == candidateState_ ||
      !elapsed(nowMs, candidateSinceMs_, config_.debounceMs)) {
    return false;
  }

  sensorState_ = candidateState_;
  if (sensorState_ == SensorState::Wet) {
    enterWet(nowMs);
  } else if (!leakLatched_ && requestedValve_ == ValveState::Open) {
    valveState_ = ValveState::Open;
  }
  return true;
}

CommandResult LeakController::requestValve(ValveState requested, uint32_t nowMs) {
  (void)nowMs;
  if (requested == ValveState::Closed) {
    persistenceDirty_ = persistenceDirty_ || requestedValve_ != ValveState::Closed;
    requestedValve_ = ValveState::Closed;
    valveState_ = ValveState::Closed;
    return CommandResult::Accepted;
  }
  if (otaActive_) {
    return CommandResult::RejectedOta;
  }
  if (sensorState_ == SensorState::Uninitialized) {
    return CommandResult::RejectedUninitialized;
  }
  if (sensorState_ == SensorState::Wet) {
    return CommandResult::RejectedWet;
  }
  persistenceDirty_ = persistenceDirty_ || leakLatched_ || requestedValve_ != ValveState::Open;
  leakLatched_ = false;
  requestedValve_ = ValveState::Open;
  valveState_ = ValveState::Open;
  return CommandResult::Accepted;
}

bool LeakController::silenceAlarm() {
  if (!alarmActive_ || alarmTimedOut_) {
    return false;
  }
  alarmSilenced_ = true;
  return true;
}

void LeakController::setOtaActive(bool active) {
  otaActive_ = active;
}

bool LeakController::tick(uint32_t nowMs) {
  if (alarmActive_ && !alarmTimedOut_ &&
      elapsed(nowMs, alarmStartedMs_, config_.alarmDurationMs)) {
    alarmTimedOut_ = true;
    return true;
  }
  return false;
}

SensorState LeakController::sensorState() const {
  return sensorState_;
}

ValveState LeakController::valveState() const {
  return valveState_;
}

bool LeakController::leakLatched() const {
  return leakLatched_;
}

bool LeakController::otaActive() const {
  return otaActive_;
}

AlarmState LeakController::alarmState(uint32_t nowMs) const {
  if (!alarmActive_) {
    return AlarmState::Inactive;
  }
  if (alarmTimedOut_ || elapsed(nowMs, alarmStartedMs_, config_.alarmDurationMs)) {
    return AlarmState::TimedOut;
  }
  if (alarmSilenced_) {
    return AlarmState::Silenced;
  }
  return AlarmState::Sounding;
}

bool LeakController::buzzerOutput(uint32_t nowMs) const {
  if (alarmState(nowMs) != AlarmState::Sounding) {
    return false;
  }
  const uint32_t period = config_.beepOnMs + config_.beepOffMs;
  if (period == 0) {
    return false;
  }
  return static_cast<uint32_t>(nowMs - alarmStartedMs_) % period < config_.beepOnMs;
}

uint32_t LeakController::alarmRemainingMs(uint32_t nowMs) const {
  if (!alarmActive_ || alarmTimedOut_ ||
      elapsed(nowMs, alarmStartedMs_, config_.alarmDurationMs)) {
    return 0;
  }
  return config_.alarmDurationMs - static_cast<uint32_t>(nowMs - alarmStartedMs_);
}

PersistentState LeakController::persistentState() const {
  return PersistentState{leakLatched_, requestedValve_};
}

bool LeakController::takePersistentDirty() {
  const bool dirty = persistenceDirty_;
  persistenceDirty_ = false;
  return dirty;
}

void LeakController::enterWet(uint32_t nowMs) {
  const bool persistenceChanged = !leakLatched_ || requestedValve_ != ValveState::Closed;
  leakLatched_ = true;
  requestedValve_ = ValveState::Closed;
  valveState_ = ValveState::Closed;
  persistenceDirty_ = persistenceDirty_ || persistenceChanged;
  startAlarm(nowMs);
}

void LeakController::startAlarm(uint32_t nowMs) {
  alarmStartedMs_ = nowMs;
  alarmActive_ = true;
  alarmSilenced_ = false;
  alarmTimedOut_ = false;
}

bool LeakController::elapsed(uint32_t nowMs, uint32_t sinceMs, uint32_t intervalMs) {
  return static_cast<uint32_t>(nowMs - sinceMs) >= intervalMs;
}

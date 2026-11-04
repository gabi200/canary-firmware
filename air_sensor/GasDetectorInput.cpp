#include "GasDetectorInput.h"

GasDetectorInput::GasDetectorInput(uint32_t debounceMs)
    : debounceMs_(debounceMs) {}

void GasDetectorInput::begin(bool contactOpen, uint32_t nowMs, bool enabled) {
  contactOpen = contactOpen && enabled;
  alarmActive_ = contactOpen;
  candidateOpen_ = contactOpen;
  candidateSinceMs_ = nowMs;
}

GasDetectorEvent GasDetectorInput::update(bool contactOpen, uint32_t nowMs, bool enabled) {
  if (!enabled) {
    const bool wasActive = alarmActive_;
    begin(false, nowMs, false);
    return wasActive ? GasDetectorEvent::AlarmCleared : GasDetectorEvent::None;
  }
  if (contactOpen != candidateOpen_) {
    candidateOpen_ = contactOpen;
    candidateSinceMs_ = nowMs;
    return GasDetectorEvent::None;
  }
  if (candidateOpen_ == alarmActive_ ||
      static_cast<uint32_t>(nowMs - candidateSinceMs_) < debounceMs_) {
    return GasDetectorEvent::None;
  }
  alarmActive_ = candidateOpen_;
  return alarmActive_ ? GasDetectorEvent::AlarmRaised
                      : GasDetectorEvent::AlarmCleared;
}

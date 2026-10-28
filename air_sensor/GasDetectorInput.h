#pragma once

#include <stdint.h>

// Dry relay contact from a separate, mains-powered household gas detector.
// The NC contact is wired between the input and GND, so a closed contact reads
// LOW. An open contact (the detector alarming, or a cut or unplugged wire)
// reads HIGH through the pull-up, and both are reported as an alarm.
//
// Monitoring only: nothing here drives the detector or its gas valve.
// No Arduino types so the native tests can use it.

enum class GasDetectorEvent : uint8_t {
  None,
  AlarmRaised,
  AlarmCleared,
};

class GasDetectorInput {
 public:
  explicit GasDetectorInput(uint32_t debounceMs);

  // Takes the boot reading as-is: the contact may already be open, and a
  // detector that is alarming must not wait out a debounce to be reported.
  void begin(bool contactOpen, uint32_t nowMs);

  // A new level is accepted only after it has held for the debounce time.
  GasDetectorEvent update(bool contactOpen, uint32_t nowMs);

  bool alarmActive() const { return alarmActive_; }

 private:
  uint32_t debounceMs_;
  bool alarmActive_ = false;
  bool candidateOpen_ = false;
  uint32_t candidateSinceMs_ = 0;
};

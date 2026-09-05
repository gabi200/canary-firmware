#pragma once

#include "LeakController.h"

#include <stdint.h>

class PersistenceRetry {
 public:
  static constexpr uint32_t RETRY_INTERVAL_MS = 1000;

  PersistenceRetry()
      : state_{false, ValveState::Open},
        pending_(false),
        immediate_(false),
        lastAttemptMs_(0) {}

  void update(const PersistentState& state) {
    state_ = state;
    pending_ = true;
    immediate_ = true;
  }

  bool due(uint32_t nowMs) const {
    return pending_ &&
           (immediate_ ||
            static_cast<uint32_t>(nowMs - lastAttemptMs_) >= RETRY_INTERVAL_MS);
  }

  const PersistentState& state() const {
    return state_;
  }

  void recordResult(bool success, uint32_t nowMs) {
    if (success) {
      pending_ = false;
      immediate_ = false;
      return;
    }
    immediate_ = false;
    lastAttemptMs_ = nowMs;
  }

 private:
  PersistentState state_;
  bool pending_;
  bool immediate_;
  uint32_t lastAttemptMs_;
};

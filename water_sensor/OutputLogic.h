#pragma once

constexpr bool activeLevelFor(bool active, bool activeHigh) {
  return active == activeHigh;
}

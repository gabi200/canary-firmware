#pragma once

#include <stdint.h>

// Decides whether this boot follows a power cut short enough that the sensors
// are still near their operating temperature. Both times are wall-clock epoch
// seconds: `bootEpoch` is the synced clock minus uptime, `lastAliveEpoch` the
// last stamp the previous run wrote while its clock was set (0 = none). A clock
// that went backwards, or no stamp at all, means a full warm-up.
inline bool quickRestart(uint32_t lastAliveEpoch, uint32_t bootEpoch,
                         uint32_t maxOffSeconds) {
  return lastAliveEpoch != 0 && bootEpoch >= lastAliveEpoch &&
         bootEpoch - lastAliveEpoch < maxOffSeconds;
}

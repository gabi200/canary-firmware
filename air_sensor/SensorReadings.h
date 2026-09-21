#pragma once

#include <stdint.h>

// Plain values handed from the sensor readers to the controller and to the
// status serializer. No Arduino types so the native tests can use them.

struct CoReading {
  uint16_t ppm;
  uint8_t gasId;    // 0x04 on current ZE03 firmware, 0x00 on pre-V2.8 units
  uint8_t decimals; // resolution exponent; 0x00 (1 ppm) for the CO variant
};

struct ParticulateReading {
  uint16_t pm1_0;   // ug/m3, atmospheric environment
  uint16_t pm2_5;
  uint16_t pm10;
  uint16_t count0_3;  // particles > 0.3um per 0.1L
  uint16_t count0_5;
  uint16_t count1_0;
  uint16_t count2_5;
};

struct ClimateReading {
  int16_t temperatureTenthsC;
  uint16_t humidityTenthsPercent;
};

struct PresenceReading {
  bool detected;
  bool moving;
  bool stationary;
  uint16_t movingDistanceCm;
  uint8_t movingEnergy;
  uint16_t stationaryDistanceCm;
  uint8_t stationaryEnergy;
  uint16_t detectionDistanceCm;
};

// A reading plus how stale it is. Readers own the freshness clock; everything
// downstream only asks "is this still usable".
template <typename Reading>
struct Sampled {
  Reading value;
  bool valid;
  uint32_t ageMs;
};

using SampledClimate = Sampled<ClimateReading>;
using SampledPresence = Sampled<PresenceReading>;

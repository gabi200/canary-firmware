#pragma once

#include "SensorReadings.h"

#include <stddef.h>
#include <stdint.h>

// Byte-stream parser for the Plantower PMS5003T. The T variant reuses the
// standard 32-byte frame but replaces the >5.0um and >10um particle-count
// fields with temperature and humidity, so the layout below is specific to it.
//
// The model cannot be detected from the wire: a plain PMS5003 sends the same
// 32-byte frame with the same length field, and feeding one to this parser
// produces a plausible-looking temperature from its >5.0um particle count.
// The model is a wiring fact, not a runtime discovery.
//
// Pure logic: feed it one UART byte at a time. No Arduino types.
class Pms5003Reader {
 public:
  static constexpr size_t FRAME_BYTES = 32;
  static constexpr uint8_t START_BYTE_1 = 0x42;
  static constexpr uint8_t START_BYTE_2 = 0x4D;
  static constexpr uint16_t FRAME_LENGTH_FIELD = 28;

  Pms5003Reader();

  // Returns true exactly once per accepted frame.
  bool consume(uint8_t byte);
  const ParticulateReading& particulate() const;
  const ClimateReading& climate() const;
  uint32_t rejectedFrames() const;

 private:
  void resync();

  uint8_t buffer_[FRAME_BYTES];
  size_t length_;
  ParticulateReading particulate_;
  ClimateReading climate_;
  uint32_t rejectedFrames_;
};

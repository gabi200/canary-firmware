#include "Pms5003Reader.h"

#include <string.h>

namespace {

uint16_t bigEndian16(const uint8_t* bytes) {
  return static_cast<uint16_t>((static_cast<uint16_t>(bytes[0]) << 8) | bytes[1]);
}

}  // namespace

Pms5003Reader::Pms5003Reader()
    : buffer_{},
      length_(0),
      particulate_{0, 0, 0, 0, 0, 0, 0},
      climate_{0, 0},
      rejectedFrames_(0) {}

bool Pms5003Reader::consume(uint8_t byte) {
  if (length_ == 0 && byte != START_BYTE_1) {
    return false;
  }
  if (length_ == 1 && byte != START_BYTE_2) {
    // A repeated 0x42 can still be the real start of the next frame.
    length_ = byte == START_BYTE_1 ? 1 : 0;
    buffer_[0] = START_BYTE_1;
    return false;
  }
  buffer_[length_++] = byte;
  // Reject a foreign length as soon as it is known. A command acknowledgement
  // is an 8-byte frame with length 0x0004; waiting for 32 bytes would swallow
  // most of the following data frame.
  if (length_ == 4 && bigEndian16(&buffer_[2]) != FRAME_LENGTH_FIELD) {
    ++rejectedFrames_;
    resync();
    return false;
  }
  if (length_ < FRAME_BYTES) {
    return false;
  }

  uint16_t sum = 0;
  for (size_t index = 0; index + 2 < FRAME_BYTES; ++index) {
    sum = static_cast<uint16_t>(sum + buffer_[index]);
  }
  if (sum != bigEndian16(&buffer_[FRAME_BYTES - 2])) {
    ++rejectedFrames_;
    resync();
    return false;
  }

  // A mass concentration with no counted particles is physically impossible,
  // and the module's own range is -20..99 C and 0..99 %RH, so either means the
  // frame is corrupt however well it checksums.
  const int16_t temperature = static_cast<int16_t>(bigEndian16(&buffer_[24]));
  const uint16_t humidity = bigEndian16(&buffer_[26]);
  if ((bigEndian16(&buffer_[16]) == 0 && bigEndian16(&buffer_[14]) > 0) ||
      temperature < -300 || temperature > 1000 || humidity > 1000) {
    ++rejectedFrames_;
    resync();
    return false;
  }

  // Atmospheric-environment values are the ones intended for indoor air
  // reporting; the CF=1 block at bytes 4..9 is the factory calibration set.
  particulate_.pm1_0 = bigEndian16(&buffer_[10]);
  particulate_.pm2_5 = bigEndian16(&buffer_[12]);
  particulate_.pm10 = bigEndian16(&buffer_[14]);
  particulate_.count0_3 = bigEndian16(&buffer_[16]);
  particulate_.count0_5 = bigEndian16(&buffer_[18]);
  particulate_.count1_0 = bigEndian16(&buffer_[20]);
  particulate_.count2_5 = bigEndian16(&buffer_[22]);
  // Plantower documents the temperature word as signed; reading it unsigned
  // turns -5.5 C into about 6553 C.
  climate_.temperatureTenthsC = temperature;
  climate_.humidityTenthsPercent = humidity;
  length_ = 0;
  return true;
}

const ParticulateReading& Pms5003Reader::particulate() const {
  return particulate_;
}

const ClimateReading& Pms5003Reader::climate() const {
  return climate_;
}

uint32_t Pms5003Reader::rejectedFrames() const {
  return rejectedFrames_;
}

// A rejected frame may contain the real start of the next one, so keep any
// later 0x42 0x4D pair instead of discarding the whole buffer.
void Pms5003Reader::resync() {
  for (size_t index = 1; index + 1 < length_; ++index) {
    if (buffer_[index] != START_BYTE_1 || buffer_[index + 1] != START_BYTE_2) {
      continue;
    }
    const size_t remaining = length_ - index;
    memmove(buffer_, buffer_ + index, remaining);
    length_ = remaining;
    return;
  }
  length_ = buffer_[length_ - 1] == START_BYTE_1 ? 1 : 0;
  buffer_[0] = START_BYTE_1;
}

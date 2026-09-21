#include "Ze03Reader.h"

#include <string.h>

namespace {

uint16_t scaleDown(uint16_t value, uint8_t decimals) {
  switch (decimals) {
    case 1:
      return static_cast<uint16_t>(value / 10);
    case 2:
      return static_cast<uint16_t>(value / 100);
    case 3:
      return static_cast<uint16_t>(value / 1000);
    default:
      return value;
  }
}

constexpr uint8_t ACTIVE_UPLOAD_REQUEST[] = {0xFF, 0x01, 0x78, 0x03,
                                             0x00, 0x00, 0x00, 0x00, 0x84};
constexpr uint8_t READ_REQUEST[] = {0xFF, 0x01, 0x86, 0x00,
                                    0x00, 0x00, 0x00, 0x00, 0x79};

}  // namespace

Ze03Reader::Ze03Reader()
    : buffer_{}, length_(0), reading_{0, 0, 0}, rejectedFrames_(0) {}

bool Ze03Reader::consume(uint8_t byte) {
  if (length_ == 0 && byte != START_BYTE) {
    return false;
  }
  buffer_[length_++] = byte;
  if (length_ == 2 && buffer_[1] != COMMAND_BYTE) {
    ++rejectedFrames_;
    resync();
    return false;
  }
  if (length_ < FRAME_BYTES) {
    return false;
  }

  const uint8_t gasId = buffer_[4];
  if (buffer_[FRAME_BYTES - 1] != checksum(buffer_, FRAME_BYTES) ||
      (gasId != GAS_ID_CO && gasId != GAS_ID_LEGACY)) {
    ++rejectedFrames_;
    resync();
    return false;
  }

  const uint8_t decimals = buffer_[5];
  const uint16_t raw = static_cast<uint16_t>(
      (static_cast<uint16_t>(buffer_[2]) << 8) | buffer_[3]);
  reading_ = CoReading{scaleDown(raw, decimals), gasId, decimals};
  length_ = 0;
  return true;
}

const CoReading& Ze03Reader::reading() const {
  return reading_;
}

uint32_t Ze03Reader::rejectedFrames() const {
  return rejectedFrames_;
}

const uint8_t* Ze03Reader::activeUploadRequest(size_t& length) {
  length = sizeof(ACTIVE_UPLOAD_REQUEST);
  return ACTIVE_UPLOAD_REQUEST;
}

const uint8_t* Ze03Reader::readRequest(size_t& length) {
  length = sizeof(READ_REQUEST);
  return READ_REQUEST;
}

// Winsen's checksum is the two's complement of bytes 1..n-2; the start marker
// and the checksum byte itself are excluded.
uint8_t Ze03Reader::checksum(const uint8_t* frame, size_t length) {
  if (frame == nullptr || length < 3) {
    return 0;
  }
  uint8_t sum = 0;
  for (size_t index = 1; index + 1 < length; ++index) {
    sum = static_cast<uint8_t>(sum + frame[index]);
  }
  return static_cast<uint8_t>(static_cast<uint8_t>(~sum) + 1);
}

// A rejected frame may still contain the real start of the next one, so keep
// any later start byte instead of discarding the whole buffer.
void Ze03Reader::resync() {
  for (size_t index = 1; index < length_; ++index) {
    if (buffer_[index] != START_BYTE) {
      continue;
    }
    const size_t remaining = length_ - index;
    memmove(buffer_, buffer_ + index, remaining);
    length_ = remaining;
    return;
  }
  length_ = 0;
}

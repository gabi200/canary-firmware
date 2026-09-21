#include "Ld2410Reader.h"

namespace {

constexpr uint8_t REPORT_HEADER[] = {0xF4, 0xF3, 0xF2, 0xF1};
constexpr uint8_t REPORT_TAIL[] = {0xF8, 0xF7, 0xF6, 0xF5};

uint16_t littleEndian16(const uint8_t* bytes) {
  return static_cast<uint16_t>(bytes[0] | (static_cast<uint16_t>(bytes[1]) << 8));
}

}  // namespace

Ld2410Reader::Ld2410Reader()
    : state_(State::Header),
      headerMatched_(0),
      lengthBytes_(0),
      tailMatched_(0),
      declaredLength_(0),
      payloadLength_(0),
      payload_{},
      reading_{false, false, false, 0, 0, 0, 0, 0},
      rejectedFrames_(0) {}

bool Ld2410Reader::consume(uint8_t byte) {
  switch (state_) {
    case State::Header:
      if (byte == REPORT_HEADER[headerMatched_]) {
        if (++headerMatched_ == sizeof(REPORT_HEADER)) {
          state_ = State::Length;
          lengthBytes_ = 0;
          declaredLength_ = 0;
        }
        return false;
      }
      // Restarting on the first header byte keeps a repeated 0xF4 usable.
      headerMatched_ = byte == REPORT_HEADER[0] ? 1 : 0;
      return false;

    case State::Length:
      declaredLength_ = static_cast<uint16_t>(
          declaredLength_ | (static_cast<uint16_t>(byte) << (8 * lengthBytes_)));
      if (++lengthBytes_ < 2) {
        return false;
      }
      if (declaredLength_ < BASIC_PAYLOAD_BYTES ||
          declaredLength_ > MAX_PAYLOAD_BYTES) {
        ++rejectedFrames_;
        reset();
        headerMatched_ = byte == REPORT_HEADER[0] ? 1 : 0;
        return false;
      }
      state_ = State::Payload;
      payloadLength_ = 0;
      return false;

    case State::Payload:
      payload_[payloadLength_++] = byte;
      if (payloadLength_ < declaredLength_) {
        return false;
      }
      state_ = State::Tail;
      tailMatched_ = 0;
      return false;

    case State::Tail:
    default:
      if (byte != REPORT_TAIL[tailMatched_]) {
        // Target data can contain bytes that look like framing: a stationary
        // distance of 244 cm encodes as F4 00. Keep a candidate header byte
        // instead of dropping it with the rest of the bad frame.
        ++rejectedFrames_;
        reset();
        headerMatched_ = byte == REPORT_HEADER[0] ? 1 : 0;
        return false;
      }
      if (++tailMatched_ < sizeof(REPORT_TAIL)) {
        return false;
      }
      {
      const uint16_t length = payloadLength_;
      reset();
      if (!acceptPayload(length)) {
        ++rejectedFrames_;
        return false;
      }
      return true;
      }
  }
}

const PresenceReading& Ld2410Reader::reading() const {
  return reading_;
}

uint32_t Ld2410Reader::rejectedFrames() const {
  return rejectedFrames_;
}

void Ld2410Reader::reset() {
  state_ = State::Header;
  headerMatched_ = 0;
  lengthBytes_ = 0;
  tailMatched_ = 0;
  declaredLength_ = 0;
  payloadLength_ = 0;
}

// Basic and engineering payloads share the same first 13 bytes, so the extra
// per-gate energies an engineering frame carries are simply ignored.
bool Ld2410Reader::acceptPayload(uint16_t length) {
  const bool basic = payload_[0] == DATA_TYPE_BASIC;
  if (!basic && payload_[0] != DATA_TYPE_ENGINEERING) {
    return false;
  }
  if (basic && length != BASIC_PAYLOAD_BYTES) {
    return false;
  }
  if (payload_[1] != PAYLOAD_HEAD || length < BASIC_PAYLOAD_BYTES ||
      payload_[length - 2] != PAYLOAD_TAIL || payload_[length - 1] != 0x00) {
    return false;
  }
  const uint8_t targetState = payload_[2];
  if (targetState > MAX_TARGET_STATE) {
    return false;
  }

  // 0x00-0x03 is a bitmask of moving and stationary targets. 0x04-0x06 are
  // background-calibration states, not a mask: treating 0x05 as "bit 0 set"
  // would report a person who is not there.
  const bool targetPresent = targetState <= 0x03;
  PresenceReading parsed{};
  parsed.moving = targetPresent && (targetState & 0x01) != 0;
  parsed.stationary = targetPresent && (targetState & 0x02) != 0;
  parsed.detected = parsed.moving || parsed.stationary;
  parsed.movingDistanceCm = littleEndian16(&payload_[3]);
  parsed.movingEnergy = payload_[5];
  parsed.stationaryDistanceCm = littleEndian16(&payload_[6]);
  parsed.stationaryEnergy = payload_[8];
  parsed.detectionDistanceCm = littleEndian16(&payload_[9]);
  reading_ = parsed;
  return true;
}

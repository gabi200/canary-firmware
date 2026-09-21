#pragma once

#include "SensorReadings.h"

#include <stddef.h>
#include <stdint.h>

// Byte-stream parser for HLK-LD2410 cyclic target-report frames. LD2410,
// LD2410B and LD2410C share this framing exactly. The LD2410S and LD2410D are
// different parts: the S defaults to a 6E...62 minimal format and the D emits
// ASCII lines, both at 115200, so neither ever syncs here and the symptom is
// silence rather than corrupt data. Only the
// report stream is consumed; this firmware never reconfigures the radar, so
// the command/ACK frame family (header FD FC FB FA) is deliberately ignored.
//
// Report frames carry no checksum, so the header, declared length, intra-frame
// markers and tail are all validated before a frame is accepted.
//
// Pure logic: feed it one UART byte at a time. No Arduino types.
class Ld2410Reader {
 public:
  static constexpr size_t MAX_PAYLOAD_BYTES = 64;
  static constexpr size_t BASIC_PAYLOAD_BYTES = 13;
  static constexpr uint8_t DATA_TYPE_ENGINEERING = 0x01;
  static constexpr uint8_t DATA_TYPE_BASIC = 0x02;
  static constexpr uint8_t PAYLOAD_HEAD = 0xAA;
  static constexpr uint8_t PAYLOAD_TAIL = 0x55;
  // 0x00-0x03 are the target states; 0x04-0x06 report background-noise
  // calibration on LD2410B/C and are valid frames, not corruption.
  static constexpr uint8_t MAX_TARGET_STATE = 0x06;

  Ld2410Reader();

  // Returns true exactly once per accepted frame.
  bool consume(uint8_t byte);
  const PresenceReading& reading() const;
  uint32_t rejectedFrames() const;

 private:
  enum class State : uint8_t { Header, Length, Payload, Tail };

  void reset();
  bool acceptPayload(uint16_t length);

  State state_;
  uint8_t headerMatched_;
  uint8_t lengthBytes_;
  uint8_t tailMatched_;
  uint16_t declaredLength_;
  uint16_t payloadLength_;
  uint8_t payload_[MAX_PAYLOAD_BYTES];
  PresenceReading reading_;
  uint32_t rejectedFrames_;
};

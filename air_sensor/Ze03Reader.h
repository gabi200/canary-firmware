#pragma once

#include "SensorReadings.h"

#include <stddef.h>
#include <stdint.h>

// Byte-stream parser for the Winsen ZE03-CO module.
//
// ZE03 uses a command-style 9-byte frame whose second byte is the constant
// 0x86. That is NOT the ZE07/ZE08 layout, which puts a gas-name byte at index 1
// and a full-range value at bytes 6-7; both families are 9 bytes, start with
// 0xFF and share a checksum, so a parser that keys only on length and checksum
// will silently mis-decode the wrong one. Keying on byte[1] == 0x86 separates
// them. The active-upload frame and the Q&A reply are byte-for-byte identical,
// so one routine serves both modes.
//
// Pure logic: feed it one UART byte at a time. No Arduino types, so the native
// tests drive it.
class Ze03Reader {
 public:
  static constexpr size_t FRAME_BYTES = 9;
  static constexpr uint8_t START_BYTE = 0xFF;
  static constexpr uint8_t COMMAND_BYTE = 0x86;
  static constexpr uint8_t GAS_ID_CO = 0x04;
  // Pre-V2.8 firmware leaves the gas-identity byte at zero.
  static constexpr uint8_t GAS_ID_LEGACY = 0x00;

  Ze03Reader();

  // Returns true exactly once per accepted frame.
  bool consume(uint8_t byte);
  const CoReading& reading() const;
  uint32_t rejectedFrames() const;

  // Restores active upload on a module that was left in Q&A mode. ZE03 selects
  // the mode with byte[3]; the 0x40/0x41 values used by ZE07 and ZE08 do not
  // work here.
  static const uint8_t* activeUploadRequest(size_t& length);
  // Q&A read, for a module that ignores the command above.
  static const uint8_t* readRequest(size_t& length);
  static uint8_t checksum(const uint8_t* frame, size_t length);

 private:
  void resync();

  uint8_t buffer_[FRAME_BYTES];
  size_t length_;
  CoReading reading_;
  uint32_t rejectedFrames_;
};

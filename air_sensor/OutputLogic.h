#pragma once

#include <stdint.h>

constexpr bool activeLevelFor(bool active, bool activeHigh) {
  return active == activeHigh;
}

// Visual alarm vocabulary. One colour per hazard class so an installer can
// identify the cause across a room without reading the API.
enum class LedColor : uint8_t {
  Off,
  Green,    // every channel nominal
  Blue,     // a channel is still warming up
  Cyan,     // a channel is faulted or stale
  Magenta,  // particulate hazard
  Orange,   // combustible-gas hazard
  Red,      // carbon-monoxide hazard
  White,    // self-test only
};

struct LedRgb {
  uint8_t red;
  uint8_t green;
  uint8_t blue;
};

constexpr LedRgb ledRgbFor(LedColor color) {
  return color == LedColor::Green     ? LedRgb{0, 255, 0}
         : color == LedColor::Blue    ? LedRgb{0, 0, 255}
         : color == LedColor::Cyan    ? LedRgb{0, 255, 255}
         : color == LedColor::Magenta ? LedRgb{180, 0, 255}
         : color == LedColor::Orange  ? LedRgb{255, 70, 0}
         : color == LedColor::Red     ? LedRgb{255, 0, 0}
         : color == LedColor::White   ? LedRgb{255, 255, 255}
                                      : LedRgb{0, 0, 0};
}

constexpr const char* ledColorName(LedColor color) {
  return color == LedColor::Green     ? "green"
         : color == LedColor::Blue    ? "blue"
         : color == LedColor::Cyan    ? "cyan"
         : color == LedColor::Magenta ? "magenta"
         : color == LedColor::Orange  ? "orange"
         : color == LedColor::Red     ? "red"
         : color == LedColor::White   ? "white"
                                      : "off";
}

// Scales a colour channel for brightness and maps it onto the wiring polarity.
// Common-anode LEDs sink current, so the duty cycle is inverted.
constexpr uint8_t ledDutyFor(uint8_t channel, uint8_t brightness, bool commonAnode) {
  const uint8_t scaled =
      static_cast<uint8_t>((static_cast<uint16_t>(channel) * brightness) / 255);
  return commonAnode ? static_cast<uint8_t>(255 - scaled) : scaled;
}

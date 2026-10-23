#include "DisplayModel.h"

#include <cstdio>
#include <cstring>

namespace {

const char* stateLabel(ChannelState state) {
  switch (state) {
    case ChannelState::Warmup:
      return "warm";
    case ChannelState::Fault:
      return "FAULT";
    case ChannelState::Warning:
      return "WARN";
    case ChannelState::Danger:
      return "DANGER";
    case ChannelState::Ok:
      break;
  }
  return "ok";
}

const char* hazardLabel(Hazard hazard) {
  switch (hazard) {
    case Hazard::CarbonMonoxide:
      return "Carbon monoxide";
    case Hazard::Gas:
      return "Combustible gas";
    case Hazard::Particulate:
      return "Smoke or dust (PM)";
    case Hazard::None:
      break;
  }
  return "";
}

// `left` from column 0 and `right` ending at the last column of a `columns`
// wide row; `left` is cut short when both do not fit.
void row(char* out, size_t columns, const char* left, const char* right) {
  const size_t rightLength = std::strlen(right);
  const size_t room = rightLength == 0        ? columns
                      : rightLength >= columns ? 0
                                               : columns - rightLength - 1;
  size_t leftLength = std::strlen(left);
  if (leftLength > room) {
    leftLength = room;
  }
  std::memset(out, ' ', columns);
  std::memcpy(out, left, leftLength);
  if (rightLength > 0) {
    const size_t shown = rightLength > columns ? columns : rightLength;
    std::memcpy(out + columns - shown, right, shown);
    out[columns] = '\0';
  } else {
    out[leftLength] = '\0';
  }
}

constexpr size_t SCRATCH = 48;  // wider than any row: row() makes the cut

void minutesSeconds(char* out, size_t size, uint32_t ms) {
  const uint32_t seconds = (ms + 999U) / 1000U;
  std::snprintf(out, size, "%lu:%02lu", static_cast<unsigned long>(seconds / 60U),
                static_cast<unsigned long>(seconds % 60U));
}

void dottedIp(char* out, size_t size, uint32_t ip) {
  std::snprintf(out, size, "%u.%u.%u.%u", static_cast<unsigned>(ip & 0xFF),
                static_cast<unsigned>((ip >> 8) & 0xFF),
                static_cast<unsigned>((ip >> 16) & 0xFF),
                static_cast<unsigned>(ip >> 24));
}

void composeStatus(const DisplayInput& in, DisplayScreen& screen) {
  if (in.portalActive) {
    char text[SCRATCH];
    std::snprintf(text, sizeof(text), "Setup %s", in.portalName);
    row(screen.status, DISPLAY_SMALL_COLUMNS, text, "");
    return;
  }
  char wifi[SCRATCH];
  if (in.wifiConnected) {
    std::snprintf(wifi, sizeof(wifi), "WiFi %lddBm", static_cast<long>(in.wifiRssi));
  } else {
    std::snprintf(wifi, sizeof(wifi), "No WiFi");
  }
  const char* hub = in.otaInProgress   ? "Updating"
                    : !in.mqttEnabled  ? "Hub off"
                    : in.mqttConnected ? "Hub OK"
                                       : "Hub lost";
  row(screen.status, DISPLAY_SMALL_COLUMNS, wifi, hub);
}

// Formats into a scratch buffer, then fits the text into a `columns` wide row.
template <typename... Args>
void put(char* out, size_t columns, const char* format, Args... args) {
  char text[SCRATCH];
  std::snprintf(text, sizeof(text), format, args...);
  row(out, columns, text, "");
}

void composeAlert(const DisplayInput& in, uint32_t nowMs, DisplayScreen& screen) {
  screen.alert = true;
  if (in.selfTest) {
    put(screen.headline, DISPLAY_COLUMNS, "SELF-TEST");
    put(screen.lines[0], DISPLAY_COLUMNS, "Alarm test running");
    return;
  }

  const bool danger = in.alarmState != AlarmState::Warning;
  put(screen.headline, DISPLAY_COLUMNS, "%s",
                danger ? "DANGER" : "WARNING");
  put(screen.lines[0], DISPLAY_COLUMNS, "%s",
                hazardLabel(in.alarmHazard));
  switch (in.alarmHazard) {
    case Hazard::CarbonMonoxide:
      put(screen.lines[1], DISPLAY_COLUMNS, "CO %u ppm",
                    static_cast<unsigned>(in.coPpm));
      break;
    case Hazard::Gas:
      put(screen.lines[1], DISPLAY_COLUMNS, "Gas level %u",
                    static_cast<unsigned>(in.gasAdc));
      break;
    case Hazard::Particulate:
      put(screen.lines[1], DISPLAY_COLUMNS, "PM2.5 %u PM10 %u",
                    static_cast<unsigned>(in.pm25Ugm3),
                    static_cast<unsigned>(in.pm10Ugm3));
      break;
    case Hazard::None:
      break;
  }

  if (in.alarmState == AlarmState::Sounding) {
    put(screen.lines[2], DISPLAY_COLUMNS, "Alarm sounding");
    // blink for attention; the buzzer and LED carry the alarm itself
    screen.inverted = (nowMs / DISPLAY_ALERT_BLINK_MS) % 2U == 0;
  } else if (in.alarmState == AlarmState::Silenced) {
    char remaining[16];
    minutesSeconds(remaining, sizeof(remaining), in.silenceRemainingMs);
    put(screen.lines[2], DISPLAY_COLUMNS, "Silenced %s", remaining);
  } else {
    put(screen.lines[2], DISPLAY_COLUMNS, "Alarm if it rises");
  }
}

void composeReadings(const DisplayInput& in, DisplayScreen& screen) {
  char text[SCRATCH];
  const bool coShown = in.coState != ChannelState::Fault;
  if (coShown) {
    std::snprintf(text, sizeof(text), "CO    %u ppm", static_cast<unsigned>(in.coPpm));
  } else {
    std::snprintf(text, sizeof(text), "CO    --");
  }
  row(screen.lines[0], DISPLAY_COLUMNS, text, stateLabel(in.coState));

  std::snprintf(text, sizeof(text), "Gas   %u", static_cast<unsigned>(in.gasAdc));
  row(screen.lines[1], DISPLAY_COLUMNS, text, stateLabel(in.gasState));

  if (in.particulateState != ChannelState::Fault) {
    std::snprintf(text, sizeof(text), "PM2.5 %u PM10 %u",
                  static_cast<unsigned>(in.pm25Ugm3), static_cast<unsigned>(in.pm10Ugm3));
  } else {
    std::snprintf(text, sizeof(text), "PM    --");
  }
  row(screen.lines[2], DISPLAY_COLUMNS, text, stateLabel(in.particulateState));

  if (in.climateValid) {
    const int32_t tenths = in.temperatureTenthsC;
    const uint32_t magnitude = static_cast<uint32_t>(tenths < 0 ? -tenths : tenths);
    std::snprintf(text, sizeof(text), "%s%lu.%luC %u%%", tenths < 0 ? "-" : "",
                  static_cast<unsigned long>(magnitude / 10U),
                  static_cast<unsigned long>(magnitude % 10U),
                  static_cast<unsigned>((in.humidityTenthsPercent + 5U) / 10U));
  } else {
    std::snprintf(text, sizeof(text), "--.-C --%%");
  }
  char right[SCRATCH] = "";
  if (in.warmupRemainingMs > 0) {
    char remaining[16];
    minutesSeconds(remaining, sizeof(remaining), in.warmupRemainingMs);
    std::snprintf(right, sizeof(right), "warm %s", remaining);
  } else if (in.presenceValid) {
    std::snprintf(right, sizeof(right), "%s", in.presenceDetected ? "occupied" : "empty");
  }
  row(screen.lines[3], DISPLAY_COLUMNS, text, right);
}

void composeFooter(const DisplayInput& in, DisplayScreen& screen) {
  if (in.portalActive) {
    // WiFiManager's access point serves its portal on 192.168.4.1
    put(screen.footer, DISPLAY_SMALL_COLUMNS, "Join, open 192.168.4.1");
  } else if (in.wifiConnected && in.ipAddress != 0) {
    char ip[16];
    dottedIp(ip, sizeof(ip), in.ipAddress);
    row(screen.footer, DISPLAY_SMALL_COLUMNS, ip, "");
  } else {
    put(screen.footer, DISPLAY_SMALL_COLUMNS, "Connecting to Wi-Fi...");
  }
}

}  // namespace

DisplayScreen composeScreen(const DisplayInput& input, uint32_t nowMs) {
  DisplayScreen screen{};
  composeStatus(input, screen);
  if (input.selfTest || input.alarmState != AlarmState::Inactive) {
    composeAlert(input, nowMs, screen);
  } else {
    composeReadings(input, screen);
    composeFooter(input, screen);
  }
  return screen;
}

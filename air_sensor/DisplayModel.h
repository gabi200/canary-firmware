#pragma once

#include "AirController.h"

#include <stddef.h>
#include <stdint.h>

// What the SSD1306 shows, decided without any Arduino types so the native
// tests drive it directly. The safety loop fills a DisplayInput snapshot; the
// display task turns it into text with composeScreen() and draws it.

struct DisplayInput {
  // readings and the controller's grading of them
  ChannelState coState;
  ChannelState gasState;
  ChannelState particulateState;
  uint16_t coPpm;
  uint16_t gasAdc;
  uint16_t pm25Ugm3;
  uint16_t pm10Ugm3;
  bool climateValid;
  int16_t temperatureTenthsC;
  uint16_t humidityTenthsPercent;
  bool presenceValid;
  bool presenceDetected;

  // alarm
  AlarmState alarmState;
  Hazard alarmHazard;
  bool selfTest;
  uint32_t silenceRemainingMs;
  uint32_t warmupRemainingMs;

  // connectivity
  bool portalActive;
  bool wifiConnected;
  int32_t wifiRssi;
  bool mqttEnabled;
  bool mqttConnected;
  bool otaInProgress;
  uint32_t ipAddress;  // as IPAddress stores it (first octet in the low byte)
  char portalName[40];  // the setup access point while the portal is open
};

// Rows are sized for the widest font used: 5x7 status and footer rows fit 25
// characters on 128 pixels, 6x10 rows 21.
constexpr size_t DISPLAY_SMALL_COLUMNS = 25;
constexpr size_t DISPLAY_COLUMNS = 21;
constexpr size_t DISPLAY_LINES = 4;

struct DisplayScreen {
  char status[DISPLAY_SMALL_COLUMNS + 1];  // Wi-Fi and hub connection
  bool alert;      // alarm or self-test: headline layout
  bool inverted;   // draw the alert area white-on-black (blinks while sounding)
  char headline[DISPLAY_COLUMNS + 1];  // alert only, large font, e.g. "CO DANGER"
  char lines[DISPLAY_LINES][DISPLAY_COLUMNS + 1];
  char footer[DISPLAY_SMALL_COLUMNS + 1];  // normal layout only: address or setup hint
};

// Blink period of the inverted alert while the alarm sounds.
constexpr uint32_t DISPLAY_ALERT_BLINK_MS = 500;

DisplayScreen composeScreen(const DisplayInput& input, uint32_t nowMs);

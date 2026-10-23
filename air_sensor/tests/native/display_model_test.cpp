#include "DisplayModel.h"

#include <cstring>
#include <iostream>
#include <string>

static int failures = 0;
#define CHECK(expr) do { if (!(expr)) { std::cerr << __func__ << ":" << __LINE__ << " CHECK(" #expr ") failed\n"; ++failures; } } while (0)
#define CHECK_TEXT(actual, expected) do { if (std::string(actual) != (expected)) { std::cerr << __func__ << ":" << __LINE__ << " got \"" << (actual) << "\" expected \"" << (expected) << "\"\n"; ++failures; } } while (0)

namespace {

DisplayInput normal() {
  DisplayInput in{};
  in.coState = ChannelState::Ok;
  in.gasState = ChannelState::Ok;
  in.particulateState = ChannelState::Ok;
  in.coPpm = 3;
  in.gasAdc = 640;
  in.pm25Ugm3 = 7;
  in.pm10Ugm3 = 9;
  in.climateValid = true;
  in.temperatureTenthsC = 224;
  in.humidityTenthsPercent = 415;
  in.presenceValid = true;
  in.presenceDetected = true;
  in.alarmState = AlarmState::Inactive;
  in.alarmHazard = Hazard::None;
  in.wifiConnected = true;
  in.wifiRssi = -61;
  in.mqttEnabled = true;
  in.mqttConnected = true;
  in.ipAddress = 192U | (168U << 8) | (1U << 16) | (40U << 24);
  return in;
}

void testNormalLayoutShowsReadingsAndConnectivity() {
  const DisplayScreen s = composeScreen(normal(), 0);
  CHECK(!s.alert);
  CHECK(!s.inverted);
  CHECK_TEXT(s.status, "WiFi -61dBm        Hub OK");
  CHECK_TEXT(s.lines[0], "CO    3 ppm        ok");
  CHECK_TEXT(s.lines[1], "Gas   640          ok");
  CHECK_TEXT(s.lines[2], "PM2.5 7 PM10 9     ok");
  CHECK_TEXT(s.lines[3], "22.4C 42%    occupied");
  CHECK_TEXT(s.footer, "192.168.1.40");
  for (const char* line : s.lines) {
    CHECK(std::strlen(line) <= DISPLAY_COLUMNS);
  }
}

void testConnectivityStates() {
  DisplayInput in = normal();
  in.mqttConnected = false;
  CHECK_TEXT(composeScreen(in, 0).status, "WiFi -61dBm      Hub lost");
  in.mqttEnabled = false;
  CHECK_TEXT(composeScreen(in, 0).status, "WiFi -61dBm       Hub off");
  in = normal();
  in.wifiConnected = false;
  in.mqttConnected = false;
  const DisplayScreen offline = composeScreen(in, 0);
  CHECK_TEXT(offline.status, "No WiFi          Hub lost");
  CHECK_TEXT(offline.footer, "Connecting to Wi-Fi...");
  in = normal();
  in.otaInProgress = true;
  CHECK_TEXT(composeScreen(in, 0).status, "WiFi -61dBm      Updating");
  in = normal();
  in.portalActive = true;
  std::strcpy(in.portalName, "kitchen-air-setup");
  const DisplayScreen portal = composeScreen(in, 0);
  CHECK_TEXT(portal.status, "Setup kitchen-air-setup");
  CHECK_TEXT(portal.footer, "Join, open 192.168.4.1");
}

void testLongPortalNameIsCut() {
  DisplayInput in = normal();
  in.portalActive = true;
  std::strcpy(in.portalName, "a-very-long-device-name-for-room-setup");
  CHECK(std::strlen(composeScreen(in, 0).status) == DISPLAY_SMALL_COLUMNS);
}

void testFaultWarmupAndInvalidClimate() {
  DisplayInput in = normal();
  in.coState = ChannelState::Fault;
  in.particulateState = ChannelState::Fault;
  in.gasState = ChannelState::Warmup;
  in.climateValid = false;
  in.warmupRemainingMs = 125000;
  const DisplayScreen s = composeScreen(in, 0);
  CHECK_TEXT(s.lines[0], "CO    --        FAULT");
  CHECK_TEXT(s.lines[1], "Gas   640        warm");
  CHECK_TEXT(s.lines[2], "PM    --        FAULT");
  CHECK_TEXT(s.lines[3], "--.-C --%   warm 2:05");
}

void testNegativeTemperatureAndEmptyRoom() {
  DisplayInput in = normal();
  in.temperatureTenthsC = -35;
  in.presenceDetected = false;
  CHECK_TEXT(composeScreen(in, 0).lines[3], "-3.5C 42%       empty");
  in.presenceValid = false;
  CHECK_TEXT(composeScreen(in, 0).lines[3], "-3.5C 42%");
}

void testSoundingAlarmTakesOverAndBlinks() {
  DisplayInput in = normal();
  in.coState = ChannelState::Danger;
  in.coPpm = 160;
  in.alarmState = AlarmState::Sounding;
  in.alarmHazard = Hazard::CarbonMonoxide;
  const DisplayScreen on = composeScreen(in, 0);
  CHECK(on.alert);
  CHECK(on.inverted);
  CHECK_TEXT(on.headline, "DANGER");
  CHECK_TEXT(on.lines[0], "Carbon monoxide");
  CHECK_TEXT(on.lines[1], "CO 160 ppm");
  CHECK_TEXT(on.lines[2], "Alarm sounding");
  CHECK_TEXT(on.status, "WiFi -61dBm        Hub OK");  // connectivity stays visible
  CHECK(!composeScreen(in, DISPLAY_ALERT_BLINK_MS).inverted);
  CHECK(composeScreen(in, 2 * DISPLAY_ALERT_BLINK_MS).inverted);
}

void testSilencedAndWarningAlerts() {
  DisplayInput in = normal();
  in.alarmState = AlarmState::Silenced;
  in.alarmHazard = Hazard::Gas;
  in.gasAdc = 2600;
  in.silenceRemainingMs = 299001;
  DisplayScreen s = composeScreen(in, 0);
  CHECK(s.alert && !s.inverted);
  CHECK_TEXT(s.headline, "DANGER");
  CHECK_TEXT(s.lines[0], "Combustible gas");
  CHECK_TEXT(s.lines[1], "Gas level 2600");
  CHECK_TEXT(s.lines[2], "Silenced 5:00");

  in.alarmState = AlarmState::Warning;
  in.alarmHazard = Hazard::Particulate;
  in.pm25Ugm3 = 60;
  in.pm10Ugm3 = 80;
  s = composeScreen(in, 0);
  CHECK(s.alert && !s.inverted);
  CHECK_TEXT(s.headline, "WARNING");
  CHECK_TEXT(s.lines[0], "Smoke or dust (PM)");
  CHECK_TEXT(s.lines[1], "PM2.5 60 PM10 80");
  CHECK_TEXT(s.lines[2], "Alarm if it rises");
}

void testSelfTest() {
  DisplayInput in = normal();
  in.selfTest = true;
  const DisplayScreen s = composeScreen(in, 0);
  CHECK(s.alert && !s.inverted);
  CHECK_TEXT(s.headline, "SELF-TEST");
  CHECK_TEXT(s.lines[0], "Alarm test running");
}

}  // namespace

int main() {
  testNormalLayoutShowsReadingsAndConnectivity();
  testConnectivityStates();
  testLongPortalNameIsCut();
  testFaultWarmupAndInvalidClimate();
  testNegativeTemperatureAndEmptyRoom();
  testSoundingAlarmTakesOverAndBlinks();
  testSilencedAndWarningAlerts();
  testSelfTest();
  if (failures != 0) {
    std::cerr << failures << " display model check(s) failed\n";
    return 1;
  }
  std::cout << "Display model tests passed\n";
  return 0;
}

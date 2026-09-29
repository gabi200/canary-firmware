#pragma once

#include <cstdint>
#include <string>

constexpr int WL_CONNECTED = 3;

extern uint32_t fakeWifiConnectionTimeoutMs;

class WiFiClient {
 public:
  void setConnectionTimeout(uint32_t milliseconds);
};

class IPAddress {
 public:
  std::string toString() const { return "0.0.0.0"; }
};

class FakeWiFi {
 public:
  int status() const;
  int hostByName(const char*, IPAddress&) const { return 0; }
};

extern FakeWiFi WiFi;

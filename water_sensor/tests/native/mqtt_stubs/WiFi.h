#pragma once

#include <cstdint>

constexpr int WL_CONNECTED = 3;

extern uint32_t fakeWifiConnectionTimeoutMs;

class WiFiClient {
 public:
  void setConnectionTimeout(uint32_t milliseconds);
};

class FakeWiFi {
 public:
  int status() const;
};

extern FakeWiFi WiFi;

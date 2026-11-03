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
  IPAddress() = default;
  IPAddress(uint8_t a, uint8_t b, uint8_t c, uint8_t d) : octets_{a, b, c, d} {}
  bool operator==(const IPAddress& other) const {
    for (int i = 0; i < 4; ++i) {
      if (octets_[i] != other.octets_[i]) return false;
    }
    return true;
  }
  std::string toString() const {
    return std::to_string(octets_[0]) + "." + std::to_string(octets_[1]) + "." +
           std::to_string(octets_[2]) + "." + std::to_string(octets_[3]);
  }

 private:
  uint8_t octets_[4] = {0, 0, 0, 0};
};

class FakeWiFi {
 public:
  int status() const;
};

extern FakeWiFi WiFi;

#pragma once

#include "WiFi.h"

#include <cstdint>
#include <string>
#include <vector>

// Host queries answer from fakeMdnsHosts (label -> address); anything else is not found.
struct FakeMdnsHost {
  std::string label;
  IPAddress address;
};

extern std::vector<FakeMdnsHost> fakeMdnsHosts;
extern std::vector<std::string> fakeMdnsQueries;

class MDNSResponder {
 public:
  IPAddress queryHost(const char* host, uint32_t timeout = 2000);
};

extern MDNSResponder MDNS;

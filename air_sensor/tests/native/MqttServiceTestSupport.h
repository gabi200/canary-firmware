#pragma once

#include <cstdint>

extern bool fakeWifiConnected;
extern uint32_t fakeWifiConnectionTimeoutMs;
extern uint64_t fakeEfuseMac;
extern bool fakeStatusSerializationResult;
extern const char* fakeStatusJson;
void runFakeMqttTaskAt(uint32_t nowMs);

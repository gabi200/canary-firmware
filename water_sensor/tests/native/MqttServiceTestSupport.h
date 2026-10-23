#pragma once

#include <cstdint>
#include <string>
#include <vector>

class MeshLink;

struct FakeMeshFrame {
  std::string topic;
  std::string payload;
};

extern bool fakeWifiConnected;
extern uint32_t fakeWifiConnectionTimeoutMs;
extern uint64_t fakeEfuseMac;
extern bool fakeConfigStoreSaveResult;
extern int fakeConfigStoreSaveCalls;
extern bool fakeStatusSerializationResult;
extern const char* fakeStatusJson;
extern MeshLink fakeMeshLink;
extern std::vector<FakeMeshFrame> fakeMeshSends;
extern std::vector<FakeMeshFrame> fakeMeshInbox;
extern int fakeMeshForwards;
void runFakeMqttTaskAt(uint32_t nowMs);

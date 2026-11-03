#include "MqttServiceTestSupport.h"

#include "Arduino.h"
#include "ESPmDNS.h"
#include "ConfigStore.h"
#include "MeshLink.h"
#include "PubSubClient.h"
#include "StatusJson.h"
#include "WiFi.h"

#include <freertos/semphr.h>
#include <freertos/task.h>

#include <cstring>

bool fakeWifiConnected = true;
uint64_t fakeEfuseMac = 0x123456ULL;
uint32_t fakeWifiConnectionTimeoutMs = 0;
bool fakeConfigStoreSaveResult = true;
int fakeConfigStoreSaveCalls = 0;
bool fakeStatusSerializationResult = true;
const char* fakeStatusJson = "{\"safe\":true}";

bool fakeMqttConnectResult = true;
std::vector<FakeMdnsHost> fakeMdnsHosts;
std::vector<std::string> fakeMdnsQueries;
MDNSResponder MDNS;

IPAddress MDNSResponder::queryHost(const char* host, uint32_t) {
  fakeMdnsQueries.emplace_back(host);
  for (const FakeMdnsHost& entry : fakeMdnsHosts) {
    if (entry.label == host) {
      return entry.address;
    }
  }
  return IPAddress();
}
int fakeMqttConnectCalls = 0;
int fakeMqttLoopCalls = 0;
int fakeMqttBufferSize = 0;
uint16_t fakeMqttKeepAlive = 0;
uint16_t fakeMqttSocketTimeout = 0;
std::string fakeMqttHost;
uint16_t fakeMqttPort = 0;
std::string fakeMqttClientId;
std::string fakeMqttUser;
std::string fakeMqttPassword;
std::string fakeMqttWillTopic;
std::string fakeMqttWillMessage;
bool fakeMqttWillRetained = false;
std::vector<std::string> fakeMqttSubscriptions;
std::vector<FakeMqttPublish> fakeMqttPublishes;
MeshLink fakeMeshLink;
std::vector<FakeMeshFrame> fakeMeshSends;
std::vector<FakeMeshFrame> fakeMeshInbox;
int fakeMeshForwards = 0;
static void (*fakeMqttCallback)(char*, uint8_t*, unsigned int) = nullptr;
static unsigned long fakeMillis = 0;
static TaskFunction_t fakeTask = nullptr;
static void* fakeTaskContext = nullptr;

namespace {
class FakeTaskYield {};
}

FakeSerial Serial;
FakeEsp ESP;
FakeWiFi WiFi;

uint64_t FakeEsp::getEfuseMac() const { return fakeEfuseMac; }
unsigned long millis() { return fakeMillis; }
int FakeWiFi::status() const { return fakeWifiConnected ? WL_CONNECTED : 0; }
void WiFiClient::setConnectionTimeout(uint32_t milliseconds) {
  fakeWifiConnectionTimeoutMs = milliseconds;
}

bool ConfigStore::saveState(const PersistentState&) {
  ++fakeConfigStoreSaveCalls;
  return fakeConfigStoreSaveResult;
}

bool buildStatusJson(const DeviceConfig&, const LeakController&,
                     const RuntimeStatus&, uint32_t, char* output,
                     size_t outputSize) {
  if (!fakeStatusSerializationResult || std::strlen(fakeStatusJson) >= outputSize) {
    return false;
  }
  std::strcpy(output, fakeStatusJson);
  return true;
}

void resetFakeMqtt() {
  fakeWifiConnected = true;
  fakeMeshSends.clear();
  fakeMeshInbox.clear();
  fakeMeshForwards = 0;
  fakeMqttConnectResult = true;
  fakeMdnsHosts.clear();
  fakeMdnsQueries.clear();
  fakeMqttConnectCalls = 0;
  fakeMqttLoopCalls = 0;
  fakeMqttBufferSize = 0;
  fakeMqttKeepAlive = 0;
  fakeMqttSocketTimeout = 0;
  fakeMqttHost.clear();
  fakeMqttPort = 0;
  fakeMqttClientId.clear();
  fakeMqttUser.clear();
  fakeMqttPassword.clear();
  fakeMqttWillTopic.clear();
  fakeMqttWillMessage.clear();
  fakeMqttWillRetained = false;
  fakeWifiConnectionTimeoutMs = 0;
  fakeMqttSubscriptions.clear();
  fakeMqttPublishes.clear();
  fakeMqttCallback = nullptr;
  fakeMillis = 0;
  fakeTask = nullptr;
  fakeTaskContext = nullptr;
}

SemaphoreHandle_t xSemaphoreCreateMutex() {
  return new FakeSemaphore{true};
}

BaseType_t xSemaphoreTake(SemaphoreHandle_t semaphore, uint32_t) {
  if (semaphore == nullptr || !semaphore->available) {
    return pdFALSE;
  }
  semaphore->available = false;
  return pdTRUE;
}

BaseType_t xSemaphoreGive(SemaphoreHandle_t semaphore) {
  if (semaphore == nullptr) {
    return pdFALSE;
  }
  semaphore->available = true;
  return pdTRUE;
}

BaseType_t xTaskCreate(TaskFunction_t task, const char*, uint32_t, void* context,
                       UBaseType_t, TaskHandle_t* output) {
  fakeTask = task;
  fakeTaskContext = context;
  if (output != nullptr) {
    *output = context;
  }
  return pdPASS;
}

void vTaskDelay(uint32_t) { throw FakeTaskYield{}; }

void runFakeMqttTaskAt(uint32_t nowMs) {
  fakeMillis = nowMs;
  if (fakeTask == nullptr) {
    return;
  }
  try {
    fakeTask(fakeTaskContext);
  } catch (const FakeTaskYield&) {
  }
}

bool PubSubClient::setBufferSize(uint16_t size) {
  fakeMqttBufferSize = size;
  return true;
}
PubSubClient& PubSubClient::setKeepAlive(uint16_t seconds) {
  fakeMqttKeepAlive = seconds;
  return *this;
}
PubSubClient& PubSubClient::setSocketTimeout(uint16_t seconds) {
  fakeMqttSocketTimeout = seconds;
  return *this;
}
PubSubClient& PubSubClient::setServer(const char* host, uint16_t port) {
  fakeMqttHost = host;
  fakeMqttPort = port;
  return *this;
}
PubSubClient& PubSubClient::setCallback(
    void (*callback)(char*, uint8_t*, unsigned int)) {
  callback_ = callback;
  fakeMqttCallback = callback;
  return *this;
}
bool PubSubClient::connect(const char* clientId, const char* user,
                           const char* password, const char* willTopic,
                           uint8_t, bool willRetained, const char* willMessage) {
  ++fakeMqttConnectCalls;
  fakeMqttClientId = clientId;
  fakeMqttUser = user == nullptr ? "" : user;
  fakeMqttPassword = password == nullptr ? "" : password;
  fakeMqttWillTopic = willTopic == nullptr ? "" : willTopic;
  fakeMqttWillMessage = willMessage == nullptr ? "" : willMessage;
  fakeMqttWillRetained = willRetained;
  connected_ = fakeMqttConnectResult;
  return connected_;
}
bool PubSubClient::connect(const char* clientId, const char* willTopic,
                           uint8_t willQos, bool willRetained,
                           const char* willMessage) {
  return connect(clientId, nullptr, nullptr, willTopic, willQos, willRetained,
                 willMessage);
}
bool PubSubClient::connected() const { return connected_; }
bool PubSubClient::publish(const char* topic, const char* payload, bool retained) {
  fakeMqttPublishes.push_back(FakeMqttPublish{topic, payload, retained});
  return true;
}
bool PubSubClient::publish(const char* topic, const uint8_t* payload,
                           unsigned int length, bool retained) {
  fakeMqttPublishes.push_back(FakeMqttPublish{
      topic, std::string(reinterpret_cast<const char*>(payload), length),
      retained});
  return true;
}
bool PubSubClient::subscribe(const char* topic, uint8_t) {
  fakeMqttSubscriptions.emplace_back(topic);
  return true;
}
bool PubSubClient::loop() {
  ++fakeMqttLoopCalls;
  return connected_;
}
// MeshLink stand-in: records sends and forwards, hands out queued frames as
// already authenticated.
void MeshLink::begin() {}
bool MeshLink::start() { return true; }
bool MeshLink::send(const char* baseTopic, const char* payload) {
  fakeMeshSends.push_back(FakeMeshFrame{baseTopic, payload});
  return true;
}
bool MeshLink::receive(MeshMessage& message) {
  if (fakeMeshInbox.empty()) {
    return false;
  }
  const FakeMeshFrame next = fakeMeshInbox.front();
  fakeMeshInbox.erase(fakeMeshInbox.begin());
  std::strcpy(message.frame.topic, next.topic.c_str());
  std::memcpy(message.bytes, next.payload.data(), next.payload.size());
  message.frame.payload = message.bytes;
  message.frame.payloadLength = next.payload.size();
  return true;
}
void MeshLink::forward(MeshMessage&) { ++fakeMeshForwards; }

void fakeMqttDeliver(const char* topic, const char* payload) {
  if (fakeMqttCallback == nullptr) {
    return;
  }
  char mutableTopic[96];
  std::strncpy(mutableTopic, topic, sizeof(mutableTopic) - 1);
  mutableTopic[sizeof(mutableTopic) - 1] = '\0';
  uint8_t mutablePayload[1024];
  const size_t length = std::strlen(payload);
  std::memcpy(mutablePayload, payload, length);
  fakeMqttCallback(mutableTopic, mutablePayload, static_cast<unsigned int>(length));
}

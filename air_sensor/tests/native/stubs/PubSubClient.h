#pragma once

#include "WiFi.h"

#include <cstdint>
#include <string>
#include <vector>

struct FakeMqttPublish {
  std::string topic;
  std::string payload;
  bool retained;
};

extern bool fakeMqttConnectResult;
extern int fakeMqttConnectCalls;
extern int fakeMqttLoopCalls;
extern int fakeMqttBufferSize;
extern uint16_t fakeMqttKeepAlive;
extern uint16_t fakeMqttSocketTimeout;
extern std::string fakeMqttHost;
extern uint16_t fakeMqttPort;
extern std::string fakeMqttClientId;
extern std::string fakeMqttUser;
extern std::string fakeMqttPassword;
extern std::string fakeMqttWillTopic;
extern std::string fakeMqttWillMessage;
extern bool fakeMqttWillRetained;
extern std::vector<std::string> fakeMqttSubscriptions;
extern std::vector<FakeMqttPublish> fakeMqttPublishes;
void resetFakeMqtt();

class PubSubClient {
 public:
  explicit PubSubClient(WiFiClient&) {}
  bool setBufferSize(uint16_t size);
  PubSubClient& setKeepAlive(uint16_t seconds);
  PubSubClient& setSocketTimeout(uint16_t seconds);
  PubSubClient& setServer(const char* host, uint16_t port);
  PubSubClient& setCallback(void (*callback)(char*, uint8_t*, unsigned int));
  bool connect(const char* clientId, const char* user, const char* password,
               const char* willTopic, uint8_t willQos, bool willRetained,
               const char* willMessage);
  bool connect(const char* clientId, const char* willTopic, uint8_t willQos,
               bool willRetained, const char* willMessage);
  bool connected() const;
  int state() const { return connected_ ? 0 : -2; }
  bool publish(const char* topic, const char* payload, bool retained = false);
  bool subscribe(const char* topic, uint8_t qos = 0);
  bool loop();

 private:
  bool connected_ = false;
  void (*callback_)(char*, uint8_t*, unsigned int) = nullptr;
};

void fakeMqttDeliver(const char* topic, const char* payload);

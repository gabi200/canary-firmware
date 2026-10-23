#pragma once

#include "ConfigStore.h"
#include "MeshLink.h"
#include "StatusJson.h"

#include <PubSubClient.h>
#include <WiFi.h>

#include <atomic>

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

class MqttService {
 public:
  MqttService(const DeviceConfig& config, LeakController& controller,
              ConfigStore& store, RuntimeStatusProvider statusProvider,
              MeshLink& mesh);
  void begin();
  // Safety-loop entrypoint: never calls WiFiClient or PubSubClient.
  void process(uint32_t nowMs);
  bool connected() const;
  void requestStatusPublish();

 private:
  enum class QueuedCommand : uint8_t { None, Open, Close, Silence };

  struct ResultHandoff {
    bool accepted;
    char command[8];
    char detail[32];
  };

  void processCommand(uint32_t nowMs);
  void refreshStatus(uint32_t nowMs);
  void networkTask();
  static void networkTaskStatic(void* context);
  void processNetwork(uint32_t nowMs);
  void configureNetworkClient();
  void handleMessage(char* topic, uint8_t* payload, unsigned int length);
  bool queueCommand(QueuedCommand command);
  bool queueCommandResult(const char* command, bool accepted, const char* detail);
  bool queueStatusError();
  bool connect(uint32_t nowMs);
  void publishPendingResult();
  void publishPendingStatusError();
  void publishStatus(uint32_t nowMs);
  void sendStatusOverMesh(uint32_t nowMs);
  void relayMeshStatus();
  bool publishResult(const char* command, bool accepted, const char* detail);
  static void messageCallback(char* topic, uint8_t* payload, unsigned int length);
  static const char* commandName(QueuedCommand command);
  bool formatTopic(char* destination, size_t destinationSize,
                   const char* suffix) const;
  static bool elapsed(uint32_t nowMs, uint32_t sinceMs, uint32_t intervalMs);

  const DeviceConfig& config_;
  // Immutable worker-owned copy. Portal saves replace config_ on the safety
  // loop before reboot, so the network task must never read that reference.
  DeviceConfig networkConfig_;
  LeakController& controller_;
  ConfigStore& store_;
  RuntimeStatusProvider statusProvider_;
  MeshLink& mesh_;
  WiFiClient wifiClient_;
  PubSubClient mqttClient_;
  char availabilityTopic_[96];
  char statusTopic_[96];
  char valveCommandTopic_[96];
  char buzzerCommandTopic_[96];
  char resultTopic_[96];

  // Worker-task-owned network state.
  uint32_t nextConnectMs_;
  uint32_t reconnectDelayMs_;
  uint32_t lastStatusRequestMs_;
  uint32_t publishedStatusGeneration_;
  uint32_t meshStatusGeneration_;
  bool networkConfigured_;
  MeshMessage meshMessage_;

  // Main-loop-owned state.
  uint32_t nextStatusRetryMs_;
  bool statusDirty_;
  bool statusFailureReported_;
  bool topicsValid_;
  bool taskStarted_;
  bool deferredCommandResult_;
  ResultHandoff deferredResult_;

  // Cross-task state protected by handoffMutex_, except the atomics.
  SemaphoreHandle_t handoffMutex_;
  TaskHandle_t taskHandle_;
  QueuedCommand queuedCommand_;
  bool commandReady_;
  bool commandInFlight_;
  ResultHandoff commandResult_;
  bool commandResultReady_;
  bool statusErrorPending_;
  char statusPayload_[STATUS_JSON_MAX_BYTES];
  uint32_t statusGeneration_;
  std::atomic<bool> connected_;
  std::atomic<bool> statusSnapshotRequested_;

  static MqttService* callbackOwner_;
};

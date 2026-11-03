#include "MqttService.h"

#include <Arduino.h>
#include <ESPmDNS.h>

#include <cctype>
#include <cstdio>
#include <cstring>

namespace {

constexpr uint16_t MQTT_BUFFER_BYTES = 2048;
constexpr uint16_t MQTT_KEEPALIVE_SECONDS = 30;
constexpr uint16_t MQTT_SOCKET_TIMEOUT_SECONDS = 2;
// This is a monitoring device, so the heartbeat is tighter than a pure
// actuator would need: a dashboard should not sit on a minute-old reading.
constexpr uint32_t STATUS_HEARTBEAT_MS = 15000;
constexpr uint32_t STATUS_RETRY_MS = 1000;
constexpr uint32_t RECONNECT_MAX_MS = 30000;
// Bounds one mDNS lookup of a ".local" broker name on the network task.
constexpr uint32_t MDNS_QUERY_TIMEOUT_MS = 1500;
constexpr uint32_t NETWORK_TASK_STACK_BYTES = 12288;
constexpr UBaseType_t NETWORK_TASK_PRIORITY = tskIDLE_PRIORITY;
constexpr size_t COMMAND_BYTES = 24;

bool isAsciiWhitespace(char value) {
  return value == ' ' || value == '\t' || value == '\r' || value == '\n' ||
         value == '\f' || value == '\v';
}

void trimAndUppercase(char* value) {
  char* start = value;
  while (isAsciiWhitespace(*start)) {
    ++start;
  }
  char* end = start + std::strlen(start);
  while (end > start && isAsciiWhitespace(end[-1])) {
    --end;
  }
  *end = '\0';
  if (start != value) {
    std::memmove(value, start, static_cast<size_t>(end - start) + 1);
  }
  for (char* cursor = value; *cursor != '\0'; ++cursor) {
    if (*cursor >= 'a' && *cursor <= 'z') {
      *cursor = static_cast<char>(*cursor - 'a' + 'A');
    }
  }
}

const char* rejectionDetail(CommandResult result) {
  switch (result) {
    case CommandResult::RejectedInactive:
      return "alarm_inactive";
    case CommandResult::RejectedBusy:
      return "self_test_busy";
    case CommandResult::RejectedOta:
      return "ota_active";
    case CommandResult::Accepted:
    default:
      return "command_rejected";
  }
}

}  // namespace

MqttService* MqttService::callbackOwner_ = nullptr;

MqttService::MqttService(const DeviceConfig& config, AirController& controller,
                         RuntimeStatusProvider statusProvider,
                         MeshLink& mesh)
    : config_(config),
      networkConfig_(config),
      controller_(controller),
      statusProvider_(statusProvider),
      mesh_(mesh),
      mqttClient_(wifiClient_),
      availabilityTopic_{},
      statusTopic_{},
      buzzerCommandTopic_{},
      resultTopic_{},
      nextConnectMs_(0),
      reconnectDelayMs_(1000),
      lastStatusRequestMs_(0),
      publishedStatusGeneration_(0),
      meshStatusGeneration_(0),
      networkConfigured_(false),
      hubPicker_(),
      serverAddress_{},
      meshMessage_{},
      nextStatusRetryMs_(0),
      statusDirty_(true),
      statusFailureReported_(false),
      topicsValid_(false),
      taskStarted_(false),
      deferredCommandResult_(false),
      deferredResult_{},
      handoffMutex_(nullptr),
      taskHandle_(nullptr),
      queuedCommand_(QueuedCommand::None),
      commandReady_(false),
      commandInFlight_(false),
      commandResult_{},
      commandResultReady_(false),
      statusErrorPending_(false),
      statusPayload_{},
      statusGeneration_(0),
      connected_(false),
      statusSnapshotRequested_(false) {}

void MqttService::begin() {
  topicsValid_ =
      formatTopic(availabilityTopic_, sizeof(availabilityTopic_), "availability") &&
      formatTopic(statusTopic_, sizeof(statusTopic_), "status") &&
      formatTopic(buzzerCommandTopic_, sizeof(buzzerCommandTopic_), "buzzer/set") &&
      formatTopic(resultTopic_, sizeof(resultTopic_), "command/result");
  if (!topicsValid_ || !config_.mqttEnabled) {
    if (!topicsValid_) {
      Serial.println("MQTT disabled: topic is too long");
    }
    return;
  }

  handoffMutex_ = xSemaphoreCreateMutex();
  if (handoffMutex_ == nullptr) {
    Serial.println("MQTT disabled: handoff allocation failed");
    return;
  }
  if (xTaskCreate(networkTaskStatic, "mqtt-service", NETWORK_TASK_STACK_BYTES,
                  this, NETWORK_TASK_PRIORITY, &taskHandle_) != pdPASS) {
    Serial.println("MQTT disabled: task creation failed");
    return;
  }
  taskStarted_ = true;
}

void MqttService::process(uint32_t nowMs) {
  // Controller and Preferences remain safety-loop-owned. No socket calls are
  // permitted in this method.
  processCommand(nowMs);
  if (statusSnapshotRequested_.exchange(false, std::memory_order_acq_rel)) {
    statusDirty_ = true;
  }
  refreshStatus(nowMs);
}

bool MqttService::connected() const {
  return connected_.load(std::memory_order_acquire);
}

void MqttService::requestStatusPublish() {
  statusDirty_ = true;
}

void MqttService::processCommand(uint32_t nowMs) {
  if (deferredCommandResult_) {
    if (queueCommandResult(deferredResult_.command, deferredResult_.accepted,
                           deferredResult_.detail)) {
      deferredCommandResult_ = false;
    }
    return;
  }
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return;
  }
  if (!commandReady_) {
    xSemaphoreGive(handoffMutex_);
    return;
  }
  const QueuedCommand command = queuedCommand_;
  queuedCommand_ = QueuedCommand::None;
  commandReady_ = false;
  xSemaphoreGive(handoffMutex_);

  const char* const name = commandName(command);
  bool accepted = false;
  const char* detail = "invalid_command";
  if (command == QueuedCommand::Silence) {
    const CommandResult result = controller_.silenceAlarm(nowMs);
    accepted = result == CommandResult::Accepted;
    detail = accepted ? "silenced" : rejectionDetail(result);
  } else if (command == QueuedCommand::Test) {
    const CommandResult result = controller_.startSelfTest(nowMs);
    accepted = result == CommandResult::Accepted;
    detail = accepted ? "self_test" : rejectionDetail(result);
  }
  if (!queueCommandResult(name, accepted, detail)) {
    deferredCommandResult_ = true;
    deferredResult_.accepted = accepted;
    std::strcpy(deferredResult_.command, name);
    std::strcpy(deferredResult_.detail, detail);
  }
  statusDirty_ = true;
}

void MqttService::refreshStatus(uint32_t nowMs) {
  if (!statusDirty_ ||
      static_cast<int32_t>(nowMs - nextStatusRetryMs_) < 0) {
    return;
  }
  char payload[STATUS_JSON_MAX_BYTES];
  const RuntimeStatus runtime = statusProvider_();
  if (!buildStatusJson(config_, controller_, runtime, nowMs, payload,
                       sizeof(payload)) ||
      std::strlen(payload) >= MQTT_BUFFER_BYTES) {
    if (!statusFailureReported_ && queueStatusError()) {
      statusFailureReported_ = true;
    }
    nextStatusRetryMs_ = nowMs + STATUS_RETRY_MS;
    return;
  }
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return;
  }
  std::strcpy(statusPayload_, payload);
  ++statusGeneration_;
  xSemaphoreGive(handoffMutex_);
  statusDirty_ = false;
  statusFailureReported_ = false;
}

void MqttService::networkTaskStatic(void* context) {
  static_cast<MqttService*>(context)->networkTask();
}

void MqttService::networkTask() {
  for (;;) {
    processNetwork(millis());
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void MqttService::processNetwork(uint32_t nowMs) {
  if (!networkConfigured_) {
    configureNetworkClient();
  }
  if (!networkConfig_.mqttEnabled || !topicsValid_) {
    connected_.store(false, std::memory_order_release);
    return;
  }
  mesh_.start();
  if (WiFi.status() != WL_CONNECTED) {
    connected_.store(false, std::memory_order_release);
    sendStatusOverMesh(nowMs);
    return;
  }

  if (mqttClient_.connected()) {
    mqttClient_.loop();
    if (!mqttClient_.connected()) {
      connected_.store(false, std::memory_order_release);
      nextConnectMs_ = nowMs;
      return;
    }
    publishPendingResult();
    publishPendingStatusError();
    publishStatus(nowMs);
    relayMeshStatus();
    if (elapsed(nowMs, lastStatusRequestMs_, STATUS_HEARTBEAT_MS)) {
      statusSnapshotRequested_.store(true, std::memory_order_release);
      lastStatusRequestMs_ = nowMs;
    }
    return;
  }

  connected_.store(false, std::memory_order_release);
  sendStatusOverMesh(nowMs);
  if (static_cast<int32_t>(nowMs - nextConnectMs_) < 0) {
    return;
  }
  connect(nowMs);
}

void MqttService::configureNetworkClient() {
  wifiClient_.setConnectionTimeout(MQTT_SOCKET_TIMEOUT_SECONDS * 1000UL);
  mqttClient_.setServer(networkConfig_.mqttHost, networkConfig_.mqttPort);
  hubPicker_.reset(networkConfig_.mqttHost);
  mqttClient_.setBufferSize(MQTT_BUFFER_BYTES);
  mqttClient_.setKeepAlive(MQTT_KEEPALIVE_SECONDS);
  mqttClient_.setSocketTimeout(MQTT_SOCKET_TIMEOUT_SECONDS);
  callbackOwner_ = this;
  mqttClient_.setCallback(messageCallback);
  networkConfigured_ = true;
}

void MqttService::handleMessage(char* topic, uint8_t* payload,
                                unsigned int length) {
  if (topic == nullptr || payload == nullptr) {
    return;
  }
  if (std::strcmp(topic, buzzerCommandTopic_) != 0) {
    return;
  }
  if (length >= COMMAND_BYTES) {
    publishResult("UNKNOWN", false, "invalid_command");
    statusSnapshotRequested_.store(true, std::memory_order_release);
    return;
  }

  char command[COMMAND_BYTES];
  std::memcpy(command, payload, length);
  command[length] = '\0';
  trimAndUppercase(command);

  QueuedCommand queued = QueuedCommand::None;
  if (std::strcmp(command, "SILENCE") == 0) {
    queued = QueuedCommand::Silence;
  } else if (std::strcmp(command, "TEST") == 0) {
    queued = QueuedCommand::Test;
  }
  if (queued == QueuedCommand::None) {
    publishResult("UNKNOWN", false, "invalid_command");
  } else if (!queueCommand(queued)) {
    publishResult(commandName(queued), false, "busy");
  }
  statusSnapshotRequested_.store(true, std::memory_order_release);
}

bool MqttService::queueCommand(QueuedCommand command) {
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return false;
  }
  if (commandInFlight_) {
    xSemaphoreGive(handoffMutex_);
    return false;
  }
  queuedCommand_ = command;
  commandReady_ = true;
  commandInFlight_ = true;
  xSemaphoreGive(handoffMutex_);
  return true;
}

bool MqttService::queueCommandResult(const char* command, bool accepted,
                                     const char* detail) {
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return false;
  }
  std::strncpy(commandResult_.command, command,
               sizeof(commandResult_.command) - 1);
  commandResult_.command[sizeof(commandResult_.command) - 1] = '\0';
  std::strncpy(commandResult_.detail, detail,
               sizeof(commandResult_.detail) - 1);
  commandResult_.detail[sizeof(commandResult_.detail) - 1] = '\0';
  commandResult_.accepted = accepted;
  commandResultReady_ = true;
  xSemaphoreGive(handoffMutex_);
  return true;
}

bool MqttService::queueStatusError() {
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return false;
  }
  statusErrorPending_ = true;
  xSemaphoreGive(handoffMutex_);
  return true;
}

bool MqttService::resolveMdnsHost(const char* host) {
  char label[sizeof(networkConfig_.mqttHost)];
  if (!HubHost::mdnsLabel(host, label, sizeof(label))) {
    return false;
  }
  const IPAddress address = MDNS.queryHost(label, MDNS_QUERY_TIMEOUT_MS);
  if (address == IPAddress()) {
    return false;
  }
  const int written = std::snprintf(serverAddress_, sizeof(serverAddress_), "%s",
                                    address.toString().c_str());
  return written > 0 && static_cast<size_t>(written) < sizeof(serverAddress_);
}

bool MqttService::connect(uint32_t nowMs) {
  char sanitizedName[sizeof(networkConfig_.deviceName)];
  size_t nameLength = 0;
  for (; nameLength < sizeof(networkConfig_.deviceName) - 1 &&
         networkConfig_.deviceName[nameLength] != '\0';
       ++nameLength) {
    const unsigned char character =
        static_cast<unsigned char>(networkConfig_.deviceName[nameLength]);
    sanitizedName[nameLength] =
        (std::isalnum(character) || character == '-' || character == '_')
            ? static_cast<char>(character)
            : '-';
  }
  sanitizedName[nameLength] = '\0';
  if (nameLength == 0) {
    std::strcpy(sanitizedName, "device");
  }

  char clientId[48];
  const unsigned long chipId =
      static_cast<unsigned long>(ESP.getEfuseMac() & 0xFFFFFFULL);
  const int clientIdLength = std::snprintf(clientId, sizeof(clientId), "%s-%06lx",
                                           sanitizedName, chipId);
  if (clientIdLength < 0 || static_cast<size_t>(clientIdLength) >= sizeof(clientId)) {
    return false;
  }

  // The saved broker host, or the hub's announced name after the saved host was unreachable
  // (HubHost.h). A ".local" name is looked up over mDNS here and connected to by address.
  const char* host = hubPicker_.current();
  bool resolvedOk = true;
  if (HubHost::isMdnsName(host)) {
    resolvedOk = resolveMdnsHost(host);
    if (resolvedOk) {
      mqttClient_.setServer(serverAddress_, networkConfig_.mqttPort);
    }
  } else {
    mqttClient_.setServer(host, networkConfig_.mqttPort);
  }

  const bool useCredentials = networkConfig_.mqttUser[0] != '\0';
  const bool success = resolvedOk && (useCredentials
                           ? mqttClient_.connect(clientId, networkConfig_.mqttUser,
                                                 networkConfig_.mqttPassword,
                                                 availabilityTopic_, 1, true,
                                                 "offline")
                           : mqttClient_.connect(clientId, availabilityTopic_, 1,
                                                 true, "offline"));
  if (!success) {
    // state(): -4 timeout, -2 no TCP connection (lookup or reachability),
    // 4 bad user/password, 5 not authorised. The password is never logged.
    const int state = resolvedOk ? mqttClient_.state() : -2;
    char shown[40] = "unresolved";
    if (HubHost::isMdnsName(host)) {
      if (resolvedOk) {
        std::snprintf(shown, sizeof(shown), "%s", serverAddress_);
      }
    } else {
      IPAddress resolved;
      if (WiFi.hostByName(host, resolved) == 1) {
        std::snprintf(shown, sizeof(shown), "%s", resolved.toString().c_str());
      }
    }
    hubPicker_.onFailure(state < 0);
    Serial.printf(
        "[mqtt] connect failed: host=%s -> %s port=%u user=%s state=%d; "
        "next host=%s, retry in %lu ms\n",
        host, shown, static_cast<unsigned>(networkConfig_.mqttPort),
        useCredentials ? networkConfig_.mqttUser : "(none)", state,
        hubPicker_.current(), static_cast<unsigned long>(reconnectDelayMs_));
    nextConnectMs_ = nowMs + reconnectDelayMs_;
    reconnectDelayMs_ = reconnectDelayMs_ < RECONNECT_MAX_MS / 2
                            ? reconnectDelayMs_ * 2
                            : RECONNECT_MAX_MS;
    return false;
  }

  Serial.printf("[mqtt] connected to %s:%u as %s\n", host,
                static_cast<unsigned>(networkConfig_.mqttPort), clientId);
  mqttClient_.publish(availabilityTopic_, "online", true);
  mqttClient_.subscribe(buzzerCommandTopic_, 1);
  connected_.store(true, std::memory_order_release);
  reconnectDelayMs_ = 1000;
  nextConnectMs_ = nowMs;
  lastStatusRequestMs_ = nowMs;
  if (handoffMutex_ != nullptr && xSemaphoreTake(handoffMutex_, 0) == pdTRUE) {
    publishedStatusGeneration_ = statusGeneration_;
    xSemaphoreGive(handoffMutex_);
  }
  statusSnapshotRequested_.store(true, std::memory_order_release);
  return true;
}

void MqttService::publishPendingResult() {
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return;
  }
  if (!commandResultReady_) {
    xSemaphoreGive(handoffMutex_);
    return;
  }
  const ResultHandoff result = commandResult_;
  xSemaphoreGive(handoffMutex_);
  if (!publishResult(result.command, result.accepted, result.detail)) {
    return;
  }
  if (xSemaphoreTake(handoffMutex_, 0) == pdTRUE) {
    if (commandResultReady_ &&
        std::strcmp(commandResult_.command, result.command) == 0) {
      commandResultReady_ = false;
      commandInFlight_ = false;
    }
    xSemaphoreGive(handoffMutex_);
  }
}

void MqttService::publishPendingStatusError() {
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return;
  }
  if (!statusErrorPending_) {
    xSemaphoreGive(handoffMutex_);
    return;
  }
  xSemaphoreGive(handoffMutex_);
  if (publishResult("STATUS", false, "status_serialization_failed") &&
      xSemaphoreTake(handoffMutex_, 0) == pdTRUE) {
    statusErrorPending_ = false;
    xSemaphoreGive(handoffMutex_);
  }
}

void MqttService::publishStatus(uint32_t nowMs) {
  (void)nowMs;
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return;
  }
  if (statusGeneration_ == publishedStatusGeneration_) {
    xSemaphoreGive(handoffMutex_);
    return;
  }
  char payload[STATUS_JSON_MAX_BYTES];
  std::strcpy(payload, statusPayload_);
  const uint32_t generation = statusGeneration_;
  xSemaphoreGive(handoffMutex_);
  if (!mqttClient_.publish(statusTopic_, payload, true)) {
    return;
  }
  if (xSemaphoreTake(handoffMutex_, 0) == pdTRUE) {
    if (statusGeneration_ == generation) {
      publishedStatusGeneration_ = generation;
    }
    xSemaphoreGive(handoffMutex_);
  }
}

// No MQTT session: hand our status to neighbours over ESP-NOW instead, keep
// the heartbeat going, and pass on what other offline nodes hand us.
void MqttService::sendStatusOverMesh(uint32_t nowMs) {
  while (mesh_.receive(meshMessage_)) {
    mesh_.forward(meshMessage_);
  }
  if (elapsed(nowMs, lastStatusRequestMs_, STATUS_HEARTBEAT_MS)) {
    statusSnapshotRequested_.store(true, std::memory_order_release);
    lastStatusRequestMs_ = nowMs;
  }
  if (handoffMutex_ == nullptr ||
      xSemaphoreTake(handoffMutex_, 0) != pdTRUE) {
    return;
  }
  if (statusGeneration_ == meshStatusGeneration_) {
    xSemaphoreGive(handoffMutex_);
    return;
  }
  char payload[STATUS_JSON_MAX_BYTES];
  std::strcpy(payload, statusPayload_);
  meshStatusGeneration_ = statusGeneration_;
  xSemaphoreGive(handoffMutex_);
  mesh_.send(networkConfig_.mqttBaseTopic, payload);
}

// A neighbour without MQTT reached us over ESP-NOW: publish its status as it
// would have. The hub drops the copies other relays publish (same uptime_ms).
void MqttService::relayMeshStatus() {
  while (mesh_.receive(meshMessage_)) {
    char topic[mesh::MAX_TOPIC_BYTES + sizeof("/status")];
    std::snprintf(topic, sizeof(topic), "%s/status", meshMessage_.frame.topic);
    if (std::strcmp(topic, statusTopic_) == 0) {
      continue;  // base topics are unique; never overwrite our own status
    }
    mqttClient_.publish(topic, meshMessage_.frame.payload,
                        static_cast<unsigned int>(meshMessage_.frame.payloadLength),
                        true);
  }
}

bool MqttService::publishResult(const char* command, bool accepted,
                                const char* detail) {
  char payload[160];
  const int length = std::snprintf(
      payload, sizeof(payload),
      accepted
          ? "{\"command\":\"%s\",\"accepted\":true,\"state\":\"%s\"}"
          : "{\"command\":\"%s\",\"accepted\":false,\"error\":\"%s\"}",
      command, detail);
  return length >= 0 && static_cast<size_t>(length) < sizeof(payload) &&
         mqttClient_.publish(resultTopic_, payload, false);
}

void MqttService::messageCallback(char* topic, uint8_t* payload,
                                  unsigned int length) {
  if (callbackOwner_ != nullptr) {
    callbackOwner_->handleMessage(topic, payload, length);
  }
}

const char* MqttService::commandName(QueuedCommand command) {
  switch (command) {
    case QueuedCommand::Silence:
      return "SILENCE";
    case QueuedCommand::Test:
      return "TEST";
    case QueuedCommand::None:
    default:
      return "UNKNOWN";
  }
}

bool MqttService::formatTopic(char* destination, size_t destinationSize,
                              const char* suffix) const {
  const size_t baseLength = strnlen(config_.mqttBaseTopic,
                                    sizeof(config_.mqttBaseTopic));
  if (baseLength == 0 || baseLength == sizeof(config_.mqttBaseTopic)) {
    return false;
  }
  const int length = std::snprintf(destination, destinationSize, "%s/%s",
                                   config_.mqttBaseTopic, suffix);
  return length >= 0 && static_cast<size_t>(length) < destinationSize;
}

bool MqttService::elapsed(uint32_t nowMs, uint32_t sinceMs,
                          uint32_t intervalMs) {
  return static_cast<uint32_t>(nowMs - sinceMs) >= intervalMs;
}

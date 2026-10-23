#pragma once

#include "DeviceConfig.h"
#include "PortalSubmissionPolicy.h"

#include <WiFiManager.h>

#include <atomic>

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

class NetworkConfig {
 public:
  NetworkConfig();
  void begin(DeviceConfig& config, bool forcePortal);
  void process();
  bool wifiConnected() const;
  int32_t wifiRssi() const;
  uint32_t wifiIp() const;
  bool portalActive() const;
  bool servicesReady() const;
  bool takeConfigChanged(DeviceConfig& output);

 private:
  static NetworkConfig* callbackOwner_;
  static void onSaveStatic();
  static void networkTaskStatic(void* context);
  void onSave();
  void networkTask();
  void publishNetworkStatus();
  void startDiscovery();
  void manageMeshFallback();
  void handleSubmissionRecovery();
  void captureStoredWiFiCredentials();
  void restoreStoredWiFiCredentials();
  void copyConfigToBuffers(const DeviceConfig& config);
  bool copyBuffersToConfig(DeviceConfig& output) const;

  WiFiManager wifiManager_;
  WiFiManagerParameter deviceNameParam_;
  WiFiManagerParameter mqttEnabledParam_;
  WiFiManagerParameter mqttHostParam_;
  WiFiManagerParameter mqttPortParam_;
  WiFiManagerParameter mqttUserParam_;
  WiFiManagerParameter mqttPasswordParam_;
  WiFiManagerParameter mqttTopicParam_;
  WiFiManagerParameter apiTokenRequiredParam_;
  WiFiManagerParameter apiTokenOptionalParam_;
  WiFiManagerParameter* apiTokenParam_;
  WiFiManagerParameter wetThresholdParam_;
  WiFiManagerParameter dryThresholdParam_;
  WiFiManagerParameter debounceParam_;
  WiFiManagerParameter alarmDurationParam_;
  DeviceConfig currentConfig_;
  DeviceConfig handoffConfig_;
  DeviceConfig pendingConfig_;
  PortalSubmissionPolicy submissionPolicy_;
  String savedWifiSsid_;
  String savedWifiPassword_;
  SemaphoreHandle_t handoffMutex_;
  TaskHandle_t taskHandle_;
  std::atomic<bool> wifiConnected_;
  std::atomic<int32_t> wifiRssi_;
  std::atomic<uint32_t> wifiIp_;
  std::atomic<bool> portalActive_;
  std::atomic<bool> servicesReady_;
  bool taskStarted_;
  bool forcePortal_;
  bool handoffChanged_;
  bool configChanged_;
  bool recoveryPending_;
  bool captureCredentialsPending_;
  PortalSubmissionAction recoveryAction_;
  char apName_[40];
  char hostname_[33];
  bool discoveryStarted_;
  bool meshFallback_;
  uint8_t meshChannel_;
  uint32_t lastConnectedMs_;
  uint32_t wifiRetryMs_;
};

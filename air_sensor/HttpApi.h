#pragma once

#include "StatusJson.h"

#include <NetworkClient.h>
#include <NetworkServer.h>

// Incremental, bounded HTTP transport. It deliberately does not use
// WebServer: WebServer buffers a whole plain POST body before any handler can
// authenticate it, and OTA uploads must be authorized before the first flash
// write.
class HttpApi {
 public:
  HttpApi(const DeviceConfig& config, AirController& controller,
          RuntimeStatusProvider statusProvider,
          StateChangeCallback stateChanged);
  void begin();
  void handleClient();
  bool otaInProgress() const;
  bool rebootDue(uint32_t nowMs) const;

 private:
  bool authorized() const;
  void sendJsonError(int status, const char* error, const char* message);
  void sendStatus(int status = 200);
  void handleBuzzer();
  void sendUpdatePage();
  void beginOtaRequest();
  void handleOtaChunk(uint8_t byte);
  void finishOtaRequest();
  void failOta(const char* fallback);
  void clearOtaInterlock();
  bool parseMultipartBoundary(const char* contentType);
  bool parseOtaPartHeaders();
  bool handleOtaFileByte(uint8_t byte);
  bool appendOtaFirmwareByte(uint8_t byte);
  bool flushOtaFirmware();
  void captureUpdateError(const char* fallback);
  void resetClient();
  void processHeaders();
  void processBody();
  bool sendResponse(int status, const char* body, size_t bodyLength);
  bool readHeaderByte(char byte);
  bool parseCommand(const char* key, char* value, size_t valueSize) const;
  static bool equalsIgnoreCase(const char* left, const char* right);
  static bool parseContentLength(const char* text, size_t& length);
  static char* trim(char* text);

  enum class ClientState : uint8_t {
    Idle,
    Headers,
    Body,
    OtaPreamble,
    OtaPartHeaders,
    OtaFile,
    OtaBoundarySuffix,
    OtaTerminalCrLf,
  };
  enum class RequestRoute : uint8_t { None, Buzzer, Ota };
  static constexpr size_t MAX_HEADER_BYTES = 512;
  static constexpr size_t MAX_BODY_BYTES = 128;
  static constexpr size_t MAX_BYTES_PER_HANDLE = 64;
  static constexpr size_t MAX_MULTIPART_BOUNDARY_BYTES = 70;
  static constexpr size_t MAX_OTA_PART_HEADER_BYTES = 256;
  static constexpr size_t MAX_OTA_ERROR_BYTES = 96;
  static constexpr uint32_t CLIENT_IDLE_TIMEOUT_MS = 1000;
  static constexpr uint32_t OTA_REBOOT_DELAY_MS = 500;

  const DeviceConfig& config_;
  AirController& controller_;
  RuntimeStatusProvider statusProvider_;
  StateChangeCallback stateChanged_;
  NetworkServer server_{80};
  NetworkClient client_;
  ClientState clientState_ = ClientState::Idle;
  RequestRoute requestRoute_ = RequestRoute::None;
  char header_[MAX_HEADER_BYTES + 1]{};
  size_t headerLength_ = 0;
  char body_[MAX_BODY_BYTES + 1]{};
  size_t bodyLength_ = 0;
  size_t expectedBodyLength_ = 0;
  size_t receivedBodyLength_ = 0;
  char authorization_[80]{};
  char multipartBoundary_[MAX_MULTIPART_BOUNDARY_BYTES + 1]{};
  size_t multipartBoundaryLength_ = 0;
  size_t otaPreambleLength_ = 0;
  char otaPartHeader_[MAX_OTA_PART_HEADER_BYTES + 1]{};
  size_t otaPartHeaderLength_ = 0;
  char otaBoundaryMatch_[MAX_MULTIPART_BOUNDARY_BYTES + 5]{};
  size_t otaBoundaryMatchLength_ = 0;
  uint8_t otaWriteBuffer_[MAX_BYTES_PER_HANDLE]{};
  size_t otaWriteBufferLength_ = 0;
  size_t otaBoundarySuffixLength_ = 0;
  bool otaAuthorized_ = false;
  bool otaFailed_ = false;
  char otaError_[MAX_OTA_ERROR_BYTES]{};
  bool rebootScheduled_ = false;
  uint32_t rebootAtMs_ = 0;
  uint32_t lastProgressMs_ = 0;
};

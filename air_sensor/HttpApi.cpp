#include "HttpApi.h"

#include "Auth.h"

#include <ArduinoJson.h>
#include <Update.h>

#include <cctype>
#include <cstddef>
#include <cstdio>
#include <cstring>

namespace {

constexpr size_t COMMAND_DOCUMENT_BYTES = 2048;

const char UPDATE_PAGE[] PROGMEM = R"html(<!doctype html><html><head><meta charset="utf-8"><title>Canary update</title></head><body><h1>Firmware update</h1><form id="update"><label>API token <input id="token" type="password" required></label><br><label>Firmware (.bin) <input id="firmware" type="file" accept=".bin,application/octet-stream" required></label><br><button>Upload</button></form><pre id="result"></pre><script>const form=document.getElementById('update');const result=document.getElementById('result');form.addEventListener('submit',async event=>{event.preventDefault();const file=document.getElementById('firmware').files[0];if(!file){return;}const data=new FormData();data.append('firmware',file);result.textContent='Uploading…';try{const response=await fetch('/api/ota',{method:'POST',headers:{Authorization:'Bearer '+document.getElementById('token').value},body:data});result.textContent=await response.text();}catch(error){result.textContent=String(error);}});</script></body></html>)html";

class FixedAllocator : public ArduinoJson::Allocator {
 public:
  void* allocate(size_t size) override {
    const size_t alignedOffset = align(offset_);
    if (size == 0 || alignedOffset > sizeof(storage_) ||
        size > sizeof(storage_) - alignedOffset || allocationCount_ == MAX_ALLOCS) {
      return nullptr;
    }
    void* result = storage_ + alignedOffset;
    allocations_[allocationCount_++] = Allocation{result, size};
    offset_ = alignedOffset + size;
    return result;
  }

  void deallocate(void* pointer) override {
    (void)pointer;
  }

  void* reallocate(void* pointer, size_t size) override {
    if (pointer == nullptr) {
      return allocate(size);
    }
    for (size_t index = 0; index < allocationCount_; ++index) {
      if (allocations_[index].pointer != pointer) {
        continue;
      }
      const size_t previousSize = allocations_[index].size;
      void* replacement = allocate(size);
      if (replacement == nullptr) {
        return nullptr;
      }
      std::memcpy(replacement, pointer,
                  previousSize < size ? previousSize : size);
      allocations_[index].pointer = replacement;
      allocations_[index].size = size;
      return replacement;
    }
    return nullptr;
  }

 private:
  struct Allocation {
    void* pointer;
    size_t size;
  };

  static constexpr size_t MAX_ALLOCS = 16;

  static size_t align(size_t value) {
    const size_t alignment = alignof(std::max_align_t);
    return (value + alignment - 1) & ~(alignment - 1);
  }

  alignas(std::max_align_t) uint8_t storage_[COMMAND_DOCUMENT_BYTES]{};
  Allocation allocations_[MAX_ALLOCS]{};
  size_t offset_ = 0;
  size_t allocationCount_ = 0;
};

const char* statusText(int status) {
  switch (status) {
    case 200:
      return "OK";
    case 400:
      return "Bad Request";
    case 401:
      return "Unauthorized";
    case 404:
      return "Not Found";
    case 409:
      return "Conflict";
    case 413:
      return "Payload Too Large";
    case 431:
      return "Request Header Fields Too Large";
    default:
      return "Internal Server Error";
  }
}

bool equalsIgnoreCaseN(const char* left, size_t leftLength, const char* right) {
  if (std::strlen(right) != leftLength) {
    return false;
  }
  for (size_t index = 0; index < leftLength; ++index) {
    if (std::tolower(static_cast<unsigned char>(left[index])) !=
        std::tolower(static_cast<unsigned char>(right[index]))) {
      return false;
    }
  }
  return true;
}

bool endsWithIgnoreCase(const char* text, const char* suffix) {
  const size_t textLength = std::strlen(text);
  const size_t suffixLength = std::strlen(suffix);
  return textLength >= suffixLength &&
         equalsIgnoreCaseN(text + textLength - suffixLength, suffixLength, suffix);
}

bool parseMultipartParameter(char* text, const char* expectedName,
                             char* output, size_t outputSize) {
  if (outputSize == 0) {
    return false;
  }
  char* cursor = text;
  while (*cursor != '\0') {
    while (*cursor == ';' || *cursor == ' ' || *cursor == '\t') {
      ++cursor;
    }
    char* name = cursor;
    while (*cursor != '\0' && *cursor != '=' && *cursor != ';') {
      ++cursor;
    }
    char* nameEnd = cursor;
    while (nameEnd > name && (nameEnd[-1] == ' ' || nameEnd[-1] == '\t')) {
      --nameEnd;
    }
    if (*cursor != '=') {
      while (*cursor != '\0' && *cursor != ';') {
        ++cursor;
      }
      continue;
    }
    const bool matchingName = equalsIgnoreCaseN(
        name, static_cast<size_t>(nameEnd - name), expectedName);
    ++cursor;
    while (*cursor == ' ' || *cursor == '\t') {
      ++cursor;
    }
    const bool quoted = *cursor == '"';
    if (quoted) {
      ++cursor;
    }
    char* value = cursor;
    while (*cursor != '\0' &&
           (quoted ? *cursor != '"' : *cursor != ';')) {
      ++cursor;
    }
    char* valueEnd = cursor;
    if (quoted) {
      if (*cursor != '"') {
        return false;
      }
      ++cursor;
      while (*cursor == ' ' || *cursor == '\t') {
        ++cursor;
      }
      if (*cursor != '\0' && *cursor != ';') {
        return false;
      }
    } else {
      while (valueEnd > value &&
             (valueEnd[-1] == ' ' || valueEnd[-1] == '\t')) {
        --valueEnd;
      }
    }
    if (matchingName) {
      const size_t valueLength = static_cast<size_t>(valueEnd - value);
      if (valueLength == 0 || valueLength >= outputSize) {
        return false;
      }
      std::memcpy(output, value, valueLength);
      output[valueLength] = '\0';
      return true;
    }
  }
  return false;
}

}  // namespace

HttpApi::HttpApi(const DeviceConfig& config, AirController& controller,
                 RuntimeStatusProvider statusProvider,
                 StateChangeCallback stateChanged)
    : config_(config),
      controller_(controller),
      statusProvider_(statusProvider),
      stateChanged_(stateChanged) {}

void HttpApi::begin() {
  server_.begin();
}

bool HttpApi::otaInProgress() const {
  return otaAuthorized_ && !otaFailed_;
}

bool HttpApi::rebootDue(uint32_t nowMs) const {
  return rebootScheduled_ &&
         static_cast<int32_t>(nowMs - rebootAtMs_) >= 0;
}

void HttpApi::handleClient() {
  const uint32_t nowMs = millis();
  if (clientState_ == ClientState::Idle) {
    client_ = server_.accept();
    if (!client_) {
      return;
    }
    client_.setNoDelay(true);
    clientState_ = ClientState::Headers;
    headerLength_ = 0;
    bodyLength_ = 0;
    expectedBodyLength_ = 0;
    receivedBodyLength_ = 0;
    requestRoute_ = RequestRoute::None;
    authorization_[0] = '\0';
    lastProgressMs_ = nowMs;
  }

  if (!client_.connected()) {
    if (requestRoute_ == RequestRoute::Ota && otaInProgress()) {
      failOta("Firmware upload interrupted");
      clearOtaInterlock();
    }
    resetClient();
    return;
  }
  if (static_cast<uint32_t>(nowMs - lastProgressMs_) > CLIENT_IDLE_TIMEOUT_MS) {
    if (requestRoute_ == RequestRoute::Ota && otaInProgress()) {
      failOta("Firmware upload timed out");
      finishOtaRequest();
      return;
    }
    resetClient();
    return;
  }

  for (size_t bytesRead = 0;
       bytesRead < MAX_BYTES_PER_HANDLE && client_.available() > 0;
       ++bytesRead) {
    const int input = client_.read();
    if (input < 0) {
      break;
    }
    lastProgressMs_ = millis();
    if (clientState_ == ClientState::Headers) {
      if (readHeaderByte(static_cast<char>(input))) {
        processHeaders();
        return;
      }
      continue;
    }

    if (clientState_ == ClientState::Body) {
      if (bodyLength_ >= expectedBodyLength_) {
        sendJsonError(400, "invalid_request", "Unexpected request body data");
        return;
      }
      body_[bodyLength_++] = static_cast<char>(input);
      if (bodyLength_ == expectedBodyLength_) {
        body_[bodyLength_] = '\0';
        processBody();
        return;
      }
      continue;
    }

    if (receivedBodyLength_ >= expectedBodyLength_) {
      sendJsonError(400, "invalid_request", "Unexpected request body data");
      return;
    }
    ++receivedBodyLength_;
    handleOtaChunk(static_cast<uint8_t>(input));
    if (clientState_ == ClientState::Idle) {
      return;
    }
    if (receivedBodyLength_ == expectedBodyLength_) {
      failOta("Incomplete multipart firmware upload");
      finishOtaRequest();
      return;
    }
  }
}

bool HttpApi::authorized() const {
  return authorizeBearer(authorization_, config_.apiToken);
}

void HttpApi::sendJsonError(int status, const char* error, const char* message) {
  char payload[192];
  const int length = std::snprintf(payload, sizeof(payload),
                                   "{\"error\":\"%s\",\"message\":\"%s\"}",
                                   error, message);
  if (length < 0 || static_cast<size_t>(length) >= sizeof(payload)) {
    static constexpr char fallback[] = "{\"error\":\"internal_error\"}";
    sendResponse(500, fallback, sizeof(fallback) - 1);
    return;
  }
  sendResponse(status, payload, static_cast<size_t>(length));
}

void HttpApi::sendStatus(int status) {
  char payload[STATUS_JSON_MAX_BYTES];
  const RuntimeStatus runtime = statusProvider_();
  if (!buildStatusJson(config_, controller_, runtime, millis(), payload,
                       sizeof(payload))) {
    sendJsonError(500, "status_unavailable", "Status serialization failed");
    return;
  }
  sendResponse(status, payload, std::strlen(payload));
}

void HttpApi::handleBuzzer() {
  char command[16];
  if (!parseCommand("command", command, sizeof(command))) {
    sendJsonError(400, "invalid_request", "command must be silence or test");
    return;
  }

  if (std::strcmp(command, "silence") == 0) {
    if (controller_.silenceAlarm(millis()) != CommandResult::Accepted) {
      sendJsonError(409, "alarm_inactive", "No sounding alarm to silence");
      return;
    }
    stateChanged_();
    sendStatus();
    return;
  }

  if (std::strcmp(command, "test") == 0) {
    const CommandResult result = controller_.startSelfTest(millis());
    if (result == CommandResult::RejectedOta) {
      sendJsonError(409, "ota_active", "Self-test is blocked during OTA update");
      return;
    }
    if (result != CommandResult::Accepted) {
      sendJsonError(409, "self_test_busy",
                    "Self-test is blocked while an alarm is active");
      return;
    }
    stateChanged_();
    sendStatus();
    return;
  }

  sendJsonError(400, "invalid_request", "command must be silence or test");
}

void HttpApi::sendUpdatePage() {
  char responseHeader[160];
  const size_t pageLength = strlen_P(UPDATE_PAGE);
  const int headerLength = std::snprintf(
      responseHeader, sizeof(responseHeader),
      "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
      "Content-Length: %u\r\nConnection: close\r\n\r\n",
      static_cast<unsigned int>(pageLength));
  if (headerLength > 0 && static_cast<size_t>(headerLength) < sizeof(responseHeader)) {
    const size_t headerWritten = client_.write(
        reinterpret_cast<const uint8_t*>(responseHeader),
        static_cast<size_t>(headerLength));
    if (headerWritten == static_cast<size_t>(headerLength)) {
      const size_t pageWritten = client_.write_P(UPDATE_PAGE, pageLength);
      if (pageWritten != pageLength) {
        client_.stop();
      }
    } else {
      client_.stop();
    }
  }
  resetClient();
}

void HttpApi::beginOtaRequest() {
  otaAuthorized_ = true;
  otaFailed_ = false;
  otaError_[0] = '\0';
  rebootScheduled_ = false;
  controller_.setOtaActive(true);
  // The hazard alarm keeps running through an update: an OTA must never mute
  // a live CO or gas warning.
  stateChanged_();
  if (!Update.begin(UPDATE_SIZE_UNKNOWN, U_FLASH)) {
    captureUpdateError("Unable to start firmware update");
    otaFailed_ = true;
    finishOtaRequest();
    return;
  }
  clientState_ = ClientState::OtaPreamble;
}

void HttpApi::handleOtaChunk(uint8_t byte) {
  if (otaFailed_) {
    return;
  }

  if (clientState_ == ClientState::OtaPreamble) {
    const size_t expectedLength = multipartBoundaryLength_ + 4;
    char expected = '\0';
    if (otaPreambleLength_ < 2) {
      expected = '-';
    } else if (otaPreambleLength_ < multipartBoundaryLength_ + 2) {
      expected = multipartBoundary_[otaPreambleLength_ - 2];
    } else if (otaPreambleLength_ == multipartBoundaryLength_ + 2) {
      expected = '\r';
    } else {
      expected = '\n';
    }
    if (byte != static_cast<uint8_t>(expected)) {
      failOta("Malformed multipart firmware upload");
      finishOtaRequest();
      return;
    }
    ++otaPreambleLength_;
    if (otaPreambleLength_ == expectedLength) {
      clientState_ = ClientState::OtaPartHeaders;
    }
    return;
  }

  if (clientState_ == ClientState::OtaPartHeaders) {
    if (otaPartHeaderLength_ == MAX_OTA_PART_HEADER_BYTES) {
      failOta("Firmware part headers are too large");
      finishOtaRequest();
      return;
    }
    otaPartHeader_[otaPartHeaderLength_++] = static_cast<char>(byte);
    otaPartHeader_[otaPartHeaderLength_] = '\0';
    if (otaPartHeaderLength_ >= 4 &&
        std::memcmp(otaPartHeader_ + otaPartHeaderLength_ - 4, "\r\n\r\n", 4) == 0) {
      if (!parseOtaPartHeaders()) {
        failOta("Firmware field is required");
        finishOtaRequest();
        return;
      }
      clientState_ = ClientState::OtaFile;
    }
    return;
  }

  if (clientState_ == ClientState::OtaFile) {
    if (!handleOtaFileByte(byte)) {
      finishOtaRequest();
    }
    return;
  }

  if (clientState_ == ClientState::OtaBoundarySuffix) {
    if (byte != '-') {
      failOta("Firmware upload has additional multipart fields");
      finishOtaRequest();
      return;
    }
    ++otaBoundarySuffixLength_;
    if (otaBoundarySuffixLength_ == 2) {
      otaBoundarySuffixLength_ = 0;
      clientState_ = ClientState::OtaTerminalCrLf;
    }
    return;
  }

  if (clientState_ == ClientState::OtaTerminalCrLf) {
    const uint8_t expected = otaBoundarySuffixLength_ == 0 ? '\r' : '\n';
    if (byte != expected) {
      failOta("Firmware upload has an invalid terminal delimiter");
      finishOtaRequest();
      return;
    }
    ++otaBoundarySuffixLength_;
    if (otaBoundarySuffixLength_ == 2) {
      if (receivedBodyLength_ != expectedBodyLength_) {
        failOta("Unexpected data after firmware upload");
        finishOtaRequest();
        return;
      }
      if (!flushOtaFirmware()) {
        finishOtaRequest();
        return;
      }
      if (!Update.end(true)) {
        captureUpdateError("Firmware verification failed");
        otaFailed_ = true;
        finishOtaRequest();
        return;
      }
      finishOtaRequest();
    }
  }
}

void HttpApi::finishOtaRequest() {
  if (!otaAuthorized_) {
    sendJsonError(401, "unauthorized", "Bearer authentication required");
    return;
  }
  if (otaFailed_) {
    if (Update.isRunning()) {
      Update.abort();
    }
    sendJsonError(500, "ota_failed",
                  otaError_[0] == '\0' ? "Firmware update failed" : otaError_);
    clearOtaInterlock();
    return;
  }
  static constexpr char success[] = "{\"ok\":true,\"rebooting\":true}";
  if (sendResponse(200, success, sizeof(success) - 1)) {
    rebootScheduled_ = true;
    rebootAtMs_ = millis() + OTA_REBOOT_DELAY_MS;
  }
}

void HttpApi::failOta(const char* fallback) {
  if (Update.isRunning()) {
    Update.abort();
  }
  std::snprintf(otaError_, sizeof(otaError_), "%s", fallback);
  otaFailed_ = true;
}

void HttpApi::clearOtaInterlock() {
  controller_.setOtaActive(false);
  otaAuthorized_ = false;
  otaFailed_ = false;
  otaError_[0] = '\0';
  stateChanged_();
}

bool HttpApi::parseMultipartBoundary(const char* contentType) {
  static constexpr char prefix[] = "multipart/form-data";
  const size_t prefixLength = sizeof(prefix) - 1;
  if (contentType == nullptr ||
      std::strlen(contentType) < prefixLength ||
      !equalsIgnoreCaseN(contentType, prefixLength, prefix) ||
      (contentType[prefixLength] != '\0' && contentType[prefixLength] != ';')) {
    return false;
  }

  const char* cursor = contentType + prefixLength;
  while (*cursor != '\0') {
    if (*cursor == ';') {
      ++cursor;
    }
    while (*cursor == ' ' || *cursor == '\t') {
      ++cursor;
    }
    const char* name = cursor;
    while (*cursor != '\0' && *cursor != '=' && *cursor != ';') {
      ++cursor;
    }
    const size_t nameLength = static_cast<size_t>(cursor - name);
    if (*cursor != '=') {
      while (*cursor != '\0' && *cursor != ';') {
        ++cursor;
      }
      continue;
    }
    ++cursor;
    const bool quoted = *cursor == '"';
    if (quoted) {
      ++cursor;
    }
    const char* value = cursor;
    while (*cursor != '\0' &&
           (quoted ? *cursor != '"' : *cursor != ';')) {
      ++cursor;
    }
    const size_t valueLength = static_cast<size_t>(cursor - value);
    if (quoted && *cursor != '"') {
      return false;
    }
    if (nameLength == 8 &&
        equalsIgnoreCaseN(name, nameLength, "boundary") &&
        valueLength > 0 && valueLength <= MAX_MULTIPART_BOUNDARY_BYTES) {
      for (size_t index = 0; index < valueLength; ++index) {
        const unsigned char character = static_cast<unsigned char>(value[index]);
        if (character <= ' ' || character >= 127) {
          return false;
        }
      }
      std::memcpy(multipartBoundary_, value, valueLength);
      multipartBoundary_[valueLength] = '\0';
      multipartBoundaryLength_ = valueLength;
      return true;
    }
    if (quoted) {
      ++cursor;
    }
  }
  return false;
}

bool HttpApi::parseOtaPartHeaders() {
  char* save = nullptr;
  bool validDisposition = false;
  bool validType = false;
  for (char* line = strtok_r(otaPartHeader_, "\r\n", &save); line != nullptr;
       line = strtok_r(nullptr, "\r\n", &save)) {
    char* separator = std::strchr(line, ':');
    if (separator == nullptr) {
      return false;
    }
    *separator = '\0';
    char* value = trim(separator + 1);
    if (equalsIgnoreCase(line, "Content-Disposition")) {
      char* parameters = std::strchr(value, ';');
      if (parameters == nullptr) {
        return false;
      }
      *parameters++ = '\0';
      char fieldName[16];
      char filename[96];
      if (!equalsIgnoreCase(trim(value), "form-data") ||
          !parseMultipartParameter(parameters, "name", fieldName,
                                   sizeof(fieldName)) ||
          !parseMultipartParameter(parameters, "filename", filename,
                                   sizeof(filename)) ||
          std::strcmp(fieldName, "firmware") != 0 ||
          !endsWithIgnoreCase(filename, ".bin")) {
        return false;
      }
      validDisposition = true;
    } else if (equalsIgnoreCase(line, "Content-Type")) {
      if (!equalsIgnoreCase(value, "application/octet-stream")) {
        return false;
      }
      validType = true;
    }
  }
  return validDisposition && validType;
}

bool HttpApi::handleOtaFileByte(uint8_t byte) {
  const size_t markerLength = multipartBoundaryLength_ + 4;
  for (size_t attempt = 0; attempt < 2; ++attempt) {
    const char expected = otaBoundaryMatchLength_ < 2
                              ? (otaBoundaryMatchLength_ == 0 ? '\r' : '\n')
                              : (otaBoundaryMatchLength_ < 4 ? '-'
                                                             : multipartBoundary_[otaBoundaryMatchLength_ - 4]);
    if (byte == static_cast<uint8_t>(expected)) {
      otaBoundaryMatch_[otaBoundaryMatchLength_++] = static_cast<char>(byte);
      if (otaBoundaryMatchLength_ == markerLength) {
        otaBoundarySuffixLength_ = 0;
        clientState_ = ClientState::OtaBoundarySuffix;
      }
      return true;
    }

    if (otaBoundaryMatchLength_ == 0) {
      return appendOtaFirmwareByte(byte);
    }
    for (size_t index = 0; index < otaBoundaryMatchLength_; ++index) {
      if (!appendOtaFirmwareByte(static_cast<uint8_t>(otaBoundaryMatch_[index]))) {
        return false;
      }
    }
    otaBoundaryMatchLength_ = 0;
  }
  return false;
}

bool HttpApi::appendOtaFirmwareByte(uint8_t byte) {
  otaWriteBuffer_[otaWriteBufferLength_++] = byte;
  if (otaWriteBufferLength_ < sizeof(otaWriteBuffer_)) {
    return true;
  }
  return flushOtaFirmware();
}

bool HttpApi::flushOtaFirmware() {
  if (otaWriteBufferLength_ == 0) {
    return true;
  }
  if (Update.write(otaWriteBuffer_, otaWriteBufferLength_) != otaWriteBufferLength_) {
    captureUpdateError("Firmware write failed");
    otaFailed_ = true;
    return false;
  }
  otaWriteBufferLength_ = 0;
  return true;
}

void HttpApi::captureUpdateError(const char* fallback) {
  const char* message = Update.errorString();
  if (message == nullptr || message[0] == '\0') {
    message = fallback;
  }
  std::snprintf(otaError_, sizeof(otaError_), "%s", message);
}

void HttpApi::resetClient() {
  if (client_) {
    client_.stop();
  }
  clientState_ = ClientState::Idle;
  headerLength_ = 0;
  bodyLength_ = 0;
  expectedBodyLength_ = 0;
  receivedBodyLength_ = 0;
  requestRoute_ = RequestRoute::None;
  authorization_[0] = '\0';
  multipartBoundary_[0] = '\0';
  multipartBoundaryLength_ = 0;
  otaPreambleLength_ = 0;
  otaPartHeaderLength_ = 0;
  otaBoundaryMatchLength_ = 0;
  otaWriteBufferLength_ = 0;
  otaBoundarySuffixLength_ = 0;
}

bool HttpApi::readHeaderByte(char byte) {
  if (headerLength_ == MAX_HEADER_BYTES) {
    sendJsonError(431, "headers_too_large", "Request headers are too large");
    return false;
  }
  header_[headerLength_++] = byte;
  header_[headerLength_] = '\0';
  return headerLength_ >= 4 && header_[headerLength_ - 4] == '\r' &&
         header_[headerLength_ - 3] == '\n' &&
         header_[headerLength_ - 2] == '\r' &&
         header_[headerLength_ - 1] == '\n';
}

void HttpApi::processHeaders() {
  char* save = nullptr;
  char* requestLine = strtok_r(header_, "\r\n", &save);
  if (requestLine == nullptr) {
    sendJsonError(400, "invalid_request", "Malformed request line");
    return;
  }

  char* firstSpace = std::strchr(requestLine, ' ');
  if (firstSpace == nullptr) {
    sendJsonError(400, "invalid_request", "Malformed request line");
    return;
  }
  *firstSpace++ = '\0';
  char* secondSpace = std::strchr(firstSpace, ' ');
  if (secondSpace == nullptr || std::strchr(secondSpace + 1, ' ') != nullptr) {
    sendJsonError(400, "invalid_request", "Malformed request line");
    return;
  }
  *secondSpace = '\0';

  bool contentLengthSeen = false;
  bool contentLengthValid = true;
  bool transferEncodingSeen = false;
  const char* contentType = nullptr;
  for (char* line = strtok_r(nullptr, "\r\n", &save); line != nullptr;
       line = strtok_r(nullptr, "\r\n", &save)) {
    char* separator = std::strchr(line, ':');
    if (separator == nullptr) {
      sendJsonError(400, "invalid_request", "Malformed request header");
      return;
    }
    *separator = '\0';
    char* value = trim(separator + 1);
    if (equalsIgnoreCase(line, "Authorization")) {
      const size_t length = std::strlen(value);
      if (length >= sizeof(authorization_)) {
        authorization_[0] = '\0';
      } else {
        std::memcpy(authorization_, value, length + 1);
      }
    } else if (equalsIgnoreCase(line, "Content-Length")) {
      contentLengthSeen = true;
      contentLengthValid = parseContentLength(value, expectedBodyLength_);
    } else if (equalsIgnoreCase(line, "Transfer-Encoding")) {
      transferEncodingSeen = true;
    } else if (equalsIgnoreCase(line, "Content-Type")) {
      contentType = value;
    }
  }

  const bool isStatus = std::strcmp(requestLine, "GET") == 0 &&
                        std::strcmp(firstSpace, "/api/status") == 0;
  const bool isBuzzer = std::strcmp(requestLine, "POST") == 0 &&
                        std::strcmp(firstSpace, "/api/buzzer") == 0;
  const bool isUpdatePage = std::strcmp(requestLine, "GET") == 0 &&
                            std::strcmp(firstSpace, "/update") == 0;
  const bool isOta = std::strcmp(requestLine, "POST") == 0 &&
                     std::strcmp(firstSpace, "/api/ota") == 0;
  if (isStatus) {
    sendStatus();
    return;
  }
  if (isUpdatePage) {
    sendUpdatePage();
    return;
  }
  if (!isBuzzer && !isOta) {
    sendJsonError(404, "not_found", "Route not found");
    return;
  }
  if (!authorized()) {
    sendJsonError(401, "unauthorized", "Bearer authentication required");
    return;
  }
  if (transferEncodingSeen || !contentLengthSeen || !contentLengthValid) {
    sendJsonError(400, "invalid_request", "Content-Length is required");
    return;
  }
  if (isOta) {
    if (otaInProgress()) {
      sendJsonError(409, "ota_active", "Firmware update is already in progress");
      return;
    }
    requestRoute_ = RequestRoute::Ota;
    beginOtaRequest();
    if (clientState_ == ClientState::Idle) {
      return;
    }
    if (!parseMultipartBoundary(contentType)) {
      failOta("multipart/form-data firmware upload is required");
      finishOtaRequest();
      return;
    }
    if (expectedBodyLength_ == 0) {
      failOta("Firmware upload is empty");
      finishOtaRequest();
    }
    return;
  }
  if (expectedBodyLength_ > MAX_BODY_BYTES) {
    sendJsonError(413, "payload_too_large", "Request body exceeds 128 bytes");
    return;
  }

  requestRoute_ = RequestRoute::Buzzer;
  clientState_ = ClientState::Body;
  bodyLength_ = 0;
  if (expectedBodyLength_ == 0) {
    processBody();
  }
}

void HttpApi::processBody() {
  handleBuzzer();
}

bool HttpApi::sendResponse(int status, const char* body, size_t bodyLength) {
  char responseHeader[160];
  const int headerLength = std::snprintf(
      responseHeader, sizeof(responseHeader),
      "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %u\r\n"
      "Connection: close\r\n\r\n",
      status, statusText(status), static_cast<unsigned int>(bodyLength));
  bool sent = false;
  if (headerLength > 0 && static_cast<size_t>(headerLength) < sizeof(responseHeader)) {
    const size_t headerWritten = client_.write(
        reinterpret_cast<const uint8_t*>(responseHeader),
        static_cast<size_t>(headerLength));
    if (headerWritten == static_cast<size_t>(headerLength)) {
      const size_t bodyWritten = client_.write(
          reinterpret_cast<const uint8_t*>(body), bodyLength);
      sent = bodyWritten == bodyLength;
      if (!sent) {
        client_.stop();
      }
    } else {
      client_.stop();
    }
  }
  resetClient();
  return sent;
}

bool HttpApi::parseCommand(const char* key, char* value, size_t valueSize) const {
  if (valueSize == 0) {
    return false;
  }
  FixedAllocator allocator;
  JsonDocument document(&allocator);
  const DeserializationError error = deserializeJson(
      document, body_, bodyLength_, DeserializationOption::NestingLimit(2));
  if (error || document.overflowed() || !document.is<JsonObject>() ||
      !document[key].is<const char*>()) {
    return false;
  }
  const char* parsed = document[key].as<const char*>();
  const size_t length = std::strlen(parsed);
  if (length >= valueSize) {
    return false;
  }
  for (size_t index = 0; index < length; ++index) {
    value[index] = static_cast<char>(std::tolower(
        static_cast<unsigned char>(parsed[index])));
  }
  value[length] = '\0';
  return true;
}

bool HttpApi::equalsIgnoreCase(const char* left, const char* right) {
  while (*left != '\0' && *right != '\0') {
    if (std::tolower(static_cast<unsigned char>(*left)) !=
        std::tolower(static_cast<unsigned char>(*right))) {
      return false;
    }
    ++left;
    ++right;
  }
  return *left == '\0' && *right == '\0';
}

bool HttpApi::parseContentLength(const char* text, size_t& length) {
  if (*text == '\0') {
    return false;
  }
  size_t parsed = 0;
  for (const char* cursor = text; *cursor != '\0'; ++cursor) {
    if (*cursor < '0' || *cursor > '9' ||
        parsed > (SIZE_MAX - static_cast<size_t>(*cursor - '0')) / 10) {
      return false;
    }
    parsed = parsed * 10 + static_cast<size_t>(*cursor - '0');
  }
  length = parsed;
  return true;
}

char* HttpApi::trim(char* text) {
  while (*text == ' ' || *text == '\t') {
    ++text;
  }
  char* end = text + std::strlen(text);
  while (end > text && (end[-1] == ' ' || end[-1] == '\t')) {
    *--end = '\0';
  }
  return text;
}

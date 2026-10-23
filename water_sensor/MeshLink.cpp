#include "MeshLink.h"

#include <Arduino.h>
#include <Preferences.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <mbedtls/md.h>
#include <mbedtls/pkcs5.h>

#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include <cstring>

namespace {

constexpr uint8_t BROADCAST[ESP_NOW_ETH_ALEN] = {0xFF, 0xFF, 0xFF,
                                                 0xFF, 0xFF, 0xFF};
constexpr UBaseType_t RECEIVE_QUEUE_DEPTH = 4;
// A broadcast is never acknowledged or retried, so each status goes out a few
// times; receivers drop the extra copies as replays.
constexpr uint8_t SEND_COPIES = 3;
constexpr char KEY_LABEL[] = "canary-mesh-v1";

struct Received {
  uint16_t length;
  uint8_t bytes[mesh::MAX_FRAME_BYTES];
};

QueueHandle_t receiveQueue = nullptr;
Received callbackScratch;  // Wi-Fi task only
Received taskScratch;      // MQTT network task only

// Runs on the Wi-Fi task: copy the frame and return without blocking. A full
// queue drops it; the sender's next heartbeat follows.
void onReceive(const esp_now_recv_info_t*, const uint8_t* data, int length) {
  if (length <= 0 || static_cast<size_t>(length) > mesh::MAX_FRAME_BYTES) {
    return;
  }
  callbackScratch.length = static_cast<uint16_t>(length);
  std::memcpy(callbackScratch.bytes, data, callbackScratch.length);
  xQueueSend(receiveQueue, &callbackScratch, 0);
}

bool hmacSha256(const uint8_t* key, size_t keyLength, const uint8_t* data,
                size_t length, uint8_t* output) {
  return mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), key,
                         keyLength, data, length, output) == 0;
}

}  // namespace

bool mesh::computeTag(const uint8_t* key, const uint8_t* data, size_t length,
                      uint8_t* tag) {
  uint8_t digest[32];
  if (!hmacSha256(key, KEY_BYTES, data, length, digest)) {
    return false;
  }
  std::memcpy(tag, digest, TAG_BYTES);
  return true;
}

void MeshLink::begin() {
  Preferences preferences;
  if (preferences.begin("canary-mesh", false)) {
    boot_ = preferences.getUInt("boot", 0) + 1;
    // A boot number that did not stick would make neighbours drop this
    // node's frames as replays, so stay off the mesh instead.
    disabled_ = preferences.putUInt("boot", boot_) != sizeof(boot_);
    preferences.end();
  } else {
    disabled_ = true;
  }
  if (disabled_) {
    Serial.println("[mesh] disabled: boot counter could not be saved");
  }
}

bool MeshLink::start() {
  if (started_ || disabled_) {
    return started_;
  }
  if (!deriveKey()) {
    return false;
  }
  receiveQueue = xQueueCreate(RECEIVE_QUEUE_DEPTH, sizeof(Received));
  esp_now_peer_info_t peer{};
  std::memcpy(peer.peer_addr, BROADCAST, sizeof(BROADCAST));
  peer.ifidx = WIFI_IF_STA;  // channel 0: whichever channel the radio is on
  uint32_t version = 0;
  if (receiveQueue == nullptr || esp_now_init() != ESP_OK ||
      esp_now_get_version(&version) != ESP_OK || version < 2 ||
      esp_now_add_peer(&peer) != ESP_OK ||
      esp_now_register_recv_cb(onReceive) != ESP_OK ||
      esp_wifi_get_mac(WIFI_IF_STA, mac_) != ESP_OK) {
    Serial.println("[mesh] disabled: ESP-NOW v2 did not start");
    disabled_ = true;
    return false;
  }
  started_ = true;
  Serial.printf("[mesh] ESP-NOW backup link ready, boot %lu\n",
                static_cast<unsigned long>(boot_));
  return true;
}

// Every node on the network already knows the Wi-Fi passphrase, so the key
// needs no provisioning. It starts from the WPA2 PMK (PBKDF2, 4096 rounds):
// a captured frame is then no cheaper to brute-force than a captured Wi-Fi
// handshake.
bool MeshLink::deriveKey() {
  wifi_config_t wifi{};
  if (esp_wifi_get_config(WIFI_IF_STA, &wifi) != ESP_OK) {
    return false;  // Wi-Fi not initialised yet
  }
  const size_t passwordLength = strnlen(
      reinterpret_cast<const char*>(wifi.sta.password), sizeof(wifi.sta.password));
  const size_t ssidLength =
      strnlen(reinterpret_cast<const char*>(wifi.sta.ssid), sizeof(wifi.sta.ssid));
  if (passwordLength == 0 || ssidLength == 0) {
    Serial.println("[mesh] disabled: open Wi-Fi gives no key to sign frames");
    disabled_ = true;
    return false;
  }
  uint8_t pmk[32];
  if (mbedtls_pkcs5_pbkdf2_hmac_ext(MBEDTLS_MD_SHA1, wifi.sta.password,
                                    passwordLength, wifi.sta.ssid, ssidLength,
                                    4096, sizeof(pmk), pmk) != 0 ||
      !hmacSha256(pmk, sizeof(pmk),
                  reinterpret_cast<const uint8_t*>(KEY_LABEL),
                  sizeof(KEY_LABEL) - 1, key_)) {
    return false;
  }
  return true;
}

bool MeshLink::send(const char* baseTopic, const char* payload) {
  if (!started_) {
    return false;
  }
  const size_t length = mesh::encode(frame_, key_, mac_, boot_, ++seq_,
                                     baseTopic, payload, std::strlen(payload));
  if (length == 0) {
    Serial.println("[mesh] status does not fit in one ESP-NOW frame");
    return false;
  }
  bool sent = false;
  for (uint8_t copy = 0; copy < SEND_COPIES; ++copy) {
    sent = esp_now_send(BROADCAST, frame_, length) == ESP_OK || sent;
  }
  return sent;
}

bool MeshLink::receive(MeshMessage& message) {
  if (!started_) {
    return false;
  }
  while (xQueueReceive(receiveQueue, &taskScratch, 0) == pdTRUE) {
    std::memcpy(message.bytes, taskScratch.bytes, taskScratch.length);
    message.length = taskScratch.length;
    if (mesh::decode(message.bytes, message.length, key_, message.frame) &&
        std::memcmp(message.frame.origin, mac_, mesh::MAC_BYTES) != 0 &&
        replay_.accept(message.frame.origin, message.frame.boot,
                       message.frame.seq)) {
      return true;
    }
  }
  return false;
}

void MeshLink::forward(MeshMessage& message) {
  if (!started_ || message.frame.ttl == 0) {
    return;
  }
  message.bytes[0] = message.frame.ttl - 1;  // outside the tag
  esp_now_send(BROADCAST, message.bytes, message.length);
}

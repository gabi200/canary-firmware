#pragma once

// Wire format of the ESP-NOW backup link (see MeshLink.h). Pure logic so the
// native tests can cover it. Keep this file identical in water_sensor/ and
// air_sensor/: a node of either kind relays the other's frames.
//
// Offset  Bytes  Field
//      0      1  ttl: rebroadcasts left. Relays change it, so the tag skips it.
//      1      2  magic "CM"
//      3      1  version
//      4      6  origin station MAC
//     10      4  boot: origin's persisted boot counter (little-endian)
//     14      4  seq: frame counter within that boot (little-endian)
//     18      1  topic length T (1..64)
//     19      T  origin MQTT base topic
//   19+T      P  payload: the status JSON, no terminator
//  end-16    16  tag: HMAC-SHA256(key, bytes 1..end-16), first 16 bytes

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace mesh {

constexpr size_t MAX_FRAME_BYTES = 1470;  // ESP-NOW v2 payload limit
constexpr size_t KEY_BYTES = 32;
constexpr size_t TAG_BYTES = 16;
constexpr size_t MAC_BYTES = 6;
constexpr size_t HEADER_BYTES = 19;
constexpr size_t MAX_TOPIC_BYTES = 64;
constexpr uint8_t VERSION = 1;
constexpr uint8_t MAX_TTL = 3;

// HMAC-SHA256(key, data) truncated to TAG_BYTES: mbedTLS on the device
// (MeshLink.cpp), a stand-in in the native tests. False on failure, so a
// frame is never accepted on an uncomputed tag.
bool computeTag(const uint8_t* key, const uint8_t* data, size_t length,
                uint8_t* tag);

struct Frame {
  uint8_t ttl;
  uint8_t origin[MAC_BYTES];
  uint32_t boot;
  uint32_t seq;
  char topic[MAX_TOPIC_BYTES + 1];
  const uint8_t* payload;  // points into the decoded buffer
  size_t payloadLength;
};

inline void put32(uint8_t* output, uint32_t value) {
  for (size_t i = 0; i < 4; ++i) {
    output[i] = static_cast<uint8_t>(value >> (8 * i));
  }
}

inline uint32_t get32(const uint8_t* input) {
  uint32_t value = 0;
  for (size_t i = 0; i < 4; ++i) {
    value |= static_cast<uint32_t>(input[i]) << (8 * i);
  }
  return value;
}

// Writes a signed frame to output (MAX_FRAME_BYTES) and returns its length,
// or 0 when the topic or payload does not fit.
inline size_t encode(uint8_t* output, const uint8_t* key, const uint8_t* origin,
                     uint32_t boot, uint32_t seq, const char* topic,
                     const char* payload, size_t payloadLength) {
  const size_t topicLength = strnlen(topic, MAX_TOPIC_BYTES + 1);
  if (topicLength == 0 || topicLength > MAX_TOPIC_BYTES ||
      payloadLength == 0 || payloadLength > MAX_FRAME_BYTES) {
    return 0;
  }
  const size_t length = HEADER_BYTES + topicLength + payloadLength + TAG_BYTES;
  if (length > MAX_FRAME_BYTES) {
    return 0;
  }
  output[0] = MAX_TTL;
  output[1] = 'C';
  output[2] = 'M';
  output[3] = VERSION;
  std::memcpy(output + 4, origin, MAC_BYTES);
  put32(output + 10, boot);
  put32(output + 14, seq);
  output[18] = static_cast<uint8_t>(topicLength);
  std::memcpy(output + HEADER_BYTES, topic, topicLength);
  std::memcpy(output + HEADER_BYTES + topicLength, payload, payloadLength);
  if (!computeTag(key, output + 1, length - 1 - TAG_BYTES,
                  output + length - TAG_BYTES)) {
    return 0;
  }
  return length;
}

// Accepts only a well-formed frame whose tag matches; frame.payload then
// points into input.
inline bool decode(const uint8_t* input, size_t length, const uint8_t* key,
                   Frame& frame) {
  if (length < HEADER_BYTES + 2 + TAG_BYTES || length > MAX_FRAME_BYTES ||
      input[1] != 'C' || input[2] != 'M' || input[3] != VERSION) {
    return false;
  }
  const size_t topicLength = input[18];
  if (topicLength == 0 || topicLength > MAX_TOPIC_BYTES ||
      HEADER_BYTES + topicLength + 1 + TAG_BYTES > length) {
    return false;
  }
  uint8_t expected[TAG_BYTES];
  if (!computeTag(key, input + 1, length - 1 - TAG_BYTES, expected)) {
    return false;
  }
  uint8_t difference = 0;
  for (size_t i = 0; i < TAG_BYTES; ++i) {
    difference |= expected[i] ^ input[length - TAG_BYTES + i];
  }
  if (difference != 0) {
    return false;
  }
  for (size_t i = 0; i < topicLength; ++i) {
    const char character = static_cast<char>(input[HEADER_BYTES + i]);
    // Not publishable as an MQTT topic name.
    if (character == '\0' || character == '+' || character == '#') {
      return false;
    }
    frame.topic[i] = character;
  }
  frame.topic[topicLength] = '\0';
  frame.ttl = input[0] < MAX_TTL ? input[0] : MAX_TTL;
  std::memcpy(frame.origin, input + 4, MAC_BYTES);
  frame.boot = get32(input + 10);
  frame.seq = get32(input + 14);
  frame.payload = input + HEADER_BYTES + topicLength;
  frame.payloadLength = length - HEADER_BYTES - topicLength - TAG_BYTES;
  return true;
}

// Remembers the newest (boot, seq) heard from each origin. Drops replays and
// also ends a flood: each node accepts, and so forwards, a frame only once.
// ponytail: 32 origins, least recently heard evicted; an evicted origin can
// have one old frame replayed. Raise it if more nodes share a neighbourhood.
class ReplayGuard {
 public:
  bool accept(const uint8_t* origin, uint32_t boot, uint32_t seq) {
    Entry* slot = find(origin);
    if (slot != nullptr &&
        (boot < slot->boot || (boot == slot->boot && seq <= slot->seq))) {
      return false;
    }
    if (slot == nullptr) {
      slot = &entries_[0];
      for (Entry& entry : entries_) {
        if (entry.lastUse < slot->lastUse) {
          slot = &entry;  // unused entries have lastUse 0
        }
      }
      std::memcpy(slot->origin, origin, MAC_BYTES);
    }
    slot->boot = boot;
    slot->seq = seq;
    slot->lastUse = ++clock_;
    return true;
  }

 private:
  struct Entry {
    uint8_t origin[MAC_BYTES];
    uint32_t boot;
    uint32_t seq;
    uint32_t lastUse;
  };

  Entry* find(const uint8_t* origin) {
    for (Entry& entry : entries_) {
      if (entry.lastUse != 0 &&
          std::memcmp(entry.origin, origin, MAC_BYTES) == 0) {
        return &entry;
      }
    }
    return nullptr;
  }

  Entry entries_[32] = {};
  uint32_t clock_ = 0;
};

}  // namespace mesh

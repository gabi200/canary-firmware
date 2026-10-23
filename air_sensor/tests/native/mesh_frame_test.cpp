#include "MeshFrame.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

static int failures = 0;
#define CHECK(expr) do { if (!(expr)) { std::cerr << __func__ << ":" << __LINE__ << " CHECK(" #expr ") failed\n"; ++failures; } } while (0)

// Stand-in for HMAC-SHA256: keyed FNV-1a. Not secure, but any changed key or
// data byte changes the tag, which is all these tests rely on.
bool mesh::computeTag(const uint8_t* key, const uint8_t* data, size_t length,
                      uint8_t* tag) {
  for (size_t half = 0; half < 2; ++half) {
    uint64_t hash = 1469598103934665603ULL ^ half;
    for (size_t i = 0; i < KEY_BYTES + length; ++i) {
      hash = (hash ^ (i < KEY_BYTES ? key[i] : data[i - KEY_BYTES])) *
             1099511628211ULL;
    }
    for (size_t i = 0; i < 8; ++i) {
      tag[half * 8 + i] = static_cast<uint8_t>(hash >> (8 * i));
    }
  }
  return true;
}

namespace {

const uint8_t KEY[mesh::KEY_BYTES] = {1, 2, 3};
const uint8_t OTHER_KEY[mesh::KEY_BYTES] = {9};
const uint8_t ORIGIN[mesh::MAC_BYTES] = {0x24, 0x6F, 0x28, 0xAA, 0xBB, 0xCC};
const char STATUS[] = "{\"sensor\":{\"state\":\"wet\"}}";

size_t encodeStatus(uint8_t* frame, const char* topic = "water-sensor") {
  return mesh::encode(frame, KEY, ORIGIN, 7, 42, topic, STATUS,
                      sizeof(STATUS) - 1);
}

}  // namespace

static void testRoundTripKeepsEveryField() {
  uint8_t frame[mesh::MAX_FRAME_BYTES];
  const size_t length = encodeStatus(frame);
  mesh::Frame decoded{};
  CHECK(length == mesh::HEADER_BYTES + 12 + sizeof(STATUS) - 1 + mesh::TAG_BYTES);
  CHECK(mesh::decode(frame, length, KEY, decoded));
  CHECK(decoded.ttl == mesh::MAX_TTL);
  CHECK(std::memcmp(decoded.origin, ORIGIN, mesh::MAC_BYTES) == 0);
  CHECK(decoded.boot == 7);
  CHECK(decoded.seq == 42);
  CHECK(std::strcmp(decoded.topic, "water-sensor") == 0);
  CHECK(std::string(reinterpret_cast<const char*>(decoded.payload),
                    decoded.payloadLength) == STATUS);
}

static void testTamperedFrameOrWrongKeyIsRejected() {
  // A relay must never publish a status that a key holder did not sign.
  uint8_t frame[mesh::MAX_FRAME_BYTES];
  const size_t length = encodeStatus(frame);
  mesh::Frame decoded{};
  CHECK(!mesh::decode(frame, length, OTHER_KEY, decoded));
  for (size_t i = 1; i < length; ++i) {
    frame[i] ^= 0x01;
    CHECK(!mesh::decode(frame, length, KEY, decoded));
    frame[i] ^= 0x01;
  }
  CHECK(!mesh::decode(frame, length - 1, KEY, decoded));
  CHECK(mesh::decode(frame, length, KEY, decoded));
}

static void testRelaysMayLowerTtlButNotRaiseIt() {
  uint8_t frame[mesh::MAX_FRAME_BYTES];
  const size_t length = encodeStatus(frame);
  mesh::Frame decoded{};
  frame[0] = 1;
  CHECK(mesh::decode(frame, length, KEY, decoded));
  CHECK(decoded.ttl == 1);
  frame[0] = 200;
  CHECK(mesh::decode(frame, length, KEY, decoded));
  CHECK(decoded.ttl == mesh::MAX_TTL);
}

static void testOversizeOrUnpublishableInputIsRefused() {
  uint8_t frame[mesh::MAX_FRAME_BYTES];
  mesh::Frame decoded{};
  const size_t room = mesh::MAX_FRAME_BYTES - mesh::HEADER_BYTES - 1 - mesh::TAG_BYTES;
  const std::string fits(room, 'x');
  const std::string tooBig(room + 1, 'x');
  CHECK(mesh::encode(frame, KEY, ORIGIN, 1, 1, "t", fits.c_str(), fits.size()) ==
        mesh::MAX_FRAME_BYTES);
  CHECK(mesh::encode(frame, KEY, ORIGIN, 1, 1, "t", tooBig.c_str(), tooBig.size()) == 0);
  CHECK(encodeStatus(frame, "") == 0);
  CHECK(encodeStatus(frame, std::string(65, 'a').c_str()) == 0);
  const size_t wildcard = encodeStatus(frame, "home/#");
  CHECK(wildcard != 0);
  CHECK(!mesh::decode(frame, wildcard, KEY, decoded));
}

static void testReplayGuardAcceptsOnlyNewerFrames() {
  // Replays (or the extra copies of one broadcast) must not reach the hub
  // twice, and a rebooted node must be heard again.
  mesh::ReplayGuard guard;
  const uint8_t other[mesh::MAC_BYTES] = {1, 2, 3, 4, 5, 6};
  CHECK(guard.accept(ORIGIN, 5, 10));
  CHECK(!guard.accept(ORIGIN, 5, 10));
  CHECK(!guard.accept(ORIGIN, 5, 9));
  CHECK(guard.accept(ORIGIN, 5, 11));
  CHECK(guard.accept(ORIGIN, 6, 1));
  CHECK(!guard.accept(ORIGIN, 5, 99));
  CHECK(guard.accept(other, 1, 1));
}

static void testReplayGuardEvictsLeastRecentlyHeard() {
  mesh::ReplayGuard guard;
  uint8_t origin[mesh::MAC_BYTES] = {};
  for (uint8_t i = 0; i < 33; ++i) {
    origin[5] = i;
    CHECK(guard.accept(origin, 1, 1));
  }
  origin[5] = 0;
  CHECK(guard.accept(origin, 1, 1));  // evicted, so forgotten
  origin[5] = 32;
  CHECK(!guard.accept(origin, 1, 1));
}

int main() {
  testRoundTripKeepsEveryField();
  testTamperedFrameOrWrongKeyIsRejected();
  testRelaysMayLowerTtlButNotRaiseIt();
  testOversizeOrUnpublishableInputIsRefused();
  testReplayGuardAcceptsOnlyNewerFrames();
  testReplayGuardEvictsLeastRecentlyHeard();
  if (failures) return EXIT_FAILURE;
  std::cout << "Mesh frame tests passed\n";
  return EXIT_SUCCESS;
}

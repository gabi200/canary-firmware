#pragma once

#include "MeshFrame.h"

#include <cstddef>
#include <cstdint>

// ESP-NOW backup path for status documents while a node has no MQTT session.
// Every node listens. A node with a live MQTT session republishes what it
// hears on <origin base>/status; a node without one rebroadcasts it, at most
// mesh::MAX_TTL times. Frames are signed with a key derived from the Wi-Fi
// passphrase, so only devices that know it can inject a status, and replayed
// frames are dropped. Status only: hub commands do not travel over the mesh.
//
// begin() runs on the safety loop because it writes NVS; everything else runs
// on the MQTT network task.
struct MeshMessage {
  uint8_t bytes[mesh::MAX_FRAME_BYTES];
  size_t length;
  mesh::Frame frame;
};

class MeshLink {
 public:
  // Advances the persisted boot counter that keeps replay protection valid
  // across restarts.
  void begin();
  // Starts ESP-NOW once Wi-Fi is up; false while it is not usable. Cheap to
  // call on every pass.
  bool start();
  bool send(const char* baseTopic, const char* payload);
  // Next authenticated frame from another node that was not seen before.
  bool receive(MeshMessage& message);
  // Rebroadcasts a received frame while it has hops left.
  void forward(MeshMessage& message);

 private:
  bool deriveKey();

  uint8_t key_[mesh::KEY_BYTES] = {};
  uint8_t mac_[mesh::MAC_BYTES] = {};
  uint8_t frame_[mesh::MAX_FRAME_BYTES] = {};
  mesh::ReplayGuard replay_;
  uint32_t boot_ = 0;
  uint32_t seq_ = 0;
  bool started_ = false;
  bool disabled_ = false;
};

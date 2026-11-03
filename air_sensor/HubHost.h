#pragma once

#include <cstddef>
#include <cstring>

// Which address the MQTT client tries next. The broker host saved in the portal comes first;
// when it cannot be reached (lookup failed, no TCP connection, timeout), the next attempt uses
// the name the hub announces over mDNS, and so on alternately. A sensor set up with the hub's
// old fixed address therefore finds the hub again after the hotspot subnet changes, without
// re-entering the portal. Refusals from a reachable broker (bad login) never switch hosts.
namespace HubHost {

constexpr char ANNOUNCED_NAME[] = "canary-hub.local";

inline char lowerAscii(char c) {
  return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

inline bool equalsIgnoreCase(const char* a, const char* b) {
  if (a == nullptr || b == nullptr) {
    return false;
  }
  for (; *a != '\0' && *b != '\0'; ++a, ++b) {
    if (lowerAscii(*a) != lowerAscii(*b)) {
      return false;
    }
  }
  return *a == *b;
}

// "name.local" (any case, an optional trailing dot): resolved with an mDNS query.
inline bool isMdnsName(const char* host) {
  if (host == nullptr) {
    return false;
  }
  size_t length = std::strlen(host);
  if (length > 0 && host[length - 1] == '.') {
    --length;
  }
  constexpr size_t suffixLength = sizeof(".local") - 1;
  if (length <= suffixLength) {
    return false;
  }
  const char* suffix = host + length - suffixLength;
  for (size_t i = 0; i < suffixLength; ++i) {
    if (lowerAscii(suffix[i]) != ".local"[i]) {
      return false;
    }
  }
  return true;
}

// Copies the label in front of ".local" ("canary-hub.local" -> "canary-hub"), which is what an
// mDNS host query takes. False when it does not fit or `host` is not an mDNS name.
inline bool mdnsLabel(const char* host, char* output, size_t capacity) {
  if (!isMdnsName(host) || output == nullptr || capacity == 0) {
    return false;
  }
  size_t length = std::strlen(host);
  if (host[length - 1] == '.') {
    --length;
  }
  length -= sizeof(".local") - 1;
  if (length + 1 > capacity) {
    return false;
  }
  std::memcpy(output, host, length);
  output[length] = '\0';
  return true;
}

class Picker {
 public:
  explicit Picker(const char* configured = "") : configured_(configured) {}

  void reset(const char* configured) {
    configured_ = configured == nullptr ? "" : configured;
    useAnnounced_ = false;
  }

  const char* current() const {
    return useAnnounced_ ? ANNOUNCED_NAME : configured_;
  }

  bool usingAnnounced() const { return useAnnounced_; }

  // After a failed attempt: a host that could not be reached hands over to the other one.
  // Nothing changes when the saved host already is the announced name.
  void onFailure(bool unreachable) {
    if (!unreachable || equalsIgnoreCase(configured_, ANNOUNCED_NAME)) {
      return;
    }
    useAnnounced_ = configured_[0] == '\0' ? true : !useAnnounced_;
  }

 private:
  const char* configured_;
  bool useAnnounced_ = false;
};

}  // namespace HubHost

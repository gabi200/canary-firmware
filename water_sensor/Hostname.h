#pragma once

#include <stddef.h>

// Builds an RFC 1123 host label (lowercase letters, digits and inner hyphens)
// from the configured device name so the device can be reached as
// <label>.local over mDNS regardless of the address DHCP assigns.
// Falls back to `fallback` when nothing usable remains.
inline void makeHostname(const char* deviceName,
                         const char* fallback,
                         char* output,
                         size_t capacity) {
  if (output == nullptr || capacity == 0) {
    return;
  }
  size_t length = 0;
  bool pendingHyphen = false;
  for (const char* cursor = deviceName;
       cursor != nullptr && *cursor != '\0' && length + 1 < capacity;
       ++cursor) {
    char c = *cursor;
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
    const bool alphanumeric = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
    if (!alphanumeric) {
      pendingHyphen = length > 0;
      continue;
    }
    if (pendingHyphen) {
      if (length + 2 >= capacity) {
        break;
      }
      output[length++] = '-';
      pendingHyphen = false;
    }
    output[length++] = c;
  }
  output[length] = '\0';
  if (length == 0) {
    size_t index = 0;
    for (; fallback != nullptr && fallback[index] != '\0' &&
           index + 1 < capacity;
         ++index) {
      output[index] = fallback[index];
    }
    output[index] = '\0';
  }
}

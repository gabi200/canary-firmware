#include "Auth.h"

#include <stddef.h>
#include <string.h>

bool authorizeBearer(const char* header, const char* expected) {
  static const char prefix[] = "Bearer ";
  if (!header || !expected || expected[0] == '\0') return false;
  if (strncmp(header, prefix, sizeof(prefix) - 1) != 0) return false;
  const char* supplied = header + sizeof(prefix) - 1;
  const size_t suppliedLen = strnlen(supplied, 65);
  const size_t expectedLen = strnlen(expected, 65);
  unsigned char diff = static_cast<unsigned char>(suppliedLen ^ expectedLen);
  for (size_t i = 0; i < 64; ++i) {
    const unsigned char a = i < suppliedLen ? static_cast<unsigned char>(supplied[i]) : 0;
    const unsigned char b = i < expectedLen ? static_cast<unsigned char>(expected[i]) : 0;
    diff |= static_cast<unsigned char>(a ^ b);
  }
  return diff == 0 && suppliedLen <= 64 && expectedLen <= 64;
}

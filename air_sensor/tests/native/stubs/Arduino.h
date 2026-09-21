#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

class String {
 public:
  String() = default;
  String(const char* value) : value_(value == nullptr ? "" : value) {}

  bool operator==(const char* value) const {
    return value_ == (value == nullptr ? "" : value);
  }

  void toCharArray(char* output, size_t outputSize) const {
    if (outputSize == 0) {
      return;
    }
    std::strncpy(output, value_.c_str(), outputSize - 1);
    output[outputSize - 1] = '\0';
  }

 private:
  std::string value_;
};

class FakeSerial {
 public:
  template <typename T>
  void println(const T&) {}
};


class FakeEsp {
 public:
  uint64_t getEfuseMac() const;
};

extern FakeSerial Serial;
extern FakeEsp ESP;
unsigned long millis();

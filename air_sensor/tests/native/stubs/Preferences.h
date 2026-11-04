#pragma once

#include <cstdint>
#include <cstring>
#include <map>
#include <string>

#include "Arduino.h"

class Preferences {
 public:
  bool begin(const char* name, bool) {
    namespace_ = name == nullptr ? "" : name;
    return true;
  }

  void end() { namespace_.clear(); }

  bool isKey(const char* key) const {
    return values_[namespace_].count(key == nullptr ? "" : key) != 0;
  }

  bool remove(const char* key) {
    return values_[namespace_].erase(key == nullptr ? "" : key) != 0;
  }

  uint8_t getUChar(const char* key, uint8_t fallback = 0) const {
    const Value* value = find(key);
    return value == nullptr || value->type != Value::Type::U8 ? fallback
                                                               : value->ucharValue;
  }

  bool getBool(const char* key, bool fallback = false) const {
    const Value* value = find(key);
    return value == nullptr || value->type != Value::Type::U8 ? fallback
                                                               : value->ucharValue != 0;
  }

  uint16_t getUShort(const char* key, uint16_t fallback = 0) const {
    const Value* value = find(key);
    return value == nullptr || value->type != Value::Type::U16 ? fallback
                                                               : value->ushortValue;
  }

  unsigned long getULong(const char* key, unsigned long fallback = 0) const {
    const Value* value = find(key);
    return value == nullptr || value->type != Value::Type::U32 ? fallback
                                                               : value->ulongValue;
  }

  String getString(const char* key, const char* fallback = "") const {
    const Value* value = find(key);
    return String(value == nullptr || value->type != Value::Type::String
                      ? fallback
                      : value->stringValue.c_str());
  }

  size_t putUChar(const char* key, uint8_t value) {
    Value& entry = values_[namespace_][key == nullptr ? "" : key];
    entry.type = Value::Type::U8;
    entry.ucharValue = value;
    return sizeof(value);
  }

  size_t putBool(const char* key, bool value) {
    if (failBoolWrite_) { failBoolWrite_ = false; return 0; }
    Value& entry = values_[namespace_][key == nullptr ? "" : key];
    entry.type = Value::Type::U8;
    entry.ucharValue = value ? 1 : 0;
    return sizeof(value);
  }

  size_t putUShort(const char* key, uint16_t value) {
    Value& entry = values_[namespace_][key == nullptr ? "" : key];
    entry.type = Value::Type::U16;
    entry.ushortValue = value;
    return sizeof(value);
  }

  size_t putULong(const char* key, unsigned long value) {
    Value& entry = values_[namespace_][key == nullptr ? "" : key];
    entry.type = Value::Type::U32;
    entry.ulongValue = value;
    return sizeof(value);
  }

  size_t putString(const char* key, const char* value) {
    Value& entry = values_[namespace_][key == nullptr ? "" : key];
    entry.type = Value::Type::String;
    entry.stringValue = value == nullptr ? "" : value;
    return entry.stringValue.size();
  }

  static void failNextBoolWriteForTest() { failBoolWrite_ = true; }
  static void resetForTest() { values_.clear(); failBoolWrite_ = false; }

 private:
  struct Value {
    enum class Type { U8, U16, U32, String };

    Type type = Type::U8;
    uint8_t ucharValue = 0;
    uint16_t ushortValue = 0;
    unsigned long ulongValue = 0;
    std::string stringValue;
  };

  const Value* find(const char* key) const {
    const auto namespaceIt = values_.find(namespace_);
    if (namespaceIt == values_.end()) {
      return nullptr;
    }
    const auto valueIt = namespaceIt->second.find(key == nullptr ? "" : key);
    return valueIt == namespaceIt->second.end() ? nullptr : &valueIt->second;
  }

  inline static bool failBoolWrite_ = false;
  std::string namespace_;
  inline static std::map<std::string, std::map<std::string, Value>> values_;
};

#include "StatusJson.h"

#include "HardwareConfig.h"

#include <ArduinoJson.h>

#include <cstddef>
#include <cstring>

namespace {

const char* sensorStateName(SensorState state) {
  switch (state) {
    case SensorState::Dry:
      return "dry";
    case SensorState::Wet:
      return "wet";
    case SensorState::Uninitialized:
    default:
      return "uninitialized";
  }
}

const char* valveStateName(ValveState state) {
  return state == ValveState::Open ? "open" : "closed";
}

const char* alarmStateName(AlarmState state) {
  switch (state) {
    case AlarmState::Sounding:
      return "sounding";
    case AlarmState::Silenced:
      return "silenced";
    case AlarmState::TimedOut:
      return "timed_out";
    case AlarmState::Inactive:
    default:
      return "inactive";
  }
}

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

  static constexpr size_t DOCUMENT_BYTES = 2048;
  static constexpr size_t MAX_ALLOCS = 16;

  static size_t align(size_t value) {
    const size_t alignment = alignof(std::max_align_t);
    return (value + alignment - 1) & ~(alignment - 1);
  }

  alignas(std::max_align_t) uint8_t storage_[DOCUMENT_BYTES]{};
  Allocation allocations_[MAX_ALLOCS]{};
  size_t offset_ = 0;
  size_t allocationCount_ = 0;
};

}  // namespace

String buildStatusJson(const DeviceConfig& config,
                       const LeakController& controller,
                       const RuntimeStatus& runtime,
                       uint32_t nowMs) {
  char serialized[STATUS_JSON_MAX_BYTES];
  if (!buildStatusJson(config, controller, runtime, nowMs, serialized,
                       sizeof(serialized))) {
    return String("{\"error\":\"status_unavailable\"}");
  }
  String output;
  output.reserve(STATUS_JSON_MAX_BYTES);
  output = serialized;
  return output;
}

bool buildStatusJson(const DeviceConfig& config,
                     const LeakController& controller,
                     const RuntimeStatus& runtime,
                     uint32_t nowMs,
                     char* output,
                     size_t outputSize) {
  if (output == nullptr || outputSize == 0) {
    return false;
  }
  FixedAllocator allocator;
  JsonDocument document(&allocator);
  const SensorState sensorState = controller.sensorState();
  const AlarmState alarmState = controller.alarmState(nowMs);
  const uint32_t alarmRemainingMs = controller.alarmRemainingMs(nowMs);
  const PersistentState persistent = controller.persistentState();

  JsonObject device = document["device"].to<JsonObject>();
  device["name"] = config.deviceName;
  device["firmware"] = Hardware::FIRMWARE_VERSION;
  document["uptime_ms"] = runtime.uptimeMs;

  JsonObject sensor = document["sensor"].to<JsonObject>();
  sensor["adc"] = runtime.sensorAdc;
  sensor["initialized"] = sensorState != SensorState::Uninitialized;
  sensor["state"] = sensorStateName(sensorState);
  sensor["wet_threshold"] = config.wetThreshold;
  sensor["dry_threshold"] = config.dryThreshold;

  document["leak_latched"] = controller.leakLatched();

  JsonObject valve = document["valve"].to<JsonObject>();
  valve["requested"] = valveStateName(persistent.requestedValve);
  valve["applied"] = valveStateName(controller.valveState());
  valve["relay_active"] = controller.valveState() == ValveState::Closed;

  JsonObject alarm = document["alarm"].to<JsonObject>();
  alarm["state"] = alarmStateName(alarmState);
  alarm["sounding"] = alarmState == AlarmState::Sounding;
  alarm["remaining_seconds"] = (alarmRemainingMs + 999UL) / 1000UL;

  JsonObject wifi = document["wifi"].to<JsonObject>();
  wifi["connected"] = runtime.wifiConnected;
  wifi["rssi"] = runtime.wifiRssi;

  JsonObject mqtt = document["mqtt"].to<JsonObject>();
  mqtt["enabled"] = config.mqttEnabled;
  mqtt["connected"] = runtime.mqttConnected;

  JsonObject ota = document["ota"].to<JsonObject>();
  ota["in_progress"] = runtime.otaInProgress;

  if (document.overflowed()) {
    return false;
  }
  const size_t requiredSize = measureJson(document);
  if (requiredSize >= outputSize) {
    return false;
  }
  return serializeJson(document, output, outputSize) == requiredSize;
}

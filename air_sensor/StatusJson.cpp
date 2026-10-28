#include "StatusJson.h"

#include "HardwareConfig.h"

#include <ArduinoJson.h>

#include <cstddef>
#include <cstdio>
#include <cstring>

namespace {

uint32_t toSeconds(uint32_t milliseconds) {
  return (milliseconds + 999UL) / 1000UL;
}

float toTenths(int32_t tenths) {
  return static_cast<float>(tenths) / 10.0f;
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

  static constexpr size_t DOCUMENT_BYTES = 4096;
  static constexpr size_t MAX_ALLOCS = 24;

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

const char* channelStateName(ChannelState state) {
  switch (state) {
    case ChannelState::Ok:
      return "ok";
    case ChannelState::Warning:
      return "warning";
    case ChannelState::Danger:
      return "danger";
    case ChannelState::Fault:
      return "fault";
    case ChannelState::Warmup:
    default:
      return "warmup";
  }
}

const char* hazardName(Hazard hazard) {
  switch (hazard) {
    case Hazard::CarbonMonoxide:
      return "co";
    case Hazard::Gas:
      return "gas";
    case Hazard::Particulate:
      return "particulate";
    case Hazard::None:
    default:
      return "none";
  }
}

const char* alarmStateName(AlarmState state) {
  switch (state) {
    case AlarmState::Warning:
      return "warning";
    case AlarmState::Sounding:
      return "sounding";
    case AlarmState::Silenced:
      return "silenced";
    case AlarmState::Inactive:
    default:
      return "inactive";
  }
}

String buildStatusJson(const DeviceConfig& config,
                       const AirController& controller,
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
                     const AirController& controller,
                     const RuntimeStatus& runtime,
                     uint32_t nowMs,
                     char* output,
                     size_t outputSize) {
  if (output == nullptr || outputSize == 0) {
    return false;
  }
  FixedAllocator allocator;
  JsonDocument document(&allocator);
  const AlarmState alarmState = controller.alarmState();
  const ParticulateReading& particulate = controller.particulate();
  const LedColor ledColor = controller.ledColor(nowMs);

  JsonObject device = document["device"].to<JsonObject>();
  device["name"] = config.deviceName;
  device["firmware"] = Hardware::FIRMWARE_VERSION;
  document["uptime_ms"] = runtime.uptimeMs;
  document["warmup_remaining_seconds"] =
      toSeconds(controller.warmupRemainingMs(nowMs));

  JsonObject co = document["co"].to<JsonObject>();
  co["ppm"] = controller.co().ppm;
  co["peak_ppm"] = controller.coPeakPpm();
  co["state"] = channelStateName(controller.coState());
  co["warn_ppm"] = config.coWarnPpm;
  co["danger_ppm"] = config.coDangerPpm;
  co["valid"] = controller.coFresh(nowMs);
  co["age_ms"] = controller.coAgeMs(nowMs);

  JsonObject gas = document["gas"].to<JsonObject>();
  gas["adc"] = controller.gasAdc();
  gas["peak_adc"] = controller.gasPeakAdc();
  gas["state"] = channelStateName(controller.gasState());
  gas["warn_adc"] = config.gasWarnAdc;
  gas["danger_adc"] = config.gasDangerAdc;

  JsonObject pm = document["particulate"].to<JsonObject>();
  pm["pm1_0"] = particulate.pm1_0;
  pm["pm2_5"] = particulate.pm2_5;
  pm["pm10"] = particulate.pm10;
  pm["peak_pm2_5"] = controller.pm25PeakUgm3();
  pm["peak_pm10"] = controller.pm10PeakUgm3();
  pm["state"] = channelStateName(controller.particulateState());
  pm["warn_pm2_5"] = config.pm25WarnUgm3;
  pm["danger_pm2_5"] = config.pm25DangerUgm3;
  pm["warn_pm10"] = config.pm10WarnUgm3;
  pm["danger_pm10"] = config.pm10DangerUgm3;
  pm["valid"] = controller.particulateFresh(nowMs);
  pm["age_ms"] = controller.particulateAgeMs(nowMs);

  JsonObject climate = document["climate"].to<JsonObject>();
  climate["temperature_c"] = toTenths(runtime.climate.value.temperatureTenthsC);
  climate["humidity_percent"] =
      toTenths(static_cast<int32_t>(runtime.climate.value.humidityTenthsPercent));
  climate["valid"] = runtime.climate.valid;
  climate["age_ms"] = runtime.climate.ageMs;

  JsonObject presence = document["presence"].to<JsonObject>();
  presence["detected"] = runtime.presence.value.detected;
  presence["moving"] = runtime.presence.value.moving;
  presence["stationary"] = runtime.presence.value.stationary;
  presence["moving_distance_cm"] = runtime.presence.value.movingDistanceCm;
  presence["moving_energy"] = runtime.presence.value.movingEnergy;
  presence["stationary_distance_cm"] =
      runtime.presence.value.stationaryDistanceCm;
  presence["stationary_energy"] = runtime.presence.value.stationaryEnergy;
  presence["detection_distance_cm"] =
      runtime.presence.value.detectionDistanceCm;
  presence["valid"] = runtime.presence.valid;
  presence["age_ms"] = runtime.presence.ageMs;

  JsonObject gasDetector = document["gas_detector"].to<JsonObject>();
  gasDetector["alarm"] = runtime.gasDetectorAlarm;

  JsonObject alarm = document["alarm"].to<JsonObject>();
  alarm["state"] = alarmStateName(alarmState);
  alarm["hazard"] = hazardName(controller.alarmHazard());
  alarm["sounding"] = alarmState == AlarmState::Sounding;
  alarm["silence_remaining_seconds"] =
      toSeconds(controller.silenceRemainingMs(nowMs));
  alarm["self_test"] = controller.selfTestActive(nowMs);
  alarm["led_color"] = ledColorName(ledColor);
  alarm["led_on"] = controller.ledOn(nowMs);

  JsonObject wifi = document["wifi"].to<JsonObject>();
  wifi["connected"] = runtime.wifiConnected;
  wifi["rssi"] = runtime.wifiRssi;
  if (runtime.wifiConnected && runtime.wifiIp != 0) {
    // the hub suggests this address for firmware pushes (staff confirm it there)
    char ip[16];
    std::snprintf(ip, sizeof(ip), "%u.%u.%u.%u",
                  static_cast<unsigned>(runtime.wifiIp & 0xFF),
                  static_cast<unsigned>((runtime.wifiIp >> 8) & 0xFF),
                  static_cast<unsigned>((runtime.wifiIp >> 16) & 0xFF),
                  static_cast<unsigned>(runtime.wifiIp >> 24));
    wifi["ip"] = ip;
  }

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

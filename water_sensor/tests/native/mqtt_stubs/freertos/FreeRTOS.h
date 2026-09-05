#pragma once

#include <cstdint>

using BaseType_t = int;
using UBaseType_t = unsigned int;

constexpr BaseType_t pdFALSE = 0;
constexpr BaseType_t pdTRUE = 1;
constexpr BaseType_t pdPASS = 1;
constexpr UBaseType_t tskIDLE_PRIORITY = 0;

#define pdMS_TO_TICKS(milliseconds) (milliseconds)

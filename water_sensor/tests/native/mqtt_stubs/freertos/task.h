#pragma once

#include "FreeRTOS.h"

using TaskFunction_t = void (*)(void*);
using TaskHandle_t = void*;

BaseType_t xTaskCreate(TaskFunction_t task, const char* name,
                       uint32_t stackBytes, void* context,
                       UBaseType_t priority, TaskHandle_t* output);
void vTaskDelay(uint32_t ticks);

#pragma once

#include "FreeRTOS.h"

struct FakeSemaphore {
  bool available;
};

using SemaphoreHandle_t = FakeSemaphore*;

SemaphoreHandle_t xSemaphoreCreateMutex();
BaseType_t xSemaphoreTake(SemaphoreHandle_t semaphore, uint32_t ticksToWait);
BaseType_t xSemaphoreGive(SemaphoreHandle_t semaphore);

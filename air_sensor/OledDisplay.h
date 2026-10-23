#pragma once

#include "DisplayModel.h"

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

// SSD1306 driver on its own low-priority task. I2C transfers, and a bus a
// broken display holds down, must never delay the safety loop: the loop only
// copies a small DisplayInput snapshot under a spinlock, and the task composes
// and draws it.
class OledDisplay {
 public:
  // Probes the bus and starts the task. False (and nothing running) when no
  // display answers, so the sensor works unchanged without one.
  bool begin(const char* firmwareVersion);
  // Safety loop: hands over the newest snapshot. Never touches I2C.
  void publish(const DisplayInput& input);

 private:
  static void taskStatic(void* context);
  void task();
  void draw(const DisplayScreen& screen);

  portMUX_TYPE lock_ = portMUX_INITIALIZER_UNLOCKED;
  DisplayInput shared_{};
  bool published_ = false;
  TaskHandle_t taskHandle_ = nullptr;
};

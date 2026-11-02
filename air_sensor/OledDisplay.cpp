#include "OledDisplay.h"

#include "HardwareConfig.h"

#include <U8g2lib.h>
#include <Wire.h>

#include <cstdio>

namespace {

constexpr uint32_t TASK_STACK_BYTES = 4096;
constexpr UBaseType_t TASK_PRIORITY = 1;  // below the loop task and the network tasks
constexpr uint8_t WIDTH = 128;

// Landscape, rotated 180° (U8G2_R2) to match how the panel is mounted.
// Full frame buffer: one 1 KB sendBuffer() per refresh. With the clock and
// data pins given, U8g2 begins Wire on them itself.
U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(U8G2_R2, U8X8_PIN_NONE,
                                          Hardware::DISPLAY_SCL_PIN,
                                          Hardware::DISPLAY_SDA_PIN);

void drawCentered(const char* text, uint8_t baseline) {
  const int width = u8g2.getStrWidth(text);
  u8g2.drawStr(width >= WIDTH ? 0 : (WIDTH - width) / 2, baseline, text);
}

}  // namespace

bool OledDisplay::begin(const char* firmwareVersion) {
  if (!Hardware::DISPLAY_ENABLED) {
    return false;
  }
  Wire.begin(Hardware::DISPLAY_SDA_PIN, Hardware::DISPLAY_SCL_PIN,
             Hardware::DISPLAY_I2C_HZ);
  Wire.beginTransmission(Hardware::DISPLAY_I2C_ADDRESS);
  if (Wire.endTransmission() != 0) {
    Serial.printf("[display] no SSD1306 at 0x%02X; display off\n",
                  Hardware::DISPLAY_I2C_ADDRESS);
    return false;
  }
  u8g2.setI2CAddress(Hardware::DISPLAY_I2C_ADDRESS << 1);  // U8g2 takes the 8-bit form
  u8g2.setBusClock(Hardware::DISPLAY_I2C_HZ);
  u8g2.begin();

  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_helvB14_tr);
  drawCentered("Canary", 30);
  u8g2.setFont(u8g2_font_6x10_tr);
  char version[24];
  std::snprintf(version, sizeof(version), "air sensor %s", firmwareVersion);
  drawCentered(version, 46);
  u8g2.sendBuffer();

  if (xTaskCreate(taskStatic, "oled-display", TASK_STACK_BYTES, this,
                  TASK_PRIORITY, &taskHandle_) != pdPASS) {
    Serial.println("[display] task creation failed; display off");
    return false;
  }
  Serial.println("[display] SSD1306 ready");
  return true;
}

void OledDisplay::publish(const DisplayInput& input) {
  portENTER_CRITICAL(&lock_);
  shared_ = input;
  published_ = true;
  portEXIT_CRITICAL(&lock_);
}

void OledDisplay::taskStatic(void* context) {
  static_cast<OledDisplay*>(context)->task();
}

void OledDisplay::task() {
  for (;;) {
    DisplayInput input;
    portENTER_CRITICAL(&lock_);
    input = shared_;
    const bool ready = published_;
    portEXIT_CRITICAL(&lock_);
    if (ready) {
      draw(composeScreen(input, millis()));
    }
    vTaskDelay(pdMS_TO_TICKS(Hardware::DISPLAY_REFRESH_MS));
  }
}

void OledDisplay::draw(const DisplayScreen& screen) {
  u8g2.clearBuffer();
  u8g2.setDrawColor(1);
  u8g2.setFont(u8g2_font_5x7_tr);
  u8g2.drawStr(0, 7, screen.status);
  u8g2.drawHLine(0, 9, WIDTH);

  if (screen.alert) {
    if (screen.inverted) {
      u8g2.drawBox(0, 11, WIDTH, 53);
      u8g2.setDrawColor(0);
    }
    u8g2.setFont(u8g2_font_helvB14_tr);
    drawCentered(screen.headline, 28);
    u8g2.setFont(u8g2_font_6x10_tr);
    for (uint8_t i = 0; i < 3; ++i) {
      drawCentered(screen.lines[i], 40 + i * 11);
    }
    u8g2.setDrawColor(1);
  } else {
    u8g2.setFont(u8g2_font_6x10_tr);
    for (uint8_t i = 0; i < DISPLAY_LINES; ++i) {
      u8g2.drawStr(0, 20 + i * 10, screen.lines[i]);
    }
    u8g2.setFont(u8g2_font_5x7_tr);
    u8g2.drawStr(0, 63, screen.footer);
  }
  u8g2.sendBuffer();
}

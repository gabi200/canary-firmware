#pragma once

#include "OutputLogic.h"

#include <Arduino.h>

// UART0 carries the CO sensor, so the USB CDC console must own the debug port.
// Without this the sketch would silently compile with Serial bound to UART0 and
// the CO sensor would never be read.
#if !defined(ARDUINO_USB_CDC_ON_BOOT) || ARDUINO_USB_CDC_ON_BOOT != 1
#error "Build with USB CDC On Boot enabled: UART0 is wired to the ZE03-CO sensor."
#endif

namespace Hardware {

// Winsen ZE03-CO on UART0. Sensor TX -> CO_RX_PIN, sensor RX -> CO_TX_PIN.
constexpr uint8_t CO_UART = 0;
constexpr int8_t CO_RX_PIN = 17;
constexpr int8_t CO_TX_PIN = 18;
constexpr uint32_t CO_BAUD = 9600;

// HLK-LD2410 presence radar on UART1. Report frames are read but never
// answered, so the radar needs no configuration. GPIO15/16 double as the
// 32.768 kHz crystal pins, which matters only on a board that fits one.
constexpr uint8_t PRESENCE_UART = 1;
constexpr int8_t PRESENCE_RX_PIN = 15;
constexpr int8_t PRESENCE_TX_PIN = 16;
// LD2410B and LD2410C leave the factory at 256000. A plain LD2410 built to
// protocol revision V1.03 ships at 57600 instead. If presence frames never
// arrive, change this before suspecting the wiring.
constexpr uint32_t PRESENCE_BAUD = 256000;

// Plantower PMS5003T on UART2.
constexpr uint8_t PARTICULATE_UART = 2;
constexpr int8_t PARTICULATE_RX_PIN = 13;
constexpr int8_t PARTICULATE_TX_PIN = 14;
constexpr uint32_t PARTICULATE_BAUD = 9600;

// MQ5 analog output. GPIO10 is ADC1_CH9, and ADC1 keeps working while Wi-Fi
// is active (ADC2 does not). At the default 11 dB attenuation the usable input
// range is about 0-2.9 V, not 0-3.3 V: anything above that reads as full
// scale. Size the divider so the MQ5's full 5 V swing lands at or below 2.5 V.
constexpr uint8_t GAS_ADC_PIN = 10;

// NC dry contact of an external household gas detector (GasDetectorInput):
// COM -> GND, NC -> 1 kOhm -> GPIO11, 33 nF from GPIO11 to GND. The internal
// pull-up is enabled; an external 10 kOhm to 3.3 V may be added. LOW = normal,
// HIGH = detector alarm or open wiring. GPIO11 is free, not a strapping pin,
// and sits next to the MQ5 pin on the DevKitC-1 header. (The ESP32-S3 has no
// GPIO25.) Read only: this firmware never drives the detector or its valve.
constexpr uint8_t GAS_DETECTOR_PIN = 11;
constexpr uint32_t GAS_DETECTOR_DEBOUNCE_MS = 200;
// Internal pull-up (~45 kOhm) x 33 nF is ~1.5 ms; wait well past that before
// the boot reading.
constexpr uint32_t GAS_DETECTOR_SETTLE_MS = 10;

// WARNING - check the module part number before using the alternative pins.
// GPIO33-GPIO37 carry the extra data lines of an in-package Octal SPI PSRAM.
// On any module whose suffix is R8 or R16V (N8R8, N16R8, N16R16VA, every
// WROOM-2), GPIO35/36/37 are wired to that PSRAM and are NOT usable, even
// though the DevKitC-1 silkscreen exposes them on J3. Every Espressif-branded
// ESP32-S3-DevKitC-1 SKU ships with Octal PSRAM. analogWrite() to a blocked
// pin fails silently: no light, no error.
//
// Modules with Quad PSRAM or no PSRAM (N4, N8, N16, N4R2, N8R2, N16R2) leave
// these pins free.
//
// The compiled set avoids GPIO35-37, so it works on every module. GPIO48 also
// drives the onboard addressable RGB LED on DevKitC-1 v1.0, and on R16V
// modules GPIO47/48 switch at 1.8 V.
// Octal-PSRAM-safe pin set, matching this unit's physical wiring.
constexpr uint8_t LED_RED_PIN = 21;
constexpr uint8_t LED_GREEN_PIN = 47;
constexpr uint8_t LED_BLUE_PIN = 48;
// Original pin set, only for modules with Quad PSRAM or no PSRAM. GPIO38 also
// drives the onboard addressable RGB LED on DevKitC-1 v1.1:
// constexpr uint8_t LED_RED_PIN = 37;
// constexpr uint8_t LED_GREEN_PIN = 36;
// constexpr uint8_t LED_BLUE_PIN = 38;
constexpr bool LED_COMMON_ANODE = false;
constexpr uint32_t LED_PWM_FREQUENCY_HZ = 5000;
constexpr uint8_t LED_PWM_RESOLUTION_BITS = 8;

// GPIO39 is MTCK, which has a weak internal pull-up enabled at reset. On an
// active-high buzzer stage that can sound briefly from power-on until setup()
// drives the pin low. Add an external pull-down if the chirp is unwanted.
constexpr uint8_t BUZZER_PIN = 39;
constexpr bool BUZZER_ACTIVE_HIGH = true;

// GPIO0 is the ESP32-S3 boot strapping pin, so it cannot be held during reset
// without entering the ROM download mode. A hold while the firmware runs
// restarts into the setup portal instead.
constexpr uint8_t CONFIG_BUTTON_PIN = 0;
constexpr bool CONFIG_BUTTON_ACTIVE_LOW = true;
constexpr uint32_t CONFIG_BUTTON_HOLD_MS = 3000;

// Optional SSD1306 128x64 OLED on I2C (OledDisplay). GPIO8/9 are the
// ESP32-S3 Arduino Wire defaults and are not strapping pins. A display that
// does not answer at boot is simply left off; nothing else depends on it.
constexpr bool DISPLAY_ENABLED = true;
constexpr int8_t DISPLAY_SDA_PIN = 8;
constexpr int8_t DISPLAY_SCL_PIN = 9;
// 0x3C on most modules; 0x3D when the module's address jumper is moved.
constexpr uint8_t DISPLAY_I2C_ADDRESS = 0x3C;
constexpr uint32_t DISPLAY_I2C_HZ = 400000;
// A full frame is ~1 KB, about 25 ms at 400 kHz, sent by the display task.
constexpr uint32_t DISPLAY_REFRESH_MS = 250;

// Some ZE03 units are found in question-and-answer mode, where they stay
// silent until polled. Nudging a quiet sensor back to active upload costs one
// 9-byte write and turns a permanently dead channel into a working one.
constexpr bool CO_SEND_RECOVERY_COMMAND = true;
constexpr uint32_t CO_RECOVERY_INTERVAL_MS = 10000;

// The PMS5003T's own laser and fan warm the air passing through it, and the
// module's temperature and humidity calibration is known to vary between
// production batches, so the reading gets a correction knob rather than being
// trusted raw. Both are in tenths and are added to the sensor value; measure
// against a reference before changing them.
// ponytail: offset only. A unit that needs gain as well (AirGradient publishes
// T x 1.181 - 5.113 above 10 C and RH x 1.259 + 7.34 for their enclosure)
// needs a multiplier added in calibratedClimate().
constexpr int16_t CLIMATE_TEMPERATURE_OFFSET_TENTHS_C = 0;
constexpr int16_t CLIMATE_HUMIDITY_OFFSET_TENTHS_PERCENT = 0;

constexpr uint32_t GAS_SAMPLE_INTERVAL_MS = 50;
constexpr uint8_t GAS_AVERAGE_SAMPLES = 16;

// A UART sensor that stops producing valid frames for this long is reported as
// faulted. Covers a 1 Hz CO frame and a ~1 Hz particulate frame with margin.
constexpr uint32_t SENSOR_TIMEOUT_MS = 15000;
constexpr uint32_t PRESENCE_TIMEOUT_MS = 3000;

constexpr uint32_t ALARM_TRIGGER_HOLD_MS = 3000;
constexpr uint32_t ALARM_CLEAR_HOLD_MS = 30000;
constexpr uint32_t SELF_TEST_MS = 4000;

// Per-loop input bound, mirroring the HTTP transport's own work limit so one
// chatty sensor cannot starve the safety loop.
constexpr size_t UART_BYTES_PER_LOOP = 192;

// The hardware FIFO is 128 bytes and the radar alone streams at 256000 baud,
// so the driver buffer is widened to survive a slow pass through loop().
constexpr size_t UART_RX_BUFFER_BYTES = 1024;

// Warm-up resume after a short power cut (WarmupResume.h). Only applies once
// SNTP has set the clock this boot. The MQ5 heater and the ZE03 cell both read
// high for a while after power returns, and the PMS5003 fan needs ~30 s, so a
// short residual warm-up stays instead of skipping it outright. The alive
// stamp is written to NVS on this interval while the clock is set; a stale
// stamp only overstates the gap, so it can cost a resume, never fake one.
constexpr uint32_t QUICK_RESTART_MAX_OFF_SECONDS = 30;
constexpr uint32_t QUICK_RESTART_WARMUP_MS = 60000;
constexpr uint32_t ALIVE_STAMP_INTERVAL_MS = 10000;
// Used when no MQTT host (the hub) is configured to answer NTP.
constexpr char FALLBACK_NTP_SERVER[] = "pool.ntp.org";

constexpr uint32_t CONFIG_SAVE_RETRY_MS = 1000;
constexpr uint32_t CONFIG_REBOOT_DELAY_MS = 500;

constexpr char FIRMWARE_VERSION[] = "1.1.0";

inline uint8_t outputLevel(bool active, bool activeHigh) {
  return activeLevelFor(active, activeHigh) ? HIGH : LOW;
}

}  // namespace Hardware

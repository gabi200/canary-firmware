#include "GasDetectorInput.h"

#include <iostream>

static int failures = 0;
#define CHECK(expr) do { if (!(expr)) { std::cerr << __func__ << ":" << __LINE__ << " CHECK(" #expr ") failed\n"; ++failures; } } while (0)

namespace {

constexpr uint32_t DEBOUNCE_MS = 200;
constexpr bool OPEN = true;
constexpr bool CLOSED = false;

void testBootStateIsTakenImmediately() {
  GasDetectorInput closedAtBoot(DEBOUNCE_MS);
  closedAtBoot.begin(CLOSED, 0);
  CHECK(!closedAtBoot.alarmActive());

  GasDetectorInput openAtBoot(DEBOUNCE_MS);
  openAtBoot.begin(OPEN, 0);
  CHECK(openAtBoot.alarmActive());
  CHECK(openAtBoot.update(OPEN, 10) == GasDetectorEvent::None);
}

void testOpenContactRaisesAfterDebounce() {
  GasDetectorInput input(DEBOUNCE_MS);
  input.begin(CLOSED, 1000);
  CHECK(input.update(OPEN, 1100) == GasDetectorEvent::None);
  CHECK(input.update(OPEN, 1299) == GasDetectorEvent::None);
  CHECK(!input.alarmActive());
  CHECK(input.update(OPEN, 1300) == GasDetectorEvent::AlarmRaised);
  CHECK(input.alarmActive());
  CHECK(input.update(OPEN, 1400) == GasDetectorEvent::None);

  CHECK(input.update(CLOSED, 2000) == GasDetectorEvent::None);
  CHECK(input.alarmActive());
  CHECK(input.update(CLOSED, 2200) == GasDetectorEvent::AlarmCleared);
  CHECK(!input.alarmActive());
}

void testBounceRestartsTheDebounce() {
  GasDetectorInput input(DEBOUNCE_MS);
  input.begin(CLOSED, 0);
  CHECK(input.update(OPEN, 100) == GasDetectorEvent::None);
  CHECK(input.update(CLOSED, 250) == GasDetectorEvent::None);
  CHECK(input.update(OPEN, 260) == GasDetectorEvent::None);
  // 300 ms after the first edge, but only 40 ms after the last bounce
  CHECK(input.update(OPEN, 300) == GasDetectorEvent::None);
  CHECK(!input.alarmActive());
  CHECK(input.update(OPEN, 460) == GasDetectorEvent::AlarmRaised);
}

void testGlitchShorterThanDebounceIsIgnored() {
  GasDetectorInput input(DEBOUNCE_MS);
  input.begin(CLOSED, 0);
  CHECK(input.update(OPEN, 100) == GasDetectorEvent::None);
  CHECK(input.update(CLOSED, 150) == GasDetectorEvent::None);
  CHECK(input.update(CLOSED, 1000) == GasDetectorEvent::None);
  CHECK(!input.alarmActive());
}

void testMillisWraparound() {
  GasDetectorInput input(DEBOUNCE_MS);
  input.begin(CLOSED, 0xFFFFFF00UL);
  CHECK(input.update(OPEN, 0xFFFFFFF0UL) == GasDetectorEvent::None);
  CHECK(input.update(OPEN, 0x000000B7UL) == GasDetectorEvent::None);
  CHECK(input.update(OPEN, 0x000000B8UL) == GasDetectorEvent::AlarmRaised);
}

}  // namespace

int main() {
  GasDetectorInput disabled(DEBOUNCE_MS);
  disabled.begin(OPEN, 0, false);
  CHECK(!disabled.alarmActive());
  CHECK(disabled.update(OPEN, 1000, false) == GasDetectorEvent::None);
  CHECK(!disabled.alarmActive());
  CHECK(disabled.update(OPEN, 1100, true) == GasDetectorEvent::None);
  CHECK(disabled.update(OPEN, 1300, true) == GasDetectorEvent::AlarmRaised);
  CHECK(disabled.update(OPEN, 1301, false) == GasDetectorEvent::AlarmCleared);
  CHECK(!disabled.alarmActive());
  testBootStateIsTakenImmediately();
  testOpenContactRaisesAfterDebounce();
  testBounceRestartsTheDebounce();
  testGlitchShorterThanDebounceIsIgnored();
  testMillisWraparound();
  if (failures != 0) {
    std::cerr << failures << " gas detector input check(s) failed\n";
    return 1;
  }
  std::cout << "Gas detector input tests passed\n";
  return 0;
}

#include "ConfigStore.h"
#include "LeakController.h"

#include <Preferences.h>

#include <cstdlib>
#include <iostream>

namespace {

LeakConfig config() {
  return LeakConfig{1200, 600, 1000, 180000, 500, 500};
}

bool establishDry(LeakController& controller) {
  return !controller.updateSensor(200, 0) && controller.updateSensor(200, 1000);
}

bool staysClosedAfterDry(const PersistentState& recovered) {
  LeakController controller(config());
  controller.restore(recovered, 0);
  return !recovered.leakLatched &&
         recovered.requestedValve == ValveState::Closed &&
         establishDry(controller) && controller.valveState() == ValveState::Closed;
}

bool isClosedRecovery(const PersistentState& recovered) {
  return !recovered.leakLatched &&
         recovered.requestedValve == ValveState::Closed;
}

void writeStateRecord(uint8_t latchValue, bool latchAsUShort,
                      uint8_t valveValue) {
  Preferences record;
  record.begin("waterstate", false);
  record.putUChar("version", 1);
  if (latchAsUShort) {
    record.putUShort("leakLatched", latchValue);
  } else {
    record.putUChar("leakLatched", latchValue);
  }
  record.putUChar("valve", valveValue);
  record.end();
}

}  // namespace

int main() {
  Preferences::resetForTest();
  ConfigStore store;
  if (!store.begin()) {
    std::cerr << "ConfigStore setup failed\n";
    return EXIT_FAILURE;
  }

  // Removing the version marker before a failed write leaves no valid saved
  // record. Recovery must retain a closed request even after stable dry input.
  if (!staysClosedAfterDry(store.loadState())) {
    std::cerr << "Missing state record did not recover to closed\n";
    return EXIT_FAILURE;
  }

  // A schema marker without every state field is also not a valid saved
  // record, even if the surviving valve byte asks to open.
  Preferences partialRecord;
  partialRecord.begin("waterstate", false);
  partialRecord.putUChar("version", 1);
  partialRecord.putUChar("valve", static_cast<uint8_t>(ValveState::Open));
  partialRecord.end();
  if (!staysClosedAfterDry(store.loadState())) {
    std::cerr << "Partial state record did not recover to closed\n";
    return EXIT_FAILURE;
  }

  // A latch is an ESP32 U8 value. Any value other than 0 or 1 is corrupt,
  // even when the schema and requested valve are otherwise valid.
  writeStateRecord(2, false, static_cast<uint8_t>(ValveState::Open));
  if (!isClosedRecovery(store.loadState())) {
    std::cerr << "Invalid U8 latch did not recover to closed\n";
    return EXIT_FAILURE;
  }

  // A latch stored with a different Preferences type is also corrupt.
  writeStateRecord(1, true, static_cast<uint8_t>(ValveState::Open));
  if (!isClosedRecovery(store.loadState())) {
    std::cerr << "Wrong-type latch did not recover to closed\n";
    return EXIT_FAILURE;
  }

  // Keep rejecting invalid persisted valve enum values.
  writeStateRecord(0, false, 2);
  if (!isClosedRecovery(store.loadState())) {
    std::cerr << "Invalid valve enum did not recover to closed\n";
    return EXIT_FAILURE;
  }

  Preferences::resetForTest();
  if (!store.saveState(PersistentState{true, ValveState::Open})) {
    std::cerr << "Saving valid state record failed\n";
    return EXIT_FAILURE;
  }
  const PersistentState roundTrip = store.loadState();
  if (roundTrip.leakLatched != true ||
      roundTrip.requestedValve != ValveState::Open) {
    std::cerr << "Valid state record did not round trip\n";
    return EXIT_FAILURE;
  }
  std::cout << "ConfigStore fallback is closed\n";
  return EXIT_SUCCESS;
}

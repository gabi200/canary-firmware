#include "HubHost.h"

#include <cstdio>
#include <cstring>

static int failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);     \
      ++failures;                                                          \
    }                                                                      \
  } while (0)

static void testMdnsNames() {
  CHECK(HubHost::isMdnsName("canary-hub.local"));
  CHECK(HubHost::isMdnsName("Canary-Hub.LOCAL"));
  CHECK(HubHost::isMdnsName("canary-hub.local."));
  CHECK(!HubHost::isMdnsName(".local"));
  CHECK(!HubHost::isMdnsName("10.91.13.240"));
  CHECK(!HubHost::isMdnsName("broker.example.com"));
  CHECK(!HubHost::isMdnsName("notlocal"));
  CHECK(!HubHost::isMdnsName(""));
  CHECK(!HubHost::isMdnsName(nullptr));
}

static void testMdnsLabel() {
  char label[16];
  CHECK(HubHost::mdnsLabel("canary-hub.local", label, sizeof(label)));
  CHECK(std::strcmp(label, "canary-hub") == 0);
  CHECK(HubHost::mdnsLabel("canary-hub.local.", label, sizeof(label)));
  CHECK(std::strcmp(label, "canary-hub") == 0);
  char tiny[4];
  CHECK(!HubHost::mdnsLabel("canary-hub.local", tiny, sizeof(tiny)));
  CHECK(!HubHost::mdnsLabel("10.91.13.240", label, sizeof(label)));
}

static void testOldAddressFallsBackToTheAnnouncedNameAndBack() {
  HubHost::Picker picker("10.91.13.240");
  CHECK(std::strcmp(picker.current(), "10.91.13.240") == 0);
  picker.onFailure(true);
  CHECK(std::strcmp(picker.current(), "canary-hub.local") == 0);
  CHECK(picker.usingAnnounced());
  // The name may be gone too (hub moving): the saved address gets its turn again.
  picker.onFailure(true);
  CHECK(std::strcmp(picker.current(), "10.91.13.240") == 0);
}

static void testRefusedLoginKeepsTheHost() {
  HubHost::Picker picker("10.91.13.240");
  picker.onFailure(false);
  CHECK(std::strcmp(picker.current(), "10.91.13.240") == 0);
}

static void testAnnouncedNameSavedNeverAlternates() {
  HubHost::Picker picker("Canary-Hub.local");
  picker.onFailure(true);
  CHECK(std::strcmp(picker.current(), "Canary-Hub.local") == 0);
  CHECK(!picker.usingAnnounced());
}

static void testEmptyHostUsesTheAnnouncedName() {
  HubHost::Picker picker("");
  picker.onFailure(true);
  CHECK(std::strcmp(picker.current(), "canary-hub.local") == 0);
  picker.onFailure(true);
  CHECK(std::strcmp(picker.current(), "canary-hub.local") == 0);
}

static void testResetStartsFromTheSavedHost() {
  HubHost::Picker picker("10.91.13.240");
  picker.onFailure(true);
  picker.reset("192.168.1.10");
  CHECK(std::strcmp(picker.current(), "192.168.1.10") == 0);
}

int main() {
  testMdnsNames();
  testMdnsLabel();
  testOldAddressFallsBackToTheAnnouncedNameAndBack();
  testRefusedLoginKeepsTheHost();
  testAnnouncedNameSavedNeverAlternates();
  testEmptyHostUsesTheAnnouncedName();
  testResetStartsFromTheSavedHost();
  if (failures != 0) {
    std::printf("%d hub host check(s) failed\n", failures);
    return 1;
  }
  std::printf("hub host tests passed\n");
  return 0;
}

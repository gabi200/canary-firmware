// Frame-level tests for the three UART sensor parsers. The vectors below are
// the vendors' own documented example frames wherever one exists, so a parser
// that drifts away from the published layout fails here rather than on a wall.
#include "Ld2410Reader.h"
#include "Pms5003Reader.h"
#include "Ze03Reader.h"

#include <cstdint>
#include <cstdlib>
#include <initializer_list>
#include <iostream>
#include <vector>

namespace {

int failures = 0;

#define CHECK(expr)                                                        \
  do {                                                                     \
    if (!(expr)) {                                                         \
      std::cerr << __func__ << ":" << __LINE__ << " CHECK(" #expr          \
                << ") failed\n";                                           \
      ++failures;                                                          \
    }                                                                      \
  } while (0)

template <typename Reader>
bool feed(Reader& reader, const std::vector<uint8_t>& bytes) {
  bool accepted = false;
  for (const uint8_t byte : bytes) {
    accepted = reader.consume(byte) || accepted;
  }
  return accepted;
}

std::vector<uint8_t> bytes(std::initializer_list<int> values) {
  std::vector<uint8_t> output;
  output.reserve(values.size());
  for (const int value : values) {
    output.push_back(static_cast<uint8_t>(value));
  }
  return output;
}

// ---------------------------------------------------------------- ZE03-CO

void testZe03AcceptsDocumentedCoFrames() {
  // FF 86 <conc hi> <conc lo> <gas id> <decimals> 00 00 <checksum>.
  Ze03Reader zero;
  CHECK(feed(zero, bytes({0xFF, 0x86, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x76})));
  CHECK(zero.reading().ppm == 0);

  Ze03Reader mid;
  CHECK(feed(mid, bytes({0xFF, 0x86, 0x00, 0x89, 0x04, 0x00, 0x00, 0x00, 0xED})));
  CHECK(mid.reading().ppm == 137);

  Ze03Reader full;
  CHECK(feed(full, bytes({0xFF, 0x86, 0x03, 0xE8, 0x04, 0x00, 0x00, 0x00, 0x8B})));
  CHECK(full.reading().ppm == 1000);
}

void testZe03AcceptsPreV28FirmwareWithoutGasId() {
  // Firmware older than V2.8 leaves the gas-identity byte at zero. Rejecting
  // those frames would silently drop every reading from an older module.
  Ze03Reader reader;
  CHECK(feed(reader, bytes({0xFF, 0x86, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x50})));
  CHECK(reader.reading().ppm == 42);
  CHECK(reader.reading().gasId == Ze03Reader::GAS_ID_LEGACY);
}

void testZe03AppliesDecimalsByte() {
  // A part built for a finer resolution reports tenths; publishing the raw
  // value would overstate the concentration tenfold.
  Ze03Reader reader;
  uint8_t frame[9] = {0xFF, 0x86, 0x00, 0xD1, 0x04, 0x01, 0x00, 0x00, 0x00};
  frame[8] = Ze03Reader::checksum(frame, sizeof(frame));
  CHECK(feed(reader, std::vector<uint8_t>(frame, frame + sizeof(frame))));
  CHECK(reader.reading().ppm == 20);
  CHECK(reader.reading().decimals == 1);
}

void testZe03RejectsOtherWinsenFamiliesAndGases() {
  // ZE07/ZE08 frames are also nine bytes, also start with 0xFF and use the
  // same checksum. Only byte 1 separates them, and a frame for a different
  // gas must never be reported as carbon monoxide.
  Ze03Reader other;
  CHECK(!feed(other, bytes({0xFF, 0x04, 0x03, 0x01, 0x00, 0x25, 0x13, 0x88, 0x38})));
  CHECK(other.rejectedFrames() > 0);

  Ze03Reader sulphurDioxide;
  CHECK(!feed(sulphurDioxide,
              bytes({0xFF, 0x86, 0x00, 0x00, 0x2B, 0x01, 0x00, 0x00, 0x4E})));

  Ze03Reader oxygen;
  CHECK(!feed(oxygen, bytes({0xFF, 0x86, 0x00, 0xD1, 0x05, 0x01, 0x00, 0x00, 0xA3})));
}

void testZe03RejectsBadChecksumAndResyncs() {
  Ze03Reader corrupt;
  CHECK(!feed(corrupt, bytes({0xFF, 0x86, 0x00, 0x89, 0x04, 0x00, 0x00, 0x00, 0x00})));
  CHECK(corrupt.rejectedFrames() == 1);

  // Leading noise, including a false start byte, must not cost the next frame.
  Ze03Reader noisy;
  CHECK(feed(noisy, bytes({0x12, 0xFF, 0x99, 0xFF, 0x86, 0x00, 0x89, 0x04, 0x00,
                           0x00, 0x00, 0xED})));
  CHECK(noisy.reading().ppm == 137);
}

void testZe03RecoveryCommandsAreWellFormed() {
  size_t length = 0;
  const uint8_t* active = Ze03Reader::activeUploadRequest(length);
  CHECK(length == 9);
  CHECK(active[3] == 0x03);  // ZE03 selects mode here; 0x40/0x41 are ZE07/ZE08
  CHECK(active[8] == Ze03Reader::checksum(active, length));

  const uint8_t* read = Ze03Reader::readRequest(length);
  CHECK(length == 9);
  CHECK(read[8] == Ze03Reader::checksum(read, length));
}

// ------------------------------------------------------------- PMS5003T

const std::vector<uint8_t> kPmsFrame = bytes(
    {0x42, 0x4D, 0x00, 0x1C, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0B, 0x00,
     0x05, 0x00, 0x0C, 0x00, 0x12, 0x05, 0xDC, 0x01, 0xA4, 0x00, 0x50,
     0x00, 0x0C, 0x00, 0xEA, 0x01, 0xE1, 0x00, 0x00, 0x04, 0x94});

void testPmsParsesAtmosphericValuesAndClimate() {
  Pms5003Reader reader;
  CHECK(feed(reader, kPmsFrame));
  const ParticulateReading& particulate = reader.particulate();
  // Bytes 10-15 are the atmospheric set; bytes 4-9 are the factory CF=1 set
  // and would report 4/9/11 here.
  CHECK(particulate.pm1_0 == 5);
  CHECK(particulate.pm2_5 == 12);
  CHECK(particulate.pm10 == 18);
  CHECK(particulate.count0_3 == 1500);
  CHECK(particulate.count2_5 == 12);
  CHECK(reader.climate().temperatureTenthsC == 234);
  CHECK(reader.climate().humidityTenthsPercent == 481);
}

void testPmsTemperatureIsSigned() {
  // Reading the temperature word unsigned turns -5.5 C into about 6553 C.
  const std::vector<uint8_t> frame = bytes(
      {0x42, 0x4D, 0x00, 0x1C, 0x00, 0x03, 0x00, 0x06, 0x00, 0x07, 0x00,
       0x03, 0x00, 0x07, 0x00, 0x09, 0x03, 0x84, 0x00, 0xFA, 0x00, 0x28,
       0x00, 0x05, 0xFF, 0xC9, 0x02, 0x8F, 0x00, 0x00, 0x04, 0xD5});
  Pms5003Reader reader;
  CHECK(feed(reader, frame));
  CHECK(reader.climate().temperatureTenthsC == -55);
  CHECK(reader.climate().humidityTenthsPercent == 655);
}

void testPmsRejectsCorruptAndImplausibleFrames() {
  std::vector<uint8_t> badChecksum = kPmsFrame;
  badChecksum[31] ^= 0xFF;
  Pms5003Reader corrupt;
  CHECK(!feed(corrupt, badChecksum));
  CHECK(corrupt.rejectedFrames() == 1);

  // Mass without any counted particles cannot happen, however well the frame
  // checksums.
  const std::vector<uint8_t> implausible = bytes(
      {0x42, 0x4D, 0x00, 0x1C, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0B, 0x00,
       0x05, 0x00, 0x0C, 0x00, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
       0x00, 0x00, 0x00, 0xEA, 0x01, 0xE1, 0x00, 0x00, 0x02, 0xB2});
  Pms5003Reader inconsistent;
  CHECK(!feed(inconsistent, implausible));
  CHECK(inconsistent.rejectedFrames() == 1);
}

void testPmsRejectsShortAcknowledgementWithoutLosingNextFrame() {
  // A command acknowledgement is eight bytes with length field 0x0004.
  // Waiting for 32 bytes would swallow most of the frame behind it.
  std::vector<uint8_t> stream =
      bytes({0x42, 0x4D, 0x00, 0x04, 0xE1, 0x00, 0x01, 0x74});
  stream.insert(stream.end(), kPmsFrame.begin(), kPmsFrame.end());
  Pms5003Reader reader;
  CHECK(feed(reader, stream));
  CHECK(reader.particulate().pm2_5 == 12);
}

void testPmsResyncsAfterNoise() {
  std::vector<uint8_t> stream = bytes({0x00, 0x42, 0x42, 0x4D, 0x99});
  stream.insert(stream.end(), kPmsFrame.begin(), kPmsFrame.end());
  Pms5003Reader reader;
  CHECK(feed(reader, stream));
  CHECK(reader.particulate().pm10 == 18);
}

// --------------------------------------------------------------- LD2410

const std::vector<uint8_t> kLd2410Basic = bytes(
    {0xF4, 0xF3, 0xF2, 0xF1, 0x0D, 0x00, 0x02, 0xAA, 0x02, 0x51, 0x00, 0x00,
     0x00, 0x00, 0x3B, 0x00, 0x00, 0x55, 0x00, 0xF8, 0xF7, 0xF6, 0xF5});

void testLd2410ParsesVendorBasicFrame() {
  Ld2410Reader reader;
  CHECK(feed(reader, kLd2410Basic));
  const PresenceReading& reading = reader.reading();
  CHECK(reading.detected);
  CHECK(reading.stationary);
  CHECK(!reading.moving);
  CHECK(reading.movingDistanceCm == 81);
  CHECK(reading.movingEnergy == 0);
  CHECK(reading.stationaryDistanceCm == 0);
  CHECK(reading.stationaryEnergy == 59);
  CHECK(reading.detectionDistanceCm == 0);
}

void testLd2410ParsesVendorEngineeringFrame() {
  // Engineering frames share the first nine payload bytes and then carry
  // per-gate energies; the extra bytes must be skipped, not misread.
  const std::vector<uint8_t> frame = bytes(
      {0xF4, 0xF3, 0xF2, 0xF1, 0x23, 0x00, 0x01, 0xAA, 0x03, 0x1E, 0x00, 0x3C,
       0x00, 0x00, 0x39, 0x00, 0x00, 0x08, 0x08, 0x3C, 0x22, 0x05, 0x03, 0x03,
       0x04, 0x03, 0x06, 0x05, 0x00, 0x00, 0x39, 0x10, 0x13, 0x06, 0x06, 0x08,
       0x04, 0x60, 0x01, 0x55, 0x00, 0xF8, 0xF7, 0xF6, 0xF5});
  Ld2410Reader reader;
  CHECK(feed(reader, frame));
  CHECK(reader.reading().moving);
  CHECK(reader.reading().stationary);
  CHECK(reader.reading().movingDistanceCm == 30);
  CHECK(reader.reading().movingEnergy == 60);
  CHECK(reader.reading().stationaryEnergy == 57);
}

void testLd2410AcceptsBackgroundCalibrationStates() {
  // LD2410B and LD2410C report 0x04-0x06 while calibrating background noise.
  // Those are valid frames, not corruption.
  std::vector<uint8_t> frame = kLd2410Basic;
  frame[8] = 0x05;
  Ld2410Reader reader;
  CHECK(feed(reader, frame));
  CHECK(!reader.reading().detected);
  CHECK(reader.rejectedFrames() == 0);

  frame[8] = 0x07;
  Ld2410Reader invalid;
  CHECK(!feed(invalid, frame));
  CHECK(invalid.rejectedFrames() == 1);
}

void testLd2410SurvivesHeaderLookalikeInPayload() {
  // A stationary distance of 244 cm encodes as F4 00, the first frame-header
  // byte. Committing on it would desynchronise the stream.
  std::vector<uint8_t> frame = kLd2410Basic;
  frame[12] = 0xF4;
  frame[13] = 0x00;
  Ld2410Reader reader;
  CHECK(feed(reader, frame));
  CHECK(reader.reading().stationaryDistanceCm == 244);
  CHECK(reader.rejectedFrames() == 0);
}

void testLd2410RejectsCommandFramesAndBadTails() {
  // Command acknowledgements use header FD FC FB FA and must never be read as
  // target data.
  std::vector<uint8_t> stream =
      bytes({0xFD, 0xFC, 0xFB, 0xFA, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04,
             0x03, 0x02, 0x01});
  stream.insert(stream.end(), kLd2410Basic.begin(), kLd2410Basic.end());
  Ld2410Reader reader;
  CHECK(feed(reader, stream));
  CHECK(reader.reading().stationaryEnergy == 59);

  std::vector<uint8_t> badTail = kLd2410Basic;
  badTail[22] = 0x00;
  Ld2410Reader broken;
  CHECK(!feed(broken, badTail));
  CHECK(broken.rejectedFrames() == 1);

  // An implausible declared length must be dropped rather than buffered.
  std::vector<uint8_t> badLength = kLd2410Basic;
  badLength[4] = 0xFF;
  badLength[5] = 0xFF;
  Ld2410Reader oversized;
  CHECK(!feed(oversized, badLength));
  CHECK(oversized.rejectedFrames() == 1);
}

}  // namespace

int main() {
  testZe03AcceptsDocumentedCoFrames();
  testZe03AcceptsPreV28FirmwareWithoutGasId();
  testZe03AppliesDecimalsByte();
  testZe03RejectsOtherWinsenFamiliesAndGases();
  testZe03RejectsBadChecksumAndResyncs();
  testZe03RecoveryCommandsAreWellFormed();
  testPmsParsesAtmosphericValuesAndClimate();
  testPmsTemperatureIsSigned();
  testPmsRejectsCorruptAndImplausibleFrames();
  testPmsRejectsShortAcknowledgementWithoutLosingNextFrame();
  testPmsResyncsAfterNoise();
  testLd2410ParsesVendorBasicFrame();
  testLd2410ParsesVendorEngineeringFrame();
  testLd2410AcceptsBackgroundCalibrationStates();
  testLd2410SurvivesHeaderLookalikeInPayload();
  testLd2410RejectsCommandFramesAndBadTails();
  if (failures) {
    return EXIT_FAILURE;
  }
  std::cout << "Sensor frame parsers passed\n";
  return EXIT_SUCCESS;
}

#include "AirController.h"

namespace {

constexpr uint8_t BRIGHTNESS_ALARM = 255;
constexpr uint8_t BRIGHTNESS_WARNING = 180;
constexpr uint8_t BRIGHTNESS_ATTENTION = 120;
constexpr uint8_t BRIGHTNESS_IDLE = 24;

}  // namespace

AirController::Channel AirController::idleChannel() {
  return Channel{ChannelState::Warmup, ChannelState::Warmup, 0, false, 0, false};
}

AirController::AirController(const AirConfig& config)
    : config_(config),
      coChannel_(idleChannel()),
      gasChannel_(idleChannel()),
      particulateChannel_(idleChannel()),
      co_{0, 0, 0},
      gasAdc_(0),
      particulate_{0, 0, 0, 0, 0, 0, 0},
      coPeakPpm_(0),
      gasPeakAdc_(0),
      pm25PeakUgm3_(0),
      pm10PeakUgm3_(0),
      bootMs_(0),
      alarmState_(AlarmState::Inactive),
      alarmHazard_(Hazard::None),
      patternEpochMs_(0),
      silencedUntilMs_(0),
      silencedHazard_(Hazard::None),
      silenceActive_(false),
      selfTestStartedMs_(0),
      selfTestRunning_(false),
      otaActive_(false) {}

void AirController::begin(uint32_t nowMs) {
  bootMs_ = nowMs;
  patternEpochMs_ = nowMs;
  coChannel_ = idleChannel();
  gasChannel_ = idleChannel();
  particulateChannel_ = idleChannel();
}

void AirController::shortenWarmup(uint32_t warmupMs) {
  if (warmupMs < config_.warmupMs) {
    config_.warmupMs = warmupMs;
  }
}

void AirController::updateCo(const CoReading& reading, uint32_t nowMs) {
  co_ = reading;
  coChannel_.lastSampleMs = nowMs;
  coChannel_.sampled = true;
  if (!warmingUp(nowMs) && reading.ppm > coPeakPpm_) {
    coPeakPpm_ = reading.ppm;
  }
}

void AirController::updateGas(uint16_t adc, uint32_t nowMs) {
  gasAdc_ = adc;
  gasChannel_.lastSampleMs = nowMs;
  gasChannel_.sampled = true;
  if (!warmingUp(nowMs) && adc > gasPeakAdc_) {
    gasPeakAdc_ = adc;
  }
}

void AirController::updateParticulate(const ParticulateReading& reading,
                                      uint32_t nowMs) {
  particulate_ = reading;
  particulateChannel_.lastSampleMs = nowMs;
  particulateChannel_.sampled = true;
  if (warmingUp(nowMs)) {
    return;
  }
  if (reading.pm2_5 > pm25PeakUgm3_) {
    pm25PeakUgm3_ = reading.pm2_5;
  }
  if (reading.pm10 > pm10PeakUgm3_) {
    pm10PeakUgm3_ = reading.pm10;
  }
}

bool AirController::tick(uint32_t nowMs) {
  bool changed = false;
  changed = applyObservation(coChannel_, observeCo(nowMs), nowMs) || changed;
  changed = applyObservation(gasChannel_, observeGas(nowMs), nowMs) || changed;
  changed = applyObservation(particulateChannel_, observeParticulate(nowMs),
                             nowMs) ||
            changed;

  const Hazard danger = worstAt(ChannelState::Danger);
  const Hazard warning = worstAt(ChannelState::Warning);

  if (danger != Hazard::None && selfTestRunning_) {
    // A real hazard always outranks an installer test.
    selfTestRunning_ = false;
    changed = true;
  }
  if (selfTestRunning_ && elapsed(nowMs, selfTestStartedMs_, config_.selfTestMs)) {
    selfTestRunning_ = false;
    changed = true;
  }

  // A silence covers exactly the hazard it was granted for. A different or
  // higher-priority hazard, or the danger clearing, retires it.
  if (silenceActive_ &&
      (danger == Hazard::None || danger != silencedHazard_ ||
       static_cast<int32_t>(nowMs - silencedUntilMs_) >= 0)) {
    silenceActive_ = false;
    changed = true;
  }

  AlarmState state = AlarmState::Inactive;
  Hazard hazard = Hazard::None;
  if (danger != Hazard::None) {
    state = silenceActive_ ? AlarmState::Silenced : AlarmState::Sounding;
    hazard = danger;
  } else if (warning != Hazard::None) {
    state = AlarmState::Warning;
    hazard = warning;
  }

  if (state != alarmState_ || hazard != alarmHazard_) {
    alarmState_ = state;
    alarmHazard_ = hazard;
    patternEpochMs_ = nowMs;
    changed = true;
  }
  return changed;
}

CommandResult AirController::silenceAlarm(uint32_t nowMs) {
  if (alarmState_ != AlarmState::Sounding) {
    return CommandResult::RejectedInactive;
  }
  silenceActive_ = true;
  silencedHazard_ = alarmHazard_;
  silencedUntilMs_ = nowMs + config_.silenceMs;
  alarmState_ = AlarmState::Silenced;
  patternEpochMs_ = nowMs;
  return CommandResult::Accepted;
}

CommandResult AirController::startSelfTest(uint32_t nowMs) {
  if (otaActive_) {
    return CommandResult::RejectedOta;
  }
  if (alarmState_ == AlarmState::Sounding || alarmState_ == AlarmState::Silenced ||
      selfTestRunning_) {
    return CommandResult::RejectedBusy;
  }
  selfTestRunning_ = true;
  selfTestStartedMs_ = nowMs;
  return CommandResult::Accepted;
}

void AirController::setOtaActive(bool active) {
  otaActive_ = active;
  if (active) {
    selfTestRunning_ = false;
  }
}

bool AirController::otaActive() const {
  return otaActive_;
}

ChannelState AirController::coState() const {
  return coChannel_.state;
}

ChannelState AirController::gasState() const {
  return gasChannel_.state;
}

ChannelState AirController::particulateState() const {
  return particulateChannel_.state;
}

const CoReading& AirController::co() const {
  return co_;
}

uint16_t AirController::gasAdc() const {
  return gasAdc_;
}

const ParticulateReading& AirController::particulate() const {
  return particulate_;
}

uint16_t AirController::coPeakPpm() const {
  return coPeakPpm_;
}

uint16_t AirController::gasPeakAdc() const {
  return gasPeakAdc_;
}

uint16_t AirController::pm25PeakUgm3() const {
  return pm25PeakUgm3_;
}

uint16_t AirController::pm10PeakUgm3() const {
  return pm10PeakUgm3_;
}

bool AirController::coFresh(uint32_t nowMs) const {
  return !stale(coChannel_, nowMs);
}

bool AirController::particulateFresh(uint32_t nowMs) const {
  return !stale(particulateChannel_, nowMs);
}

uint32_t AirController::coAgeMs(uint32_t nowMs) const {
  return coChannel_.sampled ? static_cast<uint32_t>(nowMs - coChannel_.lastSampleMs) : 0;
}

uint32_t AirController::particulateAgeMs(uint32_t nowMs) const {
  return particulateChannel_.sampled
             ? static_cast<uint32_t>(nowMs - particulateChannel_.lastSampleMs)
             : 0;
}

AlarmState AirController::alarmState() const {
  return alarmState_;
}

Hazard AirController::alarmHazard() const {
  return alarmHazard_;
}

bool AirController::selfTestActive(uint32_t nowMs) const {
  return selfTestRunning_ &&
         !elapsed(nowMs, selfTestStartedMs_, config_.selfTestMs);
}

uint32_t AirController::silenceRemainingMs(uint32_t nowMs) const {
  if (!silenceActive_ || static_cast<int32_t>(nowMs - silencedUntilMs_) >= 0) {
    return 0;
  }
  return silencedUntilMs_ - nowMs;
}

uint32_t AirController::warmupRemainingMs(uint32_t nowMs) const {
  const uint32_t sinceBoot = static_cast<uint32_t>(nowMs - bootMs_);
  return sinceBoot >= config_.warmupMs ? 0 : config_.warmupMs - sinceBoot;
}

LedColor AirController::ledColor(uint32_t nowMs) const {
  if (selfTestActive(nowMs)) {
    switch (selfTestStep(nowMs)) {
      case 0:
        return LedColor::Red;
      case 1:
        return LedColor::Orange;
      case 2:
        return LedColor::Magenta;
      default:
        return LedColor::White;
    }
  }
  if (alarmHazard_ != Hazard::None) {
    return hazardColor(alarmHazard_);
  }
  if (anyChannelAt(ChannelState::Fault)) {
    return LedColor::Cyan;
  }
  if (anyChannelAt(ChannelState::Warmup)) {
    return LedColor::Blue;
  }
  return LedColor::Green;
}

bool AirController::ledOn(uint32_t nowMs) const {
  const Pattern pattern = ledPattern(nowMs);
  const uint32_t epoch = selfTestActive(nowMs) ? selfTestStartedMs_ : patternEpochMs_;
  return phaseOn(nowMs, epoch, pattern);
}

uint8_t AirController::ledBrightness(uint32_t nowMs) const {
  if (selfTestActive(nowMs)) {
    return BRIGHTNESS_ALARM;
  }
  switch (alarmState_) {
    case AlarmState::Sounding:
    case AlarmState::Silenced:
      return BRIGHTNESS_ALARM;
    case AlarmState::Warning:
      return BRIGHTNESS_WARNING;
    case AlarmState::Inactive:
    default:
      break;
  }
  if (anyChannelAt(ChannelState::Fault) || anyChannelAt(ChannelState::Warmup)) {
    return BRIGHTNESS_ATTENTION;
  }
  return BRIGHTNESS_IDLE;
}

bool AirController::buzzerOutput(uint32_t nowMs) const {
  if (selfTestActive(nowMs)) {
    return phaseOn(nowMs, selfTestStartedMs_, Pattern{120, 380});
  }
  if (alarmState_ != AlarmState::Sounding) {
    return false;
  }
  return phaseOn(nowMs, patternEpochMs_, buzzerPattern());
}

ChannelState AirController::levelFor(uint16_t value, uint16_t warn,
                                     uint16_t danger) {
  if (value >= danger) {
    return ChannelState::Danger;
  }
  if (value >= warn) {
    return ChannelState::Warning;
  }
  return ChannelState::Ok;
}

uint8_t AirController::severityRank(ChannelState state) {
  switch (state) {
    case ChannelState::Danger:
      return 3;
    case ChannelState::Warning:
      return 2;
    case ChannelState::Fault:
      return 1;
    case ChannelState::Warmup:
    case ChannelState::Ok:
    default:
      return 0;
  }
}

LedColor AirController::hazardColor(Hazard hazard) {
  switch (hazard) {
    case Hazard::CarbonMonoxide:
      return LedColor::Red;
    case Hazard::Gas:
      return LedColor::Orange;
    case Hazard::Particulate:
      return LedColor::Magenta;
    case Hazard::None:
    default:
      return LedColor::Green;
  }
}

bool AirController::elapsed(uint32_t nowMs, uint32_t sinceMs,
                            uint32_t intervalMs) {
  return static_cast<uint32_t>(nowMs - sinceMs) >= intervalMs;
}

bool AirController::phaseOn(uint32_t nowMs, uint32_t epochMs,
                            const Pattern& pattern) {
  if (pattern.offMs == 0) {
    return pattern.onMs > 0;
  }
  const uint32_t period = pattern.onMs + pattern.offMs;
  return static_cast<uint32_t>(nowMs - epochMs) % period < pattern.onMs;
}

bool AirController::warmingUp(uint32_t nowMs) const {
  return !elapsed(nowMs, bootMs_, config_.warmupMs);
}

bool AirController::stale(const Channel& channel, uint32_t nowMs) const {
  return !channel.sampled ||
         elapsed(nowMs, channel.lastSampleMs, config_.sensorTimeoutMs);
}

bool AirController::applyObservation(Channel& channel, ChannelState observed,
                                     uint32_t nowMs) {
  if (observed == channel.state) {
    channel.candidateValid = false;
    return false;
  }

  // Warm-up and fault are already time-debounced by the clocks that produce
  // them, so entering or leaving either is immediate. Only the graded
  // ok/warning/danger transitions carry the hold timers.
  const bool immediate = observed == ChannelState::Warmup ||
                         observed == ChannelState::Fault ||
                         channel.state == ChannelState::Warmup ||
                         channel.state == ChannelState::Fault;
  if (immediate) {
    channel.state = observed;
    channel.candidateValid = false;
    return true;
  }

  if (!channel.candidateValid || channel.candidate != observed) {
    channel.candidate = observed;
    channel.candidateSinceMs = nowMs;
    channel.candidateValid = true;
    return false;
  }

  const uint32_t holdMs = severityRank(observed) > severityRank(channel.state)
                              ? config_.triggerHoldMs
                              : config_.clearHoldMs;
  if (!elapsed(nowMs, channel.candidateSinceMs, holdMs)) {
    return false;
  }
  channel.state = observed;
  channel.candidateValid = false;
  return true;
}

ChannelState AirController::observeCo(uint32_t nowMs) const {
  if (warmingUp(nowMs)) {
    return ChannelState::Warmup;
  }
  if (stale(coChannel_, nowMs)) {
    return ChannelState::Fault;
  }
  return levelFor(co_.ppm, config_.coWarnPpm, config_.coDangerPpm);
}

ChannelState AirController::observeGas(uint32_t nowMs) const {
  if (warmingUp(nowMs)) {
    return ChannelState::Warmup;
  }
  if (stale(gasChannel_, nowMs)) {
    return ChannelState::Fault;
  }
  return levelFor(gasAdc_, config_.gasWarnAdc, config_.gasDangerAdc);
}

ChannelState AirController::observeParticulate(uint32_t nowMs) const {
  if (warmingUp(nowMs)) {
    return ChannelState::Warmup;
  }
  if (stale(particulateChannel_, nowMs)) {
    return ChannelState::Fault;
  }
  const ChannelState fine =
      levelFor(particulate_.pm2_5, config_.pm25WarnUgm3, config_.pm25DangerUgm3);
  const ChannelState coarse =
      levelFor(particulate_.pm10, config_.pm10WarnUgm3, config_.pm10DangerUgm3);
  return severityRank(coarse) > severityRank(fine) ? coarse : fine;
}

Hazard AirController::worstAt(ChannelState level) const {
  if (coChannel_.state == level) {
    return Hazard::CarbonMonoxide;
  }
  if (gasChannel_.state == level) {
    return Hazard::Gas;
  }
  if (particulateChannel_.state == level) {
    return Hazard::Particulate;
  }
  return Hazard::None;
}

bool AirController::anyChannelAt(ChannelState level) const {
  return coChannel_.state == level || gasChannel_.state == level ||
         particulateChannel_.state == level;
}

AirController::Pattern AirController::ledPattern(uint32_t nowMs) const {
  if (selfTestActive(nowMs)) {
    return Pattern{1, 0};
  }
  switch (alarmState_) {
    case AlarmState::Sounding:
    case AlarmState::Silenced:
      return Pattern{200, 200};
    case AlarmState::Warning:
      return Pattern{400, 1600};
    case AlarmState::Inactive:
    default:
      break;
  }
  if (anyChannelAt(ChannelState::Fault)) {
    return Pattern{120, 880};
  }
  if (anyChannelAt(ChannelState::Warmup)) {
    return Pattern{1000, 1000};
  }
  return Pattern{1, 0};
}

AirController::Pattern AirController::buzzerPattern() const {
  switch (alarmHazard_) {
    case Hazard::CarbonMonoxide:
      return Pattern{150, 150};
    case Hazard::Gas:
      return Pattern{300, 300};
    case Hazard::Particulate:
      return Pattern{500, 2000};
    case Hazard::None:
    default:
      return Pattern{0, 1};
  }
}

uint8_t AirController::selfTestStep(uint32_t nowMs) const {
  const uint32_t slice = config_.selfTestMs / 4;
  if (slice == 0) {
    return 3;
  }
  const uint32_t step = static_cast<uint32_t>(nowMs - selfTestStartedMs_) / slice;
  return step > 3 ? 3 : static_cast<uint8_t>(step);
}

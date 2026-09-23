#pragma once

#include <stdint.h>

enum class PortalSubmissionAction : uint8_t {
  PublishConfig,
  ClearCredentialsAndRestart,
  RestoreCredentialsAndRestart,
};

class PortalSubmissionPolicy {
 public:
  explicit PortalSubmissionPolicy(bool hasValidConfig)
      : hasValidConfig_(hasValidConfig), publishPending_(false) {}

  bool shouldForcePortal(bool explicitlyForced) const {
    return explicitlyForced || !hasValidConfig_;
  }

  PortalSubmissionAction evaluate(bool submissionValid) {
    if (submissionValid) {
      hasValidConfig_ = true;
      publishPending_ = true;
      return PortalSubmissionAction::PublishConfig;
    }
    publishPending_ = false;
    return hasValidConfig_
               ? PortalSubmissionAction::RestoreCredentialsAndRestart
               : PortalSubmissionAction::ClearCredentialsAndRestart;
  }

  bool takePublishReady(bool wifiConnected) {
    if (!publishPending_ || !wifiConnected) {
      return false;
    }
    publishPending_ = false;
    return true;
  }

 private:
  bool hasValidConfig_;
  bool publishPending_;
};

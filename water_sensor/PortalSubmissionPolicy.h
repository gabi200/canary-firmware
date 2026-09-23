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
      : hasValidConfig_(hasValidConfig) {}

  bool shouldForcePortal(bool explicitlyForced) const {
    return explicitlyForced || !hasValidConfig_;
  }

  bool requiresApiTokenInput() const {
    return !hasValidConfig_;
  }

  PortalSubmissionAction evaluate(bool submissionValid) {
    if (submissionValid) {
      hasValidConfig_ = true;
      return PortalSubmissionAction::PublishConfig;
    }
    return hasValidConfig_
               ? PortalSubmissionAction::RestoreCredentialsAndRestart
               : PortalSubmissionAction::ClearCredentialsAndRestart;
  }

 private:
  bool hasValidConfig_;
};

import { useQueryClient } from "@tanstack/react-query";

import type { NodeOut } from "../api/types";
import { useAuth } from "../auth/AuthContext";
import { useT } from "../i18n";
import { COMMAND_SPACING_MS, isPending, sendNodeCommand, useLiveCommand } from "../lib/commands";
import { pick } from "../lib/nodes";
import { useNow } from "../lib/useNow";
import { canCommand } from "./NodeCommands";

export function ExternalDetectorSetting({ node }: { node: NodeOut }) {
  const { session, token } = useAuth();
  const { t } = useT();
  const qc = useQueryClient();
  const live = useLiveCommand(node.id);
  const pending = isPending(live);
  const spacing = !!live && Date.now() - live.startedAt < COMMAND_SPACING_MS;
  const now = useNow(1000, spacing);
  const enabled = pick(node.status, "gas_detector.enabled");
  if (node.kind !== "air" || typeof enabled !== "boolean" || !canCommand(session?.role)) return null;
  const reason = !node.online
    ? t("nodecmd.offlineReason")
    : pending
      ? t("nodecmd.busyReason")
      : live && now - live.startedAt < COMMAND_SPACING_MS
        ? t("nodecmd.spacingReason")
        : undefined;

  return (
    <div className="field">
      <label htmlFor={`external-detector-${node.id}`}>{t("detector.label")}</label>
      <select
        id={`external-detector-${node.id}`}
        value={enabled ? "on" : "off"}
        disabled={!!reason}
        title={reason}
        aria-describedby={`external-detector-help-${node.id}`}
        onChange={(event) => {
          void sendNodeCommand({ token, nodeId: node.id, command: event.target.value === "on" ? "DETECTOR_ON" : "DETECTOR_OFF", qc });
        }}
      >
        <option value="off">{t("detector.disabled")}</option>
        <option value="on">{t("detector.enabled")}</option>
      </select>
      <div className="muted small" id={`external-detector-help-${node.id}`}>{reason ?? t("detector.help")}</div>
    </div>
  );
}

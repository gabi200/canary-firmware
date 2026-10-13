/**
 * Status of the hub's Pis in plain words (lib/cluster): one line per problem (or "all good") on
 * the Administration Hub tab, and a compact warning on the manager page while a three-Pi hub
 * runs degraded. The text carries the meaning; the icon and colour only repeat it.
 */
import { Link } from "react-router-dom";

import { useCluster } from "../api/hooks";
import { useT } from "../i18n";
import { worstProblem, type LineTone, type StatusLine } from "../lib/cluster";
import { CheckIcon, InfoIcon, WarningIcon } from "./Icons";

const ICON: Record<LineTone, typeof CheckIcon> = {
  danger: WarningIcon,
  attention: WarningIcon,
  ok: CheckIcon,
  info: InfoIcon,
};

export function HubLine({ line }: { line: StatusLine }) {
  const Icon = ICON[line.tone];
  return (
    <li className={`hub-line ${line.tone}`}>
      <Icon />
      <div>
        <div className="hub-line-main">{line.text}</div>
        {line.sub && <div className="muted small">{line.sub}</div>}
      </div>
    </li>
  );
}

/** Manager page: the worst problem of a degraded three-Pi hub, linking to the Hub tab. Nothing
 *  in single mode, nothing for roles the hub does not tell (useCluster asks only for allowed ones). */
export function HubBanner() {
  const { t } = useT();
  const c = useCluster().data;
  if (!c || c.mode !== "triple" || !c.degraded) return null;
  const line: StatusLine = worstProblem(c, t) ?? { tone: "attention", text: t("hub.degraded") };
  const Icon = ICON[line.tone];
  return (
    <div className={`hub-line hub-banner ${line.tone}`} role="status">
      <Icon />
      <div className="hub-banner-body">
        <span className="hub-line-main">
          {t("hub.bannerTitle")} {line.text}
        </span>
        <Link to="/admin/hub" className="small">
          {t("hub.bannerLink")}
        </Link>
      </div>
    </div>
  );
}

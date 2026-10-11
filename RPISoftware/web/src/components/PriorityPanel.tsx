/**
 * Care-profile ("priority") people during an active incident: residents and household members
 * who may not be able to evacuate alone. Health data (GDPR art. 9): the backend sends it only
 * while the incident is active and audits every read; this UI keeps it in react-query memory
 * only (never storage) and renders nothing once the list is empty.
 */
import { useId, type ComponentType, type SVGProps } from "react";

import type { PriorityPerson, PriorityStatus, Roster } from "../api/types";
import { pluralCategory, useT } from "../i18n";
import { tokenLabel } from "../lib/labels";
import { fmtAgo } from "../lib/time";
import {
  BedIcon,
  CaneWalkerIcon,
  CheckIcon,
  ChildIcon,
  ClockIcon,
  EarOffIcon,
  EyeOffIcon,
  LockIcon,
  OxygenIcon,
  PawIcon,
  PhoneIcon,
  WarningIcon,
  WheelchairIcon,
} from "./Icons";

type IconType = ComponentType<Omit<SVGProps<SVGSVGElement>, "children">>;

/** Decorative icons; the word next to each one carries the meaning. */
const NEED_ICON: Record<string, IconType> = {
  reduced_mobility: CaneWalkerIcon,
  wheelchair: WheelchairIcon,
  bedridden: BedIcon,
  hearing_impaired: EarOffIcon,
  visually_impaired: EyeOffIcon,
  medical_device: OxygenIcon,
  young_child: ChildIcon,
  pet: PawIcon,
};

/** Icon inside the status pill (next to the status word), so status never relies on colour. */
const STATUS_ICON: Record<PriorityStatus, IconType> = {
  needs_help: WarningIcon,
  no_response: ClockIcon,
  unknown: ClockIcon,
  safe_inside: CheckIcon,
  safe_outside: CheckIcon,
};

/** Out of the building and confirmed safe: the only status that collapses. */
const isOut = (p: PriorityPerson) => p.status === "safe_outside";

/** Priority people not yet out, counted per unit (floor plan markers). */
export function priorityByUnit(people: PriorityPerson[] | undefined): Record<string, number> {
  const out: Record<string, number> = {};
  for (const p of people ?? []) {
    if (!isOut(p) && p.unit_id) out[p.unit_id] = (out[p.unit_id] ?? 0) + 1;
  }
  return out;
}

/** Priority people not yet confirmed safe: the roster's count, else the accounting's. */
export function priorityAwaiting(roster?: Roster, accountingCount?: number): number {
  return roster?.priority_awaiting ?? accountingCount ?? 0;
}

/** "N priority people not responding" alert line for incident banners and cards. */
export function PriorityAlert({ count }: { count: number }) {
  const { t, lang } = useT();
  if (count <= 0) return null;
  return (
    <div className="priority-alert" role="status">
      <WarningIcon className="priority-alert-icon" />
      {t(`priority.awaiting.${pluralCategory(lang, count)}`, { n: count })}
    </div>
  );
}

function StatusPill({ person }: { person: PriorityPerson }) {
  const { t } = useT();
  const StatusIcon = STATUS_ICON[person.status] ?? ClockIcon;
  return (
    <span className={`pp-status ${person.status}`}>
      <StatusIcon />
      {tokenLabel(t, "pstatus", person.status)}
    </span>
  );
}

function NeedChip({ need }: { need: string }) {
  const { t } = useT();
  const NeedIcon = NEED_ICON[need];
  return (
    <li className="need-chip">
      {NeedIcon && <NeedIcon className="need-icon" />}
      {tokenLabel(t, "need", need)}
    </li>
  );
}

/** Unit and floor labels are building data ("Ap. 12", "Etaj 3"): shown verbatim. */
export const where = (p: PriorityPerson) => [p.unit_label ?? p.unit_id, p.floor_label].filter(Boolean).join(" · ");

/** `tel:` keeps digits and a leading +. */
const telHref = (phone: string) => `tel:${phone.replace(/[^\d+]/g, "")}`;

/** One priority person (also used in the hazard map drawer). */
export function PersonCard({ person }: { person: PriorityPerson }) {
  const { t, lang } = useT();
  const place = where(person);
  return (
    <article className={`pp pp-${person.status}`} aria-label={person.display_name}>
      <div className="pp-head">
        <div className="pp-who">
          <div className="pp-name">{person.display_name}</div>
          {place && <div className="pp-where">{place}</div>}
        </div>
        <div className="pp-state">
          <StatusPill person={person} />
          <div className="pp-since">
            {person.status_ts ? fmtAgo(person.status_ts, lang) : t("priority.noCheckin")}
          </div>
        </div>
      </div>
      {person.needs.length > 0 && (
        <ul className="pp-needs" aria-label={t("priority.needs")}>
          {person.needs.map((need) => (
            <NeedChip key={need} need={need} />
          ))}
        </ul>
      )}
      {person.note && (
        <blockquote className="pp-note" aria-label={t("priority.note")}>
          {person.note}
        </blockquote>
      )}
      {person.contact_phone ? (
        <a className="pp-call" href={telHref(person.contact_phone)}>
          <PhoneIcon />
          <span className="pp-call-label">{t("priority.callHousehold")}</span>
          {person.contact_name && <span>{person.contact_name}</span>}
          <span className="pp-phone">{person.contact_phone}</span>
        </a>
      ) : (
        person.contact_name && (
          <div className="pp-contact muted small">{t("priority.contact", { name: person.contact_name })}</div>
        )
      )}
    </article>
  );
}

/** PRIORITY panel: people not yet out as full cards (backend order: most urgent first), the
 *  ones already out on one compact line, and the data-protection note. Null when empty. */
export function PriorityPanel({ people }: { people: PriorityPerson[] | undefined }) {
  const { t } = useT();
  const titleId = useId();
  if (!people || people.length === 0) return null;
  const open = people.filter((p) => !isOut(p));
  const out = people.filter(isOut);
  return (
    <section className="priority-panel" aria-labelledby={titleId}>
      <div className="priority-head">
        <h3 id={titleId}>{t("priority.title")}</h3>
        <span className="muted small">{t("priority.subtitle")}</span>
      </div>
      {open.length > 0 && (
        <div className="pp-grid">
          {open.map((p) => (
            <PersonCard key={p.care_profile_id} person={p} />
          ))}
        </div>
      )}
      {out.length > 0 && (
        <div className="pp-safe-line">
          <span className="pp-status safe_outside">
            <CheckIcon />
            {t("priority.safeLine")}
          </span>{" "}
          {out.map((p, i) => (
            <span key={p.care_profile_id}>
              {i > 0 && ", "}
              <b>{p.display_name}</b>
              {where(p) && <span className="muted"> ({where(p)})</span>}
            </span>
          ))}
        </div>
      )}
      <div className="priority-privacy muted small">
        <LockIcon />
        {t("priority.privacy")}
      </div>
    </section>
  );
}

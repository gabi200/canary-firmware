import { useFusionExplanation } from "../api/hooks";
import type { EvidenceItem } from "../api/types";
import { pluralCategory, useT, type Lang, type TFn } from "../i18n";
import { fmtNumber } from "../lib/format";
import { prettyId, sensorLabel, tokenLabel } from "../lib/labels";
import { fmtAgo, fmtDuration } from "../lib/time";
import { Card } from "./Card";
import { StatusPill } from "./StatusPill";

function evidenceLabel(value: string, t: TFn): string {
  const fresh = /^fresh_([^:]+):(.+)$/.exec(value);
  if (fresh) return t("fusion.freshEvidence", { sensor: sensorLabel(fresh[1], t), device: fresh[2] });
  return tokenLabel(t, "fusion.evidence", value);
}

function EvidenceList({ title, items, label = evidenceLabel }: {
  title: string;
  items: string[];
  label?: (value: string, t: TFn) => string;
}) {
  const { t } = useT();
  return (
    <section className="fusion-evidence">
      <h4>{title}</h4>
      {items.length ? (
        <ul>{items.map((item, index) => <li key={`${item}-${index}`}>{label(item, t)}</li>)}</ul>
      ) : (
        <div className="muted small">{t("fusion.none")}</div>
      )}
    </section>
  );
}

const ROLES = ["supporting", "contradicting", "context", "missing"] as const;

function itemLabel(item: EvidenceItem, t: TFn): string {
  const room = item.zone_id ? prettyId(item.zone_id) : "";
  if (item.source === "sensor_trust")
    return t("fusion.item.trust", {
      device: item.subject,
      state: tokenLabel(t, "trust.state", item.status),
      reason: tokenLabel(t, "trust.reason", item.reason),
    });
  if (item.source === "motion") return t("fusion.item.motion", { room, state: tokenLabel(t, "motion.state", item.status) });
  return t("fusion.item.normal", {
    room,
    sensor: sensorLabel(item.subject, t),
    status: tokenLabel(t, "normal.status", item.status),
  });
}

interface ItemGroup {
  first: EvidenceItem;
  /** who it is about: device ids (sensor trust) or rooms (motion, room normal), each once */
  subjects: string[];
  /** one room, several metrics with the same room-normal statement: the metric names */
  metrics?: string[];
}

/** Items that make the same statement (same source, status, reason, strength; for a room normal also
 *  the metric) become one group listing its subjects. Exact grouping on the structured fields, so
 *  nothing is merged that differs. */
function groupItems(items: EvidenceItem[]): ItemGroup[] {
  const groups = new Map<string, ItemGroup>();
  for (const item of items) {
    const key = [item.source, item.status, item.reason, item.strength, item.source === "zone_normal" ? item.subject : ""].join("|");
    const who = item.source === "sensor_trust" ? item.subject : item.zone_id ? prettyId(item.zone_id) : "";
    const hit = groups.get(key);
    if (!hit) groups.set(key, { first: item, subjects: [who] });
    else if (!hit.subjects.includes(who)) hit.subjects.push(who);
  }
  return mergeMetrics([...groups.values()]);
}

/** Room-normal statements about one room that differ only by metric ("Kitchen, CO ...: still
 *  learning", "Kitchen, gas ...: still learning") become one group with the metrics as chips. */
function mergeMetrics(groups: ItemGroup[]): ItemGroup[] {
  const out: ItemGroup[] = [];
  const byRoom = new Map<string, ItemGroup>();
  for (const g of groups) {
    const f = g.first;
    if (f.source !== "zone_normal" || g.subjects.length !== 1) {
      out.push(g);
      continue;
    }
    const key = [f.zone_id, f.status, f.reason, f.strength].join("|");
    const hit = byRoom.get(key);
    if (!hit) {
      const merged: ItemGroup = { first: f, subjects: g.subjects, metrics: [f.subject] };
      byRoom.set(key, merged);
      out.push(merged);
    } else hit.metrics!.push(f.subject);
  }
  // a room with a single metric keeps its own sentence
  for (const g of out) if (g.metrics && g.metrics.length === 1) delete g.metrics;
  return out;
}

/** The statement of a group of several subjects ("6 sensor channels: suspect (...)"); one subject keeps its own sentence. */
function groupLabel(g: ItemGroup, t: TFn, lang: Lang): string {
  const n = g.subjects.length;
  if (g.metrics) return t("fusion.item.normalMetrics", { room: g.subjects[0], status: tokenLabel(t, "normal.status", g.first.status) });
  if (n === 1) return itemLabel(g.first, t);
  const cat = pluralCategory(lang, n);
  const item = g.first;
  if (item.source === "sensor_trust") {
    const p = { n, state: tokenLabel(t, "trust.state", item.status), reason: tokenLabel(t, "trust.reason", item.reason) };
    return t(`fusion.group.trust.${cat}`, p);
  }
  if (item.source === "motion") return t(`fusion.group.motion.${cat}`, { n, state: tokenLabel(t, "motion.state", item.status) });
  return t(`fusion.group.normal.${cat}`, {
    n,
    sensor: sensorLabel(item.subject, t),
    status: tokenLabel(t, "normal.status", item.status),
  });
}

/** Devices once, their channels as chips ("demo-air-kitchen" then co, gas, particulate); rooms and
 *  metrics as plain chips. A chip never breaks inside its text; the full id is its title. */
function SubjectChips({ g, t }: { g: ItemGroup; t: TFn }) {
  if (g.metrics) {
    return (
      <ul className="fusion-chips">
        {g.metrics.map((m) => (
          <li className="fusion-chip name" key={m}>{sensorLabel(m, t)}</li>
        ))}
      </ul>
    );
  }
  if (g.subjects.length < 2) return null;
  if (g.first.source !== "sensor_trust") {
    return (
      <ul className="fusion-chips">
        {g.subjects.map((who) => (
          <li className="fusion-chip name" key={who}>{who}</li>
        ))}
      </ul>
    );
  }
  const devices = new Map<string, string[]>();
  for (const id of g.subjects) {
    const cut = id.lastIndexOf(":");
    const device = cut > 0 ? id.slice(0, cut) : "";
    devices.set(device, [...(devices.get(device) ?? []), id]);
  }
  return (
    <ul className="fusion-devices">
      {[...devices].map(([device, ids]) => (
        <li className="fusion-device" key={device || "_"}>
          {device && <span className="fusion-dev-id">{device}</span>}
          <ul className="fusion-chips">
            {ids.map((id) => (
              <li className="fusion-chip" key={id} title={id}>{device ? id.slice(device.length + 1) : id}</li>
            ))}
          </ul>
        </li>
      ))}
    </ul>
  );
}

/** Room evidence from sensor trust, motion and room normals. Labels only: none of it moves the score. */
function EvidenceItems({ items }: { items: EvidenceItem[] }) {
  const { t, lang } = useT();
  return (
    <section className="fusion-items">
      <h4>{t("fusion.items")}</h4>
      <div className="muted small">{t("fusion.itemsNote")}</div>
      {items.length ? (
        <div className="fusion-grid">
          {ROLES.map((role) => {
            const mine = groupItems(items.filter((item) => item.role === role));
            // grouped lines with chips get the whole card width: the chips need it to sit on few lines
            const wide = mine.some((g) => g.metrics || g.subjects.length > 1);
            return mine.length ? (
              <section className={`fusion-evidence${wide ? " wide" : ""}`} key={role}>
                <h4>{t(`fusion.role.${role}`)}</h4>
                <ul>
                  {mine.map((g, index) => (
                    <li className="fusion-group" key={`${g.first.source}-${g.first.status}-${g.first.subject}-${index}`}>
                      {groupLabel(g, t, lang)}
                      {g.first.strength === "weak" && <span className="muted small"> · {t("fusion.weak")}</span>}
                      <SubjectChips g={g} t={t} />
                    </li>
                  ))}
                </ul>
              </section>
            ) : null;
          })}
        </div>
      ) : (
        <div className="muted small">{t("fusion.none")}</div>
      )}
    </section>
  );
}

/** Current advisory evidence only. It never changes, delays or suppresses an incident. */
export function FusionExplanationPanel({ incidentId }: { incidentId: string }) {
  const { t, lang } = useT();
  const fusion = useFusionExplanation(incidentId);
  const data = fusion.data;

  return (
    <Card title={t("fusion.title")} className="fusion-card">
      {!data ? (
        <div className={fusion.isError ? "err" : "muted small"}>
          {fusion.isError ? t("fusion.unavailable") : t("fusion.loading")}
        </div>
      ) : (
        <>
          <div className="fusion-head">
            <div className="fusion-score">
              <strong>{t("fusion.scoreValue", { score: fmtNumber(data.score, lang, 2, true) })}</strong>
              <span>{t("fusion.score")}</span>
            </div>
            <div className="fusion-summary small">
              <div>
                {t("fusion.classification")}: <b>{tokenLabel(t, "signal", data.classification)}</b>
              </div>
              <div>{t("fusion.witnesses", { n: data.fresh_witnesses })}</div>
              <div className="muted">{t("fusion.assessed", { ago: fmtAgo(data.assessed_ts, lang) })}</div>
            </div>
          </div>
          <div className="muted small fusion-note">{t("fusion.note")}</div>

          <div className="fusion-grid">
            <EvidenceList title={t("fusion.supporting")} items={data.supporting_evidence} />
            <EvidenceList title={t("fusion.contradicting")} items={data.contradicting_evidence} />
            <EvidenceList
              title={t("fusion.missing")}
              items={data.missing_inputs}
              label={(item, translate) => sensorLabel(item, translate)}
            />
            <EvidenceList
              title={t("fusion.overrides")}
              items={data.active_overrides}
              label={(item, translate) => tokenLabel(translate, "fusion.override", item)}
            />
          </div>

          {data.evidence_items && <EvidenceItems items={data.evidence_items} />}

          <section className="fusion-inputs">
            <h4>{t("fusion.inputs")}</h4>
            {data.inputs.length ? (
              data.inputs.map((input) => (
                <div className="row" key={input.name}>
                  <span className="grow">
                    {input.name === "signature" ? t("fusion.input.signature") : sensorLabel(input.name, t)}
                  </span>
                  <span className="muted small">
                    {input.age_seconds == null
                      ? t("fusion.inputNever")
                      : t("fusion.inputAge", { age: fmtDuration(input.age_seconds * 1000, lang) })}
                  </span>
                  <StatusPill state={input.status} label={t(`fusion.input.${input.status}`)} />
                </div>
              ))
            ) : (
              <div className="muted small">{t("fusion.none")}</div>
            )}
          </section>
        </>
      )}
    </Card>
  );
}

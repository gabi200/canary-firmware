import { useId, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";

import { pluralCategory, useT, type Lang, type MsgKey, type TFn } from "../i18n";
import { fmtNumber, fmtReading } from "../lib/format";
import {
  FOOTER_H,
  HEADER_H,
  type ChannelState,
  type ContributorView,
  type Layout,
  type MapSensor,
  type SourceView,
  type UnitBlock,
  type ZoneView,
  worse,
  zoneStatusText,
} from "../lib/hazardMap";
import { levelLabel, prettyId, sensorLabel, tokenLabel, zoneKindNote } from "../lib/labels";
import { placeLabel, textWidth, type Box, type Circle } from "../lib/labelPlace";
import { LEVEL_COLOR, type Level } from "../lib/metrics";
import { fmtAgo } from "../lib/time";
import { DropletIcon, HomeIcon, PersonIcon, SensorIcon, StairsIcon, WarningIcon, WindIcon } from "./Icons";
import { KIND_ICON } from "./ScopeBar";

interface Props {
  layout: Layout;
  zones: ZoneView[];
  contributors: ContributorView[];
  source: SourceView | null;
  selectedZoneId?: string | null;
  /** replay mode: zones show a past moment */
  replaying?: boolean;
  onSelect: (zoneId: string, sensorId?: string) => void;
  /** apartment header: open that apartment's sensors (shared scope) */
  onOpenUnit?: (unitId: string) => void;
}

const PRIORITY_COLOR = "var(--purple)";
/** Wi-Fi motion chip: blue for movement (never green: motion is not "safe"), muted otherwise. */
const MOTION_COLOR = { motion: "var(--sky)", no_recent_motion: "var(--text-2)", calibrating: "var(--amber-fg)", unavailable: "var(--muted)" } as const;
const SOURCE_COLOR = "var(--red)";
const SELECT_COLOR = "var(--sky)";
const TEXT = "var(--text)";
const SOFT = "var(--text-2)";
const MUTED = "var(--muted)";
const TILE_FILL = "var(--fp-tile)";
const BLOCK_FILL = "var(--fp-block)";
const BLOCK_STROKE = "var(--fp-block-stroke)";
/** Status words: the text step of each state colour, readable on a tile and on its tint. */
const LEVEL_TEXT: Record<Level, string> = {
  ok: "var(--green-fg)",
  attention: "var(--amber-fg)",
  danger: "var(--red-fg)",
  unknown: MUTED,
  none: "var(--accent-fg)",
};
/** The key reading's metric, short ("Gaz 31% din prag"). */
const METRIC_SHORT: Record<string, MsgKey> = {
  "co.ppm": "short.co",
  "gas.adc": "short.combustible_gas",
  "particulate.pm2_5": "metric.pm25",
  "particulate.pm10": "metric.pm10",
  "sensor.adc": "short.water",
};

/** Fill opacity of the level colour: stronger the closer the worst reading is to the device's
 *  danger threshold (no threshold known: a fixed mid value for warn / alarm edge states). */
function fillOpacity(level: Level, ratio: number | null): number {
  if (level === "unknown" || level === "none") return 0;
  const base = { ok: 0, attention: 0.07, danger: 0.1 }[level];
  return base + (level === "ok" ? 0 : 0.1 * (ratio ?? 0.35));
}

const LABEL_FS = 12;
const LABEL_H = 15;
const LABEL_PAD = 3; // room for the dark text halo (paint-order stroke)
const dotRadius = (weight: number) => 7 + 3 * weight;

/** `text`, cut with an ellipsis to fit `max` px. */
function ellipsize(text: string, max: number, fontSize: number, weight: number): string {
  if (textWidth(text, fontSize, weight) <= max) return text;
  let s = text;
  while (s.length > 1 && textWidth(`${s}…`, fontSize, weight) > max) s = s.slice(0, -1);
  return `${s.trimEnd()}…`;
}

/** A note that only repeats the label ("Spații comune" / common areas) is left out. */
function redundant(label: string, note: string): boolean {
  const plain = (v: string) => v.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();
  return plain(label).startsWith(plain(note));
}

interface PlacedLabel {
  text: string;
  box: Box;
}

interface OverlayPlan {
  badge: Box | null;
  contributors: Map<string, PlacedLabel | null>;
}

/**
 * Collision-free overlay labels. Every label must stay inside the body band of the tile its
 * anchor sits in (or inside the plan, clear of every tile, for an anchor between tiles) and
 * touch no header / footer row, dot, core or other label. Order: airflow badge, contributor
 * values by weight. A value that fits nowhere is shown by the dot's tooltip / aria label and the
 * command view's table. (The source's own text is the badge on its tile's top edge.)
 */
function planOverlays(
  layout: Layout,
  zones: ZoneView[],
  contributors: ContributorView[],
  source: SourceView | null,
  valueText: (c: ContributorView) => string,
): OverlayPlan {
  const plan: OverlayPlan = { badge: null, contributors: new Map() };
  if (!source) return plan;
  const tiles = zones.map((z) => z.placed);
  const rows: Box[] = tiles.flatMap((p) => [
    { x: p.x, y: p.y, w: p.w, h: HEADER_H },
    { x: p.x, y: p.y + p.h - FOOTER_H, w: p.w, h: FOOTER_H },
  ]);
  const cards: Box[] = tiles.map((p) => ({ x: p.x, y: p.y, w: p.w, h: p.h }));
  const tileAt = (px: number, py: number) => tiles.find((p) => px >= p.x && px <= p.x + p.w && py >= p.y && py <= p.y + p.h);
  const area = (px: number, py: number): { within: Box; obstacles: Box[] } => {
    const p = tileAt(px, py);
    if (!p) return { within: { x: 2, y: 2, w: layout.width - 4, h: layout.height - 4 }, obstacles: cards };
    return { within: { x: p.x + 6, y: p.body.y0, w: p.w - 12, h: p.body.y1 - p.body.y0 }, obstacles: rows };
  };
  const circles: Circle[] = [
    { x: source.x, y: source.y, r: 14, owner: "source" },
    ...contributors.map((c) => ({ x: c.x, y: c.y, r: dotRadius(c.weight) + 2, owner: c.deviceId })),
  ];
  const placed: Box[] = [];
  if (source.airflow) {
    const a = area(source.x, source.y);
    plan.badge = placeLabel(
      { id: "source", ax: source.x, ay: source.y, r: 14, w: 24, h: 18, within: a.within, sides: ["left", "right", "aboveLeft", "aboveRight", "belowLeft", "belowRight", "above", "below"] },
      placed,
      a.obstacles,
      circles,
    );
    if (plan.badge) placed.push(plan.badge);
  }
  for (const c of [...contributors].sort((a, b) => b.weight - a.weight)) {
    const text = valueText(c);
    const a = area(c.x, c.y);
    const box = placeLabel(
      {
        id: c.deviceId,
        ax: c.x,
        ay: c.y,
        r: dotRadius(c.weight) + 1,
        w: textWidth(text, LABEL_FS, 700) + 2 * LABEL_PAD,
        h: LABEL_H,
        within: a.within,
        sides: ["right", "left", "below", "above", "belowRight", "belowLeft", "aboveRight", "aboveLeft"],
      },
      placed,
      a.obstacles,
      circles,
    );
    if (box) placed.push(box);
    plan.contributors.set(c.deviceId, box ? { text, box } : null);
  }
  return plan;
}

const pctOf = (ratio: number | null, lang: Lang) => (ratio == null ? null : fmtNumber(Math.round(ratio * 100), lang, 0));

function shortLabel(s: MapSensor, t: TFn): string {
  if (s.type !== "device") return t(s.type === "water" ? "short.water" : "short.air");
  return tokenLabel(t, "short", s.device?.sensor_type ?? "");
}

/** The sensor's state word on its chip (null: presence devices, never graded). */
function sensorState(s: MapSensor, t: TFn): string | null {
  if (!s.online) return t("conn.offline");
  if (!s.hazard || s.level === "none") return null;
  return s.level === "unknown" ? t("map.noData") : levelLabel(s.level, t);
}

const SensorGlyph = ({ s, x, y }: { s: MapSensor; x: number; y: number }) => {
  const props = { x: x - 5.5, y: y - 5.5, width: 11, height: 11, style: { color: "var(--fp-ink)" } };
  if (s.type === "water") return <DropletIcon {...props} />;
  if (s.type === "air") return <WindIcon {...props} />;
  return <SensorIcon {...props} />;
};

/** The zone's channel closest to its danger threshold. */
function keyChannel(z: ZoneView): ChannelState | null {
  let best: ChannelState | null = null;
  for (const s of z.sensors) for (const c of s.channels) if (c.ratio != null && (best?.ratio == null || c.ratio > best.ratio)) best = c;
  return best;
}

/** The key reading, longest first ("Gaz 31% din prag", "Gaz 31%", "31%"). */
function readingTexts(z: ZoneView, t: TFn, lang: Lang): string[] {
  const c = keyChannel(z);
  if (!c || c.ratio == null) return [];
  const pct = fmtNumber(Math.round(c.ratio * 100), lang, 0);
  const metric = t(METRIC_SHORT[c.metric.field] ?? c.metric.label);
  return [t("plan.reading", { metric, pct }), t("plan.readingShort", { metric, pct }), `${pct}%`];
}

function sensorTip(s: MapSensor, t: TFn, lang: Lang): string[] {
  const lines = [s.name];
  if (s.type === "device") {
    const r = s.reading;
    lines.push(
      `${sensorLabel(s.device?.sensor_type ?? "", t)}${r ? ` · ${fmtReading(r.value, r.units, lang, t)}` : ""}`,
    );
    if (s.hazard) lines.push(levelLabel(s.level, t));
  } else {
    for (const c of s.channels) {
      const pct = pctOf(c.ratio, lang);
      lines.push(
        `${t(c.metric.label)}: ${c.value == null ? "—" : `${fmtNumber(c.value, lang, c.metric.digits, c.metric.fixed)} ${c.metric.unit}`}${pct ? ` · ${t("map.ofDanger", { pct })}` : ""}`,
      );
    }
    lines.push(t(s.online ? "conn.online" : "conn.offline"));
  }
  if (s.lastTs) lines.push(t("map.updated", { ago: fmtAgo(s.lastTs, lang) }));
  return lines;
}

function zoneTip(z: ZoneView, unit: string | undefined, source: SourceView | null, t: TFn, lang: Lang): string[] {
  const pct = pctOf(z.ratio, lang);
  const name = z.placed.zone.label || prettyId(z.placed.zone.id);
  const lines = [unit ? `${name} · ${unit}` : name];
  lines.push(z.level === "unknown" ? t("map.noData") : `${zoneStatusText(z, t)}${pct ? ` · ${t("map.ofDanger", { pct })}` : ""}`);
  if (z.isSource) {
    const conf = source ? ` (${t("dispatch.confidence", { pct: Math.round(source.confidence * 100) })})` : "";
    lines.push(`${t("map.sourceBadge")}${conf}`);
  }
  lines.push(t("map.sensorsInZone", { n: z.sensors.length }));
  if (z.occupancy > 0) lines.push(t("map.people", { n: fmtNumber(z.occupancy, lang, 0) }));
  if (z.priority > 0) lines.push(t("map.priorityChip", { n: z.priority }));
  const last = z.sensors.map((s) => s.lastTs).filter((x): x is string => !!x).sort().pop();
  if (last) lines.push(t("map.updated", { ago: fmtAgo(last, lang) }));
  return lines;
}

interface BlockState {
  level: Level;
  sensors: number;
  affected: boolean;
  /** outline colour of an affected block */
  hazard: string;
}

function blockState(u: UnitBlock, byId: Map<string, ZoneView>): BlockState {
  const zs = u.zoneIds.map((id) => byId.get(id)).filter((z): z is ZoneView => !!z);
  let level: Level = "unknown";
  for (const z of zs) level = level === "unknown" ? z.level : worse(level, z.level);
  const affected = zs.some((z) => z.isSource || z.isAffected);
  const hazard = level === "danger" || zs.some((z) => z.isSource) ? SOURCE_COLOR : LEVEL_COLOR.attention;
  return { level, sensors: zs.reduce((n, z) => n + z.sensors.length, 0), affected, hazard };
}

/** Interactive apartment-first plan: apartment headers, rooms and sensors are keyboard-focusable
 *  buttons (Enter / Space), in reading order. */
export function FloorPlan({ layout, zones, contributors, source, selectedZoneId, replaying, onSelect, onOpenUnit }: Props) {
  const { t, lang } = useT();
  const box = useRef<HTMLDivElement>(null);
  const [tip, setTip] = useState<{ x: number; y: number; lines: string[] } | null>(null);

  const show = (el: Element, lines: string[]) => {
    const host = box.current?.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    if (!host) return;
    // ponytail: clamp by half the CSS max-width (280px) so edge tips stay inside the plan
    const x = Math.min(Math.max(r.left - host.left + r.width / 2, 140), host.width - 140);
    setTip({ x, y: r.top - host.top, lines });
  };
  const hide = () => setTip(null);
  const button = (label: string, lines: string[], activate: () => void) => ({
    role: "button",
    tabIndex: 0,
    "aria-label": label,
    onClick: activate,
    onKeyDown: (e: KeyboardEvent) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        activate();
      }
    },
    onMouseEnter: (e: { currentTarget: Element }) => show(e.currentTarget, lines),
    onMouseLeave: hide,
    onFocus: (e: { currentTarget: Element }) => show(e.currentTarget, lines),
    onBlur: hide,
  });

  const uid = useId().replace(/[^a-zA-Z0-9_-]/g, "");
  const maskId = `halo-${uid}`;
  const byId = useMemo(() => new Map(zones.map((z) => [z.placed.zone.id, z])), [zones]);
  const unitOf = useMemo(() => {
    const m = new Map<string, UnitBlock>();
    for (const u of layout.units) for (const id of u.zoneIds) m.set(id, u);
    return m;
  }, [layout]);
  const sourceZone = zones.find((z) => z.isSource);
  const plan = useMemo(
    () => planOverlays(layout, zones, contributors, source, (c) => `${fmtNumber(c.value, lang, c.digits)} ${c.unit}`),
    [layout, zones, contributors, source, lang],
  );
  const sensorCount = (n: number) => t(`rooms.sensorCount.${pluralCategory(lang, n)}`, { n: fmtNumber(n, lang, 0) });
  const statusWord = (level: Level) => (level === "unknown" ? t("map.noData") : levelLabel(level, t));

  const floorText = (id: string, label: string | null) => {
    if (label) return label;
    const n = /(\d+)$/.exec(id)?.[1];
    return t("drawer.floor", { n: n ? String(Number(n)) : prettyId(id) });
  };

  /** One room tile: text (under its button), the button (with the source badge) and its sensor chips. */
  const tile = (z: ZoneView): ReactNode => {
    const { x, y, w, h, zone } = z.placed;
    const name = zone.label || prettyId(zone.id);
    const KindIcon = KIND_ICON[zone.kind] as (typeof KIND_ICON)[string] | undefined;

    // header row 1: kind icon, name (+ kind note), people / priority chips on the right
    const chips: ReactNode[] = [];
    let right = x + w - 10;
    if (z.occupancy > 0) {
      const n = fmtNumber(Math.round(z.occupancy), lang, 0);
      const cw = 26 + textWidth(n, 12, 600);
      right -= cw;
      chips.push(
        <g key="occ">
          <rect x={right} y={y + 8} width={cw} height={22} rx={6} fill="var(--fp-chip)" stroke="var(--border-strong)" />
          <PersonIcon x={right + 5} y={y + 11} width={15} height={15} style={{ color: TEXT }} />
          <text x={right + 21} y={y + 23.5} fill={TEXT} fontSize={12} fontWeight={600}>
            {n}
          </text>
        </g>,
      );
      right -= 6;
    }
    if (z.priority > 0) {
      const n = String(z.priority);
      const cw = 28 + textWidth(n, 12, 600);
      right -= cw;
      chips.push(
        <g key="prio">
          <rect x={right} y={y + 8} width={cw} height={22} rx={6} fill={PRIORITY_COLOR} stroke="#ffffff" strokeWidth={1.2} />
          <WarningIcon x={right + 6} y={y + 11} width={15} height={15} style={{ color: "#ffffff" }} />
          <text x={right + 23} y={y + 23.5} fill="#ffffff" fontSize={12} fontWeight={600}>
            {n}
          </text>
        </g>,
      );
      right -= 6;
    }
    if (z.motion && z.motion !== "no_presence_sensor") {
      const label = t(`motion.chip.${z.motion}`);
      const cw = 20 + textWidth(label, 12, 600);
      const color = MOTION_COLOR[z.motion];
      right -= cw;
      chips.push(
        <g key="motion">
          <title>{t(`motion.state.${z.motion}`)}</title>
          <rect x={right} y={y + 8} width={cw} height={22} rx={6} fill="var(--fp-chip)" stroke={color}
            strokeDasharray={z.motion === "unavailable" ? "3 3" : undefined} />
          <circle cx={right + 10} cy={y + 19} r={4} fill={z.motion === "motion" ? color : "none"} stroke={color} strokeWidth={1.5} />
          <text x={right + 18} y={y + 23.5} fill={color} fontSize={12} fontWeight={600}>
            {label}
          </text>
        </g>,
      );
      right -= 6;
    }
    const nameX = x + (KindIcon ? 38 : 16);
    const shownName = ellipsize(name, right - nameX - 4, 14, 600);
    const note = zoneKindNote(name, zone.kind, t);
    const noteX = nameX + textWidth(shownName, 14, 600) + 7;
    const showNote = note && shownName === name && noteX + textWidth(note, 12, 500) <= right - 4;

    // header row 2: status word, then the key reading as far as it fits
    const status = ellipsize(zoneStatusText(z, t), w - 30, 13, 600);
    const afterStatus = x + 16 + textWidth(status, 13, 600);
    const reading = readingTexts(z, t, lang).find((r) => afterStatus + textWidth(` · ${r}`, 12.5, 600) <= x + w - 10);

    // footer: one chip per sensor (state word dropped when the row is short, then "+N")
    const footY = y + h - FOOTER_H / 2 - 1;
    const limit = x + w - 10;
    const items = z.sensors.map((s) => {
      const label = shortLabel(s, t);
      const state = sensorState(s, t);
      const base = 23 + textWidth(label, 12, 600) + 9;
      return { s, label, state, base, full: base + (state ? 5 + textWidth(state, 12, 600) : 0) };
    });
    const start = x + 12;
    const fits = (ws: number[]) => ws.reduce((sum, v) => sum + v + 5, -5) <= limit - start;
    const withState = fits(items.map((i) => i.full));
    const chipsRow: ReactNode[] = [];
    let cursor = start;
    let hidden = 0;
    const reserve = withState || fits(items.map((i) => i.base)) ? 0 : 26; // room for "+N"
    for (const it of items) {
      const cw = withState ? it.full : it.base;
      if (hidden || cursor + cw > limit - reserve) {
        hidden += 1;
        continue;
      }
      const { s } = it;
      const cx = cursor + 11;
      const lines = sensorTip(s, t, lang);
      const color = s.level === "none" ? "var(--sky)" : LEVEL_COLOR[s.level];
      chipsRow.push(
        <g key={s.id} className="fp-btn" {...button(lines.join(", "), lines, () => onSelect(s.zoneId, s.id))}>
          <rect x={cursor} y={footY - 11} width={cw} height={22} rx={6} fill="var(--fp-chip)" stroke="var(--border-strong)" />
          <circle cx={cx} cy={footY} r={8} fill={color} opacity={s.online ? 1 : 0.45} />
          <SensorGlyph s={s} x={cx} y={footY} />
          <text x={cursor + 23} y={footY + 4} fill={TEXT} fontSize={12} fontWeight={600}>
            {it.label}
            {withState && it.state && (
              <tspan dx={5} fill={s.online ? LEVEL_TEXT[s.level] : MUTED} fontWeight={700}>
                {it.state}
              </tspan>
            )}
          </text>
          <rect className="fp-ring" x={cursor - 2} y={footY - 13} width={cw + 4} height={26} rx={8} />
        </g>,
      );
      cursor += cw + 5;
    }

    const lines = zoneTip(z, unitOf.get(zone.id)?.label, source, t, lang);
    const badgeFull = source ? t("plan.sourceBadge", { pct: `${fmtNumber(Math.round(source.confidence * 100), lang, 0)}%` }) : "";
    const badge = textWidth(badgeFull, 12, 600) + 20 <= w - 24 ? badgeFull : t("map.sourceBadge");
    return (
      <g key={`t-${zone.id}`}>
        <g aria-hidden="true">
          {KindIcon && <KindIcon x={x + 14} y={y + 9} width={18} height={18} style={{ color: SOFT }} />}
          <text className="fp-text" x={nameX} y={y + 24} fill={TEXT} fontSize={14} fontWeight={600}>
            {shownName}
          </text>
          {showNote && (
            <text className="fp-text" x={noteX} y={y + 24} fill={z.level === "danger" || z.level === "attention" ? SOFT : MUTED} fontSize={12} fontWeight={500}>
              {note}
            </text>
          )}
          <text className="fp-text" x={x + 16} y={y + 43} fontSize={13} fontWeight={600} fill={LEVEL_TEXT[z.level]}>
            {status}
            {reading && (
              <tspan fill={SOFT} fontSize={12.5} fontWeight={600}>
                {` · ${reading}`}
              </tspan>
            )}
          </text>
          {chips}
        </g>
        <g className="fp-btn" {...button(lines.join(", "), lines, () => onSelect(zone.id))}>
          <rect x={x} y={y} width={w} height={h} rx={6} fill="transparent" />
          {z.isSource && source && (
            <g>
              <rect x={x + 12} y={y - 13} width={textWidth(badge, 12, 600) + 20} height={18} rx={6} fill={SOURCE_COLOR} stroke="var(--fp-bg)" strokeWidth={2} />
              <text x={x + 22} y={y} fill="#ffffff" fontSize={12} fontWeight={600}>
                {badge}
              </text>
            </g>
          )}
          <rect className="fp-ring" x={x - 3} y={y - 3} width={w + 6} height={h + 6} rx={8} />
        </g>
        {chipsRow}
        {hidden > 0 && (
          <text x={limit} y={footY + 4} textAnchor="end" fill={MUTED} fontSize={12} fontWeight={600}>
            +{hidden}
          </text>
        )}
      </g>
    );
  };

  /** Apartment / common block: header (a button: opens its sensors) and its room tiles. */
  const block = (u: UnitBlock): ReactNode => {
    const st = blockState(u, byId);
    const { x, y, w } = u;
    const Icon = u.common ? StairsIcon : HomeIcon;
    const statusText = statusWord(st.level);
    // status line right of the label: with the sensor count when it fits, else the word only
    // (a long label on a phone), the label cut last
    const room = w - 42 - 14;
    const labelW = textWidth(u.label, 16, 600);
    const wordW = textWidth(statusText, 13, 600);
    const fullCount = ` · ${sensorCount(st.sensors)}`;
    const countText = labelW + 16 + wordW + textWidth(fullCount, 13, 600) <= room ? fullCount : "";
    const statusW = wordW + (countText ? textWidth(countText, 13, 600) : 0);
    const showStatus = room - statusW - 16 >= Math.min(labelW, 60);
    const labelMax = room - (showStatus ? statusW + 16 : 0);
    const label = ellipsize(u.label, labelMax, 16, 600);
    const tag = t("plan.common");
    const tagX = x + 42 + textWidth(label, 16, 600) + 8;
    const showTag = u.common && label === u.label && !redundant(u.label, tag) && tagX + textWidth(tag, 12, 600) <= x + w - 14 - (showStatus ? statusW + 16 : 0);
    const lines = [
      u.common && !redundant(u.label, tag) ? `${u.label} (${tag})` : u.label,
      `${statusText}${fullCount}`,
      ...(st.affected ? [t("plan.affected")] : []),
      ...(onOpenUnit ? [t("plan.openUnit", { unit: u.label })] : []),
    ];
    const head = (
      <g aria-hidden="true">
        <Icon x={x + 14} y={y + 12} width={20} height={20} style={{ color: SOFT }} />
        <text className="fp-text" x={x + 42} y={y + 29} fill={TEXT} fontSize={16} fontWeight={600}>
          {label}
        </text>
        {showTag && (
          <text className="fp-text" x={tagX} y={y + 29} fill={MUTED} fontSize={12} fontWeight={600}>
            {tag}
          </text>
        )}
        {showStatus && (
          <text className="fp-text" x={x + w - 14} y={y + 29} textAnchor="end" fontSize={13} fontWeight={600} fill={LEVEL_TEXT[st.level]}>
            {statusText}
            {countText && (
              <tspan fill={MUTED} fontWeight={600}>
                {countText}
              </tspan>
            )}
          </text>
        )}
      </g>
    );
    return (
      <g key={`u-${u.id}`} role="group" aria-label={lines.slice(0, st.affected ? 3 : 2).join(", ")}>
        {head}
        {onOpenUnit && (
          <g className="fp-btn" {...button(lines.join(", "), lines, () => onOpenUnit(u.id))}>
            <rect x={x} y={y} width={w} height={40} rx={8} fill="transparent" />
            <rect className="fp-ring" x={x + 4} y={y + 4} width={w - 8} height={36} rx={6} />
          </g>
        )}
        {u.zoneIds.map((id) => {
          const z = byId.get(id);
          return z ? tile(z) : null;
        })}
      </g>
    );
  };

  return (
    <div className="fp-wrap" ref={box}>
      <svg
        className={`floorplan ${replaying ? "replaying" : ""}`}
        viewBox={`0 0 ${layout.width} ${layout.height}`}
        preserveAspectRatio="xMidYMid meet"
        role="group"
        aria-label={t("floor.aria")}
      >
        {/* 1. floors, blocks and room fills */}
        {layout.floors.map((f) => {
          const label = floorText(f.id, f.label);
          const lw = textWidth(label, 13, 600);
          return (
            <g key={`fl-${f.id}`} aria-hidden="true">
              <text className="fp-text" x={f.x + 2} y={f.y + 19} fill={MUTED} fontSize={13} fontWeight={600}>
                {label}
              </text>
              <line x1={f.x + lw + 14} x2={f.x + f.w} y1={f.y + 14} y2={f.y + 14} stroke="var(--border-strong)" />
            </g>
          );
        })}
        {layout.units.map((u) => {
          const st = blockState(u, byId);
          return (
            <g key={`ub-${u.id}`}>
              <rect
                x={u.x}
                y={u.y}
                width={u.w}
                height={u.h}
                rx={8}
                fill={u.common ? "var(--fp-block-2)" : BLOCK_FILL}
                stroke={st.affected ? st.hazard : BLOCK_STROKE}
                strokeWidth={st.affected ? 1.5 : 1}
                strokeDasharray={u.common && !st.affected ? "4 4" : undefined}
              />
            </g>
          );
        })}
        {zones.map((z) => {
          const { x, y, w, h } = z.placed;
          const sel = z.placed.zone.id === selectedZoneId;
          return (
            <g key={`f-${z.placed.zone.id}`}>
              <rect x={x} y={y} width={w} height={h} rx={6} fill={TILE_FILL} />
              <rect
                x={x}
                y={y}
                width={w}
                height={h}
                rx={6}
                fill={LEVEL_COLOR[z.level]}
                fillOpacity={fillOpacity(z.level, z.ratio)}
                stroke={sel ? SELECT_COLOR : z.isSource ? SOURCE_COLOR : z.isAffected ? LEVEL_COLOR.attention : z.level === "danger" || z.level === "attention" ? LEVEL_COLOR[z.level] : "var(--border)"}
                strokeWidth={sel ? 2 : z.isSource ? 2 : z.isAffected ? 1.5 : 1}
                strokeDasharray={z.isAffected && !z.isSource && !sel ? "6 4" : undefined}
              />
            </g>
          );
        })}

        {/* 2. overlays (under every room's text and chips) */}
        {source && (
          <>
            {/* uncertainty halo: one radial falloff from the estimate outwards (no ruled edges).
                With a source tile it is clipped to that room's rounded rectangle and stays light
                enough for the room's name / status rows and sensor chips drawn over it. Between
                rooms it stays unclipped, faint over the room tiles so their contents read. */}
            <defs>
              <radialGradient id={`${maskId}-fall`} gradientUnits="userSpaceOnUse" cx={source.x} cy={source.y} r={source.r}>
                <stop offset="0" stopColor={SOURCE_COLOR} stopOpacity={0.26} />
                <stop offset="0.55" stopColor={SOURCE_COLOR} stopOpacity={0.12} />
                <stop offset="1" stopColor={SOURCE_COLOR} stopOpacity={0} />
              </radialGradient>
              {sourceZone ? (
                <clipPath id={maskId}>
                  <rect x={sourceZone.placed.x} y={sourceZone.placed.y} width={sourceZone.placed.w} height={sourceZone.placed.h} rx={6} />
                </clipPath>
              ) : (
                <mask id={maskId} maskUnits="userSpaceOnUse" x={0} y={0} width={layout.width} height={layout.height}>
                  <rect x={0} y={0} width={layout.width} height={layout.height} fill="#ffffff" />
                  {zones.map((z) => (
                    <rect key={z.placed.zone.id} x={z.placed.x} y={z.placed.y} width={z.placed.w} height={z.placed.h} rx={6} fill="#4d4d4d" />
                  ))}
                </mask>
              )}
            </defs>
            <circle
              cx={source.x}
              cy={source.y}
              r={source.r}
              fill={`url(#${maskId}-fall)`}
              clipPath={sourceZone ? `url(#${maskId})` : undefined}
              mask={sourceZone ? undefined : `url(#${maskId})`}
              stroke={sourceZone ? undefined : SOURCE_COLOR}
              strokeOpacity={0.45}
              strokeDasharray="4 4"
              pointerEvents="none"
            />
          </>
        )}
        {source &&
          contributors.map((c) => (
            <line
              key={`l-${c.deviceId}`}
              x1={c.x}
              y1={c.y}
              x2={source.x}
              y2={source.y}
              stroke="var(--fp-contrast)"
              strokeOpacity={0.3 + 0.6 * c.weight}
              strokeWidth={1 + 5 * c.weight}
              strokeLinecap="round"
            />
          ))}
        {source && (
          <g pointerEvents="none">
            <circle className="fp-pulse" cx={source.x} cy={source.y} r={13} fill="none" stroke="var(--fp-contrast)" strokeWidth={2} />
            <circle cx={source.x} cy={source.y} r={6.5} fill="#ffffff" stroke={SOURCE_COLOR} strokeWidth={2.5} />
          </g>
        )}

        {/* 3. per block, in reading order: header, then each room's text, button and sensor chips */}
        {layout.units.map(block)}

        {/* 4a. airflow badge (placed collision-free next to the source) */}
        {source && plan.badge && (
          <g
            className="fp-btn"
            {...button(t("map.airflowHint"), [t("map.airflowHint")], () => sourceZone && onSelect(sourceZone.placed.zone.id))}
          >
            <rect x={plan.badge.x} y={plan.badge.y} width={24} height={18} rx={6} fill="var(--panel)" stroke={SELECT_COLOR} />
            <WindIcon x={plan.badge.x + 6} y={plan.badge.y + 3} width={12} height={12} style={{ color: SELECT_COLOR }} />
            <rect className="fp-ring" x={plan.badge.x - 2} y={plan.badge.y - 2} width={28} height={22} rx={6} />
          </g>
        )}

        {/* 4b. contributor dots (their value labels come from the plan) */}
        {contributors.map((c) => {
          const lines = [c.name, `${fmtNumber(c.value, lang, c.digits)} ${c.unit}`, t("map.weight", { pct: `${fmtNumber(Math.round(c.weight * 100), lang, 0)}%` })];
          return (
            <g
              key={`c-${c.deviceId}`}
              className="fp-btn"
              {...button(lines.join(", "), lines, () => onSelect(c.zoneId, c.sensorId))}
            >
              <circle cx={c.x} cy={c.y} r={dotRadius(c.weight)} fill={SOURCE_COLOR} stroke="#ffffff" strokeWidth={2} />
              <circle className="fp-ring" cx={c.x} cy={c.y} r={dotRadius(c.weight) + 4} />
            </g>
          );
        })}

        {/* contributor value labels: never clickable (the room stays clickable) */}
        {contributors.map((c) => {
          const l = plan.contributors.get(c.deviceId);
          return l ? (
            <text
              key={`cl-${c.deviceId}`}
              className="fp-text fp-halo"
              x={l.box.x + LABEL_PAD}
              y={l.box.y + LABEL_H - 3}
              fill="var(--fp-contrast)"
              fontSize={LABEL_FS}
              fontWeight={700}
              pointerEvents="none"
            >
              {l.text}
            </text>
          ) : null;
        })}
      </svg>

      {tip && (
        <div className="fp-tip" style={{ left: tip.x, top: tip.y }} role="tooltip">
          {tip.lines.map((l, i) => (
            <div key={i} className={i === 0 ? "fp-tip-title" : undefined}>
              {l}
            </div>
          ))}
        </div>
      )}

      <div className="legend">
        {(["ok", "attention", "danger"] as const).map((l) => (
          <span key={l}>
            <span className="sw" style={{ background: LEVEL_COLOR[l] }} /> {levelLabel(l, t)}
          </span>
        ))}
        <span><span className="sw" style={{ background: MUTED }} /> {t("map.noData")}</span>
        {source && (
          <>
            <span><span className="sw round" style={{ background: "#ffffff", borderColor: SOURCE_COLOR }} /> {t("map.legendSource")}</span>
            <span><span className="sw line" /> {t("map.legendLine")}</span>
          </>
        )}
        {zones.some((z) => z.occupancy > 0) && <span><PersonIcon /> {t("map.legendPeople")}</span>}
        {zones.some((z) => z.priority > 0) && (
          <span><span className="sw" style={{ background: PRIORITY_COLOR }} /> {t("map.legendPriority")}</span>
        )}
      </div>
      <div className="muted small fp-hint">{t(onOpenUnit ? "plan.hint" : "map.hint")}</div>
    </div>
  );
}

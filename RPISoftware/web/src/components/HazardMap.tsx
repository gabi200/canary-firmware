import { useEffect, useLayoutEffect, useMemo, useRef, useState, type RefObject } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";

import {
  useAccounting,
  useDevices,
  useEvacuation,
  useMotion,
  useNodeHistories,
  useNodes,
  useOccupancy,
  useReadings,
  useResidents,
  useRoster,
  useSummary,
  useTriangulation,
  useTriangulationHistory,
  useZones,
} from "../api/hooks";
import type { Incident, Triangulation } from "../api/types";
import { useT } from "../i18n";
import {
  MAP_FIELDS,
  MINI_WIDTH,
  type UnitInfo,
  contributorViews,
  historyRows,
  incidentWindowMinutes,
  layoutZones,
  liveSensors,
  sensorsAt,
  sourceView,
  zoneViews,
} from "../lib/hazardMap";
import { natural } from "../lib/format";
import { buildZoneNames, prettyId } from "../lib/labels";
import { latestByDevice } from "../lib/latest";
import { unitsFromZones, useScope } from "../lib/scope";
import { fmtClock, parseTs } from "../lib/time";
import { FloorPlan } from "./FloorPlan";
import { ObservedSequence } from "./ObservedSequence";
import { RoomIndex } from "./RoomIndex";
import { PauseIcon, PlayIcon } from "./Icons";
import { priorityByUnit } from "./PriorityPanel";
import { ZoneCommand } from "./ZoneCommand";

/** Replay fetches at most this many node histories (one request each). */
const MAX_REPLAY_NODES = 8;

/** Width of the element in CSS px (0 until measured), followed while it resizes: the plan is laid
 *  out for it and drawn 1:1. */
function useWidth<T extends HTMLElement>(): [RefObject<T>, number] {
  const ref = useRef<T>(null);
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setWidth(Math.floor(el.clientWidth));
    measure();
    if (typeof ResizeObserver === "undefined") return;
    // next frame: re-laying out the plan inside the observer callback would resize it again
    let frame = 0;
    const ro = new ResizeObserver(() => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(measure);
    });
    ro.observe(el);
    return () => {
      cancelAnimationFrame(frame);
      ro.disconnect();
    };
  }, []);
  return [ref, width];
}

function ReplayBar({
  start,
  end,
  value,
  onChange,
  loading,
  estimate,
}: {
  start: number;
  end: number;
  value: number | null;
  onChange: (t: number | null) => void;
  loading: boolean;
  /** stored estimates available: ts of the one shown (null = none yet); undefined = no history */
  estimate?: string | null;
}) {
  const { t, lang } = useT();
  const [playing, setPlaying] = useState(false);
  const span = Math.max(end - start, 1000);

  // play: step through the incident in ~12 s (user-started, stops at "now")
  useEffect(() => {
    if (!playing) return;
    let cur = value ?? start;
    const timer = window.setInterval(() => {
      cur += span / 120;
      if (cur >= end) {
        window.clearInterval(timer);
        setPlaying(false);
        onChange(null);
      } else onChange(cur);
    }, 100);
    return () => window.clearInterval(timer);
  }, [playing]); // value / end are read once when play starts

  const live = value == null;
  return (
    <div className="replay">
      <div className="replay-head">
        <span className="panel-label">{t("scrub.title")}</span>
        <button
          type="button"
          className="btn small-btn"
          onClick={() => {
            if (!playing && live) onChange(start);
            setPlaying((p) => !p);
          }}
          aria-pressed={playing}
        >
          {playing ? <PauseIcon /> : <PlayIcon />} {playing ? t("scrub.pause") : t("scrub.play")}
        </button>
        <button
          type="button"
          className="btn small-btn"
          disabled={live}
          onClick={() => {
            setPlaying(false);
            onChange(null);
          }}
        >
          {t("scrub.backToLive")}
        </button>
        <span className="spacer" />
        {!live && estimate !== undefined && (
          <span className="small replay-estimate">
            {estimate ? t("scrub.estimateAt", { time: fmtClock(estimate, lang) }) : t("scrub.noEstimate")}
          </span>
        )}
        <span className={`small ${live ? "replay-live" : "replay-past"}`}>
          {live ? t("scrub.live") : t("scrub.showing", { time: fmtClock(value!, lang) })}
        </span>
      </div>
      <input
        type="range"
        className="replay-range"
        min={start}
        max={end}
        step={Math.max(1000, Math.round(span / 400))}
        value={value ?? end}
        onChange={(e) => {
          setPlaying(false);
          const v = Number(e.target.value);
          onChange(v >= end - 1000 ? null : v);
        }}
        aria-label={t("scrub.slider")}
        aria-valuetext={live ? t("scrub.live") : fmtClock(value!, lang)}
      />
      <div className="replay-foot small muted">
        <span>{t("scrub.start", { time: fmtClock(start, lang) })}</span>
        <span>{loading ? t("scrub.loading") : t(estimate !== undefined ? "scrub.noteHistory" : "scrub.note")}</span>
      </div>
    </div>
  );
}

/** Interactive hazard map for the manager and dispatch views: live zone state, triangulation
 *  overlay, incident replay and a details drawer (deep link: ?zone=<id>&sensor=<id>). */
export function HazardMap({ incident }: { incident: Incident | null }) {
  const { t } = useT();
  const zones = useZones();
  const devices = useDevices();
  const readings = useReadings(undefined, 400);
  const nodes = useNodes();
  const summary = useSummary();
  const triangulation = useTriangulation(incident?.id ?? null);
  const triHistory = useTriangulationHistory(incident?.id ?? null);
  const roster = useRoster(incident?.id ?? null);
  const accounting = useAccounting(incident?.id ?? null);
  const occupancy = useOccupancy();
  const motion = useMotion();
  const residents = useResidents();
  const evacuation = useEvacuation();
  const [params, setParams] = useSearchParams();
  const [replayT, setReplayT] = useState<number | null>(null);
  /** floor shown on the plan ("all": every floor stacked) */
  const [floorSel, setFloorSel] = useState("all");
  const scope = useScope();
  const navigate = useNavigate();
  const [mapRef, mapWidth] = useWidth<HTMLDivElement>();

  const zoneList = useMemo(() => zones.data ?? [], [zones.data]);
  const nodeList = useMemo(() => nodes.data ?? [], [nodes.data]);
  // apartment labels and which units are common areas: the admin API when this role may call it
  // (lib/scope), else inferred from the room kinds; a label the zones lack comes from the summary
  const summaryUnitLabels = (summary.data?.zones ?? []).map((z) => `${z.unit_id}=${z.unit_label}`).join(";");
  const unitInfo = useMemo(() => {
    const fromSummary = new Map<string, string>();
    for (const z of summary.data?.zones ?? []) if (z.unit_id && z.unit_label) fromSummary.set(z.unit_id, z.unit_label);
    const m = new Map<string, UnitInfo>();
    for (const u of [...unitsFromZones(zoneList), ...scope.units]) {
      m.set(u.id, { label: u.label === prettyId(u.id) ? (fromSummary.get(u.id) ?? u.label) : u.label, common: u.common });
    }
    return m;
  }, [zoneList, scope.units, summaryUnitLabels]); // summary.data is a new object every poll
  const hasIncident = !!incident;
  const floors = useMemo(
    () =>
      [...new Map(zoneList.map((z) => [z.floor_id, z.floor_label || prettyId(z.floor_id)])).entries()].sort((a, b) =>
        natural(a[1], b[1]),
      ),
    [zoneList],
  );
  const floorShown = floors.some(([id]) => id === floorSel) ? floorSel : "all";
  const planZones = useMemo(
    () => (floorShown === "all" ? zoneList : zoneList.filter((z) => z.floor_id === floorShown)),
    [zoneList, floorShown],
  );
  const layout = useMemo(
    () => layoutZones(planZones, { width: mapWidth || 960, units: unitInfo, overlays: hasIncident }),
    [planZones, mapWidth, unitInfo, hasIncident],
  );
  // the command view's mini-map: same schematic, compact
  const miniLayout = useMemo(() => layoutZones(zoneList, { width: MINI_WIDTH, units: unitInfo, compact: true }), [zoneList, unitInfo]);
  const latest = useMemo(() => latestByDevice(readings.data), [readings.data]);
  const live = useMemo(() => liveSensors(nodeList, devices.data ?? [], latest), [nodeList, devices.data, latest]);
  const zoneNames = useMemo(() => buildZoneNames(zoneList), [zoneList]);
  const tri = incident ? triangulation.data : undefined;

  // replay: nodes in the zones involved in the incident
  const windowMinutes = incidentWindowMinutes(incident?.opened_ts);
  const involved = new Set<string>([
    ...(tri?.contributors ?? []).map((c) => c.zone_id),
    ...(incident?.affected_zone_ids ?? []),
    ...[incident?.primary_zone_id, incident?.est_source_zone_id, tri?.source_zone_id].filter((x): x is string => !!x),
  ]);
  // small buildings: every node; otherwise only the nodes of the involved zones (capped)
  const replayNodes = !incident
    ? []
    : nodeList.length <= MAX_REPLAY_NODES
      ? nodeList
      : nodeList.filter((n) => involved.has(n.zone_id)).slice(0, MAX_REPLAY_NODES);
  const histories = useNodeHistories(
    replayNodes.map((n) => ({ nodeId: n.id, fields: MAP_FIELDS[n.kind] ?? [] })),
    windowMinutes,
    windowMinutes <= 360 ? 60_000 : 300_000,
  );
  const historyStamp = histories.map((h) => h.dataUpdatedAt).join(",");
  const historyMap = useMemo(
    () => historyRows(nodeList, histories.map((h) => h.data)),
    [nodeList, historyStamp], // histories is a new array every render; its data changes with the stamp
  );
  useEffect(() => setReplayT(null), [incident?.id]);

  const sensors = replayT != null ? sensorsAt(live, historyMap, replayT) : live;
  // replay moves the estimate through its stored snapshots (older backends: current estimate)
  const snapshots = triHistory.isError ? undefined : triHistory.data?.snapshots;
  const snapshot =
    replayT != null && snapshots
      ? [...snapshots].reverse().find((s) => parseTs(s.ts) <= replayT) ?? null
      : undefined;
  const shownTri: Triangulation | undefined =
    snapshot === undefined ? tri : snapshot ? { ...snapshot, incident_id: incident?.id ?? "" } : undefined;
  const occupancyByZone: Record<string, number> = {};
  for (const z of (incident ? accounting.data?.zones_with_people : occupancy.data?.zones) ?? []) {
    occupancyByZone[z.zone_id] = z.persons_est;
  }
  const source = incident && snapshot !== null ? sourceView(shownTri, incident, layout) : null;
  // Wi-Fi motion is live only: a replay shows no motion chips rather than today's on the past
  const motionByZone = new Map((motion.data?.zones ?? []).map((z) => [z.zone_id, z.state]));
  const views = zoneViews(layout, sensors, {
    incident,
    sourceZoneId: source?.zoneId ?? null,
    occupancyByZone,
    priorityByUnit: incident ? priorityByUnit(roster.data?.priority) : {},
  }).map((v) => (replayT == null ? { ...v, motion: motionByZone.get(v.placed.zone.id) } : v));
  const contributors = incident ? contributorViews(shownTri, layout, nodeList, latest) : [];

  // the command view always shows the live state (the map may be replaying the past)
  const replaying = replayT != null;
  const liveSource = replaying ? (incident ? sourceView(tri, incident, layout) : null) : source;
  const liveViews = replaying
    ? zoneViews(layout, live, {
        incident,
        sourceZoneId: liveSource?.zoneId ?? null,
        occupancyByZone,
        priorityByUnit: incident ? priorityByUnit(roster.data?.priority) : {},
      })
    : views;
  const selectedId = params.get("zone");
  const selected = liveViews.find((v) => v.placed.zone.id === selectedId) ?? null;
  const miniSource = selected && incident ? sourceView(tri, incident, miniLayout) : null;
  const miniViews = selected
    ? zoneViews(miniLayout, live, {
        incident,
        sourceZoneId: miniSource?.zoneId ?? null,
        occupancyByZone,
        priorityByUnit: incident ? priorityByUnit(roster.data?.priority) : {},
      })
    : [];
  const miniContributors = selected && incident ? contributorViews(tri, miniLayout, nodeList, latest) : [];
  const select = (zoneId: string, sensorId?: string) =>
    setParams(
      (p) => {
        p.set("zone", zoneId);
        if (sensorId) p.set("sensor", sensorId);
        else p.delete("sensor");
        return p;
      },
      { replace: true },
    );
  // apartment header: that apartment becomes the shared scope of the Sensors page
  const openUnit = (unitId: string) => {
    scope.setScope({ unit: unitId, room: "all" });
    navigate("/sensors");
  };
  const close = () =>
    setParams(
      (p) => {
        p.delete("zone");
        p.delete("sensor");
        return p;
      },
      { replace: true },
    );

  const start = incident ? parseTs(incident.opened_ts) : 0;
  const end = Date.now();
  // floors holding a room of the incident get a red mark on their tab
  const floorOfZone = new Map(zoneList.map((z) => [z.id, z.floor_id]));
  const hotFloors = new Set([...involved].map((id) => floorOfZone.get(id)));

  return (
    <div className="hazard-map" ref={mapRef}>
      {floors.length > 1 && (
        <div className="seg map-floors" role="group" aria-label={t("map.floorsAria")}>
          {[["all", t("map.allFloors")] as const, ...floors].map(([id, label]) => (
            <button
              key={id}
              type="button"
              className={floorShown === id ? "active" : ""}
              aria-pressed={floorShown === id}
              onClick={() => setFloorSel(id)}
            >
              {id !== "all" && hotFloors.has(id) && <span className="lvl danger" aria-hidden="true" />} {label}
            </button>
          ))}
        </div>
      )}
      <FloorPlan
        layout={layout}
        zones={views}
        contributors={contributors}
        source={source}
        selectedZoneId={selectedId}
        replaying={replayT != null}
        onSelect={select}
        onOpenUnit={openUnit}
      />
      {incident && replayNodes.length > 0 && end > start && (
        <ReplayBar
          start={start}
          end={end}
          value={replayT}
          onChange={setReplayT}
          loading={histories.some((h) => h.isLoading)}
          estimate={snapshots ? (snapshot ? snapshot.ts : null) : undefined}
        />
      )}
      {incident && <ObservedSequence incidentId={incident.id} replayT={replayT} zoneNames={zoneNames} />}
      <RoomIndex
        zones={liveViews}
        unitLabel={(id) => unitInfo.get(id)?.label ?? prettyId(id)}
        selectedId={selectedId}
        onSelect={(id) => select(id)}
      />
      {selected && (
        <ZoneCommand
          zone={selected}
          focusSensorId={params.get("sensor")}
          onClose={close}
          onSelectZone={(id) => select(id)}
          ctx={{
            incident,
            windowMinutes,
            triangulation: tri,
            contributors: miniContributors,
            zoneNames,
            roster: incident ? roster.data : undefined,
            residents: residents.data,
            evacuation: evacuation.data,
            summaryZone: summary.data?.zones.find((z) => z.zone_id === selected.placed.zone.id),
            layout: miniLayout,
            zones: miniViews,
            source: miniSource,
          }}
        />
      )}
    </div>
  );
}

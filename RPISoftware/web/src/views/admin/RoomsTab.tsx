/**
 * Room manager: every room of the building on an editable floor plan (drag to reposition, snaps
 * to 0.5 m, arrow keys move the selected room; rooms outside the chosen apartment are faded), a
 * list of the chosen apartment's rooms (every room for the whole building) with the sensors'
 * state, an editor for the selected room (name, kind, apartment, position, its sensors, delete)
 * and the apartments / floors panel. The selected room is the scope bar's room.
 */
import { useEffect, useRef, useState } from "react";

import {
  useAdminFloors,
  useAdminUnits,
  useAdminZones,
  useCreateZone,
  useDeleteZone,
  useMoveNode,
  useUpdateZone,
} from "../../api/adminHooks";
import { ApiError } from "../../api/client";
import type { AdminFloor, AdminUnit, AdminZone, AdminZoneNode, AdminZonePatch } from "../../api/types";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { KIND_ICON } from "../../components/ScopeBar";
import { DropletIcon, InfoIcon, MoveIcon, PlusIcon, TrashIcon, WindIcon } from "../../components/Icons";
import { pluralCategory, useT, type MsgKey } from "../../i18n";
import { fmtNumber } from "../../lib/format";
import { zoneKindLabel, zoneKindNote } from "../../lib/labels";
import { useScope } from "../../lib/scope";
import { AdminUnavailable } from "./AdminUnavailable";
import { BuildingStructure } from "./BuildingStructure";
import { PlaceHere } from "./NewSensors";
import { RoomPlan, snap } from "./RoomPlan";
import {
  ZONE_KINDS,
  freeSpot,
  hasPos,
  natural,
  roomStatus,
  sortedFloors,
  sortedUnits,
  spotNear,
  toPlanRoom,
  uniqueName,
} from "./roomModel";

const NUDGE_SAVE_MS = 600;

/** "2 senzori" / "1 sensor" in the active language. */
function useSensorCount() {
  const { t, lang } = useT();
  return (n: number) => t(`rooms.sensorCount.${pluralCategory(lang, n)}`, { n: fmtNumber(n, lang, 0) });
}

function UnitOptions({ floors, units }: { floors: AdminFloor[]; units: AdminUnit[] }) {
  const { t } = useT();
  const byFloor = floors.map((f) => ({ f, us: sortedUnits(units.filter((u) => u.floor_id === f.floor_id)) }));
  const orphans = units.filter((u) => !floors.some((f) => f.floor_id === u.floor_id));
  return (
    <>
      {byFloor
        .filter((g) => g.us.length > 0)
        .map(({ f, us }) => (
          <optgroup key={f.floor_id} label={f.label}>
            {us.map((u) => (
              <option key={u.unit_id} value={u.unit_id}>
                {u.label}
                {u.kind === "common" ? ` (${t("rooms.common")})` : ""}
              </option>
            ))}
          </optgroup>
        ))}
      {orphans.map((u) => (
        <option key={u.unit_id} value={u.unit_id}>
          {u.label}
        </option>
      ))}
    </>
  );
}

function KindOptions({ current }: { current?: string }) {
  const { t } = useT();
  const kinds = current && !ZONE_KINDS.includes(current) ? [...ZONE_KINDS, current] : ZONE_KINDS;
  return (
    <>
      {kinds.map((k) => (
        <option key={k} value={k}>
          {zoneKindLabel(k, t)}
        </option>
      ))}
    </>
  );
}

const NodeKindIcon = ({ kind }: { kind: string }) => (kind === "water" ? <DropletIcon /> : <WindIcon />);

/** Parse a metre value typed with "," or "."; null when not a number. */
function parseMetres(s: string): number | null {
  const v = Number(s.trim().replace(",", "."));
  return s.trim() !== "" && Number.isFinite(v) ? v : null;
}

// --------------------------------------------------------------------------- //
// selected room editor
// --------------------------------------------------------------------------- //

function SensorRow({ node, zone, zones, units }: { node: AdminZoneNode; zone: AdminZone; zones: AdminZone[]; units: AdminUnit[] }) {
  const { t } = useT();
  const move = useMoveNode();
  const [name, setName] = useState(node.name);
  useEffect(() => setName(node.name), [node.name]);
  const renamed = name.trim() !== "" && name.trim() !== node.name;
  const unitLabel = (id: string) => units.find((u) => u.unit_id === id)?.label ?? "";
  const targets = [...zones].sort((a, b) => natural(`${unitLabel(a.unit_id)} ${a.label}`, `${unitLabel(b.unit_id)} ${b.label}`));

  return (
    <li className="re-sensor">
      <div className="re-sensor-head">
        <NodeKindIcon kind={node.kind} />
        <input
          className="input"
          value={name}
          aria-label={t("rooms.sensorName")}
          maxLength={60}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && renamed) move.mutate({ nodeId: node.node_id, patch: { name: name.trim() } });
          }}
        />
        {renamed && (
          <button
            type="button"
            className="btn small-btn primary"
            disabled={move.isPending}
            onClick={() => move.mutate({ nodeId: node.node_id, patch: { name: name.trim() } })}
          >
            {t("common.save")}
          </button>
        )}
        <span className={`pill ${node.online ? "ok" : "attention"}`}>{t(node.online ? "conn.online" : "conn.offline")}</span>
      </div>
      <label className="re-move">
        <span className="muted small">{t("rooms.moveTo")}</span>
        <select
          className="input"
          value={zone.zone_id}
          disabled={move.isPending}
          onChange={(e) => move.mutate({ nodeId: node.node_id, patch: { zone_id: e.target.value } })}
        >
          {targets.map((z) => (
            <option key={z.zone_id} value={z.zone_id}>
              {z.label} · {unitLabel(z.unit_id) || z.unit_label}
            </option>
          ))}
        </select>
      </label>
      <div className="muted small re-node-id">{node.node_id}</div>
      {move.isError && <div className="err">{t("admin.saveFailed", { msg: (move.error as Error).message })}</div>}
    </li>
  );
}

interface EditorProps {
  zone: AdminZone;
  zones: AdminZone[];
  floors: AdminFloor[];
  units: AdminUnit[];
  /** position currently shown on the plan (a drag / arrow move may not be saved yet) */
  shownPos: { x: number; y: number };
  onDeleted: () => void;
}

function RoomEditor({ zone, zones, floors, units, shownPos, onDeleted }: EditorProps) {
  const { t, lang } = useT();
  const sensorCount = useSensorCount();
  const update = useUpdateZone();
  const del = useDeleteZone();
  const [label, setLabel] = useState(zone.label);
  const [kind, setKind] = useState(zone.kind);
  const [unitId, setUnitId] = useState(zone.unit_id);
  // null: follow the plan; a string once typed into
  const [xs, setXs] = useState<string | null>(null);
  const [ys, setYs] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [saved, setSaved] = useState(false);
  const num = (v: number) => fmtNumber(v, lang, 1, true);

  const x = xs == null ? shownPos.x : parseMetres(xs);
  const y = ys == null ? shownPos.y : parseMetres(ys);
  const patch: AdminZonePatch = {};
  if (label.trim() && label.trim() !== zone.label) patch.label = label.trim();
  if (kind !== zone.kind) patch.kind = kind;
  if (unitId !== zone.unit_id) patch.unit_id = unitId;
  if (xs != null && x != null && x !== zone.pos_x) patch.pos_x = x;
  if (ys != null && y != null && y !== zone.pos_y) patch.pos_y = y;
  const dirty = Object.keys(patch).length > 0;
  const invalid = !label.trim() || x == null || y == null;
  const n = zone.nodes.length;

  const save = () =>
    update.mutate(
      { zoneId: zone.zone_id, patch },
      {
        onSuccess: () => {
          setXs(null);
          setYs(null);
          setSaved(true);
        },
      },
    );

  return (
    <section className="card room-editor" aria-labelledby={`re-${zone.zone_id}`}>
      <h3 id={`re-${zone.zone_id}`}>{t("rooms.editor")}</h3>
      <div className="re-title">
        <span className={`lvl ${roomStatus(zone) === "none" || roomStatus(zone) === "offline" ? "unknown" : roomStatus(zone)}`} />
        <b>{zone.label}</b>
        <span className="muted small">
          {zone.unit_label ?? ""} · {zone.floor_label ?? ""}
        </span>
      </div>
      <div className="form-grid">
        <label className="field">
          <span>{t("rooms.name")}</span>
          <input
            className="input"
            value={label}
            maxLength={60}
            onChange={(e) => {
              setLabel(e.target.value);
              setSaved(false);
            }}
          />
        </label>
        <label className="field">
          <span>{t("rooms.kind")}</span>
          <select
            className="input"
            value={kind}
            onChange={(e) => {
              setKind(e.target.value);
              setSaved(false);
            }}
          >
            <KindOptions current={zone.kind} />
          </select>
        </label>
        <label className="field span-2">
          <span>{t("rooms.unit")}</span>
          <select
            className="input"
            value={unitId}
            onChange={(e) => {
              setUnitId(e.target.value);
              setSaved(false);
            }}
          >
            <UnitOptions floors={floors} units={units} />
          </select>
        </label>
        <label className="field">
          <span>{t("rooms.posX")}</span>
          <input
            className="input"
            inputMode="decimal"
            value={xs ?? num(shownPos.x)}
            onChange={(e) => {
              setXs(e.target.value);
              setSaved(false);
            }}
            onBlur={() => xs != null && x != null && setXs(num(snap(x)))}
          />
        </label>
        <label className="field">
          <span>{t("rooms.posY")}</span>
          <input
            className="input"
            inputMode="decimal"
            value={ys ?? num(shownPos.y)}
            onChange={(e) => {
              setYs(e.target.value);
              setSaved(false);
            }}
            onBlur={() => ys != null && y != null && setYs(num(snap(y)))}
          />
        </label>
      </div>
      <div className="btn-row">
        <button type="button" className="btn primary" disabled={!dirty || invalid || update.isPending} onClick={save}>
          {update.isPending ? t("common.saving") : t("common.save")}
        </button>
        {saved && !dirty && <span className="t-ok small save-note">{t("admin.saved")}</span>}
      </div>
      {update.isError && <div className="err">{t("admin.saveFailed", { msg: (update.error as Error).message })}</div>}

      <div className="panel-label re-sensors-title">
        {t("rooms.sensors")} · {sensorCount(n)}
      </div>
      {n === 0 ? (
        <div className="muted small">{t("rooms.noSensors")}</div>
      ) : (
        <ul className="re-sensors">
          {zone.nodes.map((node) => (
            <SensorRow key={node.node_id} node={node} zone={zone} zones={zones} units={units} />
          ))}
        </ul>
      )}
      <PlaceHere zoneId={zone.zone_id} />

      <div className="re-delete">
        <button type="button" className="btn danger-outline" disabled={n > 0 || del.isPending} onClick={() => setConfirmDelete(true)}>
          <TrashIcon /> {t("rooms.delete")}
        </button>
        {n > 0 && (
          <div className="muted small re-delete-why">
            <InfoIcon /> {t(`rooms.deleteBlocked.${pluralCategory(lang, n)}`, { n: fmtNumber(n, lang, 0) })}
          </div>
        )}
        {del.isError && (
          <div className="err">
            {del.error instanceof ApiError && del.error.status === 409
              ? t("rooms.deleteConflict")
              : t("admin.saveFailed", { msg: (del.error as Error).message })}
          </div>
        )}
      </div>
      {confirmDelete && (
        <ConfirmDialog
          title={t("rooms.confirmDeleteTitle", { name: zone.label })}
          confirmLabel={t("rooms.delete")}
          danger
          busy={del.isPending}
          onCancel={() => setConfirmDelete(false)}
          onConfirm={() =>
            del.mutate(zone.zone_id, {
              onSuccess: () => {
                setConfirmDelete(false);
                onDeleted();
              },
              onError: () => setConfirmDelete(false),
            })
          }
        >
          <p>{t("rooms.confirmDeleteBody")}</p>
        </ConfirmDialog>
      )}
    </section>
  );
}

// --------------------------------------------------------------------------- //
// new room
// --------------------------------------------------------------------------- //

interface AddProps {
  floors: AdminFloor[];
  units: AdminUnit[];
  zones: AdminZone[];
  defaultUnitId: string;
  /** where the click on the plan was; otherwise next to the apartment's rooms */
  at: { x: number; y: number } | null;
  onCreated: (zoneId: string, unitId: string) => void;
  onCancel: () => void;
}

/** One click per room: pick the apartment, press the room type. The room gets its usual name
 *  ("Dormitor 2" when there is one already) and lands next to the apartment's rooms (or where
 *  the plan was clicked); rename and drag it afterwards. */
function QuickAddRoom({ floors, units, zones, defaultUnitId, at, onCreated, onCancel }: AddProps) {
  const { t } = useT();
  const create = useCreateZone();
  const [unitId, setUnitId] = useState(defaultUnitId);
  const floorId = units.find((u) => u.unit_id === unitId)?.floor_id ?? "";
  const pos = (z: AdminZone) => ({ x: z.pos_x!, y: z.pos_y! });
  const add = (kind: string) => {
    const mine = zones.filter((z) => z.unit_id === unitId);
    const spot =
      at ?? spotNear(mine.filter(hasPos).map(pos), zones.filter((z) => z.floor_id === floorId && hasPos(z)).map(pos));
    const label = uniqueName(t(`roomname.${kind}` as MsgKey), mine.map((z) => z.label));
    create.mutate(
      { label, kind, unit_id: unitId, pos_x: snap(spot.x), pos_y: snap(spot.y) },
      { onSuccess: (z) => onCreated(z.zone_id, z.unit_id || unitId) },
    );
  };

  return (
    <div className="add-room">
      <div className="qa-head">
        <span className="panel-label">{t("rooms.addTo")}</span>
        <select className="input" value={unitId} aria-label={t("rooms.unit")} onChange={(e) => setUnitId(e.target.value)}>
          <UnitOptions floors={floors} units={units} />
        </select>
        <span className="spacer" />
        <button type="button" className="btn small-btn" onClick={onCancel}>
          {t("common.cancel")}
        </button>
      </div>
      <div className="qa-kinds" role="group" aria-label={t("rooms.kind")}>
        {ZONE_KINDS.map((k) => {
          const Icon = KIND_ICON[k] ?? PlusIcon;
          return (
            <button key={k} type="button" className="qa-kind" disabled={!unitId || create.isPending} onClick={() => add(k)}>
              <Icon />
              <span>{t(`roomname.${k}` as MsgKey)}</span>
            </button>
          );
        })}
      </div>
      <div className="muted small">{at ? t("rooms.addHereHint") : t("rooms.quickAddHint")}</div>
      {create.isError && <div className="err">{t("admin.saveFailed", { msg: (create.error as Error).message })}</div>}
    </div>
  );
}

// --------------------------------------------------------------------------- //
// room list
// --------------------------------------------------------------------------- //

function RoomList({
  title,
  zones,
  floors,
  units,
  selectedId,
  onSelect,
}: {
  title: string;
  zones: AdminZone[];
  floors: AdminFloor[];
  units: AdminUnit[];
  selectedId: string | null;
  onSelect: (z: AdminZone) => void;
}) {
  const { t } = useT();
  const sensorCount = useSensorCount();
  return (
    <section className="card room-list">
      <h3>{title}</h3>
      {floors.map((f) => {
        const us = sortedUnits(units.filter((u) => u.floor_id === f.floor_id));
        return (
          <div key={f.floor_id} className="rl-floor">
            {floors.length > 1 && <div className="rl-floor-label">{f.label}</div>}
            {us.map((u) => {
              const rooms = zones.filter((z) => z.unit_id === u.unit_id).sort((a, b) => natural(a.label, b.label));
              return (
                <div key={u.unit_id} className="rl-unit">
                  <div className="rl-unit-head">
                    <b>{u.label}</b>
                    {u.kind === "common" && <span className="tag">{t("rooms.common")}</span>}
                    <span className="muted small">{floors.length > 1 ? "" : f.label}</span>
                  </div>
                  {rooms.length === 0 && <div className="muted small rl-empty">{t("rooms.unitNoRooms")}</div>}
                  <ul>
                    {rooms.map((z) => {
                      const st = roomStatus(z);
                      const on = z.nodes.filter((n) => n.online).length;
                      const off = z.nodes.length - on;
                      return (
                        <li key={z.zone_id}>
                          <button
                            type="button"
                            className={`rl-room ${z.zone_id === selectedId ? "sel" : ""}`}
                            aria-pressed={z.zone_id === selectedId}
                            onClick={() => onSelect(z)}
                          >
                            <span className={`lvl ${st === "none" || st === "offline" ? "unknown" : st}`} />
                            <span className="rl-name">{z.label}</span>
                            <span className="rl-kind muted">{zoneKindNote(z.label, z.kind, t)}</span>
                            <span className="rl-sensors muted">{z.nodes.length ? sensorCount(z.nodes.length) : t("rooms.statusNone")}</span>
                            {z.nodes.length > 0 && (
                              <span className={`rl-online ${off ? "t-attention" : "t-ok"}`}>
                                {off ? t("rooms.offlineCount", { n: off }) : t("rooms.allOnline")}
                              </span>
                            )}
                          </button>
                        </li>
                      );
                    })}
                  </ul>
                </div>
              );
            })}
          </div>
        );
      })}
    </section>
  );
}

// --------------------------------------------------------------------------- //
// the tab
// --------------------------------------------------------------------------- //

export function RoomsTab() {
  const { t, lang } = useT();
  const zonesQ = useAdminZones();
  const floorsQ = useAdminFloors();
  const unitsQ = useAdminUnits();
  const update = useUpdateZone();
  const sc = useScope();
  // a floor picked by hand holds until the scope changes; otherwise the plan shows the floor of
  // the selected room, else of the chosen apartment
  const scopeKey = `${sc.scope.floor}|${sc.scope.unit}|${sc.scope.room}`;
  const [floorPick, setFloorPick] = useState<{ key: string; floorId: string } | null>(null);
  /** the quick-add panel is open; `at`: the plan spot that was clicked */
  const [adding, setAdding] = useState<{ at: { x: number; y: number } | null } | null>(null);
  const [overrides, setOverrides] = useState<Map<string, { x: number; y: number }>>(new Map());
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const nudgeTimers = useRef(new Map<string, number>());
  const num = (v: number) => fmtNumber(v, lang, 1, true);

  const zones = zonesQ.data ?? [];
  const floors = sortedFloors(floorsQ.data);
  const units = unitsQ.data ?? [];
  const selected = zones.find((z) => z.zone_id === sc.scope.room) ?? null;
  const selectedId = selected?.zone_id ?? null;
  const scopedUnit = units.find((u) => u.unit_id === sc.scope.unit) ?? null;
  const inScope = (z: AdminZone) => !scopedUnit || z.unit_id === scopedUnit.unit_id;
  const floorId =
    floorPick?.key === scopeKey ? floorPick.floorId : (selected?.floor_id ?? scopedUnit?.floor_id ?? sc.floor?.id);
  const floor = floors.find((f) => f.floor_id === floorId) ?? floors[0];
  const setFloorId = (id: string) => setFloorPick({ key: scopeKey, floorId: id });
  /** select a room (any apartment's: the scope follows it) */
  const selectRoom = (id: string) => {
    const z = zones.find((x) => x.zone_id === id);
    if (z) sc.setScope({ unit: z.unit_id, room: z.zone_id });
  };

  useEffect(() => {
    const timers = nudgeTimers.current;
    return () => timers.forEach((id) => window.clearTimeout(id));
  }, []);

  const dropOverride = (id: string) =>
    setOverrides((m) => {
      const next = new Map(m);
      next.delete(id);
      return next;
    });

  const savePos = (id: string, x: number, y: number) => {
    update.mutate(
      { zoneId: id, patch: { pos_x: x, pos_y: y } },
      {
        onSuccess: () => setNote({ ok: true, text: t("rooms.moved", { x: num(x), y: num(y) }) }),
        onError: (e) => setNote({ ok: false, text: t("rooms.moveFailed", { msg: (e as Error).message }) }),
        onSettled: () => dropOverride(id),
      },
    );
  };

  const move = (id: string, x: number, y: number) => {
    setOverrides((m) => new Map(m).set(id, { x, y }));
    savePos(id, x, y);
  };

  const nudge = (id: string, x: number, y: number) => {
    setOverrides((m) => new Map(m).set(id, { x, y }));
    const timers = nudgeTimers.current;
    window.clearTimeout(timers.get(id));
    timers.set(
      id,
      window.setTimeout(() => {
        timers.delete(id);
        savePos(id, x, y);
      }, NUDGE_SAVE_MS),
    );
  };

  if ((zonesQ.isError && !zonesQ.data) || (floorsQ.isError && !floorsQ.data) || (unitsQ.isError && !unitsQ.data)) {
    return <AdminUnavailable error={zonesQ.error ?? floorsQ.error ?? unitsQ.error} />;
  }
  if (!zonesQ.data || !floorsQ.data || !unitsQ.data) return <div className="muted">{t("common.loading")}</div>;

  const floorZones = zones.filter((z) => z.floor_id === floor?.floor_id);
  const placed = floorZones.filter(hasPos).map((z) => ({ ...toPlanRoom(z, overrides.get(z.zone_id)), dim: !inScope(z) }));
  const unplaced = floorZones.filter((z) => !hasPos(z) && inScope(z));
  const shownPos = (z: AdminZone) => overrides.get(z.zone_id) ?? { x: z.pos_x ?? 0, y: z.pos_y ?? 0 };
  // a new room goes to the chosen apartment
  const defaultUnit =
    scopedUnit?.unit_id ??
    sortedUnits(units.filter((u) => u.floor_id === floor?.floor_id))[0]?.unit_id ??
    units[0]?.unit_id ??
    "";

  return (
    <div className="rooms-layout">
      <div className="rooms-main">
        <section className="card rooms-plan-card">
          <div className="rooms-plan-head">
            <h3>{t("rooms.plan")}</h3>
            {floors.length > 1 && (
              <div className="seg" role="group" aria-label={t("rooms.floor")}>
                {floors.map((f) => (
                  <button
                    key={f.floor_id}
                    type="button"
                    className={f.floor_id === floor?.floor_id ? "active" : ""}
                    aria-pressed={f.floor_id === floor?.floor_id}
                    onClick={() => setFloorId(f.floor_id)}
                  >
                    {f.label}
                  </button>
                ))}
              </div>
            )}
            {floors.length === 1 && <span className="tag">{floor?.label}</span>}
            <span className="spacer" />
            <button type="button" className="btn primary" disabled={units.length === 0 || !!adding} onClick={() => setAdding({ at: null })}>
              <PlusIcon /> {t("rooms.add")}
            </button>
          </div>
          {units.length === 0 && <div className="muted small">{t("rooms.noFloors")}</div>}
          {adding && (
            <QuickAddRoom
              key={adding.at ? `${adding.at.x},${adding.at.y}` : "next"}
              floors={floors}
              units={units}
              zones={zones}
              defaultUnitId={defaultUnit}
              at={adding.at}
              onCancel={() => setAdding(null)}
              onCreated={(id, unitId) => {
                setAdding(null);
                sc.setScope({ unit: unitId, room: id });
              }}
            />
          )}
          {placed.length === 0 ? (
            <div className="muted rooms-empty">{t("rooms.empty")}</div>
          ) : (
            <RoomPlan
              rooms={placed}
              selectedId={selectedId}
              onSelect={selectRoom}
              onMove={move}
              onNudge={nudge}
              onEmptyClick={units.length ? (x, y) => setAdding({ at: { x, y } }) : undefined}
            />
          )}
          <div className="rooms-plan-foot">
            <span className="muted small">
              <MoveIcon /> {t("rooms.planHint")}
            </span>
            <span className="spacer" />
            {update.isPending ? (
              <span className="muted small">{t("common.saving")}</span>
            ) : note ? (
              <span className={`small ${note.ok ? "t-ok" : "t-danger"}`} role="status">
                {note.text}
              </span>
            ) : null}
          </div>
          {unplaced.length > 0 && (
            <div className="rooms-unplaced">
              <div className="panel-label">{t("rooms.unplaced")}</div>
              {unplaced.map((z) => (
                <div key={z.zone_id} className="row">
                  <span className="grow">
                    {z.label} <span className="muted small">{z.unit_label}</span>
                  </span>
                  <button
                    type="button"
                    className="btn small-btn"
                    onClick={() => {
                      const spot = freeSpot(placed);
                      move(z.zone_id, spot.x, spot.y);
                      selectRoom(z.zone_id);
                    }}
                  >
                    {t("rooms.placeOnPlan")}
                  </button>
                </div>
              ))}
            </div>
          )}
        </section>
        <BuildingStructure floors={floors} units={units} zones={zones} />
      </div>

      <div className="rooms-side">
        {selected ? (
          <RoomEditor
            key={selected.zone_id}
            zone={selected}
            zones={zones}
            floors={floors}
            units={units}
            shownPos={shownPos(selected)}
            onDeleted={() => sc.setScope({ unit: sc.scope.unit, room: "all" })}
          />
        ) : (
          <div className="card muted room-hint">{t("rooms.selectHint")}</div>
        )}
        <RoomList
          title={scopedUnit ? t("rooms.listOf", { unit: scopedUnit.label }) : t("rooms.list")}
          zones={zones}
          floors={scopedUnit ? floors.filter((f) => f.floor_id === scopedUnit.floor_id) : floors}
          units={scopedUnit ? [scopedUnit] : units}
          selectedId={selectedId}
          onSelect={(z) => selectRoom(z.zone_id)}
        />
      </div>
    </div>
  );
}

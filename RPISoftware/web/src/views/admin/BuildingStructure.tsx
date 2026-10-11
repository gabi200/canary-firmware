/**
 * Compact apartments / floors panel of the room manager: add a floor, add an apartment (or a
 * common area) to a floor, rename an apartment, switch residential / common.
 */
import { useState } from "react";

import { useCreateFloor, useCreateUnit, useCreateZone, useUpdateUnit } from "../../api/adminHooks";
import { ApiError } from "../../api/client";
import type { AdminFloor, AdminUnit, AdminZone, UnitKind } from "../../api/types";
import { PencilIcon, PlusIcon } from "../../components/Icons";
import { pluralCategory, useT, type MsgKey } from "../../i18n";
import { fmtNumber } from "../../lib/format";
import { STANDARD_ROOMS, blockSpots, hasPos, residentCount, sortedUnits } from "./roomModel";

function unitError(e: unknown, t: ReturnType<typeof useT>["t"]): string {
  if (e instanceof ApiError && e.status === 409) return t("struct.commonConflict");
  return t("admin.saveFailed", { msg: (e as Error).message });
}

function UnitRow({ unit, rooms }: { unit: AdminUnit; rooms: number }) {
  const { t, lang } = useT();
  const update = useUpdateUnit();
  const [editing, setEditing] = useState(false);
  const [label, setLabel] = useState(unit.label);
  const residents = residentCount(unit);
  const setKind = (kind: UnitKind) => kind !== unit.kind && update.mutate({ unitId: unit.unit_id, patch: { kind } });
  const rename = () => {
    if (!label.trim() || label.trim() === unit.label) return setEditing(false);
    update.mutate({ unitId: unit.unit_id, patch: { label: label.trim() } }, { onSuccess: () => setEditing(false) });
  };

  return (
    <li className="st-unit">
      <div className="st-unit-row">
        {editing ? (
          <form
            className="st-rename"
            onSubmit={(e) => {
              e.preventDefault();
              rename();
            }}
          >
            <input
              className="input"
              value={label}
              maxLength={60}
              autoFocus
              aria-label={t("struct.unitLabel")}
              onChange={(e) => setLabel(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Escape") {
                  setLabel(unit.label);
                  setEditing(false);
                }
              }}
            />
            <button type="submit" className="btn small-btn primary" disabled={update.isPending}>
              {t("common.save")}
            </button>
            <button
              type="button"
              className="btn small-btn"
              onClick={() => {
                setLabel(unit.label);
                setEditing(false);
              }}
            >
              {t("common.cancel")}
            </button>
          </form>
        ) : (
          <>
            <b className="st-unit-name">{unit.label}</b>
            <button
              type="button"
              className="btn icon-btn st-edit"
              title={t("struct.rename")}
              aria-label={`${t("struct.rename")}: ${unit.label}`}
              onClick={() => setEditing(true)}
            >
              <PencilIcon />
            </button>
          </>
        )}
        <span className="spacer" />
        <span className="muted small st-counts">
          {t(`struct.rooms.${pluralCategory(lang, rooms)}`, { n: fmtNumber(rooms, lang, 0) })}
          {" · "}
          {t(`struct.residents.${pluralCategory(lang, residents)}`, { n: fmtNumber(residents, lang, 0) })}
        </span>
        <div className="seg st-kind" role="group" aria-label={`${t("struct.kind")}: ${unit.label}`}>
          {(["residential", "common"] as const).map((k) => (
            <button
              key={k}
              type="button"
              className={unit.kind === k ? "active" : ""}
              aria-pressed={unit.kind === k}
              disabled={update.isPending}
              onClick={() => setKind(k)}
            >
              {t(k === "residential" ? "struct.kindResidential" : "struct.kindCommon")}
            </button>
          ))}
        </div>
      </div>
      {update.isError && <div className="err">{unitError(update.error, t)}</div>}
    </li>
  );
}

function AddUnit({ floor, zones }: { floor: AdminFloor; zones: AdminZone[] }) {
  const { t } = useT();
  const create = useCreateUnit();
  const createZone = useCreateZone();
  const [open, setOpen] = useState(false);
  const [label, setLabel] = useState("");
  const [kind, setKind] = useState<UnitKind>("residential");
  const [withRooms, setWithRooms] = useState(true);
  const busy = create.isPending || createZone.isPending;
  if (!open) {
    return (
      <button type="button" className="btn small-btn" onClick={() => setOpen(true)}>
        <PlusIcon /> {t("struct.addUnit")}
      </button>
    );
  }
  return (
    <form
      className="st-add"
      onSubmit={(e) => {
        e.preventDefault();
        if (!label.trim()) return;
        create.mutate(
          { label: label.trim(), floor_id: floor.floor_id, kind },
          {
            onSuccess: async (unit) => {
              if (kind === "residential" && withRooms) {
                const taken = zones.filter((z) => z.floor_id === floor.floor_id && hasPos(z)).map((z) => ({ x: z.pos_x!, y: z.pos_y! }));
                const spots = blockSpots(taken);
                for (const [i, k] of STANDARD_ROOMS.entries()) {
                  await createZone.mutateAsync({
                    label: t(`roomname.${k}` as MsgKey),
                    kind: k,
                    unit_id: unit.unit_id,
                    pos_x: spots[i].x,
                    pos_y: spots[i].y,
                  });
                }
              }
              setLabel("");
              setOpen(false);
            },
          },
        );
      }}
    >
      <input
        className="input"
        value={label}
        maxLength={60}
        autoFocus
        placeholder={t("struct.unitLabelPh")}
        aria-label={t("struct.unitLabel")}
        onChange={(e) => setLabel(e.target.value)}
      />
      <select className="input" value={kind} aria-label={t("struct.kind")} onChange={(e) => setKind(e.target.value as UnitKind)}>
        <option value="residential">{t("struct.kindResidential")}</option>
        <option value="common">{t("struct.kindCommon")}</option>
      </select>
      <button type="submit" className="btn small-btn primary" disabled={!label.trim() || busy}>
        {busy ? t("common.saving") : t("common.add")}
      </button>
      <button type="button" className="btn small-btn" onClick={() => setOpen(false)}>
        {t("common.cancel")}
      </button>
      {kind === "residential" && (
        <label className="st-with-rooms small">
          <input type="checkbox" checked={withRooms} onChange={(e) => setWithRooms(e.target.checked)} />
          {t("struct.withRooms")}
        </label>
      )}
      {(create.isError || createZone.isError) && (
        <div className="err">{t("admin.saveFailed", { msg: ((create.error ?? createZone.error) as Error).message })}</div>
      )}
    </form>
  );
}

function AddFloor({ floors }: { floors: AdminFloor[] }) {
  const { t } = useT();
  const create = useCreateFloor();
  const [open, setOpen] = useState(false);
  const next = floors.length ? Math.max(...floors.map((f) => f.level)) + 1 : 0;
  const [label, setLabel] = useState("");
  const [level, setLevel] = useState(String(next));
  const lvl = Number(level);
  const ok = label.trim() !== "" && level.trim() !== "" && Number.isInteger(lvl) && lvl >= -10 && lvl <= 200;
  if (!open) {
    return (
      <button
        type="button"
        className="btn small-btn"
        onClick={() => {
          setLevel(String(next));
          setOpen(true);
        }}
      >
        <PlusIcon /> {t("struct.addFloor")}
      </button>
    );
  }
  return (
    <form
      className="st-add"
      onSubmit={(e) => {
        e.preventDefault();
        if (!ok) return;
        create.mutate(
          { label: label.trim(), level: lvl },
          {
            onSuccess: () => {
              setLabel("");
              setOpen(false);
            },
          },
        );
      }}
    >
      <input
        className="input"
        value={label}
        maxLength={60}
        autoFocus
        placeholder={t("struct.floorLabelPh", { n: next })}
        aria-label={t("struct.floorLabel")}
        onChange={(e) => setLabel(e.target.value)}
      />
      <label className="st-level">
        <span className="muted small">{t("struct.level")}</span>
        <input className="input" type="number" min={-10} max={200} step={1} value={level} onChange={(e) => setLevel(e.target.value)} />
      </label>
      <button type="submit" className="btn small-btn primary" disabled={!ok || create.isPending}>
        {t("common.add")}
      </button>
      <button type="button" className="btn small-btn" onClick={() => setOpen(false)}>
        {t("common.cancel")}
      </button>
      {create.isError && <div className="err">{t("admin.saveFailed", { msg: (create.error as Error).message })}</div>}
    </form>
  );
}

export function BuildingStructure({ floors, units, zones }: { floors: AdminFloor[]; units: AdminUnit[]; zones: AdminZone[] }) {
  const { t, lang } = useT();
  return (
    <section className="card structure">
      <div className="st-head">
        <h3>{t("struct.title")}</h3>
        <span className="spacer" />
        <AddFloor floors={floors} />
      </div>
      {floors.length === 0 && <div className="muted small">{t("struct.noFloors")}</div>}
      {floors.map((f) => {
        const us = sortedUnits(units.filter((u) => u.floor_id === f.floor_id));
        return (
          <div key={f.floor_id} className="st-floor">
            <div className="st-floor-head">
              <b>{f.label}</b>
              <span className="muted small">{t("struct.levelShort", { n: fmtNumber(f.level, lang, 0) })}</span>
              <span className="spacer" />
              <AddUnit floor={f} zones={zones} />
            </div>
            {us.length === 0 ? (
              <div className="muted small">{t("struct.noUnits")}</div>
            ) : (
              <ul className="st-units">
                {us.map((u) => (
                  <UnitRow key={u.unit_id} unit={u} rooms={zones.filter((z) => z.unit_id === u.unit_id).length} />
                ))}
              </ul>
            )}
          </div>
        );
      })}
    </section>
  );
}

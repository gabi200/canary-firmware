/**
 * Firmware: the version every sensor of the scope runs, and pushes of a new image. The hub streams
 * the .bin to the sensor's own /api/ota at the address and with the API token staff pinned here
 * (the address a sensor reports over MQTT is only a suggestion), one sensor at a time; the sensor
 * reboots and its next status confirms the version it now runs. Reading: every staff role;
 * device access and pushes: technician and system admin (the backend enforces it).
 */
import { useMemo, useState } from "react";

import {
  useClearOtaTarget,
  useFirmware,
  useNodeFirmware,
  usePushFirmware,
  useSetOtaTarget,
} from "../../api/adminHooks";
import { useZones } from "../../api/hooks";
import type { FirmwareUpdate, NodeFirmware } from "../../api/types";
import { useAuth } from "../../auth/AuthContext";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { ChipIcon, DropletIcon, HistoryIcon, LockIcon, WarningIcon, WindIcon } from "../../components/Icons";
import { useT, type MsgKey, type TFn } from "../../i18n";
import { fmtNumber } from "../../lib/format";
import { buildZoneNames, kindLabel } from "../../lib/labels";
import { useScope } from "../../lib/scope";
import { fmtAgo, fmtDateTime } from "../../lib/time";
import { AdminUnavailable } from "./AdminUnavailable";
import { natural } from "./roomModel";

const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const CHIP_KIND: Record<number, { kind: "air" | "water"; label: MsgKey }> = {
  9: { kind: "air", label: "fw.imageAir" },
  5: { kind: "water", label: "fw.imageWater" },
};

type Image = { file: File; kind: "air" | "water"; label: MsgKey } | { file: File; error: MsgKey };

/** The checks the hub makes, before uploading: ESP32 image magic, chip id, application header. */
async function inspect(file: File): Promise<Image> {
  if (file.size > MAX_IMAGE_BYTES) return { file, error: "fw.imageTooBig" };
  const b = new Uint8Array(await file.slice(0, 64).arrayBuffer());
  if (b.length < 64 || b[0] !== 0xe9) return { file, error: "fw.imageNotEsp" };
  const chip = CHIP_KIND[b[12] | (b[13] << 8)];
  if (!chip) return { file, error: "fw.imageChip" };
  if (((b[32] | (b[33] << 8) | (b[34] << 16) | (b[35] << 24)) >>> 0) !== 0xabcd5432) return { file, error: "fw.imageNotApp" };
  return { file, ...chip };
}

const canMaintain = (role: string | undefined) => role === "system_admin" || role === "technician";

export function detailLabel(detail: string | null, t: TFn): string {
  if (!detail) return "";
  if (detail.startsWith("ota_failed: ")) return t("fw.err.otaFailed", { msg: detail.slice(12) });
  const known: Record<string, MsgKey> = {
    unauthorized: "fw.err.unauthorized",
    ota_active: "fw.blocked.ota_active",
    no_target: "fw.blocked.no_target",
    hub_error: "fw.err.hub",
    timeout: "fw.err.timeout",
    no_answer: "fw.err.noAnswer",
  };
  return known[detail] ? t(known[detail]) : detail;
}

function UpdateLine({ u }: { u: FirmwareUpdate }) {
  const { t, lang } = useT();
  const tone = u.status === "confirmed" ? "t-ok" : u.status === "failed" || u.status === "timeout" ? "t-danger" : "t-attention";
  return (
    <span className={tone}>
      {t(`fw.st.${u.status}`)}
      {u.status === "confirmed" && u.firmware_after && ` · ${t("fw.runsNow", { v: u.firmware_after })}`}
      {u.detail && ` · ${detailLabel(u.detail, t)}`}
      <span className="muted"> · {fmtAgo(u.finished_ts ?? u.created_ts, lang)}</span>
    </span>
  );
}

function AccessForm({ node, onDone }: { node: NodeFirmware; onDone: () => void }) {
  const { t } = useT();
  const save = useSetOtaTarget();
  const clear = useClearOtaTarget();
  const [address, setAddress] = useState(node.address ?? node.reported_ip ?? "");
  const [token, setToken] = useState("");
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    save.mutate({ nodeId: node.node_id, address: address.trim(), deviceToken: token || undefined }, { onSuccess: onDone });
  };
  return (
    <form className="fw-access" onSubmit={submit}>
      <p className="muted small">{t("fw.accessHint")}</p>
      <div className="form-grid">
        <label className="field">
          <span>{t("fw.addressLabel")}</span>
          <input className="input mono" value={address} onChange={(e) => setAddress(e.target.value)} placeholder="192.168.1.40" required />
        </label>
        <label className="field">
          <span>{t("fw.tokenLabel")}</span>
          <input
            className="input"
            type="password"
            autoComplete="off"
            value={token}
            onChange={(e) => setToken(e.target.value)}
            placeholder={node.token_set ? t("fw.tokenKeep") : ""}
            required={!node.token_set}
          />
        </label>
      </div>
      {save.isError && <div className="err">{t("admin.saveFailed", { msg: (save.error as Error).message })}</div>}
      <div className="btn-row">
        <button type="submit" className="btn primary small-btn" disabled={save.isPending || !address.trim()}>
          {t("fw.save")}
        </button>
        <button type="button" className="btn small-btn" onClick={onDone}>
          {t("common.cancel")}
        </button>
        {node.token_set && (
          <button
            type="button"
            className="btn danger-outline small-btn"
            disabled={clear.isPending}
            onClick={() => clear.mutate(node.node_id, { onSuccess: onDone })}
          >
            {t("fw.remove")}
          </button>
        )}
      </div>
    </form>
  );
}

function History({ nodeId }: { nodeId: string }) {
  const { t, lang } = useT();
  const q = useNodeFirmware(nodeId, true);
  if (!q.data) return <div className="muted small">{q.isError ? (q.error as Error).message : t("common.loading")}</div>;
  return (
    <div className="fw-history">
      <h4>{t("fw.versions")}</h4>
      {q.data.history.length === 0 ? (
        <p className="muted small">{t("fw.noHistory")}</p>
      ) : (
        <ul>
          {q.data.history.map((h) => (
            <li key={`${h.firmware}|${h.ts}`}>
              <b className="mono">{h.firmware}</b> <span className="muted">· {t("fw.since", { time: fmtDateTime(h.ts, lang) })}</span>
            </li>
          ))}
        </ul>
      )}
      <h4>{t("fw.pushes")}</h4>
      {q.data.updates.length === 0 ? (
        <p className="muted small">{t("fw.noPushes")}</p>
      ) : (
        <ul>
          {q.data.updates.map((u) => (
            <li key={u.update_id}>
              <span className="mono">{u.filename}</span>{" "}
              <span className="muted small mono" title={u.sha256}>
                {u.sha256.slice(0, 12)}
              </span>
              <div className="small">
                <UpdateLine u={u} />
                {u.requested_by_name && <span className="muted"> · {t("fw.by", { name: u.requested_by_name })}</span>}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function FirmwareCard({ node, room, maintain }: { node: NodeFirmware; room: string; maintain: boolean }) {
  const { t } = useT();
  const [panel, setPanel] = useState<"access" | "history" | null>(null);
  const setTarget = useSetOtaTarget();
  const pinnedIp = node.address?.split(":")[0];
  const moved = !!(node.address && node.reported_ip && pinnedIp !== node.reported_ip);

  return (
    <article className={`dev-card ${node.online ? "" : "conn-offline"}`}>
      <div className="dev-head">
        <span className={`dev-kind ${node.kind}`} aria-hidden="true">
          {node.kind === "water" ? <DropletIcon /> : <WindIcon />}
        </span>
        <div className="dev-title">
          <div className="dev-name">{node.name || node.node_id}</div>
          <div className="dev-room">{room}</div>
        </div>
        <span className={`dev-conn ${node.online ? "online" : "offline"}`}>
          <span className="dot" aria-hidden="true" />
          {t(node.online ? "conn.online" : "conn.offline")}
        </span>
      </div>
      <dl className="dev-facts">
        <div>
          <dt>{t("fw.version")}</dt>
          <dd className="mono">{node.firmware || "—"}</dd>
        </div>
        <div>
          <dt>{t("fw.address")}</dt>
          <dd>
            {node.address ? <span className="mono">{node.address}</span> : <span className="muted">{t("fw.notSet")}</span>}
            {!node.address && node.reported_ip && (
              <span className="env-fact-sub">{t("fw.reported", { ip: node.reported_ip })}</span>
            )}
          </dd>
        </div>
        <div className="wide">
          <dt>{t("fw.last")}</dt>
          <dd>{node.last_update ? <UpdateLine u={node.last_update} /> : <span className="muted">—</span>}</dd>
        </div>
      </dl>
      {moved && (
        <div className="hub-note small t-attention">
          <WarningIcon /> {t("fw.ipMismatch", { ip: node.reported_ip!, address: node.address! })}{" "}
          {maintain && (
            <button
              type="button"
              className="btn small-btn"
              disabled={setTarget.isPending}
              onClick={() => setTarget.mutate({ nodeId: node.node_id, address: node.reported_ip! })}
            >
              {t("fw.useIp", { ip: node.reported_ip! })}
            </button>
          )}
        </div>
      )}
      <div className="dev-foot">
        <span className="dev-id muted small mono">{node.node_id}</span>
        <span className="btn-row">
          {maintain && (
            <button
              type="button"
              className="btn small-btn"
              aria-expanded={panel === "access"}
              onClick={() => setPanel(panel === "access" ? null : "access")}
            >
              <LockIcon /> {t("fw.access")}
            </button>
          )}
          <button
            type="button"
            className="btn small-btn"
            aria-expanded={panel === "history"}
            onClick={() => setPanel(panel === "history" ? null : "history")}
          >
            <HistoryIcon /> {t("fw.history")}
          </button>
        </span>
      </div>
      {panel === "access" && <AccessForm node={node} onDone={() => setPanel(null)} />}
      {panel === "history" && <History nodeId={node.node_id} />}
    </article>
  );
}

function PushPanel({ nodes, roomOf, scope }: { nodes: NodeFirmware[]; roomOf: (n: NodeFirmware) => string; scope: string }) {
  const { t, lang } = useT();
  const push = usePushFirmware();
  const [image, setImage] = useState<Image | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [confirm, setConfirm] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [queued, setQueued] = useState(false);

  const matching = image && "kind" in image ? nodes.filter((n) => n.kind === image.kind) : [];
  const ready = matching.filter((n) => !n.blocked);
  const selected = ready.filter((n) => picked.has(n.node_id));

  const choose = async (file: File | undefined) => {
    setErrors({});
    setQueued(false);
    if (!file) return setImage(null);
    const img = await inspect(file);
    setImage(img);
    setPicked(new Set("kind" in img ? nodes.filter((n) => n.kind === img.kind && !n.blocked).map((n) => n.node_id) : []));
  };

  const toggle = (id: string) =>
    setPicked((old) => {
      const next = new Set(old);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const send = async () => {
    setConfirm(false);
    if (!image) return;
    const failed: Record<string, string> = {};
    // the hub queues them and pushes one at a time
    for (const n of selected) {
      try {
        await push.mutateAsync({ nodeId: n.node_id, file: image.file });
      } catch (e) {
        failed[n.node_id] = (e as Error).message;
      }
    }
    setErrors(failed);
    setQueued(true);
  };

  return (
    <section className="card fw-push">
      <h3>
        <ChipIcon /> {t("fw.pushTitle")}
      </h3>
      <p className="muted small">{t("fw.pushHint")}</p>
      <label className="field">
        <span>{t("fw.chooseFile")}</span>
        <input type="file" accept=".bin,application/octet-stream" onChange={(e) => void choose(e.target.files?.[0])} />
      </label>
      {image && "error" in image && <div className="err">{t(image.error)}</div>}
      {image && "kind" in image && (
        <>
          <div className="small">
            <b>{t(image.label)}</b>
            <span className="muted"> · {fmtNumber(image.file.size / (1024 * 1024), lang, 2)} MB</span>
          </div>
          {matching.length === 0 ? (
            <p className="muted">{t("fw.noMatching", { scope })}</p>
          ) : (
            <ul className="fw-targets">
              {matching.map((n) => (
                <li key={n.node_id} className={n.blocked ? "muted" : ""}>
                  <label>
                    <input
                      type="checkbox"
                      checked={!n.blocked && picked.has(n.node_id)}
                      disabled={!!n.blocked}
                      onChange={() => toggle(n.node_id)}
                    />
                    <span className="tl-name">
                      {n.name || n.node_id} <span className="muted">· {roomOf(n)}</span>
                    </span>
                    <span className="mono small">{n.firmware || "—"}</span>
                    <span className="small">
                      {n.blocked ? t(`fw.blocked.${n.blocked}`) : ""}
                      {errors[n.node_id] && <span className="t-danger">{errors[n.node_id]}</span>}
                    </span>
                  </label>
                </li>
              ))}
            </ul>
          )}
          <div className="btn-row">
            <button
              type="button"
              className="btn primary"
              disabled={selected.length === 0 || push.isPending}
              onClick={() => setConfirm(true)}
            >
              {t("fw.pushButton", { n: fmtNumber(selected.length, lang, 0) })}
            </button>
            {queued && <span className="muted small">{t("fw.queuedAll")}</span>}
          </div>
        </>
      )}
      {confirm && image && (
        <ConfirmDialog
          title={t("fw.confirmTitle")}
          confirmLabel={t("fw.pushButton", { n: fmtNumber(selected.length, lang, 0) })}
          onCancel={() => setConfirm(false)}
          onConfirm={() => void send()}
        >
          <p>{t("fw.confirmBody", { file: image.file.name, n: fmtNumber(selected.length, lang, 0) })}</p>
          <ul className="small">
            {selected.map((n) => (
              <li key={n.node_id}>
                {n.name || n.node_id} · <span className="mono">{n.firmware || "—"}</span>
              </li>
            ))}
          </ul>
        </ConfirmDialog>
      )}
    </section>
  );
}

export function FirmwareTab() {
  const { t } = useT();
  const { session } = useAuth();
  const firmware = useFirmware();
  const zones = useZones();
  const sc = useScope();
  const maintain = canMaintain(session?.role);
  const names = buildZoneNames(zones.data);
  const zoneById = useMemo(() => new Map((zones.data ?? []).map((z) => [z.id, z])), [zones.data]);

  const roomOf = (n: NodeFirmware) => {
    const z = zoneById.get(n.zone_id);
    if (!z) return names.get(n.zone_id) ?? t("devs.unknownRoom");
    return z.unit_label ? `${z.label} · ${z.unit_label}` : z.label;
  };

  if (firmware.isError && !firmware.data) return <AdminUnavailable error={firmware.error} />;
  if (!firmware.data || !sc.ready) return <div className="muted">{t("common.loading")}</div>;

  const shown = firmware.data
    .filter((n) => sc.includes(n.zone_id))
    .sort((a, b) => a.kind.localeCompare(b.kind) || natural(roomOf(a), roomOf(b)) || natural(a.name, b.name));
  const versions = new Map<string, number>();
  for (const n of shown) {
    const key = `${n.kind}|${n.firmware}`;
    versions.set(key, (versions.get(key) ?? 0) + 1);
  }

  return (
    <>
      <div className="card fw-summary">
        <h3>{t("fw.summary")}</h3>
        {shown.length === 0 ? (
          <span className="muted">{t("scope.noSensors", { scope: sc.title })}</span>
        ) : (
          <ul className="env-chips">
            {[...versions].sort(([a], [b]) => natural(a, b)).map(([key, n]) => {
              const [kind, version] = key.split("|");
              return (
                <li key={key} className="env-chip">
                  {kindLabel(kind, t)} <b className="mono">{version || t("fw.unknownVersion")}</b> × {n}
                </li>
              );
            })}
          </ul>
        )}
      </div>
      {maintain ? (
        <PushPanel nodes={shown} roomOf={roomOf} scope={sc.title} />
      ) : (
        <p className="muted small">{t("fw.readOnly")}</p>
      )}
      <div className="dev-grid">
        {shown.map((n) => (
          <FirmwareCard key={n.node_id} node={n} room={roomOf(n)} maintain={maintain} />
        ))}
      </div>
    </>
  );
}

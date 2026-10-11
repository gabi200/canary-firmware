/**
 * Accounts: searchable table (name, username, role, apartments, phone, active), "add account"
 * form, inline edit and an activate / deactivate switch (asks first). Server 409 / 422 answers
 * are shown next to the field they concern. Sign-in is test-only (username, no password).
 * hoa_manager: their building, resident accounts only (no role choice).
 * Scope bar: an apartment shows its residents only; staff accounts only under the whole building.
 */
import { useMemo, useState } from "react";

import { useAdminUnits, useAdminUsers, useCreateUser, useUpdateUser } from "../../api/adminHooks";
import { ApiError } from "../../api/client";
import type { AdminUnit, AdminUser, AdminUserPatch } from "../../api/types";
import { useAuth } from "../../auth/AuthContext";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { InfoIcon, PencilIcon, PlusIcon, SearchIcon } from "../../components/Icons";
import { pluralCategory, useT, type TFn } from "../../i18n";
import { fmtNumber } from "../../lib/format";
import { tokenLabel } from "../../lib/labels";
import { useScope } from "../../lib/scope";
import { AdminUnavailable } from "./AdminUnavailable";
import { natural } from "./roomModel";

const ALL_ROLES = ["resident", "hoa_manager", "dispatcher_external", "technician", "system_admin"];
/** belong to the building, not to an apartment */
const STAFF_ROLES = new Set(["hoa_manager", "dispatcher_external", "technician", "system_admin"]);
const USERNAME_RE = /^[a-z0-9._-]{3,32}$/;

/** lower case, no diacritics: "Ștefan" matches "stefan" */
const fold = (s: string) =>
  s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase();

interface Draft {
  username: string;
  display_name: string;
  role: string;
  phone: string;
  email: string;
  unit_ids: string[];
}

type Errors = Partial<Record<keyof Draft | "general", string>>;

/** Server error -> messages next to the fields (422 field list, 409 username / self). */
function serverErrors(e: unknown, t: TFn, mode: "create" | "edit" | "toggle"): Errors {
  if (!(e instanceof ApiError)) return { general: (e as Error)?.message ?? t("error.network") };
  if (e.status === 409) {
    if (mode === "create") return { username: t("acct.usernameTaken") };
    if (mode === "toggle") return { general: t("acct.selfDeactivate") };
    return { general: e.message };
  }
  if (e.status === 403) return { general: t("acct.forbidden") };
  if (e.status === 422) {
    const fields = e.fieldErrors();
    const out: Errors = {};
    for (const [k, msg] of Object.entries(fields)) {
      if (k === "username") out.username = t("acct.usernameInvalid");
      else if (k === "display_name") out.display_name = t("acct.nameRequired");
      else if (k === "phone") out.phone = t("acct.phoneInvalid");
      else if (k === "email") out.email = t("acct.emailInvalid");
      else if (k === "unit_ids") out.unit_ids = msg;
      else out.general = `${k}: ${msg}`;
    }
    if (Object.keys(out).length === 0) {
      // a plain-text 422 (e.g. phone / email rejected by the hub's own checks)
      const m = e.message.toLowerCase();
      if (m.includes("phone")) out.phone = t("acct.phoneInvalid");
      else if (m.includes("email")) out.email = t("acct.emailInvalid");
      else if (m.includes("unit")) out.unit_ids = e.message;
      else out.general = e.message;
    }
    return out;
  }
  return { general: e.message };
}

function validate(d: Draft, t: TFn, creating: boolean): Errors {
  const out: Errors = {};
  if (creating && !USERNAME_RE.test(d.username)) out.username = t("acct.usernameInvalid");
  if (!d.display_name.trim()) out.display_name = t("acct.nameRequired");
  return out;
}

/** Toggle chips for the building's apartments (residential units), sorted by name. */
function UnitPicker({
  units,
  value,
  onChange,
  error,
}: {
  units: AdminUnit[];
  value: string[];
  onChange: (ids: string[]) => void;
  error?: string;
}) {
  const { t } = useT();
  const homes = units.filter((u) => u.kind !== "common").sort((a, b) => natural(a.label, b.label));
  if (homes.length === 0) return <div className="muted small">{t("acct.noUnits")}</div>;
  return (
    <div>
      <div className="unit-chips" role="group" aria-label={t("acct.units")}>
        {homes.map((u) => {
          const on = value.includes(u.unit_id);
          return (
            <button
              key={u.unit_id}
              type="button"
              className={`unit-chip ${on ? "on" : ""}`}
              aria-pressed={on}
              title={u.floor_label ?? undefined}
              onClick={() => onChange(on ? value.filter((v) => v !== u.unit_id) : [...value, u.unit_id])}
            >
              {u.label}
            </button>
          );
        })}
      </div>
      {error && <div className="field-err">{error}</div>}
    </div>
  );
}

function FieldErr({ msg }: { msg?: string }) {
  return msg ? <div className="field-err">{msg}</div> : null;
}

function roleOptions(isAdmin: boolean): string[] {
  return isAdmin ? ALL_ROLES : ["resident"];
}

// --------------------------------------------------------------------------- //
// add account
// --------------------------------------------------------------------------- //

interface AddProps {
  units: AdminUnit[];
  isAdmin: boolean;
  /** pre-ticked: the apartment chosen in the scope bar */
  unitIds: string[];
  onDone: (username: string) => void;
}

function AddAccount({ units, isAdmin, unitIds, onDone }: AddProps) {
  const { t } = useT();
  const create = useCreateUser();
  const [d, setD] = useState<Draft>({ username: "", display_name: "", role: "resident", phone: "", email: "", unit_ids: unitIds });
  const [errors, setErrors] = useState<Errors>({});
  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => {
    setD((p) => ({ ...p, [k]: v }));
    setErrors((p) => ({ ...p, [k]: undefined, general: undefined }));
  };

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const local = validate(d, t, true);
    if (Object.keys(local).length) return setErrors(local);
    create.mutate(
      {
        username: d.username,
        display_name: d.display_name.trim(),
        role: d.role,
        phone: d.phone.trim(),
        email: d.email.trim(),
        unit_ids: d.role === "resident" ? d.unit_ids : [],
      },
      {
        onSuccess: () => onDone(d.username),
        onError: (err) => setErrors(serverErrors(err, t, "create")),
      },
    );
  };

  return (
    <form className="card acct-add" onSubmit={submit} noValidate>
      <h3>{t("acct.add")}</h3>
      <div className="form-grid cols-3">
        <label className="field">
          <span>{t("acct.username")}</span>
          <input
            className={`input ${errors.username ? "bad" : ""}`}
            value={d.username}
            autoFocus
            autoComplete="off"
            spellCheck={false}
            maxLength={32}
            onChange={(e) => set("username", e.target.value.toLowerCase().replace(/\s+/g, ""))}
          />
          {errors.username ? <FieldErr msg={errors.username} /> : <span className="muted small">{t("acct.usernameHint")}</span>}
        </label>
        <label className="field">
          <span>{t("acct.displayName")}</span>
          <input
            className={`input ${errors.display_name ? "bad" : ""}`}
            value={d.display_name}
            maxLength={60}
            onChange={(e) => set("display_name", e.target.value)}
          />
          <FieldErr msg={errors.display_name} />
        </label>
        <label className="field">
          <span>{t("acct.role")}</span>
          <select className="input" value={d.role} disabled={!isAdmin} onChange={(e) => set("role", e.target.value)}>
            {roleOptions(isAdmin).map((r) => (
              <option key={r} value={r}>
                {tokenLabel(t, "role", r)}
              </option>
            ))}
          </select>
          {!isAdmin && <span className="muted small">{t("acct.managerOnlyResidents")}</span>}
        </label>
        <label className="field">
          <span>{t("acct.phone")}</span>
          <input
            className={`input ${errors.phone ? "bad" : ""}`}
            value={d.phone}
            inputMode="tel"
            placeholder={t("acct.phonePlaceholder")}
            onChange={(e) => set("phone", e.target.value)}
          />
          <FieldErr msg={errors.phone} />
        </label>
        <label className="field">
          <span>{t("acct.email")}</span>
          <input
            className={`input ${errors.email ? "bad" : ""}`}
            value={d.email}
            type="email"
            maxLength={254}
            onChange={(e) => set("email", e.target.value)}
          />
          <FieldErr msg={errors.email} />
        </label>
      </div>
      {d.role === "resident" && (
        <div className="field">
          <span className="field-label">{t("acct.units")}</span>
          <UnitPicker units={units} value={d.unit_ids} onChange={(v) => set("unit_ids", v)} error={errors.unit_ids} />
        </div>
      )}
      {errors.general && <div className="err">{errors.general}</div>}
      <div className="btn-row">
        <button type="submit" className="btn primary" disabled={create.isPending}>
          <PlusIcon /> {create.isPending ? t("common.saving") : t("acct.create")}
        </button>
        <button type="button" className="btn" onClick={() => onDone("")}>
          {t("common.cancel")}
        </button>
      </div>
    </form>
  );
}

// --------------------------------------------------------------------------- //
// one account row (view / edit)
// --------------------------------------------------------------------------- //

function AccountRow({ user, units, isAdmin, isSelf }: { user: AdminUser; units: AdminUnit[]; isAdmin: boolean; isSelf: boolean }) {
  const { t } = useT();
  const update = useUpdateUser();
  const toggle = useUpdateUser();
  const [editing, setEditing] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const [d, setD] = useState<Draft | null>(null);
  const [errors, setErrors] = useState<Errors>({});
  const [toggleErr, setToggleErr] = useState<string | null>(null);
  // managers may only touch resident accounts
  const editable = isAdmin || user.role === "resident";

  const start = () => {
    setD({
      username: user.username,
      display_name: user.display_name,
      role: user.role,
      phone: user.phone ?? "",
      email: user.email ?? "",
      unit_ids: user.units.map((u) => u.unit_id),
    });
    setErrors({});
    setEditing(true);
  };
  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => {
    setD((p) => (p ? { ...p, [k]: v } : p));
    setErrors((p) => ({ ...p, [k]: undefined, general: undefined }));
  };

  const save = () => {
    if (!d) return;
    const local = validate(d, t, false);
    if (Object.keys(local).length) return setErrors(local);
    const patch: AdminUserPatch = {};
    if (d.display_name.trim() !== user.display_name) patch.display_name = d.display_name.trim();
    if (d.phone.trim() !== (user.phone ?? "")) patch.phone = d.phone.trim();
    if (d.email.trim() !== (user.email ?? "")) patch.email = d.email.trim();
    if (isAdmin && d.role !== user.role) patch.role = d.role;
    const before = user.units.map((u) => u.unit_id).sort().join(",");
    const ids = d.role === "resident" ? d.unit_ids : [];
    // a staff role holds no apartments: the hub wants unit_ids: [] with the role change
    if (ids.slice().sort().join(",") !== before || (patch.role && patch.role !== "resident")) patch.unit_ids = ids;
    if (Object.keys(patch).length === 0) return setEditing(false);
    update.mutate(
      { userId: user.user_id, patch },
      {
        onSuccess: () => setEditing(false),
        onError: (err) => setErrors(serverErrors(err, t, "edit")),
      },
    );
  };

  const unitsText = user.units.length ? user.units.map((u) => u.unit_label).join(", ") : "—";

  if (editing && d) {
    return (
      <tr className="acct-row editing">
        <td colSpan={7}>
          <div className="acct-edit">
            <div className="form-grid cols-4">
              <label className="field">
                <span>{t("acct.displayName")}</span>
                <input
                  className={`input ${errors.display_name ? "bad" : ""}`}
                  value={d.display_name}
                  maxLength={60}
                  autoFocus
                  onChange={(e) => set("display_name", e.target.value)}
                />
                <FieldErr msg={errors.display_name} />
              </label>
              <label className="field">
                <span>{t("acct.role")}</span>
                <select className="input" value={d.role} disabled={!isAdmin || isSelf} onChange={(e) => set("role", e.target.value)}>
                  {(isAdmin ? ALL_ROLES : [user.role]).map((r) => (
                    <option key={r} value={r}>
                      {tokenLabel(t, "role", r)}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                <span>{t("acct.phone")}</span>
                <input
                  className={`input ${errors.phone ? "bad" : ""}`}
                  value={d.phone}
                  inputMode="tel"
                  placeholder={t("acct.phonePlaceholder")}
                  onChange={(e) => set("phone", e.target.value)}
                />
                <FieldErr msg={errors.phone} />
              </label>
              <label className="field">
                <span>{t("acct.email")}</span>
                <input
                  className={`input ${errors.email ? "bad" : ""}`}
                  value={d.email}
                  type="email"
                  maxLength={254}
                  onChange={(e) => set("email", e.target.value)}
                />
                <FieldErr msg={errors.email} />
              </label>
            </div>
            {d.role === "resident" ? (
              <div className="field">
                <span className="field-label">{t("acct.units")}</span>
                <UnitPicker units={units} value={d.unit_ids} onChange={(v) => set("unit_ids", v)} error={errors.unit_ids} />
              </div>
            ) : (
              user.units.length > 0 && <div className="muted small">{t("acct.staffNoUnits")}</div>
            )}
            {errors.general && <div className="err">{errors.general}</div>}
            <div className="btn-row">
              <button type="button" className="btn primary" disabled={update.isPending} onClick={save}>
                {update.isPending ? t("common.saving") : t("common.save")}
              </button>
              <button type="button" className="btn" onClick={() => setEditing(false)}>
                {t("common.cancel")}
              </button>
              <span className="muted small acct-edit-user">
                {t("acct.colUsername")}: <b>{user.username}</b>
              </span>
            </div>
          </div>
        </td>
      </tr>
    );
  }

  return (
    <tr className={`acct-row ${user.active ? "" : "inactive"}`}>
      <td>
        <div className="acct-name">
          {user.display_name}
          {isSelf && <span className="tag">{t("acct.you")}</span>}
        </div>
        {user.email && <div className="muted small">{user.email}</div>}
      </td>
      <td className="mono">{user.username}</td>
      <td>{tokenLabel(t, "role", user.role)}</td>
      <td>{unitsText}</td>
      <td className="mono">{user.phone || "—"}</td>
      <td>
        <button
          type="button"
          role="switch"
          aria-checked={user.active}
          className={`switch ${user.active ? "on" : ""}`}
          disabled={!editable || toggle.isPending || (isSelf && user.active)}
          title={!editable ? t("acct.onlyAdminEdits") : isSelf && user.active ? t("acct.selfDeactivate") : undefined}
          onClick={() => {
            setToggleErr(null);
            setConfirm(true);
          }}
        >
          <span className="knob" aria-hidden="true" />
          <span>{t(user.active ? "acct.active" : "acct.inactive")}</span>
        </button>
        {toggleErr && <div className="field-err">{toggleErr}</div>}
      </td>
      <td className="acct-actions">
        <button
          type="button"
          className="btn small-btn"
          disabled={!editable}
          title={!editable ? t("acct.onlyAdminEdits") : undefined}
          onClick={start}
        >
          <PencilIcon /> {t("common.edit")}
        </button>
        {confirm && (
          <ConfirmDialog
            title={t(user.active ? "acct.confirmDeactivateTitle" : "acct.confirmActivateTitle", { name: user.display_name })}
            confirmLabel={t(user.active ? "acct.deactivate" : "acct.activate")}
            danger={user.active}
            busy={toggle.isPending}
            onCancel={() => setConfirm(false)}
            onConfirm={() =>
              toggle.mutate(
                { userId: user.user_id, patch: { active: !user.active } },
                {
                  onSettled: () => setConfirm(false),
                  onError: (err) => setToggleErr(serverErrors(err, t, "toggle").general ?? (err as Error).message),
                },
              )
            }
          >
            <p>{t(user.active ? "acct.confirmDeactivateBody" : "acct.confirmActivateBody", { username: user.username })}</p>
            {user.active && <p className="muted small">{t("acct.sessionNote")}</p>}
          </ConfirmDialog>
        )}
      </td>
    </tr>
  );
}

// --------------------------------------------------------------------------- //
// the tab
// --------------------------------------------------------------------------- //

export function AccountsTab() {
  const { t, lang } = useT();
  const { session } = useAuth();
  const users = useAdminUsers();
  const units = useAdminUnits();
  const sc = useScope();
  const [q, setQ] = useState("");
  const [adding, setAdding] = useState(false);
  const [created, setCreated] = useState<string | null>(null);
  const isAdmin = session?.role === "system_admin";

  const scopeUnit = sc.unit?.id ?? null;
  // an apartment: its residents (staff accounts are listed under the whole building only)
  const scoped = useMemo(
    () =>
      (users.data ?? []).filter(
        (u) => !scopeUnit || (!STAFF_ROLES.has(u.role) && u.units.some((x) => x.unit_id === scopeUnit)),
      ),
    [users.data, scopeUnit],
  );

  const list = useMemo(() => {
    const needle = fold(q.trim());
    return scoped
      .filter((u) => {
        if (!needle) return true;
        const hay = fold([u.display_name, u.username, u.phone, u.email, tokenLabel(t, "role", u.role), ...u.units.map((x) => x.unit_label)].join(" "));
        return hay.includes(needle);
      })
      .sort((a, b) => Number(b.active) - Number(a.active) || natural(a.display_name, b.display_name));
  }, [scoped, q, t]);

  if (users.isError && !users.data) return <AdminUnavailable error={users.error} />;
  const total = scoped.length;
  const homeIds = scopeUnit && !sc.unit?.common ? [scopeUnit] : [];
  const emptyText = q.trim()
    ? scopeUnit
      ? t("acct.noMatchScoped", { q: q.trim(), scope: sc.title })
      : t("acct.noMatch", { q: q.trim() })
    : sc.unit?.common
      ? t("acct.commonNoAccounts")
      : scopeUnit
        ? t("acct.emptyScoped", { scope: sc.title })
        : t("acct.empty");

  return (
    <>
      <div className="acct-toolbar">
        <label className="search">
          <SearchIcon />
          <input
            className="input"
            type="search"
            value={q}
            placeholder={t("acct.searchPlaceholder")}
            aria-label={t("common.search")}
            onChange={(e) => setQ(e.target.value)}
          />
        </label>
        <span className="muted">{t(`acct.count.${pluralCategory(lang, total)}`, { n: fmtNumber(total, lang, 0) })}</span>
        <span className="spacer" />
        <button
          type="button"
          className="btn primary"
          disabled={adding}
          onClick={() => {
            setCreated(null);
            setAdding(true);
          }}
        >
          <PlusIcon /> {t("acct.add")}
        </button>
      </div>
      <div className="info-note">
        <InfoIcon /> {t("acct.testLogin")}
      </div>
      {homeIds.length > 0 && <div className="muted small acct-scope-note">{t("acct.staffUnderBuilding")}</div>}
      {created && (
        <div className="ok-note" role="status">
          {t("acct.created", { username: created })}
        </div>
      )}
      {adding && (
        <AddAccount
          units={units.data ?? []}
          isAdmin={isAdmin}
          unitIds={homeIds}
          onDone={(username) => {
            setAdding(false);
            if (username) setCreated(username);
          }}
        />
      )}

      {!users.data ? (
        <div className="muted">{t("common.loading")}</div>
      ) : (
        <div className="card pad-0 acct-table-wrap">
          <table className="acct-table">
            <thead>
              <tr>
                <th>{t("acct.colName")}</th>
                <th>{t("acct.colUsername")}</th>
                <th>{t("acct.colRole")}</th>
                <th>{t("acct.colUnits")}</th>
                <th>{t("acct.colPhone")}</th>
                <th>{t("acct.colActive")}</th>
                <th>
                  <span className="sr-only">{t("acct.colActions")}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {list.map((u) => (
                <AccountRow key={u.user_id} user={u} units={units.data ?? []} isAdmin={isAdmin} isSelf={u.user_id === session?.userId} />
              ))}
              {list.length === 0 && (
                <tr>
                  <td colSpan={7} className="muted acct-empty">
                    {emptyText}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}
      <div className="muted small acct-foot">{t("acct.sessionNote")}</div>
    </>
  );
}

import { useEffect, useId, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";

import { useT } from "../i18n";
import { WarningIcon } from "./Icons";

interface Props {
  title: string;
  children?: ReactNode;
  confirmLabel: string;
  /** red confirm button (destructive or disruptive action) */
  danger?: boolean;
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/** Modal yes / no question. Esc or the backdrop cancel; focus starts on Cancel (the safe
 *  answer), stays inside, and returns to the element that opened it. */
export function ConfirmDialog({ title, children, confirmLabel, danger, busy, onConfirm, onCancel }: Props) {
  const { t } = useT();
  const titleId = useId();
  const box = useRef<HTMLDivElement>(null);
  const cancel = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null;
    cancel.current?.focus();
    return () => opener?.focus?.();
  }, []);

  const onKeyDown = (e: React.KeyboardEvent) => {
    // keys stay in the dialog (a zone view around it must not react to them)
    e.stopPropagation();
    if (e.key === "Escape") {
      onCancel();
    } else if (e.key === "Tab") {
      const items = box.current?.querySelectorAll<HTMLElement>("button:not(:disabled)");
      if (!items?.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    }
  };

  return createPortal(
    <>
      <div className="dlg-backdrop" onClick={onCancel} />
      <div
        ref={box}
        className="dlg"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        onKeyDown={onKeyDown}
      >
        <div className="dlg-head">
          <WarningIcon className={danger ? "t-danger" : "t-attention"} />
          <h2 id={titleId}>{title}</h2>
        </div>
        {children && <div className="dlg-body">{children}</div>}
        <div className="dlg-actions">
          <button ref={cancel} type="button" className="btn" onClick={onCancel} disabled={busy}>
            {t("common.cancel")}
          </button>
          <button type="button" className={`btn ${danger ? "danger" : "primary"}`} onClick={onConfirm} disabled={busy}>
            {confirmLabel}
          </button>
        </div>
      </div>
    </>,
    document.body,
  );
}

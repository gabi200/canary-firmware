import { useRef, useState } from "react";
import { useParams } from "react-router-dom";

import { CheckIcon, ClockIcon, CopyIcon, HomeIcon, WarningIcon } from "../components/Icons";
import { LangToggle } from "../components/LangToggle";
import { useT } from "../i18n";

/** Invitation codes as the backend issues them (anything else is not a valid link). */
const CODE_RE = /^[A-Za-z0-9_-]{4,64}$/;

type CopyState = "idle" | "copied" | "manual";

/** Clipboard API, then the legacy execCommand path (http:// pages have no clipboard API). */
async function copyText(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    /* fall through */
  }
  try {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(ta);
    return ok;
  } catch {
    return false;
  }
}

/**
 * Public household-invitation page ({hub}/join/{code}), opened on phones: no login and no API
 * calls. Hands the code to the mobile app (canary://join/{code}) or lets the person copy it.
 */
export function JoinPage() {
  const { t } = useT();
  const raw = useParams().code ?? "";
  const code = (() => {
    try {
      return decodeURIComponent(raw).trim();
    } catch {
      return "";
    }
  })();
  const valid = CODE_RE.test(code);
  const [copy, setCopy] = useState<CopyState>("idle");
  const codeBox = useRef<HTMLElement>(null);

  const onCopy = async () => {
    if (await copyText(code)) {
      setCopy("copied");
      window.setTimeout(() => setCopy("idle"), 2500);
      return;
    }
    // last resort: select the code so the person can copy it by hand
    const el = codeBox.current;
    if (el) {
      const range = document.createRange();
      range.selectNodeContents(el);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
    }
    setCopy("manual");
  };

  return (
    <main className="join">
      <div className="join-card">
        <div className="join-top">
          <div className="brand join-brand">
            Canary<span className="dot">.</span>
          </div>
          <LangToggle />
        </div>

        {!valid ? (
          <div className="join-invalid" role="alert">
            <WarningIcon />
            <p>{t("join.invalid")}</p>
          </div>
        ) : (
          <>
            <div className="join-hero">
              <span className="join-hero-icon">
                <HomeIcon />
              </span>
              <h1>{t("join.title")}</h1>
              <p className="muted">{t("join.lead")}</p>
            </div>

            <a className="btn primary join-open" href={`canary://join/${encodeURIComponent(code)}`}>
              {t("join.open")}
            </a>
            <p className="muted small join-hint">{t("join.noApp")}</p>

            <div className="join-code-block">
              <div className="join-label" id="join-code-label">
                {t("join.codeLabel")}
              </div>
              <div className="join-code-row">
                <code ref={codeBox} className="join-code" aria-labelledby="join-code-label">
                  {code}
                </code>
                <button type="button" className="btn join-copy" onClick={onCopy}>
                  {copy === "copied" ? <CheckIcon /> : <CopyIcon />}
                  {copy === "copied" ? t("join.copied") : t("join.copy")}
                </button>
              </div>
              <div className={`join-copy-status small ${copy === "copied" ? "sr-only" : ""}`} aria-live="polite">
                {copy === "manual" ? t("join.copyManual") : copy === "copied" ? t("join.copied") : ""}
              </div>
            </div>

            <ol className="join-steps">
              <li>{t("join.step1")}</li>
              <li>{t("join.step2")}</li>
              <li>{t("join.step3")}</li>
            </ol>

            <p className="join-expiry small">
              <ClockIcon />
              {t("join.expiry")}
            </p>
          </>
        )}
      </div>
    </main>
  );
}

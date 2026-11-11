import { useState } from "react";
import { useNavigate } from "react-router-dom";

import { config } from "../config";
import { Card } from "../components/Card";
import { LangToggle } from "../components/LangToggle";
import { ThemeToggle } from "../components/ThemeToggle";
import { useT } from "../i18n";
import { useAuth } from "./AuthContext";

export function LoginPage() {
  const { login } = useAuth();
  const { t } = useT();
  const navigate = useNavigate();
  const [username, setUsername] = useState("mihai");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    try {
      await login(username.trim());
      navigate("/");
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login">
      <Card>
        <div className="box">
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, marginBottom: 4 }}>
            <div className="brand">
              Canary<span className="dot">.</span>
            </div>
            <div className="btn-row">
              <LangToggle />
              <ThemeToggle />
            </div>
          </div>
          <div className="muted small" style={{ marginBottom: 20 }}>
            {t("login.tagline")}
          </div>
          <form onSubmit={submit}>
            <div className="field">
              <label htmlFor="login-username">{t("login.username")}</label>
              <input id="login-username" value={username} onChange={(e) => setUsername(e.target.value)} />
            </div>
            <div className="btn-row" style={{ marginBottom: 12 }} role="group" aria-label={t("login.demoAccounts")}>
              {["mihai", "dispecer", "tehnician", "admin"].map((u) => (
                <button type="button" key={u} className="btn" onClick={() => setUsername(u)}>
                  {u}
                </button>
              ))}
            </div>
            {err && <div className="err">{err}</div>}
            <button type="submit" className="btn primary" style={{ width: "100%" }} disabled={busy}>
              {busy ? t("login.signingIn") : t("login.signIn")}
            </button>
          </form>
          <div className="muted small" style={{ marginTop: 12 }}>
            {t("login.server", {
              url: config.apiBase || t("login.sameOrigin", { origin: window.location.origin }),
            })}
          </div>
        </div>
      </Card>
    </div>
  );
}

import { useState } from "react";
import { useNavigate } from "react-router-dom";

import { config } from "../config";
import { Card } from "../components/Card";
import { useAuth } from "./AuthContext";

export function LoginPage() {
  const { login } = useAuth();
  const navigate = useNavigate();
  const [username, setUsername] = useState("mihai");
  const [buildingId, setBuildingId] = useState(config.defaultBuildingId);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    try {
      await login(username.trim(), buildingId.trim());
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
          <div className="brand" style={{ fontSize: 26, marginBottom: 4 }}>
            Canary<span className="dot">.</span>
          </div>
          <div className="muted small" style={{ marginBottom: 20 }}>
            Operations console — managers &amp; emergency services
          </div>
          <form onSubmit={submit}>
            <div className="field">
              <label>Username</label>
              <input value={username} onChange={(e) => setUsername(e.target.value)} />
            </div>
            <div className="field">
              <label>Building ID</label>
              <input value={buildingId} onChange={(e) => setBuildingId(e.target.value)} />
            </div>
            <div className="btn-row" style={{ marginBottom: 12 }}>
              {["mihai", "dispecer", "admin"].map((u) => (
                <button type="button" key={u} className="btn" onClick={() => setUsername(u)}>
                  {u}
                </button>
              ))}
            </div>
            {err && <div className="err">{err}</div>}
            <button type="submit" className="btn primary" style={{ width: "100%" }} disabled={busy}>
              {busy ? "Signing in…" : "Sign in"}
            </button>
          </form>
          <div className="muted small" style={{ marginTop: 12 }}>
            Server: {config.apiBase || `${window.location.origin} (same origin)`}
          </div>
        </div>
      </Card>
    </div>
  );
}

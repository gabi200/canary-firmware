import { createContext, useContext, useMemo, useState, type ReactNode } from "react";

import { api } from "../api/client";
import type { Token } from "../api/types";
import { config } from "../config";

export interface Session {
  token: string;
  role: string;
  userId: string;
  username: string;
  buildingId: string;
}

interface AuthValue {
  session: Session | null;
  token: string | null;
  buildingId: string;
  login: (username: string, buildingId: string) => Promise<void>;
  logout: () => void;
}

const STORAGE_KEY = "canary.session";

function load(): Session | null {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as Session;
  } catch {
    return null;
  }
}

const AuthContext = createContext<AuthValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(load);

  const value = useMemo<AuthValue>(
    () => ({
      session,
      token: session?.token ?? null,
      buildingId: session?.buildingId ?? config.defaultBuildingId,
      async login(username, buildingId) {
        const tok = await api.post<Token>("/api/v1/auth/token", null, { username });
        const next: Session = {
          token: tok.access_token,
          role: tok.role,
          userId: tok.user_id,
          username,
          buildingId,
        };
        localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
        setSession(next);
      },
      logout() {
        localStorage.removeItem(STORAGE_KEY);
        setSession(null);
      },
    }),
    [session],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}

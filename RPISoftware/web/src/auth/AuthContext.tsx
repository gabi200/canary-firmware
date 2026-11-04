import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useLocation } from "react-router-dom";

import { UNAUTHORIZED_EVENT, api } from "../api/client";
import type { HubMode, Token } from "../api/types";
import { config } from "../config";
import { useT } from "../i18n";

export interface Session {
  token: string;
  role: string;
  userId: string;
  username: string;
}

interface AuthValue {
  session: Session | null;
  token: string | null;
  /** the building of the hub's current mode (Demo or Real) */
  buildingId: string;
  /** the hub's mode answer; null until the first one arrives (or if it failed) */
  hubMode: HubMode | null;
  /** false while signed in and waiting for the first mode answer */
  modeReady: boolean;
  login: (username: string) => Promise<void>;
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
  const queryClient = useQueryClient();
  const { lang } = useT();
  const token = session?.token ?? null;
  // the public invitation page (/join/…) makes no API calls at all
  const publicPage = useLocation().pathname.startsWith("/join/");

  // the hub-wide demo/real mode picks the building every screen shows
  const modeQuery = useQuery({
    queryKey: ["mode"],
    queryFn: () => api.get<HubMode>("/api/v1/mode", token),
    enabled: !!token && !publicPage,
    refetchInterval: 5_000,
    retry: false,
  });
  const hubMode = modeQuery.data ?? null;
  // on a failed first request, fall back to the default building instead of blocking forever
  const modeReady = !token || publicPage || modeQuery.isSuccess || modeQuery.isError;

  // the server sends managers' notifications in their language: tell it after login and on
  // every switch (best effort: an older backend without PATCH /me just ignores it)
  useEffect(() => {
    if (!token || publicPage) return;
    api.patch("/api/v1/me", token, { language: lang }).catch(() => undefined);
  }, [token, lang, publicPage]);

  // the session expired (8 h) or the hub's key changed: back to the login page
  useEffect(() => {
    const drop = () => {
      try {
        localStorage.removeItem(STORAGE_KEY);
      } catch {
        /* storage blocked */
      }
      setSession(null);
      queryClient.clear();
    };
    window.addEventListener(UNAUTHORIZED_EVENT, drop);
    return () => window.removeEventListener(UNAUTHORIZED_EVENT, drop);
  }, [queryClient]);

  const value = useMemo<AuthValue>(
    () => ({
      session,
      token: session?.token ?? null,
      buildingId: hubMode?.building_id ?? config.defaultBuildingId,
      hubMode,
      modeReady,
      async login(username) {
        const tok = await api.post<Token>("/api/v1/auth/token", null, { username });
        const next: Session = {
          token: tok.access_token,
          role: tok.role,
          userId: tok.user_id,
          username,
        };
        localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
        setSession(next);
      },
      logout() {
        localStorage.removeItem(STORAGE_KEY);
        setSession(null);
        // drop everything fetched under this session from memory (rosters carry health data)
        queryClient.clear();
      },
    }),
    [session, queryClient, hubMode, modeReady],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}

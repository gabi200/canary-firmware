/**
 * Dark / light theme. Dark is the default; the choice is stored per browser and applied as
 * `data-theme` on <html> (index.html applies the stored value before first paint).
 */
import { useCallback, useSyncExternalStore } from "react";

export type Theme = "dark" | "light";

const STORAGE_KEY = "canary.theme";
const listeners = new Set<() => void>();

function read(): Theme {
  return document.documentElement.dataset.theme === "light" ? "light" : "dark";
}

function subscribe(fn: () => void) {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function useTheme(): { theme: Theme; setTheme: (next: Theme) => void } {
  const theme = useSyncExternalStore(subscribe, read);
  const setTheme = useCallback((next: Theme) => {
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      /* storage unavailable (private mode, blocked): the choice lasts for this page */
    }
    listeners.forEach((fn) => fn());
  }, []);
  return { theme, setTheme };
}

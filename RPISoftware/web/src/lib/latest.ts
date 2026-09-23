import type { Reading } from "../api/types";

/** Reduce a list of readings to the latest reading per device_id. */
export function latestByDevice(readings: Reading[] | undefined): Map<string, Reading> {
  const m = new Map<string, Reading>();
  for (const r of readings ?? []) {
    const cur = m.get(r.device_id);
    if (!cur || r.ts > cur.ts) m.set(r.device_id, r);
  }
  return m;
}

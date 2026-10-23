/**
 * Administration API (/api/v1/admin/...): accounts, floors, apartments (units), rooms (zones),
 * plus a node's command history. system_admin: everything; hoa_manager: their building only and
 * resident accounts only (the backend enforces it, the UI just hides what it would refuse).
 */
import { useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";

import { useAuth } from "../auth/AuthContext";
import { api } from "./client";
import type {
  AdminFloor,
  AdminUnit,
  AdminUser,
  AdminUserCreate,
  AdminUserPatch,
  AdminZone,
  AdminZoneCreate,
  AdminZonePatch,
  CommandRecord,
  FirmwareUpdate,
  NodeFirmware,
  NodeFirmwareDetail,
  UnitKind,
} from "./types";

const enc = encodeURIComponent;

/** Everything a room / apartment / sensor change can affect, on every screen. */
function invalidateBuilding(qc: QueryClient) {
  for (const key of ["admin", "zones", "nodes", "summary", "devices", "residents"]) {
    qc.invalidateQueries({ queryKey: [key] });
  }
}

/** Accounts: managers see their building's (`building_id`), the system admin every account. */
export function useAdminUsers() {
  const { token, buildingId, session } = useAuth();
  const scoped = session?.role !== "system_admin";
  const qs = scoped ? `?building_id=${enc(buildingId)}` : "";
  return useQuery({
    queryKey: ["admin", "users", scoped ? buildingId : "all"],
    queryFn: () => api.get<AdminUser[]>(`/api/v1/admin/users${qs}`, token),
    retry: false,
  });
}

export function useCreateUser() {
  const { token } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: AdminUserCreate) => api.post<AdminUser>(`/api/v1/admin/users`, token, body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin"] });
      qc.invalidateQueries({ queryKey: ["residents"] });
    },
  });
}

export function useUpdateUser() {
  const { token } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ userId, patch }: { userId: string; patch: AdminUserPatch }) =>
      api.patch<AdminUser>(`/api/v1/admin/users/${enc(userId)}`, token, patch),
    onSuccess: (updated) => {
      // show the saved row at once (the refetch follows)
      if (updated?.user_id) {
        qc.setQueriesData<AdminUser[]>({ queryKey: ["admin", "users"] }, (old) =>
          old?.map((u) => (u.user_id === updated.user_id ? updated : u)),
        );
      }
      qc.invalidateQueries({ queryKey: ["admin"] });
      qc.invalidateQueries({ queryKey: ["residents"] });
    },
  });
}

export function useAdminFloors() {
  const { token, buildingId } = useAuth();
  return useQuery({
    queryKey: ["admin", "floors", buildingId],
    queryFn: () => api.get<AdminFloor[]>(`/api/v1/admin/buildings/${enc(buildingId)}/floors`, token),
    retry: false,
  });
}

export function useCreateFloor() {
  const { token, buildingId } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { label: string; level: number }) =>
      api.post<AdminFloor>(`/api/v1/admin/buildings/${enc(buildingId)}/floors`, token, body),
    onSuccess: () => invalidateBuilding(qc),
  });
}

/** `enabled: false` for roles the admin API refuses (the scope bar on the Sensors page). */
export function useAdminUnits(enabled = true) {
  const { token, buildingId } = useAuth();
  return useQuery({
    queryKey: ["admin", "units", buildingId],
    queryFn: () => api.get<AdminUnit[]>(`/api/v1/admin/buildings/${enc(buildingId)}/units`, token),
    enabled,
    retry: false,
  });
}

export function useCreateUnit() {
  const { token, buildingId } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { label: string; floor_id: string; kind: UnitKind }) =>
      api.post<AdminUnit>(`/api/v1/admin/buildings/${enc(buildingId)}/units`, token, body),
    onSuccess: () => invalidateBuilding(qc),
  });
}

export function useUpdateUnit() {
  const { token } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ unitId, patch }: { unitId: string; patch: { label?: string; kind?: UnitKind } }) =>
      api.patch<AdminUnit>(`/api/v1/admin/units/${enc(unitId)}`, token, patch),
    onSuccess: () => invalidateBuilding(qc),
  });
}

/** Rooms with their sensors (node id, name, kind, online, status). */
export function useAdminZones() {
  const { token, buildingId } = useAuth();
  return useQuery({
    queryKey: ["admin", "zones", buildingId],
    queryFn: () => api.get<AdminZone[]>(`/api/v1/admin/buildings/${enc(buildingId)}/zones`, token),
    refetchInterval: 15_000,
    retry: false,
  });
}

export function useCreateZone() {
  const { token, buildingId } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: AdminZoneCreate) =>
      api.post<AdminZone>(`/api/v1/admin/buildings/${enc(buildingId)}/zones`, token, body),
    onSuccess: () => invalidateBuilding(qc),
  });
}

export function useUpdateZone() {
  const { token, buildingId } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ zoneId, patch }: { zoneId: string; patch: AdminZonePatch }) =>
      api.patch<AdminZone>(`/api/v1/admin/zones/${enc(zoneId)}`, token, patch),
    onSuccess: (updated, { zoneId, patch }) => {
      // keep the dropped position on screen until the refetch lands (no jump back)
      qc.setQueryData<AdminZone[]>(["admin", "zones", buildingId], (old) =>
        old?.map((z) => (z.zone_id === zoneId ? { ...z, ...patch, ...(updated ?? {}), nodes: z.nodes } : z)),
      );
      invalidateBuilding(qc);
    },
  });
}

export function useDeleteZone() {
  const { token } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (zoneId: string) => api.delete(`/api/v1/admin/zones/${enc(zoneId)}`, token),
    onSuccess: () => invalidateBuilding(qc),
  });
}

/** Move (zone_id) or rename a sensor from the room manager (PATCH /nodes/{id}). */
export function useMoveNode() {
  const { token } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ nodeId, patch }: { nodeId: string; patch: { zone_id?: string; name?: string } }) =>
      api.patch(`/api/v1/nodes/${enc(nodeId)}`, token, patch),
    onSuccess: () => invalidateBuilding(qc),
  });
}

/** Remove an offline sensor (409 while it is online; it re-registers itself if it reconnects). */
export function useDeleteNode() {
  const { token } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (nodeId: string) => api.delete(`/api/v1/admin/nodes/${enc(nodeId)}`, token),
    onSuccess: () => invalidateBuilding(qc),
  });
}

/** Last commands sent to a node, newest first (history popover). */
export function useNodeCommandHistory(nodeId: string, enabled: boolean) {
  const { token } = useAuth();
  return useQuery({
    queryKey: ["commands", nodeId],
    enabled,
    queryFn: () => api.get<CommandRecord[]>(`/api/v1/nodes/${enc(nodeId)}/commands?limit=20`, token),
    refetchInterval: enabled ? 5_000 : false,
    retry: false,
  });
}

/** Every node of the building with its firmware version and push readiness. */
export function useFirmware() {
  const { token, buildingId } = useAuth();
  return useQuery({
    queryKey: ["admin", "firmware", buildingId],
    queryFn: () => api.get<NodeFirmware[]>(`/api/v1/admin/buildings/${enc(buildingId)}/firmware`, token),
    // online / offline changes arrive as node events; this keeps readiness current without them
    refetchInterval: 15_000,
    retry: false,
  });
}

/** One node's version history and pushes (history panel). */
export function useNodeFirmware(nodeId: string, enabled: boolean) {
  const { token } = useAuth();
  return useQuery({
    queryKey: ["admin", "firmware", "node", nodeId],
    enabled,
    queryFn: () => api.get<NodeFirmwareDetail>(`/api/v1/admin/nodes/${enc(nodeId)}/firmware`, token),
    retry: false,
  });
}

/** Pin the device's address and (optionally, when one is stored) its API token. */
export function useSetOtaTarget() {
  const { token } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ nodeId, address, deviceToken }: { nodeId: string; address: string; deviceToken?: string }) =>
      api.put<NodeFirmware>(`/api/v1/admin/nodes/${enc(nodeId)}/ota-target`, token, {
        address,
        ...(deviceToken ? { token: deviceToken } : {}),
      }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["admin", "firmware"] }),
  });
}

export function useClearOtaTarget() {
  const { token } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (nodeId: string) => api.delete(`/api/v1/admin/nodes/${enc(nodeId)}/ota-target`, token),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["admin", "firmware"] }),
  });
}

/** Queue a .bin for one node; the hub pushes one node at a time (WebSocket `firmware_update`). */
export function usePushFirmware() {
  const { token } = useAuth();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ nodeId, file }: { nodeId: string; file: File }) => {
      const form = new FormData();
      form.append("firmware", file);
      return api.upload<FirmwareUpdate>(`/api/v1/admin/nodes/${enc(nodeId)}/firmware`, token, form);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: ["admin", "firmware"] }),
  });
}

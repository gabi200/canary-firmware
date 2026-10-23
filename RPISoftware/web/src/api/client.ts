import { config } from "../config";
import { getLang, translate } from "../i18n";

/** One FastAPI validation error (422 `detail` list). */
export interface FieldError {
  loc: (string | number)[];
  msg: string;
  type?: string;
}

export class ApiError extends Error {
  /** `detail`: the raw error body detail (a string, or a FastAPI 422 field-error list). */
  constructor(message: string, readonly status?: number, readonly detail?: unknown) {
    super(message);
  }

  /** Field errors of a 422 answer, keyed by the last `loc` element (`body.username` -> username). */
  fieldErrors(): Record<string, string> {
    const out: Record<string, string> = {};
    if (!Array.isArray(this.detail)) return out;
    for (const e of this.detail as FieldError[]) {
      const field = e?.loc?.length ? String(e.loc[e.loc.length - 1]) : "";
      if (field && !out[field]) out[field] = e.msg;
    }
    return out;
  }
}

/** Readable message of an error body detail: a string, or the messages of a 422 list. */
function detailMessage(detail: unknown, fallback: string): string {
  if (typeof detail === "string") return detail;
  if (Array.isArray(detail)) {
    const msgs = detail
      .map((e: Partial<FieldError>) => {
        const field = e?.loc?.length ? String(e.loc[e.loc.length - 1]) : "";
        return e?.msg ? (field ? `${field}: ${e.msg}` : e.msg) : "";
      })
      .filter(Boolean);
    if (msgs.length) return msgs.join("; ");
  }
  return fallback;
}

/** Fired on window when the hub answers 401 to a request that carried a token. */
export const UNAUTHORIZED_EVENT = "canary:unauthorized";

async function request<T>(
  path: string,
  token: string | null,
  options: RequestInit = {},
): Promise<T> {
  const headers: Record<string, string> = {
    // FormData sets its own multipart boundary
    ...(options.body instanceof FormData ? {} : { "Content-Type": "application/json" }),
    // backend-generated text (analysis headlines, advice) follows the dashboard language
    "Accept-Language": getLang(),
    ...(options.headers as Record<string, string> | undefined),
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  let res: Response;
  try {
    res = await fetch(`${config.apiBase}${path}`, { ...options, headers });
  } catch (e) {
    throw new ApiError((e as Error).message || translate(getLang(), "error.network"));
  }

  if (!res.ok) {
    let detail: unknown = undefined;
    try {
      const body = await res.json();
      detail = body?.detail;
    } catch {
      /* non-JSON error body */
    }
    // an expired / rejected session: AuthProvider logs out, so the login page shows
    if (res.status === 401 && token) window.dispatchEvent(new Event(UNAUTHORIZED_EVENT));
    throw new ApiError(detailMessage(detail, res.statusText), res.status, detail);
  }
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

export const api = {
  get: <T>(path: string, token: string | null) => request<T>(path, token),
  post: <T>(path: string, token: string | null, body?: unknown) =>
    request<T>(path, token, { method: "POST", body: body ? JSON.stringify(body) : undefined }),
  patch: <T>(path: string, token: string | null, body: unknown) =>
    request<T>(path, token, { method: "PATCH", body: JSON.stringify(body) }),
  put: <T>(path: string, token: string | null, body: unknown) =>
    request<T>(path, token, { method: "PUT", body: JSON.stringify(body) }),
  upload: <T>(path: string, token: string | null, form: FormData) => request<T>(path, token, { method: "POST", body: form }),
  delete: <T = void>(path: string, token: string | null) => request<T>(path, token, { method: "DELETE" }),
};

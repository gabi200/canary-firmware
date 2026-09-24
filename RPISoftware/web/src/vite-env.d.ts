/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Backend base URL; empty string = same origin (see config.ts). */
  readonly VITE_API_BASE?: string;
}

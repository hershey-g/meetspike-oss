/**
 * Types and the auth error shared by the code that reads WHOOP heart rate
 * from stored data and by the WHOOP web API client in web-api/. They hold no
 * URLs and no network code, so they stay in every build and the web-api
 * facade (and its stub) re-export them.
 */

/**
 * Session for WHOOP's web app API, cached in KV. Order on every use:
 *   1. a cached access token that is still good;
 *   2. the cached refresh token;
 *   3. a password login with WHOOP_WEB_EMAIL / WHOOP_WEB_PASSWORD — at most
 *      once per 6 hours, because repeated password logins can lock the account.
 * Tokens, the email and the password are never logged or returned.
 */
export type WhoopWebSession = {
  access_token: string;
  refresh_token: string | null;
  expires_at: string;
  user_id: string | null;
  obtained_via: "password" | "refresh" | "manual";
  updated_at: string;
};

export type WhoopWebLoginState = {
  last_attempt_at: string;
  last_ok: boolean;
  last_error: string | null;
};

export type WhoopWebDeps = {
  fetch?: typeof fetch;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  /**
   * False stops password logins (cached token and refresh still work).
   * The Worker passes false unless WHOOP_WEB_WORKER_LOGIN is on, because
   * WHOOP's bot wall answers the Worker's logins with a 403 HTML page.
   */
  passwordLogin?: boolean;
  /** Where auth events go when there is no D1 (the codebox job). Never given a secret. */
  onLog?: (row: { status: "ok" | "error"; errorText: string | null }) => void;
};

export type WhoopWebAuthCode =
  | "no_credentials"
  | "login_backoff"
  | "login_failed"
  | "login_disabled"
  | "blocked"
  | "no_user_id";

/**
 * Where the session and login backoff live: the Worker's KV namespace, or a
 * mode-600 JSON file on codebox2 (codebox/file-store.ts). KVNamespace fits.
 */
export type SessionStore = {
  get(key: string): Promise<string | null>;
  put(key: string, value: string): Promise<void>;
  delete(key: string): Promise<void>;
};

/** What the WHOOP web login and client need. DB is optional: without it, auth events go to deps.onLog. */
export type WhoopWebAuthEnv = {
  TOKENS: SessionStore;
  DB?: D1Database;
  WHOOP_WEB_EMAIL?: string;
  WHOOP_WEB_PASSWORD?: string;
};

export class WhoopWebAuthError extends Error {
  code: WhoopWebAuthCode;
  constructor(code: WhoopWebAuthCode, message: string) {
    super(message);
    this.name = "WhoopWebAuthError";
    this.code = code;
  }
}

export type WhoopWebResult<T> =
  | { ok: true; value: T }
  | { ok: false; status: number; reason: string };

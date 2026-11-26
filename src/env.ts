export interface Env {
  DB: D1Database;
  RAW: R2Bucket;
  TOKENS: KVNamespace;
  LIVE_HR?: DurableObjectNamespace;
  INGEST_Q: Queue;
  BACKFILL: Workflow;
  RECONCILE: Workflow;
  ASSETS: Fetcher;
  OURA_CLIENT_ID: string;
  OURA_CLIENT_SECRET: string;
  /** Optional. Defaults to <this Worker's address>/auth/oura/callback. */
  OURA_REDIRECT_URI?: string;
  OURA_SANDBOX?: string;
  /**
   * Preferred wearable for dashboard comparisons: "whoop" or "oura".
   * Unset keeps an Oura-only install on Oura; see src/lib/wearable.ts.
   */
  WEARABLE?: string;
  WHOOP_CLIENT_ID?: string;
  WHOOP_CLIENT_SECRET?: string;
  WHOOP_WEBHOOK_SECRET?: string;
  /** Optional. Defaults to <this Worker's address>/api/whoop/callback. */
  WHOOP_REDIRECT_URI?: string;
  /**
   * "enabled" turns on per-meeting heart rate and Stress Monitor from WHOOP's
   * web app API (src/sources/whoop-web). Anything else, or unset, is off.
   */
  WHOOP_WEB_HR?: string;
  /** Secrets for the WHOOP web login. Never logged, never returned. */
  WHOOP_WEB_EMAIL?: string;
  WHOOP_WEB_PASSWORD?: string;
  /**
   * "enabled" lets the Worker itself try a WHOOP web password login (cron,
   * page, backfill). Off by default: WHOOP's bot wall answers the Worker with
   * a 403 HTML page, so the codebox2 job logs in and posts heart rate to
   * POST /api/whoop-web/ingest. A cached token or refresh still works here.
   */
  WHOOP_WEB_WORKER_LOGIN?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  GOOGLE_REDIRECT_URI?: string;
  /** Optional personal title. Default UI brand is Meetspike. */
  DISPLAY_TITLE?: string;
  /** Shared secret for POST /api/plaud/ingest. Not a Plaud token. */
  INGEST_ADMIN_SECRET?: string;
  /**
   * Optional Cloudflare Access service token for the iPhone app. When both
   * are set, pairing by QR code hands them to the phone along with the
   * ingest secret; otherwise the phone asks for them in Settings.
   */
  PHONE_ACCESS_CLIENT_ID?: string;
  PHONE_ACCESS_CLIENT_SECRET?: string;
  /**
   * Cloudflare Access team domain, e.g. https://myteam.cloudflareaccess.com,
   * and the Access application's Application Audience (AUD) tag. Routes that
   * hand out secrets (POST /api/pair/start) verify the Access token against
   * these and refuse to run without them. Not secrets.
   */
  ACCESS_TEAM_DOMAIN?: string;
  ACCESS_AUD?: string;
  /** Optional Pushover app token and user key for "turn on HR Broadcast" reminders. */
  PUSHOVER_TOKEN?: string;
  PUSHOVER_USER?: string;
  /**
   * Optional Apple push (APNs) for "turn on HR Broadcast" reminders that only
   * come when no heart rate is arriving. A .p8 key (PKCS8 PEM; real newlines or
   * literal \n), its key id, and the Apple team id. APNS_TOPIC defaults to
   * com.hersheyg.meetspike.hr. Without the first three the phone keeps its
   * own local reminders.
   */
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
  /**
   * Optional. 32+ random characters used to encrypt the user's own Claude
   * API key at rest in KV. Without it, "Ask your data" stays off.
   */
  AI_KEY_SECRET?: string;
}

export function displayTitle(env: Env): string {
  const custom = env.DISPLAY_TITLE?.trim();
  return custom && custom.length ? custom : "Meetspike";
}

export function sandboxMode(env: Env): boolean {
  return (env.OURA_SANDBOX ?? "true").toLowerCase() !== "false";
}

/**
 * The address an OAuth provider sends the browser back to. An explicit
 * *_REDIRECT_URI wins; otherwise it is this Worker's own origin plus `path`,
 * so a fresh install has one less value to copy around.
 */
export function redirectUri(configured: string | undefined, requestUrl: string, path: string): string {
  const explicit = configured?.trim();
  if (explicit) return explicit;
  return new URL(path, requestUrl).toString();
}

/** WHOOP_WEB_HR flag: on only for "enabled" (also true/on/1), any case. */
export function whoopWebHrFlag(env: { WHOOP_WEB_HR?: string }): boolean {
  const v = env.WHOOP_WEB_HR?.trim().toLowerCase();
  return v === "enabled" || v === "true" || v === "on" || v === "1";
}

/** WHOOP_WEB_WORKER_LOGIN flag: same spellings as WHOOP_WEB_HR. Off when unset. */
export function whoopWebWorkerLoginFlag(env: { WHOOP_WEB_WORKER_LOGIN?: string }): boolean {
  const v = env.WHOOP_WEB_WORKER_LOGIN?.trim().toLowerCase();
  return v === "enabled" || v === "true" || v === "on" || v === "1";
}

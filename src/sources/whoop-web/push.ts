import type { Env } from "../../env.ts";
import { loadTimeZone } from "../../lib/db.ts";
import { applyOverrides, loadOverridesForIds, OverrideSet, type ResolvedOverride } from "../../lib/meeting-override.ts";
import { DEFAULT_TIME_ZONE } from "../../lib/time.ts";
import { whoopWebHrActive } from "../../lib/wearable.ts";
import { meetingLimitS } from "./meeting-hr.ts";
import { COVERED_MATCH_MS, phoneCheckIn, setPhoneOwner } from "./reminder.ts";

/**
 * "Turn on HR Broadcast" reminders as an Apple push (APNs), sent from the
 * every-minute cron only when no heart rate is coming in. The iPhone registers
 * its device token at check-in (POST /api/whoop-web/reminder/owner). Nothing
 * here ever logs or returns the key, the JWT or the device token, and no
 * meeting title or heart rate ever goes into a push or a log line.
 */

/** The every-minute cron string. Must match wrangler.jsonc, wrangler.jsonc.example and the deploy workflow. */
export const PUSH_CRON = "* * * * *";

const DEFAULT_TOPIC = "com.hersheyg.meetspike.hr";
const DEVICE_KEY = "push:device";
const JWT_KEY = "push:jwt";
const DONE_PREFIX = "push:done:";
const DONE_TTL_S = 86_400;
const JWT_REUSE_S = 40 * 60;
const DEVICE_RECHECK_MS = 24 * 3600_000;
/** A device Apple has only been unreachable for (not rejected) stays trusted this long after its last good check. */
const DEVICE_BLIP_MAX_MS = 72 * 3600_000;
/**
 * Registration may use two attempts (a fresh JWT retry) and the phone gives up
 * at 10 s, so each attempt gets 3 s: both finish well under 8 s.
 */
const REGISTER_ATTEMPT_MS = 3000;
const APNS_TIMEOUT_MS = 8000;
const MIN = 60_000;

type KvLike = Pick<KVNamespace, "get" | "put" | "delete">;
type PushEnv = Pick<Env, "APNS_KEY_P8" | "APNS_KEY_ID" | "APNS_TEAM_ID" | "APNS_TOPIC">;

export type PushEnvironment = "production" | "development";
export type PushRegistration = { token: string; environment: PushEnvironment };
export type PushDevice = PushRegistration & { verifiedAt: string };
export type PushKind = "on" | "followUp" | "off";
export type SendResult = "sent" | "gone" | "failed" | "not_configured";
export type ApnsMessage = {
  kind: string;
  pushType: "alert" | "background";
  payload: unknown;
  /** Unix seconds. */
  expiration: number;
  collapseId?: string;
};

const present = (v: unknown): v is string => typeof v === "string" && v.trim().length > 0;

export function pushConfigured(env: Partial<PushEnv>): boolean {
  return present(env.APNS_KEY_P8) && present(env.APNS_KEY_ID) && present(env.APNS_TEAM_ID);
}

/** undefined when absent, null when invalid, else the cleaned registration. */
export function parsePushRegistration(value: unknown): PushRegistration | undefined | null {
  if (value === undefined) return undefined;
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const v = value as { token?: unknown; environment?: unknown };
  if (typeof v.token !== "string" || !/^[0-9a-fA-F]{64,200}$/.test(v.token)) return null;
  if (v.environment !== "production" && v.environment !== "development") return null;
  return { token: v.token.toLowerCase(), environment: v.environment };
}

/**
 * Is the owner's heart rate coming in? A phone or Mac reading (source 'ble')
 * newer than the window, allowing a minute of clock skew. Throws when the
 * query fails: callers decide what that means.
 */
export async function heartRateLive(db: D1Database, now: number, windowMs = 60_000): Promise<boolean> {
  const row = await db
    .prepare(`SELECT 1 AS live FROM whoop_web_hr_raw WHERE user_id = 'owner' AND source = 'ble' AND time_ms > ? AND time_ms <= ? LIMIT 1`)
    .bind(now - windowMs, now + 60_000)
    .first<{ live: number }>();
  return row != null;
}

// ---------------------------------------------------------------------------------------------------------------
// JWT

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const b64urlText = (text: string): string => b64url(new TextEncoder().encode(text));

async function importKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/\\n/g, "\n").replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (ch) => ch.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** An ES256 provider token. Reused for 40 minutes through KV, since APNs rejects providers that mint tokens too often. */
export async function apnsJwt(env: PushEnv, kv: KvLike | undefined, nowMs: number): Promise<string> {
  const keyId = env.APNS_KEY_ID!.trim();
  const iat = Math.floor(nowMs / 1000);
  try {
    const cached = await kv?.get(JWT_KEY);
    if (cached) {
      const v = JSON.parse(cached) as { keyId?: unknown; jwt?: unknown; iat?: unknown };
      if (
        v.keyId === keyId && typeof v.jwt === "string" && v.jwt.split(".").length === 3 &&
        typeof v.iat === "number" && iat - v.iat >= 0 && iat - v.iat < JWT_REUSE_S
      ) return v.jwt;
    }
  } catch {
    // a KV failure or a bad record: sign a new one
  }
  const head = b64urlText(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64urlText(JSON.stringify({ iss: env.APNS_TEAM_ID!.trim(), iat }));
  const key = await importKey(env.APNS_KEY_P8!);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${claims}`)));
  const jwt = `${head}.${claims}.${b64url(sig)}`;
  try {
    await kv?.put(JWT_KEY, JSON.stringify({ keyId, jwt, iat }), { expirationTtl: JWT_REUSE_S });
  } catch {
    // not cached: the next send signs again
  }
  return jwt;
}

// ---------------------------------------------------------------------------------------------------------------
// Sending

async function readReason(res: Response): Promise<string | undefined> {
  try {
    const parsed = JSON.parse(await res.text()) as { reason?: unknown };
    return typeof parsed.reason === "string" && /^[A-Za-z]{1,64}$/.test(parsed.reason) ? parsed.reason : undefined;
  } catch {
    return undefined;
  }
}

/** Apple's final answer was a 4xx other than 429 (or a gone token): retrying the same token will not help. */
export function permanentRejection(sent: { result: SendResult; status: number }): boolean {
  return sent.result === "gone" || (sent.result === "failed" && sent.status >= 400 && sent.status < 500 && sent.status !== 429);
}

/** Send one push. Never throws. The device token, key and JWT never reach a log line. */
export async function sendApns(
  env: PushEnv & { TOKENS?: KvLike },
  device: PushRegistration,
  message: ApnsMessage,
  now: number,
  fetchImpl: typeof fetch = fetch,
  timeoutMs: number = APNS_TIMEOUT_MS,
): Promise<SendResult> {
  return (await sendApnsDetailed(env, device, message, now, fetchImpl, timeoutMs)).result;
}

/** Same as sendApns, with the HTTP status of Apple's last answer (0 when there was none). */
export async function sendApnsDetailed(
  env: PushEnv & { TOKENS?: KvLike },
  device: PushRegistration,
  message: ApnsMessage,
  now: number,
  fetchImpl: typeof fetch = fetch,
  timeoutMs: number = APNS_TIMEOUT_MS,
): Promise<{ result: SendResult; status: number }> {
  if (!pushConfigured(env)) return { result: "not_configured", status: 0 };
  const host = device.environment === "development" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const topic = present(env.APNS_TOPIC) ? env.APNS_TOPIC.trim() : DEFAULT_TOPIC;
  const body = JSON.stringify(message.payload);
  let status = 0;
  let reason: string | undefined;
  try {
    for (let attempt = 0; attempt < 2; attempt++) {
      const jwt = await apnsJwt(env, env.TOKENS, now);
      const headers: Record<string, string> = {
        authorization: `bearer ${jwt}`,
        "apns-topic": topic,
        "apns-push-type": message.pushType,
        "apns-priority": message.pushType === "alert" ? "10" : "5",
        "apns-expiration": String(message.expiration),
        "content-type": "application/json",
      };
      if (message.collapseId) headers["apns-collapse-id"] = message.collapseId;
      const res = await fetchImpl(`${host}/3/device/${device.token}`, {
        method: "POST", headers, body, signal: AbortSignal.timeout(timeoutMs),
      });
      status = res.status;
      reason = status === 200 ? undefined : await readReason(res);
      if (status === 200) return { result: "sent", status };
      if (attempt === 0 && status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) {
        try {
          await env.TOKENS?.delete(JWT_KEY);
        } catch {
          // the retry signs a fresh one only if the cache is gone; a failed delete just means one more failure
        }
        continue;
      }
      break;
    }
  } catch {
    // a network error, a timeout or a key that cannot sign: failed, with whatever status we had
  }
  console.error(JSON.stringify({ event: "push_failed", kind: message.kind, status, ...(reason ? { reason } : {}) }));
  const gone = status === 410 || (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"));
  return { result: gone ? "gone" : "failed", status };
}

// ---------------------------------------------------------------------------------------------------------------
// The device record

export async function readDevice(kv: KvLike): Promise<PushDevice | null> {
  try {
    const raw = await kv.get(DEVICE_KEY);
    if (!raw) return null;
    const v = JSON.parse(raw) as Partial<PushDevice>;
    const reg = parsePushRegistration({ token: v.token, environment: v.environment });
    if (!reg || typeof v.verifiedAt !== "string") return null;
    return { ...reg, verifiedAt: v.verifiedAt };
  } catch {
    return null;
  }
}

export async function clearDevice(kv: KvLike): Promise<void> {
  try {
    await kv.delete(DEVICE_KEY);
  } catch (error) {
    console.error(JSON.stringify({ event: "push_device_clear_failed", message: String((error as Error)?.message ?? error).slice(0, 200) }));
  }
}

/**
 * Check a device token with Apple (an invisible background push) and remember
 * it. True only when Apple accepted a message for this token. A blip keeps a
 * device we already have, so a hiccup never flips reminders back to local.
 */
export async function registerDevice(
  env: PushEnv & { TOKENS: KvLike; WHOOP_WEB_HR?: string },
  reg: PushRegistration,
  now: number,
  fetchImpl: typeof fetch = fetch,
): Promise<boolean> {
  if (!pushConfigured(env) || !whoopWebHrActive(env)) {
    await clearDevice(env.TOKENS);
    return false;
  }
  const stored = await readDevice(env.TOKENS);
  const same = stored != null && stored.token === reg.token && stored.environment === reg.environment;
  if (same) {
    const verified = Date.parse(stored.verifiedAt);
    if (Number.isFinite(verified) && now - verified >= 0 && now - verified < DEVICE_RECHECK_MS) return true;
  }
  const sent = await sendApnsDetailed(
    env, reg,
    { kind: "register", pushType: "background", payload: { aps: { "content-available": 1 } }, expiration: Math.floor(now / 1000) + 60 },
    now, fetchImpl, REGISTER_ATTEMPT_MS,
  );
  if (sent.result === "sent") {
    try {
      await env.TOKENS.put(DEVICE_KEY, JSON.stringify({ ...reg, verifiedAt: new Date(now).toISOString() }));
      return true;
    } catch (error) {
      console.error(JSON.stringify({ event: "push_device_store_failed", message: String((error as Error)?.message ?? error).slice(0, 200) }));
      return false;
    }
  }
  // A blip (429, 5xx, no answer) keeps a device we verified recently. A permanent rejection never does.
  if (sent.result === "failed" && same && !permanentRejection(sent)) {
    const verified = Date.parse(stored.verifiedAt);
    if (Number.isFinite(verified) && now - verified >= 0 && now - verified <= DEVICE_BLIP_MAX_MS) return true;
  }
  await clearDevice(env.TOKENS);
  return false;
}

// ---------------------------------------------------------------------------------------------------------------
// Timing

/** A calendar row as the push tick reads it: times already effective, overrides resolved, left-out rows kept. */
export type CoveredRow = {
  id: string;
  start_utc: string;
  end_utc: string;
  duration_s: number;
  deleted_at?: string | null;
  override?: ResolvedOverride;
};

export type DuePush = { kind: PushKind; anchorMs: number; startMs: number; endMs?: number };

const ON_LEAD_MS = 120_000;
const FOLLOW_UP_FROM_MS = 60_000;
const FOLLOW_UP_UNTIL_MS = 180_000;
const OFF_FROM_MS = 540_000;
const OFF_UNTIL_MS = 600_000;
const OFF_CLEAR_AHEAD_MS = 15 * MIN;
/** A candidate the phone has no end for is assumed to run this long when checking for overlap. */
const UNKNOWN_END_MS = 60 * MIN;

type Candidate = { startMs: number; endMs?: number };

/** The meetings the phone covers, on their effective times. Pure. */
function candidates(covered: number[], rows: CoveredRow[]): Candidate[] {
  const byStart = new Map<number, Candidate>();
  const add = (startMs: number, endMs: number | undefined) => {
    const have = byStart.get(startMs);
    if (!have) byStart.set(startMs, { startMs, ...(endMs === undefined ? {} : { endMs }) });
    else if (endMs !== undefined && (have.endMs === undefined || endMs > have.endMs)) have.endMs = endMs;
  };
  for (const c of covered) {
    const matched = rows.filter((row) => Math.abs(Date.parse(row.override?.calendarStartUtc ?? row.start_utc) - c) <= COVERED_MATCH_MS);
    if (!matched.length) {
      add(c, undefined);
      continue;
    }
    for (const row of matched) {
      if (row.deleted_at || row.override?.excluded) continue;
      const startMs = Date.parse(row.start_utc);
      const endMs = Date.parse(row.end_utc);
      if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) continue;
      if (!(row.duration_s > 0 && row.duration_s <= meetingLimitS(row.override?.timesChanged))) continue;
      add(startMs, endMs);
    }
  }
  return [...byStart.values()].sort((a, b) => a.startMs - b.startMs);
}

/** Which pushes are due at `now`. Pure. See the build 11 spec for the rules. */
export function duePushes(input: { covered: number[]; rows: CoveredRow[]; now: number }): DuePush[] {
  const { now } = input;
  const all = candidates(input.covered, input.rows);
  const out: DuePush[] = [];
  const minutes = { on: new Set<number>(), followUp: new Set<number>() };
  const offAnchors = new Set<number>();
  for (const c of all) {
    const ahead = c.startMs - now;
    const minute = Math.floor(c.startMs / MIN);
    if (ahead > 0 && ahead <= ON_LEAD_MS && !minutes.on.has(minute)) {
      minutes.on.add(minute);
      out.push({ kind: "on", anchorMs: c.startMs, startMs: c.startMs, endMs: c.endMs });
    }
    const since = now - c.startMs;
    if (since >= FOLLOW_UP_FROM_MS && since < FOLLOW_UP_UNTIL_MS && !minutes.followUp.has(minute)) {
      minutes.followUp.add(minute);
      out.push({ kind: "followUp", anchorMs: c.startMs, startMs: c.startMs, endMs: c.endMs });
    }
    if (c.endMs !== undefined) {
      const over = now - c.endMs;
      if (over >= OFF_FROM_MS && over < OFF_UNTIL_MS && !offAnchors.has(c.endMs)) {
        const blocked = all.some((o) => o !== c && o.startMs <= now + OFF_CLEAR_AHEAD_MS && (o.endMs ?? o.startMs + UNKNOWN_END_MS) > now);
        if (!blocked) offAnchors.add(c.endMs);
        if (!blocked) out.push({ kind: "off", anchorMs: c.endMs, startMs: c.startMs, endMs: c.endMs });
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// The tick

function clock(ms: number, timeZone: string): string {
  const format = (tz: string) => {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit", hour12: true }).formatToParts(new Date(ms));
    const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
    return `${get("hour")}:${get("minute")} ${get("dayPeriod")}`;
  };
  try {
    return format(timeZone);
  } catch {
    return format(DEFAULT_TIME_ZONE);
  }
}

function messageFor(due: DuePush, now: number, timeZone: string): ApnsMessage {
  const at = clock(due.startMs, timeZone);
  const base = { sound: "default", "thread-id": "meetspike.broadcast" };
  const collapseId = `meetspike.broadcast.${due.kind}.${due.anchorMs}`;
  if (due.kind === "on") {
    const minutes = Math.max(1, Math.ceil((due.startMs - now) / MIN));
    return {
      kind: due.kind, pushType: "alert", collapseId, expiration: Math.floor((due.startMs + 5 * MIN) / 1000),
      payload: {
        aps: {
          alert: {
            title: "Turn on HR Broadcast in the WHOOP app",
            body: `Your ${at} meeting starts in ${minutes} ${minutes === 1 ? "minute" : "minutes"} and no heart rate is coming in. In WHOOP, open Device Settings and turn on HR Broadcast.`,
          },
          ...base, "interruption-level": "time-sensitive",
        },
      },
    };
  }
  if (due.kind === "followUp") {
    return {
      kind: due.kind, pushType: "alert", collapseId, expiration: Math.floor((due.startMs + 10 * MIN) / 1000),
      payload: {
        aps: {
          alert: { title: "Still no heart rate", body: `Your ${at} meeting has started and no heart rate is coming in. Turn on HR Broadcast in the WHOOP app.` },
          ...base, "interruption-level": "time-sensitive",
        },
      },
    };
  }
  return {
    kind: due.kind, pushType: "alert", collapseId, expiration: Math.floor((now + 30 * MIN) / 1000),
    payload: {
      aps: {
        alert: { title: "You can turn off HR Broadcast", body: `Your ${at} meeting is over and heart rate is still coming in.` },
        ...base,
      },
    },
  };
}

/** Only the covered starts that could matter now are read from the calendar. */
const RANGE_BEHIND_MS = 16 * 3600_000;
const RANGE_AHEAD_MS = 3 * 3600_000;

const errorText = (error: unknown): string => {
  try {
    return String((error as Error)?.message ?? error).slice(0, 200);
  } catch {
    return "unprintable";
  }
};

async function loadRows(db: D1Database, starts: number[]): Promise<CoveredRow[]> {
  const from = new Date(Math.min(...starts) - COVERED_MATCH_MS).toISOString();
  const to = new Date(Math.max(...starts) + COVERED_MATCH_MS).toISOString();
  const { results } = await db
    .prepare(
      `SELECT id, start_utc, end_utc, duration_s, deleted_at FROM calendar_event
       WHERE start_utc >= ? AND start_utc <= ? AND source_type = 'calendar'`,
    )
    .bind(from, to)
    .all<CoveredRow>();
  const found = results ?? [];
  const set = found.length ? await loadOverridesForIds(db, found.map((row) => row.id)) : OverrideSet.none;
  return applyOverrides(found, set, { includeExcluded: true });
}

/**
 * Apple permanently rejected this token. If it is still the stored one, forget
 * it and drop the phone's check-in too, so the Mac reminds again (GET reminder
 * answers owner "mac"). Never throws.
 */
async function dropRejectedDevice(kv: KvLike, rejected: PushRegistration, now: number): Promise<void> {
  try {
    const current = await readDevice(kv);
    if (current && (current.token !== rejected.token || current.environment !== rejected.environment)) return;
    await clearDevice(kv);
    await setPhoneOwner(kv, false, now);
  } catch (error) {
    console.error(JSON.stringify({ event: "push_tick_error", stage: "drop_device", message: errorText(error) }));
  }
}

/**
 * The every-minute job. `now` is the cron's scheduled time. Sends the reminder
 * pushes that are due and not decided yet. Never throws: a failure is logged
 * and the next minute tries again.
 */
export async function runPushTick(
  env: Env,
  now: number,
  fetchImpl: typeof fetch = fetch,
): Promise<{ sent: string[]; skipped?: string }> {
  const sent: string[] = [];
  try {
    if (!pushConfigured(env)) return { sent, skipped: "not_configured" };
    if (!whoopWebHrActive(env)) return { sent, skipped: "whoop_web_off" };
    const device = await readDevice(env.TOKENS);
    if (!device) return { sent, skipped: "no_device" };
    const checkIn = await phoneCheckIn(env.TOKENS, now);
    const covered = (checkIn?.covered ?? []).filter((c) => c >= now - RANGE_BEHIND_MS && c <= now + RANGE_AHEAD_MS);
    if (!covered.length) return { sent, skipped: "nothing_in_range" };

    const due = duePushes({ covered, rows: await loadRows(env.DB, covered), now });
    if (!due.length) return { sent, skipped: "nothing_due" };

    const liveByWindow = new Map<number, boolean | null>();
    const live = async (windowMs: number): Promise<boolean | null> => {
      if (!liveByWindow.has(windowMs)) {
        try {
          liveByWindow.set(windowMs, await heartRateLive(env.DB, now, windowMs));
        } catch (error) {
          console.error(JSON.stringify({ event: "push_tick_error", stage: "heart_rate", message: errorText(error) }));
          liveByWindow.set(windowMs, null);
        }
      }
      return liveByWindow.get(windowMs) ?? null;
    };
    const decide = async (key: string, kind: PushKind, result: string) => {
      console.log(JSON.stringify({ event: "push_reminder", kind, result }));
      try {
        await env.TOKENS.put(key, result, { expirationTtl: DONE_TTL_S });
      } catch (error) {
        console.error(JSON.stringify({ event: "push_tick_error", stage: "record", message: errorText(error) }));
      }
    };

    let timeZone: string | null = null;
    // One kind and anchor goes out at most once in a tick, even if the done record cannot be written.
    const handled = new Set<string>();
    for (const item of due) {
      const key = `${DONE_PREFIX}${item.kind}:${item.anchorMs}`;
      if (handled.has(key)) continue;
      handled.add(key);
      try {
        if (await env.TOKENS.get(key)) continue;
      } catch (error) {
        console.error(JSON.stringify({ event: "push_tick_error", stage: "done_read", message: errorText(error) }));
        continue; // never push without knowing whether this one already went out
      }
      const isLive = await live(item.kind === "off" ? 90_000 : 60_000);
      if (isLive === null) continue;
      if (item.kind === "off") {
        if (!isLive) {
          await decide(key, item.kind, "quiet");
          continue;
        }
      } else if (isLive) {
        await decide(key, item.kind, "live");
        continue;
      }
      timeZone ??= await loadTimeZone(env.DB).catch(() => DEFAULT_TIME_ZONE);
      const result = await sendApnsDetailed(env, device, messageFor(item, now, timeZone), now, fetchImpl);
      if (result.result === "sent") {
        sent.push(`${item.kind}:${item.anchorMs}`);
        await decide(key, item.kind, "sent");
      } else if (permanentRejection(result)) {
        await dropRejectedDevice(env.TOKENS, device, now);
        break;
      }
      // failed: not recorded, the next tick inside the window tries again
    }
    return { sent };
  } catch (error) {
    console.error(JSON.stringify({ event: "push_tick_error", stage: "tick", message: errorText(error) }));
    return { sent, skipped: "error" };
  }
}

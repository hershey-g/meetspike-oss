import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { Env } from "../env.ts";
import { loadTimeZone } from "../lib/db.ts";
import { readAdminSecret, timingSafeEqual } from "../lib/secret.ts";
import { DEFAULT_TIME_ZONE } from "../lib/time.ts";
import { whoopWebHrActive } from "../lib/wearable.ts";
import { isSourceDisplayed } from "../lib/source-display.ts";
import { diagnostics } from "./diagnostics.ts";
import {
  readLoginState,
  readWhoopWebSession,
  resetLoginBackoff,
  storeManualToken,
  webApiIncluded,
  WEB_API_NOT_INCLUDED,
} from "../sources/whoop-web/web-api/index.ts";
import { BACKFILL_MAX_DAYS } from "../sources/whoop-web/constants.ts";
import { readBackfill, runWhoopWebFill, startBackfill } from "../sources/whoop-web/fill.ts";
import { applyWhoopWebIngest, parseIngestPayload } from "../sources/whoop-web/ingest.ts";
import { currentLiveMeeting, liveMeetingWindow, parseLiveBatch, type LiveRead } from "../sources/whoop-web/live.ts";
import { rebuildRawHrDay, storeRawHr } from "../sources/whoop-web/raw.ts";
import { parseIsoInstant, reprojectIfMoved } from "./override.ts";
import { eventKey, loadOverridesForIds, saveSighting } from "../lib/meeting-override.ts";
import { clearDevice, heartRateLive, parsePushRegistration, registerDevice } from "../sources/whoop-web/push.ts";
import { ownerFor, parseCovered, phoneCheckIn, pushoverConfigured, reminderMessage, sendPushover, setPhoneOwner, startingMeeting } from "../sources/whoop-web/reminder.ts";

/**
 * Admin routes for WHOOP web heart rate, mounted at /api/whoop-web.
 * POSTs need INGEST_ADMIN_SECRET (x-admin-secret or Authorization: Bearer),
 * the same guard as /api/plaud/ingest. Nothing here returns a token.
 * POST /ingest accepts heart rate from the Codebox job and BLE clients.
 */
export const whoopWeb = new Hono<{ Bindings: Env }>();

function adminDenied(c: Context<{ Bindings: Env }>): Response | null {
  const expected = c.env.INGEST_ADMIN_SECRET?.trim() ?? "";
  if (!expected) return c.json({ error: "INGEST_ADMIN_SECRET is not set" }, 503);
  const got = readAdminSecret(c.req.header("x-admin-secret"), c.req.header("authorization"));
  if (!got || !timingSafeEqual(got, expected)) return c.json({ error: "unauthorized" }, 401);
  return null;
}

function waitUntil(c: Context<{ Bindings: Env }>, p: Promise<unknown>): boolean {
  try {
    c.executionCtx.waitUntil(p.catch(() => {}));
    return true;
  } catch {
    return false;
  }
}

/** Connection state, without secrets. */
whoopWeb.get("/status", async (c) => {
  const [session, login, backfill] = await Promise.all([
    readWhoopWebSession(c.env),
    readLoginState(c.env),
    readBackfill(c.env),
  ]);
  return c.json({
    ok: true,
    enabled: whoopWebHrActive(c.env),
    credentialsSet: Boolean(c.env.WHOOP_WEB_EMAIL?.trim() && c.env.WHOOP_WEB_PASSWORD),
    session: session
      ? {
          obtainedVia: session.obtained_via,
          expiresAt: session.expires_at,
          hasRefresh: Boolean(session.refresh_token),
          hasUserId: Boolean(session.user_id),
          updatedAt: session.updated_at,
        }
      : null,
    lastLogin: login ? { at: login.last_attempt_at, ok: login.last_ok, error: login.last_error } : null,
    backfill,
    // Only a build without the web API says so; the full build's answer is unchanged.
    ...(webApiIncluded ? {} : { webApi: { included: false, message: WEB_API_NOT_INCLUDED } }),
  });
});

/**
 * Paste a bearer token by hand (when password login is locked out or not
 * wanted). Body: { accessToken, refreshToken?, userId?, expiresInS? }.
 */
whoopWeb.post("/token", async (c) => {
  const denied = adminDenied(c);
  if (denied) return denied;
  if (!webApiIncluded) return c.json({ error: WEB_API_NOT_INCLUDED }, 409);
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
  if (!body) return c.json({ error: "JSON body required" }, 400);
  const res = await storeManualToken(c.env, {
    accessToken: body.accessToken ?? body.access_token,
    refreshToken: body.refreshToken ?? body.refresh_token,
    userId: body.userId ?? body.user_id,
    expiresInS: body.expiresInS ?? body.expires_in,
  });
  if (!res.ok) return c.json({ error: res.error }, 400);
  return c.json(res);
});

/**
 * Clear the 6-hour password-login backoff (KV whoop-web:login) so the next
 * fill may try a password login right away, e.g. after a fixed deploy.
 * It does not log in by itself.
 */
whoopWeb.post("/login-reset", async (c) => {
  const denied = adminDenied(c);
  if (denied) return denied;
  if (!webApiIncluded) return c.json({ error: WEB_API_NOT_INCLUDED }, 409);
  const cleared = await resetLoginBackoff(c.env);
  return c.json({ ok: true, cleared });
});

/**
 * One-time backfill of the last `days` (default and max 30) of meetings.
 * Runs one paced batch now and leaves a marker so the 15-minute cron keeps
 * going, about 20 WHOOP requests a run, until everything is filled.
 */
whoopWeb.post("/backfill", async (c) => {
  const denied = adminDenied(c);
  if (denied) return denied;
  if (!webApiIncluded) return c.json({ error: WEB_API_NOT_INCLUDED }, 409);
  if (!whoopWebHrActive(c.env)) return c.json({ error: "WHOOP_WEB_HR is not enabled" }, 409);
  const body = (await c.req.json().catch(() => ({}))) as { days?: unknown };
  const days = typeof body.days === "number" && body.days > 0 ? body.days : BACKFILL_MAX_DAYS;
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const marker = await startBackfill(c.env, days, Date.now(), tz);
  const started = waitUntil(c, runWhoopWebFill(c.env, { trigger: "backfill" }));
  return c.json({ ok: true, fromDay: marker.fromDay, firstBatch: started ? "started" : "next_cron" }, 202);
});

/** Largest ingest body we read (a 30-day backfill of minute heart rate is about 2 MB). */
const INGEST_MAX_BYTES = 8 * 1024 * 1024;

/**
 * See src/sources/whoop-web/ingest.ts for the body. Stores raw heart rate,
 * projects meeting rows, and stores Stress Monitor days.
 */
whoopWeb.post("/ingest", async (c) => {
  const denied = adminDenied(c);
  if (denied) return denied;
  if (!whoopWebHrActive(c.env)) return c.json({ error: "WHOOP_WEB_HR is not enabled" }, 409);
  const len = Number(c.req.header("content-length") ?? "0");
  if (Number.isFinite(len) && len > INGEST_MAX_BYTES) return c.json({ error: "body too large" }, 413);
  const body = (await c.req.json().catch(() => null)) as unknown;
  const now = Date.now();
  const parsed = parseIngestPayload(body, now);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  return c.json(await applyWhoopWebIngest(c.env, parsed, now));
});

/** Rebuild raw heart rate for meetings starting on a local calendar day. */
whoopWeb.post("/rebuild", async (c, next) => {
  c.header("Cache-Control", "private, no-store");
  const denied = adminDenied(c);
  if (denied) return denied;
  await next();
}, bodyLimit({ maxSize: 2048, onError: (c) => c.json({ error: "body too large" }, 413) }), async (c) => {
  if (!whoopWebHrActive(c.env)) return c.json({ error: "WHOOP web heart rate is off" }, 409);
  const body = (await c.req.json().catch(() => null)) as { day?: unknown } | null;
  const day = body?.day;
  if (typeof day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(day)) {
    return c.json({ error: "day must be a calendar date in YYYY-MM-DD format" }, 400);
  }
  const date = new Date(day);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== day) {
    return c.json({ error: "day must be a calendar date in YYYY-MM-DD format" }, 400);
  }
  const timeZone = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const meetings = await rebuildRawHrDay(c.env.DB, day, timeZone, Date.now());
  return c.json({ ok: true, day, timeZone, meetings });
});

/**
 * GET: the calendar meeting starting within two minutes (or in progress), so
 * the Mac app can remind before it, whether Pushover is configured, and who
 * reminds about that meeting: "phone" only when the phone scheduled a reminder
 * for it, otherwise "mac". ownerUntil is the phone's check-in expiry. live is
 * true when the owner's heart rate arrived in the last minute (null when that
 * check failed), so the Mac stays quiet while the phone streams. Admin
 * secret like the other Mac routes. A calendar failure reads as no meeting.
 */
whoopWeb.get("/reminder", async (c) => {
  c.header("Cache-Control", "private, no-store");
  const denied = adminDenied(c);
  if (denied) return denied;
  const now = Date.now();
  const [meeting, checkIn, live] = await Promise.all([
    startingMeeting(c.env.DB, now).catch(() => null),
    phoneCheckIn(c.env.TOKENS, now),
    heartRateLive(c.env.DB, now).catch(() => null),
  ]);
  const owner = ownerFor(checkIn, meeting?.calendarStartUtc ?? meeting?.startUtc);
  return c.json({ ok: true, meeting, pushover: pushoverConfigured(c.env), owner: owner.owner, ownerUntil: owner.until, live });
});

/**
 * POST { active: boolean, covered?: string[], push?: { token, environment } }:
 * the iPhone app checks in while it is signed in and allowed to notify, with
 * the ISO UTC starts of the meetings it covers (at most 60), and steps down
 * otherwise. With push, the Worker checks the device token with Apple and
 * replies push: true only when Apple accepted it; then reminders come as a
 * push from the server, and only when no heart rate is arriving. Without push
 * (older builds), or when stepping down, the stored device is cleared.
 * Logs the owner state, covered count and the push boolean only.
 */
whoopWeb.post("/reminder/owner", async (c, next) => {
  c.header("Cache-Control", "private, no-store");
  const denied = adminDenied(c);
  if (denied) return denied;
  await next();
}, bodyLimit({ maxSize: 4096, onError: (c) => c.json({ error: "body too large" }, 413) }), async (c) => {
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
  if (typeof body?.active !== "boolean") return c.json({ error: "Send active as true or false." }, 400);
  const covered = parseCovered(body.covered);
  if (!covered) return c.json({ error: "Send covered as at most 60 ISO UTC times." }, 400);
  const registration = parsePushRegistration(body.push);
  if (registration === null) return c.json({ error: "Send push as a device token and environment." }, 400);
  const now = Date.now();
  const state = await setPhoneOwner(c.env.TOKENS, body.active, now, covered);
  let push = false;
  if (body.active && registration) {
    push = await registerDevice(c.env, registration, now).catch((error) => {
      console.error(JSON.stringify({ event: "push_register_error", message: String((error as Error)?.message ?? error).slice(0, 200) }));
      return false;
    });
  } else {
    await clearDevice(c.env.TOKENS);
  }
  console.log(JSON.stringify({ event: "reminder_owner", owner: state.owner, covered: state.covered, push }));
  return c.json({ ok: true, owner: state.owner, ownerUntil: state.until, covered: state.covered, push });
});

/**
 * POST { title?: string, repeat?: boolean }: forward "turn on WHOOP Heart Rate
 * Broadcast" to Pushover when PUSHOVER_TOKEN / PUSHOVER_USER are set. The Mac
 * app rate-limits (once per meeting plus one repeat after 5 minutes). Answers
 * pushover "live" and sends nothing while heart rate is coming in.
 */
whoopWeb.post("/reminder", async (c, next) => {
  const denied = adminDenied(c);
  if (denied) return denied;
  await next();
}, bodyLimit({ maxSize: 2048, onError: (c) => c.json({ error: "body too large" }, 413) }), async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown> | null;
  // Heart rate is already coming in (phone or Mac): nothing to remind about. A failed check sends as before.
  if (await heartRateLive(c.env.DB, Date.now()).catch(() => false)) return c.json({ ok: true, pushover: "live" });
  const pushover = await sendPushover(c.env, reminderMessage(body?.title, body?.repeat === true));
  return c.json({ ok: true, pushover }, pushover === "failed" ? 502 : 200);
});

/** KV key for the newest iPhone TestFlight build number. */
export const IOS_BUILD_KEY = "app:ios-latest-build";

/**
 * GET: the newest iPhone TestFlight build, so the app can show "Update
 * available". POST { build: positive integer, force?: true }: set by the
 * release script once App Store Connect has processed the build. Only a
 * higher build is stored unless force is true; the reply is the stored build.
 * Admin secret on both.
 */
whoopWeb.get("/app/ios", async (c) => {
  c.header("Cache-Control", "private, no-store");
  const denied = adminDenied(c);
  if (denied) return denied;
  const stored = Number(await c.env.TOKENS.get(IOS_BUILD_KEY));
  return c.json({ ok: true, build: Number.isSafeInteger(stored) && stored > 0 ? stored : null });
});

whoopWeb.post("/app/ios", async (c, next) => {
  c.header("Cache-Control", "private, no-store");
  const denied = adminDenied(c);
  if (denied) return denied;
  await next();
}, bodyLimit({ maxSize: 256, onError: (c) => c.json({ error: "body too large" }, 413) }), async (c) => {
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
  const build = body?.build;
  if (typeof build !== "number" || !Number.isSafeInteger(build) || build < 1) {
    return c.json({ error: "Send build as a positive integer." }, 400);
  }
  // Monotonic: a late release run must not lower the build. force: true rolls back on purpose.
  const stored = Number(await c.env.TOKENS.get(IOS_BUILD_KEY));
  const current = Number.isSafeInteger(stored) && stored > 0 ? stored : 0;
  if (build > current || body?.force === true) {
    await c.env.TOKENS.put(IOS_BUILD_KEY, String(build));
    console.log(JSON.stringify({ event: "ios_build", build, previous: current || null }));
    return c.json({ ok: true, build });
  }
  return c.json({ ok: true, build: current });
});

/** Matches a report to a meeting this close to its calendar start. */
const ATTENDANCE_MATCH_MS = 90_000;

/**
 * POST { meetingStartUtc, title?, seenStartUtc, seenEndUtc, seenNone }: what
 * the Mac saw of a Zoom meeting. Matches exactly one calendar meeting by its
 * original start (90 s either way); the title only breaks a tie. No match, or
 * more than one, answers 202 { matched: false } and stores nothing. A report
 * only widens the seen times, never touches the owner's state or times, and
 * any sighting clears seenNone for good. Admin secret, like the other Mac routes.
 */
whoopWeb.post("/app/attendance", async (c, next) => {
  c.header("Cache-Control", "private, no-store");
  const denied = adminDenied(c);
  if (denied) return denied;
  await next();
}, bodyLimit({ maxSize: 4096, onError: (c) => c.json({ error: "body too large" }, 413) }), async (c) => {
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
  if (!body || typeof body !== "object" || Array.isArray(body)) return c.json({ error: "Send a JSON object." }, 400);
  const start = parseIsoInstant(body.meetingStartUtc);
  if (!start) return c.json({ error: "meetingStartUtc is a date and time like 2026-11-10T12:00:00Z." }, 400);
  if (typeof body.seenNone !== "boolean") return c.json({ error: "Send seenNone as true or false." }, 400);
  if (body.title != null && typeof body.title !== "string") return c.json({ error: "title is text." }, 400);
  let sighting: Parameters<typeof saveSighting>[2];
  if (body.seenNone) {
    if (body.seenStartUtc != null || body.seenEndUtc != null) return c.json({ error: "A meeting the Mac did not see has no seen times." }, 400);
    sighting = { seenNone: true };
  } else {
    const seenStartUtc = parseIsoInstant(body.seenStartUtc);
    const seenEndUtc = parseIsoInstant(body.seenEndUtc);
    if (!seenStartUtc || !seenEndUtc) return c.json({ error: "seenStartUtc and seenEndUtc are dates and times." }, 400);
    if (Date.parse(seenEndUtc) < Date.parse(seenStartUtc)) return c.json({ error: "The seen end is before the seen start." }, 400);
    sighting = { seenStartUtc, seenEndUtc };
  }

  const at = Date.parse(start);
  const { results } = await c.env.DB.prepare(
    `SELECT id, title, start_utc, end_utc FROM calendar_event
     WHERE deleted_at IS NULL AND source_type = 'calendar' AND start_utc >= ? AND start_utc <= ?
     ORDER BY start_utc, id`,
  ).bind(new Date(at - ATTENDANCE_MATCH_MS).toISOString(), new Date(at + ATTENDANCE_MATCH_MS).toISOString())
    .all<{ id: string; title: string | null; start_utc: string; end_utc: string }>();
  let found = results ?? [];
  if (found.length > 1 && typeof body.title === "string") {
    const wanted = body.title.trim().toLowerCase();
    found = found.filter((row) => (row.title ?? "").trim().toLowerCase() === wanted);
  }
  if (found.length !== 1) return c.json({ matched: false }, 202);
  const meeting = found[0];

  const before = await loadOverridesForIds(c.env.DB, [meeting.id]);
  if (!before.available || !(await saveSighting(c.env.DB, meeting.id, sighting))) {
    return c.json({ error: "Meeting choices need the database update first." }, 503);
  }
  const after = await loadOverridesForIds(c.env.DB, [meeting.id]);
  const pending = reprojectIfMoved(c, meeting.id, meeting, before, after);
  if (pending) await pending;
  console.log(JSON.stringify({ event: "meeting_attendance", meetingId: meeting.id, key: eventKey(meeting.id), seenNone: "seenNone" in sighting }));
  return c.json({ ok: true, matched: true, id: meeting.id });
});

// iPhone crash and diagnostic reports, stored in R2.
whoopWeb.route("/app/diagnostics", diagnostics);

const LIVE_ORIGIN = "https://live-hr.internal";
function liveBuffer(namespace: DurableObjectNamespace) {
  return namespace.get(namespace.idFromName("hg-biometrics-live-hr"));
}

whoopWeb.post("/live", async (c, next) => {
  c.header("Cache-Control", "private, no-store");
  const denied = adminDenied(c);
  if (denied) return denied;
  await next();
}, bodyLimit({ maxSize: 4096, onError: (c) => c.json({ error: "body too large" }, 413) }), async (c) => {
  if (!whoopWebHrActive(c.env)) return c.json({ error: "WHOOP live heart rate is off" }, 409);
  const batch = parseLiveBatch(await c.req.json().catch(() => null));
  if (!batch) return c.json({ error: "invalid live heart-rate batch" }, 400);
  await storeRawHr(c.env.DB, "ble", batch.points, Date.now());
  if (!c.env.LIVE_HR) return c.json({ error: "live heart rate is unavailable" }, 503);
  const stored = await liveBuffer(c.env.LIVE_HR).fetch(LIVE_ORIGIN, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(batch.points),
  });
  if (!stored.ok) return c.json({ error: "could not store live heart rate" }, 503);
  // A calendar lookup failure should not cause a successfully stored batch to be replayed.
  const metadata = batch.includeMeeting
    ? await currentLiveMeeting(c.env.DB, Date.now()).then((meeting) => ({ meeting })).catch(() => ({}))
    : {};
  return c.json({ ok: true, ...metadata });
});

// Uses the same Cloudflare Access browser policy as the other meeting views.
export const meetingLive = new Hono<{ Bindings: Env }>();
meetingLive.get("/:id/live-hr", async (c) => {
  c.header("Cache-Control", "private, no-store");
  if (!whoopWebHrActive(c.env) || !c.env.LIVE_HR || !await isSourceDisplayed(c.env, "whoop")) {
    return c.json({ error: "live heart rate is unavailable" }, 404);
  }
  const since = Number(c.req.query("since") ?? 0);
  if (!Number.isSafeInteger(since) || since < 0) return c.json({ error: "invalid live cursor" }, 400);
  const window = await liveMeetingWindow(c.env.DB, c.req.param("id"));
  if (!window) return c.json({ error: "meeting not found" }, 404);
  const now = Date.now();
  const active = now >= window.fromMs && now < window.toMs;
  if (!active) return c.json({ window, active, points: [], cursor: since });
  const url = new URL(LIVE_ORIGIN);
  url.search = new URLSearchParams({ from: String(window.fromMs), to: String(window.toMs), since: String(since) }).toString();
  const buffered = await liveBuffer(c.env.LIVE_HR).fetch(url.toString());
  if (!buffered.ok) return c.json({ error: "live heart rate is unavailable" }, 503);
  const { points, cursor } = await buffered.json<LiveRead>();
  return c.json({ window, active, points, cursor });
});

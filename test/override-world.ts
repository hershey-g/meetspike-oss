import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { api } from "../src/routes/api.ts";
import { putCachedHr, resetScoringHrCache } from "../src/sources/whoop-web/store.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

/**
 * Shared world for the build 9 meeting override tests. Real SQLite with every
 * migration applied, the real api router, no network.
 *
 * Most tests use one trick: "excluded is the same as absent". They build the
 * same world twice, once with the meeting present and excluded through the
 * PUT route, once with the meeting (and its heart rate) never stored, and
 * require the same answer from every route that should not show it.
 */

export const ADMIN = "admin-secret-xyz";
export const MIN = 60_000;
export const RANGE = "start=2026-11-01&end=2026-11-20";

export type Ev = {
  id: string;
  start: string;
  end: string;
  title: string;
  /** Attendee emails besides the owner. */
  people: string[];
  /** Constant bpm for the stored WHOOP heart rate around the meeting, or null for none. */
  hr: number | null;
  sourceType?: string;
  source?: string;
};

/** Mon 9 Nov to Thu 12 Nov 2026. New York is on EST (UTC-5) all week. */
export const EVENTS: Ev[] = [
  { id: "a1", start: "2026-11-09T14:00:00.000Z", end: "2026-11-09T15:00:00.000Z", title: "Acme sync", people: ["pat@acme.com"], hr: 70 },
  { id: "ser1_20261109T160000Z", start: "2026-11-09T16:00:00.000Z", end: "2026-11-09T16:30:00.000Z", title: "Weekly sync", people: ["sam@weekly.io"], hr: 72 },
  { id: "ser1_20261110T160000Z", start: "2026-11-10T16:00:00.000Z", end: "2026-11-10T16:30:00.000Z", title: "Weekly sync", people: ["sam@weekly.io"], hr: 74 },
  { id: "ser1_20261111T160000Z", start: "2026-11-11T16:00:00.000Z", end: "2026-11-11T16:30:00.000Z", title: "Weekly sync", people: ["sam@weekly.io"], hr: 76 },
  { id: "evt-board", start: "2026-11-11T15:00:00.000Z", end: "2026-11-11T16:00:00.000Z", title: "Board prep", people: ["dana@exco.io"], hr: 150 },
  { id: "b1", start: "2026-11-11T18:30:00.000Z", end: "2026-11-11T19:30:00.000Z", title: "Globex call", people: ["gee@globex.io"], hr: 72 },
  { id: "f1", start: "2026-11-12T20:00:00.000Z", end: "2026-11-12T21:00:00.000Z", title: "Planning", people: ["lee@initech.com"], hr: 85 },
];

export const TWIN: Ev = {
  id: "plaud-board", start: "2026-11-11T15:00:00.000Z", end: "2026-11-11T16:00:00.000Z", title: "Board prep",
  people: ["dana@exco.io"], hr: null, sourceType: "plaud_phone", source: "plaud",
};

const SELF = "me@example.com";

type Raw = ReturnType<typeof sqliteD1>["raw"];

export function insertEvent(raw: Raw, e: Ev & { tzOffsetMin?: number }) {
  const startMs = Date.parse(e.start);
  const endMs = Date.parse(e.end);
  const off = e.tzOffsetMin ?? -300;
  const localHour = new Date(startMs + off * MIN).getUTCHours();
  const attendees = [{ email: SELF, self: true }, ...e.people.map((email) => ({ email, displayName: email.split("@")[0] }))];
  const source = e.source ?? "google";
  raw.prepare(`INSERT INTO calendar_event
    (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, attendee_count, after_hours,
     updated_at, attendees_json, source_type)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'client', ?, ?, 't', ?, ?)`)
    .run(e.id, source, new Date(startMs + off * MIN).toISOString().slice(0, 10), e.start, e.end, off,
      (endMs - startMs) / 1000, e.title, attendees.length, localHour >= 18 ? 1 : 0,
      JSON.stringify(attendees), e.sourceType ?? "calendar");
  for (const a of attendees) {
    raw.prepare(`INSERT INTO calendar_attendee (event_id, source, email, self, display_name) VALUES (?, ?, ?, ?, ?)`)
      .run(e.id, source, a.email, "self" in a ? 1 : 0, "displayName" in a ? a.displayName : null);
  }
}

/** One stored WHOOP reading per minute across the meeting and its 10 minute pads. */
export async function seedHr(db: D1Database, e: Pick<Ev, "id" | "start" | "end">, bpm: number, at = "2026-11-20T00:00:00.000Z") {
  const from = Date.parse(e.start) - 10 * MIN;
  const to = Date.parse(e.end) + 10 * MIN;
  const points: Array<[number, number]> = [];
  for (let t = from; t <= to; t += MIN) points.push([t, bpm]);
  await putCachedHr(db, {
    eventId: e.id,
    windowStartUtc: new Date(from).toISOString(),
    windowEndUtc: new Date(to).toISOString(),
    status: "ok",
    points,
    errorText: null,
    fetchedAt: at,
  });
}

export type World = Awaited<ReturnType<typeof world>>;

export async function world(opts: { omit?: string[]; extra?: Ev[]; twin?: boolean; hrFlag?: string } = {}) {
  resetScoringHrCache();
  const { db, raw } = sqliteD1();
  const events = [...EVENTS, ...(opts.twin ? [TWIN] : []), ...(opts.extra ?? [])]
    .filter((e) => !(opts.omit ?? []).includes(e.id));
  for (const e of events) {
    insertEvent(raw, e);
    if (e.hr != null) await seedHr(db, e, e.hr);
  }
  for (const [day, ready, sleep] of [
    ["2026-11-09", 70, 80], ["2026-11-10", 66, 77], ["2026-11-11", 60, 71], ["2026-11-12", 52, 64], ["2026-11-13", 45, 58],
  ] as const) {
    raw.prepare(`INSERT INTO daily_readiness (day, source, source_day, score, updated_at) VALUES (?, 'whoop', ?, ?, 't')`).run(day, day, ready);
    raw.prepare(`INSERT INTO daily_sleep (day, source, source_day, score, lowest_hr, updated_at) VALUES (?, 'whoop', ?, ?, 52, 't')`).run(day, day, sleep);
  }
  const kv = fakeKv({ "settings:source_display:whoop": "true" });
  const env = {
    DB: db, TOKENS: kv, WEARABLE: "whoop", WHOOP_WEB_HR: opts.hrFlag ?? "enabled", INGEST_ADMIN_SECRET: ADMIN,
  } as Record<string, unknown>;
  const pending: Promise<unknown>[] = [];
  const ctx = { waitUntil: (p: Promise<unknown>) => void pending.push(p), passThroughOnException: () => {} };
  /** Everything handed to waitUntil has settled. */
  const settle = async () => {
    while (pending.length) await Promise.allSettled(pending.splice(0));
  };
  const call = async (path: string, init: RequestInit = {}, bindings: Record<string, unknown> = env) => {
    const res = await api.request(`https://app.example${path}`, init, bindings as never, ctx as never);
    const text = await res.text();
    let body: any = null;
    try { body = JSON.parse(text); } catch { /* not JSON */ }
    return { status: res.status, headers: res.headers, text, body };
  };
  const get = async (path: string) => {
    const r = await call(path);
    assert.equal(r.status, 200, `${path}: ${r.text.slice(0, 300)}`);
    return r.body;
  };
  const put = (id: string, body: unknown, headers: Record<string, string> = { "content-type": "application/json" }) =>
    call(`/meetings/${encodeURIComponent(id)}/override`, {
      method: "PUT", headers, body: typeof body === "string" ? body : JSON.stringify(body),
    });
  /** PUT that must succeed. */
  const set = async (id: string, body: unknown) => {
    const r = await put(id, body);
    assert.equal(r.status, 200, `PUT ${id} ${JSON.stringify(body)}: ${r.text.slice(0, 300)}`);
    await settle();
    return r.body;
  };
  const attend = (body: unknown, headers: Record<string, string> = { authorization: `Bearer ${ADMIN}`, "content-type": "application/json" }) =>
    call("/whoop-web/app/attendance", { method: "POST", headers, body: typeof body === "string" ? body : JSON.stringify(body) });
  const rows = () => raw.prepare("SELECT * FROM meeting_override ORDER BY key").all() as Array<Record<string, any>>;
  const row = (key: string) => raw.prepare("SELECT * FROM meeting_override WHERE key = ?").get(key) as Record<string, any> | undefined;
  return { db, raw, env, kv, call, get, put, set, attend, settle, rows, row };
}

/**
 * What a route says with the override extras taken off: listed-but-excluded
 * meetings dropped, `override` and `excluded` keys removed.
 */
export function plain(value: unknown): unknown {
  if (Array.isArray(value)) return value.filter((v) => !(v && typeof v === "object" && (v as any).excluded === true)).map(plain);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      if (k === "override" || k === "excluded") continue;
      out[k] = plain(v);
    }
    return out;
  }
  return value;
}

/** GET routes that must answer the same with an excluded meeting as without it. */
export const SAME_AS_ABSENT: string[] = [
  "/briefing/day?date=2026-11-11",
  "/briefing/day?date=2026-11-12",
  "/briefing/range?start=2026-11-09&end=2026-11-13",
  "/briefing/week?date=2026-11-11",
  "/meetings/stressed?start=2026-11-09&end=2026-11-13",
  "/meetings/sleep-impact?start=2026-11-09&end=2026-11-13",
  "/insights/hits?start=2026-11-09&end=2026-11-13",
  "/meetings/f1/hr?fill=0",
  "/people?" + RANGE,
  "/people/pat%40acme.com/meetings?" + RANGE,
  "/people/dana%40exco.io/meetings?" + RANGE,
  "/people/sam%40weekly.io/meetings?" + RANGE,
  "/companies?" + RANGE,
  "/companies/search?q=exco",
  "/companies/search?q=weekly",
  "/companies/exco.io/meetings?" + RANGE,
  "/companies/weekly.io/meetings?" + RANGE,
  "/view?date=2026-11-11",
  "/view?date=2026-11-10",
  "/view?date=2026-11-12",
  "/view?start=2026-11-09&end=2026-11-13",
];

export async function answers(w: World, paths: string[] = SAME_AS_ABSENT): Promise<Record<string, unknown>> {
  const out: Record<string, unknown> = {};
  for (const p of paths) {
    const r = await w.call(p);
    // A route may answer 404 for a person or company that is gone; that is an answer too.
    out[p] = { status: r.status, body: plain(r.body) };
  }
  return out;
}

export function sameAnswers(a: Record<string, unknown>, b: Record<string, unknown>, label: string) {
  for (const p of Object.keys(a)) assert.deepEqual(a[p], b[p], `${label}: ${p}`);
}

/** Routes whose answers are fingerprinted without the table. */
export const PATHS = [
  ...SAME_AS_ABSENT,
  "/briefing/day?date=2026-11-10",
  "/briefing/week?date=2026-11-10",
  "/meetings/ser1_20261110T160000Z/hr?fill=0",
  "/insights/hits?start=2026-11-01&end=2026-11-14",
];

/** A short stable fingerprint of what a route said, for answers that must not change byte for byte. */
export function fingerprint(path: string, text: string): string {
  let out = text;
  // /view says what day it is; everything else about it is stored data.
  if (path.startsWith("/view")) {
    const body = JSON.parse(text) as Record<string, unknown>;
    delete body.today;
    out = JSON.stringify(body);
  }
  return createHash("sha256").update(out).digest("hex").slice(0, 16);
}

/** The file of the meeting_override migration, found by suffix, never by number. */
export function overrideMigration(): { name: string; number: number } | null {
  const dir = join(import.meta.dirname, "..", "migrations");
  const name = readdirSync(dir).find((n) => /^\d+_meeting_override\.sql$/.test(n));
  return name ? { name, number: Number(name.split("_")[0]) } : null;
}

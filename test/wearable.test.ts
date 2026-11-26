import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { activeWearable, parseWearable, wearableChoice, wearableInfo } from "../src/lib/wearable.ts";
import { redirectUri } from "../src/env.ts";
import { api } from "../src/routes/api.ts";
import { buildBaseline, composeHitSentence, rankHits } from "../src/lib/insights.ts";
import { GRAIN_NOTE, composeWeekSummary, grainNote } from "../src/sources/calendar/meetings.ts";
// @ts-expect-error — browser module, plain JS on purpose.

describe("WEARABLE setting", () => {
  it("accepts whoop and oura in any case, and nothing else", () => {
    assert.equal(parseWearable("whoop"), "whoop");
    assert.equal(parseWearable(" Oura "), "oura");
    assert.equal(parseWearable("WHOOP"), "whoop");
    assert.equal(parseWearable("fitbit"), null);
    assert.equal(parseWearable(""), null);
    assert.equal(parseWearable(undefined), null);
  });

  it("follows the setting when it is set", () => {
    assert.equal(activeWearable({ WEARABLE: "oura", WHOOP_CLIENT_ID: "x" }), "oura");
    assert.equal(activeWearable({ WEARABLE: "whoop", OURA_CLIENT_ID: "x" }), "whoop");
  });

  it("defaults a new install to WHOOP", () => {
    assert.equal(activeWearable({}), "whoop");
    assert.equal(activeWearable({ WHOOP_CLIENT_ID: "x" }), "whoop");
    assert.equal(activeWearable({ WHOOP_CLIENT_ID: "x", OURA_CLIENT_ID: "y" }), "whoop");
    assert.deepEqual(wearableChoice({}), { source: "whoop", reason: "default" });
  });

  it("keeps an install that only has Oura keys on Oura when WEARABLE is missing", () => {
    assert.equal(activeWearable({ OURA_CLIENT_ID: "x" }), "oura");
    assert.equal(activeWearable({ OURA_CLIENT_ID: "x", WHOOP_CLIENT_ID: "  " }), "oura");
    assert.deepEqual(wearableChoice({ OURA_CLIENT_ID: "x" }), { source: "oura", reason: "legacy_oura" });
    // A typo in the setting must not flip a running Oura install either.
    assert.equal(activeWearable({ WEARABLE: "woop", OURA_CLIENT_ID: "x" }), "oura");
  });

  it("describes what each wearable can report", () => {
    const oura = wearableInfo("oura");
    assert.equal(oura.hasIntradayHr, true);
    assert.equal(oura.readinessLabel, "Readiness");
    assert.equal(oura.strainLabel, null);
    const whoop = wearableInfo("whoop");
    assert.equal(whoop.hasIntradayHr, false);
    assert.equal(whoop.readinessLabel, "Recovery");
    assert.equal(whoop.strainLabel, "Strain");
    assert.equal(whoop.strainMax, 21);
    assert.match(whoop.note, /does not share minute-by-minute heart rate/);
  });

  it("derives redirect addresses from the Worker's own address unless one is set", () => {
    assert.equal(redirectUri(undefined, "https://app.example/auth/whoop/start?x=1", "/api/whoop/callback"), "https://app.example/api/whoop/callback");
    assert.equal(redirectUri("  ", "http://localhost:8787/auth/oura/start", "/auth/oura/callback"), "http://localhost:8787/auth/oura/callback");
    assert.equal(redirectUri("https://set.example/cb", "https://app.example/x", "/auth/oura/callback"), "https://set.example/cb");
  });
});

/** D1 stand-in. `rows` maps a table name to what a SELECT from it returns. */
function fakeDb(rows: Record<string, Array<Record<string, unknown>>> = {}) {
  const db = {
    prepare(sql: string) {
      const table = /FROM (\w+)/.exec(sql)?.[1] ?? "";
      const stmt = {
        bind: () => stmt,
        all: async () => ({
          results: /COUNT\(\*\)/.test(sql) ? [{ n: (rows[table] ?? []).length }] : rows[table] ?? [],
        }),
        first: async () => (/COUNT\(\*\)/.test(sql) ? { n: (rows[table] ?? []).length } : null),
        run: async () => ({ success: true }),
      };
      return stmt;
    },
    // D1 runs a batch in one round trip; here each statement just runs in turn.
    batch: async (stmts: Array<{ all: () => Promise<unknown> }>) => Promise.all(stmts.map((st) => st.all())),
  };
  return db as unknown as D1Database;
}

function fakeKv(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  return {
    get: async (k: string) => store.get(k) ?? null,
    put: async (k: string, v: string) => void store.set(k, v),
    delete: async (k: string) => void store.delete(k),
  };
}

/** An archive that fails the test if anything reads it. */
const untouchableRaw = {
  get: async () => {
    throw new Error("the heart-rate archive must not be read for a wearable without intraday heart-rate");
  },
};

const HR_DOC = JSON.stringify({
  data: [
    { bpm: 70, source: "awake", timestamp: "2026-11-05T14:00:00+00:00" },
    { bpm: 96, source: "awake", timestamp: "2026-11-05T15:10:00+00:00" },
    { bpm: 98, source: "awake", timestamp: "2026-11-05T15:30:00+00:00" },
    { bpm: 72, source: "awake", timestamp: "2026-11-05T18:00:00+00:00" },
  ],
});

const DAY_ROWS = {
  calendar_event: [
    {
      id: "m1",
      source: "sandbox",
      day: "2026-11-05",
      start_utc: "2026-11-05T15:00:00.000Z",
      end_utc: "2026-11-05T16:00:00.000Z",
      start_local: "2026-11-05T10:00:00-05:00",
      end_local: "2026-11-05T11:00:00-05:00",
      tz_offset_min: -300,
      duration_s: 3600,
      title: "Client review",
      kind: "client",
      client_key: null,
      project_key: null,
      attendee_count: 2,
      attendees_json: null,
      after_hours: 0,
      location: null,
      raw_id: 1,
      deleted_at: null,
      updated_at: "t",
    },
  ],
  daily_sleep: [{ day: "2026-11-05", score: 82, avg_hrv: 47, lowest_hr: 55, total_sleep_s: 25_000 }],
  daily_readiness: [{ day: "2026-11-05", score: 58, contributors_json: null }],
  daily_strain: [{ day: "2026-11-05", strain: 13.4, avg_hr: 70, max_hr: 151 }],
  raw_object: [{ r2_key: "oura/heartrate/hr-2026-11-05-p0/abc.json", day: "2026-11-05", document_id: "hr-2026-11-05-p0" }],
};

async function get(path: string, env: Record<string, unknown>) {
  const res = await api.request(`https://app.example${path}`, {}, env as never);
  return { status: res.status, body: (await res.json()) as Record<string, any> };
}

describe("API — WEARABLE=whoop vs WEARABLE=oura", () => {
  const whoopEnv = () => ({ WEARABLE: "whoop", DB: fakeDb(DAY_ROWS), TOKENS: fakeKv({ "settings:source_display:whoop": "true" }), RAW: untouchableRaw });
  const ouraEnv = () => ({ WEARABLE: "oura", DB: fakeDb(DAY_ROWS), TOKENS: fakeKv({ "settings:source_display:oura": "true" }), RAW: { get: async () => ({ text: async () => HR_DOC }) } });

  it("Oura: the day carries the heart-rate strip and a per-meeting heart-rate reading", async () => {
    const { status, body } = await get("/briefing/day?date=2026-11-05", ouraEnv());
    assert.equal(status, 200);
    assert.equal(body.wearable.source, "oura");
    assert.equal(body.wearable.hasIntradayHr, true);
    assert.ok(body.hr, "day strip present");
    assert.ok(body.hr.series.length > 0);
    const meeting = body.calendar.events[0];
    assert.equal(meeting.hrStress.coverage, "ok");
    assert.ok(meeting.hrStress.meanBpm > 90);
    assert.equal("strain" in body.priorNight, false);
  });

  it("WHOOP: no strip and no per-meeting reading; recovery and strain sit next to the meeting load", async () => {
    const { status, body } = await get("/briefing/day?date=2026-11-05", whoopEnv());
    assert.equal(status, 200);
    assert.equal(body.wearable.source, "whoop");
    assert.equal(body.wearable.hasIntradayHr, false);
    assert.equal(body.hr, null, "no day strip");
    assert.equal(body.calendar.events[0].hrStress, null, "no in-meeting heart-rate is invented");
    assert.equal(body.calendar.eventCount, 1);
    assert.equal(body.priorNight.readinessScore, 58);
    assert.equal(body.priorNight.strain, 13.4);
    assert.match(body.methodNote, /WHOOP does not share minute-by-minute heart rate/);
    assert.match(body.summary, /recovery 58/);

  });

  it("WHOOP: ranges, the week and hits skip the heart-rate archive and say so in plain words", async () => {
    const env = whoopEnv();
    const range = await get("/briefing/range?start=2026-11-03&end=2026-11-06", env);
    assert.equal(range.status, 200);
    assert.equal(range.body.wearable.source, "whoop");
    assert.equal(range.body.summary.noHr, 1);
    assert.equal(range.body.summary.line, "1 meeting across 1 day from Nov 3 to Nov 6: 1 hour in meetings.");
    assert.equal(range.body.recovery.avgStrain, 13.4);
    assert.match(range.body.grain.stress, /WHOOP does not share heart rate during the day/);

    const week = await get("/briefing/week?date=2026-11-05", env);
    assert.equal(week.body.summary.line, "1 meeting this week, 1 hour in total.");

    const hits = await get("/insights/hits?start=2026-11-03&end=2026-11-06", env);
    assert.equal(hits.status, 200);
    assert.match(hits.body.baseline.note, /WHOOP does not share heart rate during the day/);
    assert.ok(hits.body.hits.every((h: { hrStress: unknown }) => h.hrStress === null));

    const person = await get("/people/a%40example.com/meetings?start=2026-11-03&end=2026-11-06", env);
    assert.equal(person.status, 200);
    assert.equal(person.body.wearable.hasIntradayHr, false);
  });

  it("Oura: range wording and notes are unchanged", async () => {
    const env = { WEARABLE: "oura", DB: fakeDb(), TOKENS: fakeKv({ "settings:source_display:oura": "true" }), RAW: untouchableRaw };
    const range = await get("/briefing/range?start=2026-11-03&end=2026-11-06", env);
    assert.equal(range.body.wearable.source, "oura");
    assert.deepEqual(range.body.grain, { ...GRAIN_NOTE });
    assert.equal("avgStrain" in range.body.recovery, false);
    const hits = await get("/insights/hits?days=28", env);
    assert.match(hits.body.baseline.note, /not Oura's daytime stress score/);
  });

  it("health reports the active wearable and its own token", async () => {
    const tokens = { "whoop:tokens": JSON.stringify({ access_token: "a", expires_at: "2030-01-01T00:00:00.000Z" }) };
    const whoop = await get("/health", { WEARABLE: "whoop", OURA_SANDBOX: "true", DB: fakeDb(), TOKENS: fakeKv({ ...tokens, "settings:source_display:whoop": "true" }) });
    assert.equal(whoop.body.wearable.source, "whoop");
    assert.equal(whoop.body.wearable.chosenBy, "configured");
    assert.equal(whoop.body.token.present, true);
    assert.equal(whoop.body.sandbox, false, "WHOOP has no sandbox");
    assert.equal(whoop.body.counts.daily_strain, 0);

    const oura = await get("/health", { WEARABLE: "oura", DB: fakeDb(), TOKENS: fakeKv({ ...tokens, "settings:source_display:oura": "true" }) });
    assert.equal(oura.body.wearable.source, "oura");
    assert.equal(oura.body.token.present, false, "a WHOOP token does not count for Oura");
    assert.equal(oura.body.sandbox, true);
    assert.equal("daily_strain" in oura.body.counts, false);

    const legacy = await get("/health", { OURA_CLIENT_ID: "x", DB: fakeDb(), TOKENS: fakeKv({ "settings:source_display:oura": "true" }) });
    assert.equal(legacy.body.wearable.source, "oura");
    assert.equal(legacy.body.wearable.chosenBy, "legacy_oura");
  });

  it("WHOOP backfill: no sandbox, and a clear answer when not connected", async () => {
    const post = async (body: unknown, env: Record<string, unknown>) => {
      const res = await api.request(
        "https://app.example/backfill",
        { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) },
        env as never,
      );
      return { status: res.status, body: (await res.json()) as Record<string, any> };
    };
    const env = { WEARABLE: "whoop", DB: fakeDb(), TOKENS: fakeKv() };
    const sandbox = await post({ mode: "sandbox" }, env);
    assert.equal(sandbox.status, 400);
    assert.match(sandbox.body.error, /WHOOP has no sandbox/);
    const notConnected = await post({ mode: "production" }, env);
    assert.equal(notConnected.status, 401);
    assert.match(notConnected.body.error, /connect WHOOP at \/auth\/whoop\/start/);
  });

  it("setup status gives exact redirect addresses and never a secret value", async () => {
    const env = {
      DB: fakeDb(),
      TOKENS: fakeKv({ "google:tokens": JSON.stringify({ access_token: "a", expires_at: "2030-01-01T00:00:00.000Z" }) }),
      WHOOP_CLIENT_ID: "made-up-id",
      WHOOP_CLIENT_SECRET: "made-up-secret",
    };
    const { status, body } = await get("/setup/status", env);
    assert.equal(status, 200);
    assert.equal(body.origin, "https://app.example");
    assert.equal(body.wearable.source, "whoop");
    assert.equal(body.wearable.chosenBy, "default");
    assert.equal(body.whoop.redirectUri, "https://app.example/api/whoop/callback");
    assert.equal(body.whoop.startPath, "/auth/whoop/start");
    assert.equal(body.whoop.appUrl, "https://developer-dashboard.whoop.com/apps/create");
    assert.deepEqual(body.whoop.secrets, { WHOOP_CLIENT_ID: true, WHOOP_CLIENT_SECRET: true });
    assert.equal(body.whoop.connected, false);
    assert.equal(body.oura.redirectUri, "https://app.example/auth/oura/callback");
    assert.deepEqual(body.oura.secrets, { OURA_CLIENT_ID: false, OURA_CLIENT_SECRET: false });
    assert.equal(body.google.redirectUri, "https://app.example/auth/google/callback");
    assert.equal(body.google.connected, true);
    assert.equal(body.ready, false);
    assert.doesNotMatch(JSON.stringify(body), /made-up/);
  });
});

describe("API — /view, one request per screen", () => {
  it("WHOOP: a day carries the briefing, the usual, the heavy-day comparison and status, and never reads the archive", async () => {
    const env = { WEARABLE: "whoop", DB: fakeDb(DAY_ROWS), TOKENS: fakeKv(), RAW: untouchableRaw };
    const { status, body } = await get("/view?date=2026-11-05", env);
    assert.equal(status, 200);
    assert.equal(body.start, "2026-11-05");
    assert.equal(body.end, "2026-11-05");
    assert.equal(body.day.calendar.eventCount, 1);
    assert.equal(body.range, null);
    assert.equal(body.usual.days, 28);
    assert.equal(body.usual.from, "2026-10-09");
    assert.equal(body.hits, null, "no heart-rate ranking without heart-rate in meetings");
    assert.equal(body.status.wearableConnected, false);
    assert.equal(body.series.length, 1);
    assert.ok(Array.isArray(body.costly));
    assert.ok(Array.isArray(body.people));
  });

  it("WHOOP: a range returns the range briefing and one series point per day", async () => {
    const env = { WEARABLE: "whoop", DB: fakeDb(DAY_ROWS), TOKENS: fakeKv(), RAW: untouchableRaw };
    const { status, body } = await get("/view?start=2026-11-03&end=2026-11-06", env);
    assert.equal(status, 200);
    assert.equal(body.day, null);
    assert.equal(body.range.spanDays, 4);
    assert.deepEqual(body.series.map((d: { day: string }) => d.day), ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"]);
    assert.equal(body.effect.from, "2026-11-03");
  });

  it("rejects a bad range with the reason", async () => {
    const env = { WEARABLE: "whoop", DB: fakeDb(DAY_ROWS), TOKENS: fakeKv(), RAW: untouchableRaw };
    const { status, body } = await get("/view?start=2026-11-10&end=2026-11-01", env);
    assert.equal(status, 400);
    assert.match(body.error, /end must be on or after start/);
  });
});

describe("copy without per-meeting heart-rate", () => {
  const labels = { provider: "WHOOP", readiness: "recovery", intradayHr: false };

  it("names the wearable and its score in insight sentences", () => {
    const base = buildBaseline([], 28, undefined, labels);
    assert.match(base.note, /^Your usual from the last 28 days\./);
    assert.match(base.note, /ranked by the sleep and recovery that followed/);
    assert.doesNotMatch(base.note, /Oura|\bring\b/);
    assert.equal(composeHitSentence([], labels), "WHOOP for this join is not in yet.");
    assert.equal(composeHitSentence([]), "Oura for this join is not in yet.");
  });

  it("ranks days by the night that followed when there is no heart-rate", () => {
    const day = (d: string, sleep: number | null, ready: number | null) => ({
      day: d, sleepScore: sleep, readinessScore: ready, activityScore: null, steps: null,
      stressHighS: null, recoveryHighS: null, stressSummary: null, avgHrv: null, lowestHr: null, totalSleepS: null,
    });
    const days = [day("2026-11-03", 80, 70), day("2026-11-04", 80, 70), day("2026-11-05", 80, 70), day("2026-11-06", 60, 40)];
    const hits = rankHits({
      days,
      meetings: [],
      baseline: buildBaseline(days, 4, undefined, labels),
      from: "2026-11-03",
      to: "2026-11-05",
      hrByMeetingId: new Map(),
      labels,
    });
    assert.equal(hits.length, 1);
    assert.equal(hits[0].day, "2026-11-05");
    assert.equal(hits[0].hrStress, null);
    assert.match(hits[0].sentence, /next-morning recovery 30 below your median/);
    assert.equal(hits[0].compare[1].label, "Next-morning recovery");
  });

  it("keeps the Oura notes byte-for-byte and rewords them for WHOOP", () => {
    assert.equal(grainNote(), GRAIN_NOTE);
    const whoop = grainNote({ provider: "WHOOP", readiness: "recovery", strain: "strain", intradayHr: false });
    assert.equal(whoop.join, "work day D → WHOOP sleep/recovery on morning D+1");
    assert.match(whoop.stress, /compared by recovery, strain and meeting load/);
    assert.equal(whoop.afterHours, GRAIN_NOTE.afterHours);
    assert.equal(
      composeWeekSummary({ meetingCount: 3, elevated: 0, watching: 0, restored: 0, noHr: 3, hardest: null, intradayHr: false, totalDurationS: 9000 }),
      "3 meetings this week, 2.5 hours in total.",
    );
    assert.match(
      composeWeekSummary({ meetingCount: 3, elevated: 0, watching: 0, restored: 0, noHr: 3, hardest: null }),
      /No ring HR in those windows/,
    );
  });
});

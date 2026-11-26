import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import { MAX_COVERED, REMINDER_OWNER_TTL_S, parseCovered, reminderMessage, reminderOwner, sendPushover, setPhoneOwner, startingMeeting } from "../src/sources/whoop-web/reminder.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

const SECRET = "admin-secret-xyz";

function insertMeeting(raw: ReturnType<typeof sqliteD1>["raw"], id: string, startMs: number, endMs: number, title = "Client review") {
  const startUtc = new Date(startMs).toISOString();
  const endUtc = new Date(endMs).toISOString();
  raw
    .prepare(
      `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, attendee_count, after_hours, updated_at, start_local, end_local)
       VALUES (?, 'google', ?, ?, ?, -300, ?, ?, 'client', 2, 0, 't', ?, ?)`,
    )
    .run(id, startUtc.slice(0, 10), startUtc, endUtc, (endMs - startMs) / 1000, title, startUtc, endUtc);
}

describe("HR Broadcast reminder", () => {
  it("finds the meeting starting within two minutes or in progress", async () => {
    const { db, raw } = sqliteD1();
    const now = Date.parse("2026-11-20T14:28:30Z");
    insertMeeting(raw, "later", now + 5 * 60_000, now + 35 * 60_000);
    assert.equal(await startingMeeting(db, now), null, "five minutes out is not yet starting");
    insertMeeting(raw, "soon", Date.parse("2026-11-20T14:30:00Z"), Date.parse("2026-11-20T15:30:00Z"), "Weekly sync");
    assert.equal((await startingMeeting(db, now))?.id, "soon");
    assert.equal((await startingMeeting(db, Date.parse("2026-11-20T15:00:00Z")))?.id, "later", "the latest start wins when two overlap");
    assert.equal((await startingMeeting(db, Date.parse("2026-11-20T15:10:00Z")))?.id, "soon", "in progress still counts");
    assert.equal(await startingMeeting(db, Date.parse("2026-11-20T15:30:00Z")), null, "over");
  });

  it("sends Pushover only when configured, and never throws", async () => {
    const calls: Array<{ url: string; body: string }> = [];
    const ok = (async (url: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(url), body: String(init?.body) });
      return new Response("{}", { status: 200 });
    }) as typeof fetch;
    assert.equal(await sendPushover({}, "x", ok), "not_configured");
    assert.equal(calls.length, 0);
    assert.equal(await sendPushover({ PUSHOVER_TOKEN: "tok", PUSHOVER_USER: "usr" }, reminderMessage("Weekly sync", false), ok), "sent");
    assert.equal(calls[0].url, "https://api.pushover.net/1/messages.json");
    const form = new URLSearchParams(calls[0].body);
    assert.equal(form.get("token"), "tok");
    assert.equal(form.get("user"), "usr");
    assert.match(form.get("message") ?? "", /^“Weekly sync” is starting\. Turn on HR Broadcast in the WHOOP app\.$/);
    const boom = (async () => {
      throw new Error("network");
    }) as unknown as typeof fetch;
    assert.equal(await sendPushover({ PUSHOVER_TOKEN: "tok", PUSHOVER_USER: "usr" }, "x", boom), "failed");
    assert.match(reminderMessage("", true), /^Still no heart rate for your meeting\. Turn on HR Broadcast in the WHOOP app\.$/);
  });

  it("routes need the ingest secret; POST answers not_configured without Pushover secrets", async () => {
    const { db, raw } = sqliteD1();
    const env = { DB: db, TOKENS: fakeKv(), INGEST_ADMIN_SECRET: SECRET };
    const now = Date.now();
    insertMeeting(raw, "now", now - 60_000, now + 30 * 60_000);
    const auth = { authorization: `Bearer ${SECRET}` };
    assert.equal((await api.request("https://app.example/whoop-web/reminder", {}, env as never)).status, 401);
    const got = await api.request("https://app.example/whoop-web/reminder", { headers: auth }, env as never);
    assert.equal(got.status, 200);
    const body = (await got.json()) as Record<string, any>;
    assert.equal(body.meeting.id, "now");
    assert.equal(body.pushover, false);
    assert.equal(body.live, false, "build 11: the lookup also says whether heart rate is coming in");
    const posted = await api.request(
      "https://app.example/whoop-web/reminder",
      { method: "POST", body: JSON.stringify({ title: "Weekly sync" }), headers: { ...auth, "content-type": "application/json" } },
      env as never,
    );
    assert.equal(posted.status, 200);
    assert.deepEqual(await posted.json(), { ok: true, pushover: "not_configured" });
  });

  it("the phone owns only the meetings it covered while its check-in is fresh, otherwise the Mac", async () => {
    const kv = fakeKv();
    const t = Date.parse("2026-11-20T14:00:00Z");
    const start = "2026-11-20T15:00:00.000Z";
    assert.deepEqual(await reminderOwner(kv, t, start), { owner: "mac", until: null }, "no phone yet");
    const checkedIn = await setPhoneOwner(kv, true, t, [Date.parse(start)]);
    assert.equal(checkedIn.owner, "phone");
    assert.equal(checkedIn.covered, 1);
    const until = new Date(t + REMINDER_OWNER_TTL_S * 1000).toISOString();
    assert.equal(checkedIn.until, until);
    assert.deepEqual(await reminderOwner(kv, t + 60_000, start), { owner: "phone", until });
    assert.equal((await reminderOwner(kv, t, "2026-11-20T15:01:30.000Z")).owner, "phone", "within 90 s still matches");
    assert.deepEqual(await reminderOwner(kv, t, "2026-11-20T15:01:31.000Z"), { owner: "mac", until }, "91 s off is another meeting");
    assert.equal((await reminderOwner(kv, t, "2026-11-22T15:00:00.000Z")).owner, "mac", "a meeting past the phone's coverage is the Mac's");
    assert.equal((await reminderOwner(kv, t, null)).owner, "mac", "no calendar meeting (Zoom only) is the Mac's");
    assert.equal((await reminderOwner(kv, t + REMINDER_OWNER_TTL_S * 1000, start)).owner, "mac", "a stale check-in hands back to the Mac");
    assert.deepEqual(await setPhoneOwner(kv, false, t + 1), { owner: "mac", until: null, covered: 0 }, "signing out steps down");
    assert.equal((await reminderOwner(kv, t + 2, start)).owner, "mac");
    const broken = { get: async () => { throw new Error("kv"); }, put: async () => {}, delete: async () => {} };
    assert.equal((await reminderOwner(broken as never, t, start)).owner, "mac", "a KV failure falls back to the Mac");
  });

  it("an old-format check-in (a bare ISO time) covers no meeting", async () => {
    const kv = fakeKv();
    const t = Date.parse("2026-11-20T14:00:00Z");
    await kv.put("reminders:phone_owner", new Date(t).toISOString());
    const state = await reminderOwner(kv, t + 60_000, "2026-11-20T14:01:00.000Z");
    assert.equal(state.owner, "mac", "the Mac reminds until the phone checks in with coverage");
    assert.equal(state.until, new Date(t + REMINDER_OWNER_TTL_S * 1000).toISOString());
    await kv.put("reminders:phone_owner", "{not json");
    assert.deepEqual(await reminderOwner(kv, t, "2026-11-20T14:01:00.000Z"), { owner: "mac", until: null });
  });

  it("covered is validated strictly", () => {
    assert.deepEqual(parseCovered(undefined), []);
    assert.deepEqual(parseCovered(["2026-11-24T14:00:00.000Z", "2026-11-24T15:00:00Z"]), [Date.parse("2026-11-24T14:00:00Z"), Date.parse("2026-11-24T15:00:00Z")]);
    assert.equal(parseCovered("2026-11-24T14:00:00.000Z"), null);
    assert.equal(parseCovered([1_800_000_000_000]), null);
    assert.equal(parseCovered(["2026-11-24T14:00:00+01:00"]), null, "UTC only");
    assert.equal(parseCovered(["2026-11-24"]), null);
    assert.equal(parseCovered(["2026-13-40T99:00:00.000Z"]), null, "a real date");
    assert.equal(parseCovered(Array.from({ length: MAX_COVERED + 1 }, () => "2026-11-24T14:00:00.000Z")), null);
    assert.equal(parseCovered(Array.from({ length: MAX_COVERED }, () => "2026-11-24T14:00:00.000Z"))?.length, MAX_COVERED);
  });

  it("owner check-in needs the ingest secret; GET says phone only for a covered meeting", async () => {
    const { db, raw } = sqliteD1();
    const env = { DB: db, TOKENS: fakeKv(), INGEST_ADMIN_SECRET: SECRET };
    const auth = { authorization: `Bearer ${SECRET}`, "content-type": "application/json" };
    const post = (body: unknown, headers: Record<string, string> = auth) =>
      api.request("https://app.example/whoop-web/reminder/owner", { method: "POST", body: JSON.stringify(body), headers }, env as never);
    const lookup = async () =>
      (await (await api.request("https://app.example/whoop-web/reminder", { headers: auth }, env as never)).json()) as Record<string, any>;
    const now = Date.now();
    const start = Math.floor((now + 60_000) / 1000) * 1000;
    insertMeeting(raw, "soon", start, start + 30 * 60_000);
    const logs: string[] = [];
    const original = console.log;
    console.log = (...args: unknown[]) => { logs.push(args.map(String).join(" ")); };
    try {
      assert.equal((await post({ active: true }, { "content-type": "application/json" })).status, 401);
      assert.equal((await post({ active: "yes" })).status, 400);
      assert.equal((await post({ active: true, covered: ["tomorrow"] })).status, 400);
      assert.equal((await post({ active: true, covered: Array.from({ length: 61 }, () => new Date(start).toISOString()) })).status, 400);
      assert.equal((await post({ active: true, push: { token: "not-hex", environment: "production" } })).status, 400, "build 11: a bad push registration");

      const withoutPush = (await (await post({ active: true, covered: [new Date(start).toISOString()] })).json()) as Record<string, unknown>;
      assert.equal(withoutPush.push, false, "build 11: an old phone with no push key gets push false");
      const other = await post({ active: true, covered: [new Date(start + 3 * 3_600_000).toISOString()] });
      assert.equal(other.status, 200);
      assert.deepEqual(((await other.json()) as Record<string, unknown>).covered, 1);
      const notCovered = await lookup();
      assert.equal(notCovered.meeting.id, "soon");
      assert.equal(notCovered.owner, "mac", "the phone did not schedule this meeting, so the Mac reminds");
      assert.equal(typeof notCovered.ownerUntil, "string", "ownerUntil stays in the reply");

      const ok = await post({ active: true, covered: [new Date(start).toISOString()] });
      assert.equal(ok.status, 200);
      assert.equal(((await ok.json()) as Record<string, unknown>).owner, "phone");
      const covered = await lookup();
      assert.equal(covered.owner, "phone");
      assert.equal(typeof covered.ownerUntil, "string");

      assert.equal((await post({ active: true })).status, 200, "an older phone without covered still checks in");
      assert.equal((await lookup()).owner, "mac", "but covers nothing");

      await post({ active: false });
      const after = await lookup();
      assert.equal(after.owner, "mac");
      assert.equal(after.ownerUntil, null);
    } finally {
      console.log = original;
    }
    const audit = logs.filter((l) => l.includes("reminder_owner")).map((l) => JSON.parse(l));
    assert.deepEqual(audit, [
      { event: "reminder_owner", owner: "phone", covered: 1, push: false },
      { event: "reminder_owner", owner: "phone", covered: 1, push: false },
      { event: "reminder_owner", owner: "phone", covered: 1, push: false },
      { event: "reminder_owner", owner: "phone", covered: 0, push: false },
      { event: "reminder_owner", owner: "mac", covered: 0, push: false },
    ], "every owner change is logged with state, count and the push boolean only (build 11)");
    assert.ok(!logs.some((l) => l.includes(SECRET) || l.includes("Client review")), "no secrets or titles in logs");
  });
});

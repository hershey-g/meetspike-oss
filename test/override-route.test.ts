import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ADMIN, world, type Ev } from "./override-world.ts";

const ms = (s: string) => Date.parse(s);
const JSON_HEADERS = { "content-type": "application/json" };

describe("PUT /api/meetings/:id/override", () => {
  it("saves a choice and answers 200 with ok", async () => {
    const w = await world();
    const r = await w.put("evt-board", { scope: "event", state: "not_joined" });
    assert.equal(r.status, 200, r.text);
    assert.equal(r.body.ok, true);
    assert.deepEqual(w.rows().map((x) => [x.key, x.state, x.start_utc, x.end_utc, x.seen_none]), [["event:evt-board", "not_joined", null, null, 0]]);
    assert.match(w.row("event:evt-board")!.updated_at, /^\d{4}-\d{2}-\d{2}T/);
    // Again, and with a charset on the content type: still one row.
    const again = await w.put("evt-board", { scope: "event", state: "not_joined" }, { "content-type": "application/json; charset=utf-8" });
    assert.equal(again.status, 200);
    assert.equal(w.rows().length, 1);
  });

  it("changes only what it is sent: an omitted field is left alone, null clears it", async () => {
    const w = await world();
    await w.set("f1", { scope: "event", startUtc: "2026-11-12T19:45:00Z" });
    await w.set("f1", { scope: "event", state: "linked" });
    assert.deepEqual([w.row("event:f1")!.state, ms(w.row("event:f1")!.start_utc)], ["linked", ms("2026-11-12T19:45:00Z")]);
    await w.set("f1", { scope: "event", endUtc: "2026-11-12T21:15:00Z" });
    assert.equal(w.row("event:f1")!.state, "linked");
    assert.equal(ms(w.row("event:f1")!.start_utc), ms("2026-11-12T19:45:00Z"));
    await w.set("f1", { scope: "event", state: null });
    assert.equal(w.row("event:f1")!.state, null);
    assert.equal(ms(w.row("event:f1")!.end_utc), ms("2026-11-12T21:15:00Z"));
    // Clearing a choice that was never made is fine.
    assert.equal((await w.put("b1", { scope: "event", state: null })).status, 200);
  });

  it("clearing everything leaves nothing behind that changes an answer", async () => {
    const w = await world();
    const before = await w.call("/view?date=2026-11-12");
    await w.set("f1", { scope: "event", state: "not_joined", startUtc: "2026-11-12T19:45:00Z", endUtc: "2026-11-12T21:15:00Z" });
    await w.set("f1", { scope: "event", state: null, startUtc: null, endUtc: null });
    assert.equal((await w.call("/view?date=2026-11-12")).text, before.text);
  });

  it("takes times only for one meeting, not a series", async () => {
    const w = await world();
    for (const body of [
      { scope: "series", state: "not_joined", startUtc: "2026-11-10T16:00:00Z" },
      { scope: "series", endUtc: "2026-11-10T16:30:00Z" },
    ]) {
      const r = await w.put("ser1_20261110T160000Z", body);
      assert.equal(r.status, 400, JSON.stringify(body));
    }
    assert.deepEqual(w.rows(), []);
  });

  it("answers 400 for a body of the wrong shape, 415 for another content type, 413 for a big body, 404 for an unknown meeting, and saves nothing", async () => {
    const w = await world();
    const bad: unknown[] = [
      "not json", "[]", "null", "42", "{}", {},
      { state: "not_joined" },
      { scope: "meeting", state: "not_joined" },
      { scope: 1, state: "not_joined" },
      { scope: "event", state: "excluded" },
      { scope: "event", state: 1 },
      { scope: "event", state: true },
      { scope: "event", startUtc: "tomorrow" },
      { scope: "event", startUtc: 1_700_000_000_000 },
      { scope: "event", endUtc: "2026-11-12" },
      { scope: "event", endUtc: "" },
      { scope: "event", startUtc: {} },
    ];
    for (const body of bad) {
      const r = await w.put("f1", body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.equal(typeof r.body?.error, "string", JSON.stringify(body));
      assert.doesNotMatch(r.body.error, /—/);
    }
    const ok = JSON.stringify({ scope: "event", state: "not_joined" });
    for (const type of ["text/plain", "application/x-www-form-urlencoded", "text/plain; charset=utf-8", ""]) {
      const headers: Record<string, string> = type ? { "content-type": type } : {};
      assert.equal((await w.put("f1", ok, headers)).status, 415, type || "no content type");
    }
    const big = JSON.stringify({ scope: "event", state: "not_joined", pad: "x".repeat(200_000) });
    assert.equal((await w.put("f1", big, JSON_HEADERS)).status, 413);
    assert.equal((await w.put("no-such-meeting", { scope: "event", state: "not_joined" })).status, 404);
    assert.equal((await w.put("no_such_20261110T150000Z", { scope: "series", state: "not_joined" })).status, 404);
    assert.deepEqual(w.rows(), []);
  });

  it("answers 503, in plain words, when the table has not been created yet", async () => {
    const w = await world();
    w.raw.exec("DROP TABLE meeting_override");
    const r = await w.put("f1", { scope: "event", state: "not_joined" });
    assert.equal(r.status, 503);
    assert.equal(typeof r.body.error, "string");
    assert.doesNotMatch(r.body.error, /—/);
  });
});

describe("POST /api/whoop-web/app/attendance", () => {
  const A = "2026-11-10T12:00:00.000Z";
  const two = (): Ev[] => [
    { id: "tie1", start: A, end: "2026-11-10T12:30:00.000Z", title: "Standup", people: [], hr: null },
    { id: "tie2", start: A, end: "2026-11-10T13:00:00.000Z", title: "Retro", people: [], hr: null },
  ];
  const sighting = (extra: Record<string, unknown> = {}) => ({
    meetingStartUtc: A, seenStartUtc: "2026-11-10T12:03:00.000Z", seenEndUtc: "2026-11-10T12:28:00.000Z", seenNone: false, ...extra,
  });

  it("is for the Mac only: it needs the admin secret", async () => {
    const w = await world({ extra: [two()[0]] });
    const body = JSON.stringify(sighting());
    assert.equal((await w.attend(body, JSON_HEADERS)).status, 401);
    assert.equal((await w.attend(body, { ...JSON_HEADERS, authorization: "Bearer nope" })).status, 401);
    assert.equal((await w.attend(body, { ...JSON_HEADERS, "x-admin-secret": "wrong" })).status, 401);
    assert.equal((await w.call("/whoop-web/app/attendance", { method: "POST", headers: { ...JSON_HEADERS, authorization: `Bearer ${ADMIN}` }, body }, { ...w.env, INGEST_ADMIN_SECRET: "" })).status, 503);
    assert.deepEqual(w.rows(), []);
    assert.equal((await w.attend(body, { ...JSON_HEADERS, "x-admin-secret": ADMIN })).status, 200, "x-admin-secret works like the other Mac routes");
  });

  it("rejects bodies of the wrong shape, oversized bodies and a missing table, and writes nothing", async () => {
    const w = await world({ extra: [two()[0]] });
    for (const body of [
      "not json", "[]", "null", {},
      sighting({ meetingStartUtc: undefined }),
      sighting({ meetingStartUtc: "soon" }),
      sighting({ seenStartUtc: "later" }),
      sighting({ seenEndUtc: 5 }),
      sighting({ seenNone: "yes" }),
      sighting({ seenNone: undefined }),
      sighting({ seenStartUtc: "2026-11-10T12:20:00.000Z", seenEndUtc: "2026-11-10T12:10:00.000Z" }),
      sighting({ title: 5 }),
    ]) {
      const r = await w.attend(body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.doesNotMatch(String(r.body?.error), /—/);
    }
    assert.equal((await w.attend(JSON.stringify(sighting({ title: "x".repeat(200_000) })))).status, 413);
    assert.deepEqual(w.rows(), []);
    w.raw.exec("DROP TABLE meeting_override");
    assert.equal((await w.attend(sighting())).status, 503);
  });

  it("matches exactly one meeting by its original start, give or take 90 seconds", async () => {
    const w = await world({ extra: [two()[0]] });
    const at = (offsetS: number) => new Date(ms(A) + offsetS * 1000).toISOString();
    for (const off of [0, 90, -90, 45]) {
      const r = await w.attend(sighting({ meetingStartUtc: at(off) }));
      assert.equal(r.status, 200, `${off}s`);
      assert.equal(r.body?.matched, true, `${off}s`);
    }
    for (const off of [91, -91, 3600]) {
      const r = await w.attend(sighting({ meetingStartUtc: at(off) }));
      assert.equal(r.status, 202, `${off}s`);
      assert.deepEqual(r.body, { matched: false }, `${off}s`);
    }
    assert.deepEqual(w.rows().map((r) => r.key), ["event:tie1"]);
  });

  it("matches without milliseconds and ignores deleted meetings", async () => {
    const w = await world({ extra: [two()[0], { ...two()[1], id: "gone", start: A }] });
    w.raw.exec("UPDATE calendar_event SET deleted_at = '2026-11-10T00:00:00.000Z' WHERE id = 'gone'");
    const r = await w.attend(sighting({ meetingStartUtc: "2026-11-10T12:00:00Z" }));
    assert.equal(r.body?.matched, true);
    assert.deepEqual(w.rows().map((x) => x.key), ["event:tie1"]);
  });

  it("answers 202 matched false for zero matches and for two or more, and the title only breaks a tie", async () => {
    const w = await world({ extra: two() });
    const none = await w.attend(sighting({ meetingStartUtc: "2026-11-10T09:00:00.000Z" }));
    assert.deepEqual([none.status, none.body], [202, { matched: false }]);
    const ambiguous = await w.attend(sighting());
    assert.deepEqual([ambiguous.status, ambiguous.body], [202, { matched: false }]);
    const wrongTitle = await w.attend(sighting({ title: "Something else" }));
    assert.deepEqual([wrongTitle.status, wrongTitle.body], [202, { matched: false }]);
    assert.deepEqual(w.rows(), [], "an unmatched report stores nothing");
    const tied = await w.attend(sighting({ title: "Retro" }));
    assert.equal(tied.status, 200);
    assert.equal(tied.body?.matched, true);
    assert.deepEqual(w.rows().map((r) => r.key), ["event:tie2"]);
    // Two meetings a minute apart are both inside the window of a start between them.
    const near = await world({ extra: [two()[0], { ...two()[1], start: "2026-11-10T12:01:00.000Z", end: "2026-11-10T12:40:00.000Z" }] });
    const between = await near.attend(sighting({ meetingStartUtc: "2026-11-10T12:00:30.000Z" }));
    assert.deepEqual([between.status, between.body], [202, { matched: false }]);
  });

  it("with one candidate the title is not needed and is not checked", async () => {
    const w = await world({ extra: [two()[0]] });
    assert.equal((await w.attend(sighting({ title: "A different name" }))).body?.matched, true);
    assert.equal((await w.attend(sighting())).body?.matched, true);
  });

  it("matches on the calendar's start, not the time the user moved the meeting to", async () => {
    const w = await world({ extra: [two()[0]] });
    await w.set("tie1", { scope: "event", startUtc: "2026-11-10T11:30:00Z" });
    assert.equal((await w.attend(sighting())).body?.matched, true, "the original start still finds it");
    const moved = await w.attend(sighting({ meetingStartUtc: "2026-11-10T11:30:00.000Z" }));
    assert.deepEqual([moved.status, moved.body], [202, { matched: false }], "the moved start does not");
  });

  it("stores the sighting on the event and is safe to send again", async () => {
    const w = await world({ extra: [two()[0]] });
    assert.equal((await w.attend(sighting())).status, 200);
    const row = w.row("event:tie1")!;
    assert.equal(row.state, null);
    assert.equal(row.start_utc, null);
    assert.equal(row.end_utc, null);
    assert.equal(ms(row.seen_start_utc), ms("2026-11-10T12:03:00.000Z"));
    assert.equal(ms(row.seen_end_utc), ms("2026-11-10T12:28:00.000Z"));
    assert.equal(row.seen_none, 0);
    const strip = (r: Record<string, any>) => ({ ...r, updated_at: undefined });
    for (let i = 0; i < 3; i++) assert.equal((await w.attend(sighting())).status, 200);
    assert.deepEqual(w.rows().map(strip), [strip(row)]);
  });

  it("only widens the seen times", async () => {
    const w = await world({ extra: [two()[0]] });
    const seen = () => [ms(w.row("event:tie1")!.seen_start_utc), ms(w.row("event:tie1")!.seen_end_utc)];
    const t = (hhmm: string) => ms(`2026-11-10T${hhmm}:00.000Z`);
    await w.attend(sighting({ seenStartUtc: "2026-11-10T12:05:00.000Z", seenEndUtc: "2026-11-10T12:20:00.000Z" }));
    assert.deepEqual(seen(), [t("12:05"), t("12:20")]);
    await w.attend(sighting({ seenStartUtc: "2026-11-10T12:08:00.000Z", seenEndUtc: "2026-11-10T12:15:00.000Z" }));
    assert.deepEqual(seen(), [t("12:05"), t("12:20")], "a narrower report changes nothing");
    await w.attend(sighting({ seenStartUtc: "2026-11-10T12:02:00.000Z", seenEndUtc: "2026-11-10T12:18:00.000Z" }));
    assert.deepEqual(seen(), [t("12:02"), t("12:20")], "each side widens by itself");
    await w.attend(sighting({ seenStartUtc: "2026-11-10T12:04:00.000Z", seenEndUtc: "2026-11-10T12:29:00.000Z" }));
    assert.deepEqual(seen(), [t("12:02"), t("12:29")]);
  });

  it("seenNone says the Mac saw nothing, and any sighting clears it for good", async () => {
    const w = await world({ extra: [two()[0]] });
    const none = sighting({ seenStartUtc: null, seenEndUtc: null, seenNone: true });
    assert.equal((await w.attend(none)).body?.matched, true);
    let row = w.row("event:tie1")!;
    assert.deepEqual([row.seen_none, row.seen_start_utc, row.seen_end_utc, row.state], [1, null, null, null]);
    const e = async () => (await w.get("/view?date=2026-11-10")).day.calendar.events.find((x: any) => x.id === "tie1");
    const looked = await e();
    assert.equal(looked.override.seenNone, true);
    assert.equal(looked.override.state, null, "a quiet note, not a state");
    assert.ok(!looked.excluded);
    assert.equal(ms(looked.startUtc), ms(A));
    await w.attend(sighting());
    row = w.row("event:tie1")!;
    assert.equal(row.seen_none, 0);
    assert.equal((await e()).override.seenNone, false);
    await w.attend(none);
    row = w.row("event:tie1")!;
    assert.equal(row.seen_none, 0, "a later 'saw nothing' does not undo a sighting");
    assert.equal(ms(row.seen_start_utc), ms("2026-11-10T12:03:00.000Z"));
  });

  it("never changes the user's state or times, whatever the Mac saw", async () => {
    const w = await world({ extra: [two()[0]] });
    await w.set("tie1", { scope: "event", state: "not_joined", startUtc: "2026-11-10T11:45:00Z", endUtc: "2026-11-10T12:40:00Z" });
    const before = w.row("event:tie1")!;
    await w.attend(sighting());
    await w.attend(sighting({ seenStartUtc: null, seenEndUtc: null, seenNone: true }));
    const after = w.row("event:tie1")!;
    assert.equal(after.state, "not_joined");
    assert.equal(after.start_utc, before.start_utc);
    assert.equal(after.end_utc, before.end_utc);
    assert.equal(ms(after.seen_start_utc), ms("2026-11-10T12:03:00.000Z"));
    // An excluded meeting is still a meeting the Mac can report on.
    const view = (await w.get("/view?date=2026-11-10")).day.calendar.events.find((x: any) => x.id === "tie1");
    assert.equal(view.excluded, true);
    for (const state of ["linked", "unlinked", null]) {
      await w.set("tie1", { scope: "event", state });
      await w.attend(sighting());
      assert.equal(w.row("event:tie1")!.state, state);
    }
  });

  it("writes to the event, never to its series", async () => {
    const w = await world();
    await w.set("ser1_20261110T160000Z", { scope: "series", state: "not_joined" });
    const series = w.row("series:ser1")!;
    const r = await w.attend({ meetingStartUtc: "2026-11-10T16:00:00.000Z", title: "Weekly sync", seenStartUtc: "2026-11-10T16:01:00.000Z", seenEndUtc: "2026-11-10T16:20:00.000Z", seenNone: false });
    assert.equal(r.body?.matched, true);
    assert.deepEqual(w.row("series:ser1"), series);
    assert.equal(w.row("event:ser1_20261110T160000Z")!.state, null);
    const e = (await w.get("/view?date=2026-11-10")).day.calendar.events.find((x: any) => x.id === "ser1_20261110T160000Z");
    assert.equal(e.excluded, true, "the series choice still applies");
    assert.equal(e.override.scope, "series");
  });
});

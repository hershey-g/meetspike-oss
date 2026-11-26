import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import { saveAiKey } from "../src/lib/ai-key.ts";
import { answers, RANGE, sameAnswers, SAME_AS_ABSENT, world, type World } from "./override-world.ts";

const E = "evt-board";
const S = ["ser1_20261109T160000Z", "ser1_20261110T160000Z", "ser1_20261111T160000Z"];

describe("excluded meetings are gone, as if never stored", () => {
  it("the fixture matters: with the meeting present the answers differ on every route that should drop it", async () => {
    const present = await world();
    const absent = await world({ omit: [E] });
    const a = await answers(present);
    const b = await answers(absent);
    for (const p of [
      "/briefing/day?date=2026-11-11", "/briefing/range?start=2026-11-09&end=2026-11-13", "/briefing/week?date=2026-11-11",
      "/meetings/stressed?start=2026-11-09&end=2026-11-13", "/insights/hits?start=2026-11-09&end=2026-11-13",
      "/meetings/f1/hr?fill=0", "/people?" + RANGE, "/companies?" + RANGE, "/companies/search?q=exco",
      "/people/dana%40exco.io/meetings?" + RANGE, "/view?date=2026-11-11", "/view?date=2026-11-12",
    ]) assert.notDeepEqual(a[p], b[p], `${p} should show the meeting when it is not excluded`);
  });

  for (const state of ["not_joined", "unlinked"] as const) {
    it(`${state}: scores, baseline, people, companies, search, week, range and briefings answer as if it was never there`, async () => {
      const excluded = await world();
      await excluded.set(E, { scope: "event", state });
      const absent = await world({ omit: [E] });
      sameAnswers(await answers(excluded), await answers(absent), state);
    });
  }

  it("the heart rate baseline of a later meeting no longer includes the excluded meeting", async () => {
    const excluded = await world();
    await excluded.set(E, { scope: "event", state: "not_joined" });
    const absent = await world({ omit: [E] });
    const detail = async (w: World) => (await w.get("/meetings/f1/hr?fill=0"));
    const a = await detail(excluded);
    const b = await detail(absent);
    assert.deepEqual(a.baseline, b.baseline);
    assert.deepEqual(a.hrStress, b.hrStress);
    const present = await detail(await world());
    assert.notEqual(present.baseline.meanBpm, b.baseline.meanBpm, "the 150 bpm meeting moves the baseline when it counts");
    // The same numbers in the list views.
    const day = async (w: World) =>
      (await w.get("/briefing/day?date=2026-11-12")).calendar.events.find((e: any) => e.id === "f1").hrStress;
    assert.deepEqual(await day(excluded), await day(absent));
  });

  it("it is still listed on that day in /view, marked excluded, with no heart rate and no scores", async () => {
    const w = await world();
    await w.set(E, { scope: "event", state: "not_joined" });
    const view = await w.get("/view?date=2026-11-11");
    const events: any[] = view.day.calendar.events;
    const e = events.find((x) => x.id === E);
    assert.ok(e, "excluded meetings stay in the day's list so they can be undone");
    assert.equal(e.excluded, true);
    assert.equal(e.override.state, "not_joined");
    assert.equal(e.override.scope, "event");
    assert.ok(e.hrStress == null || e.hrStress.coverage !== "ok", "no heart rate");
    assert.equal(e.signals.nextReadinessScore, null);
    assert.equal(e.signals.nextSleepScore, null);
    for (const other of events.filter((x) => x.id !== E)) assert.ok(!other.excluded, other.id);
    assert.equal(events.filter((x) => x.title === "Board prep").length, 1);
    // Not in the numbers on the same screen.
    const absent = await (await world({ omit: [E] })).get("/view?date=2026-11-11");
    assert.deepEqual(view.day.calendar.eventCount, absent.day.calendar.eventCount);
    assert.deepEqual(view.day.calendar.totalDurationS, absent.day.calendar.totalDurationS);
    assert.deepEqual(view.series, absent.series);
    assert.deepEqual(view.usual, absent.usual);
    assert.deepEqual(view.morningScores, absent.morningScores);
  });

  it("the other briefings do not list it at all", async () => {
    const w = await world();
    await w.set(E, { scope: "event", state: "unlinked" });
    const ids = (events: any[]) => events.map((x) => x.id);
    assert.ok(!ids((await w.get("/briefing/day?date=2026-11-11")).calendar.events).includes(E));
    const week = await w.get("/briefing/week?date=2026-11-11");
    assert.ok(!JSON.stringify(week).includes(E));
    const range = await w.get("/briefing/range?start=2026-11-09&end=2026-11-13");
    assert.ok(!JSON.stringify(range).includes(E));
    const stressed = await w.get("/meetings/stressed?start=2026-11-09&end=2026-11-13");
    assert.ok(!ids(stressed.meetings).includes(E));
    assert.equal((await w.call("/companies/exco.io/meetings?" + RANGE)).body?.meetings?.length ?? 0, 0);
    assert.equal((await w.get("/companies/search?q=exco")).companies.length, 0);
    const companies = await w.get("/companies?" + RANGE);
    assert.ok(!companies.companies.some((c: any) => c.domain === "exco.io"));
    const people = await w.get("/people?" + RANGE);
    assert.ok(!people.people.some((p: any) => p.email === "dana@exco.io"));
  });

  it("people search no longer finds someone met only in excluded meetings", async () => {
    const w = await world();
    assert.equal((await w.get("/people/search?q=dana")).people.length, 1);
    await w.set(E, { scope: "event", state: "not_joined" });
    assert.deepEqual((await w.get("/people/search?q=dana")).people, []);
    await w.set(E, { scope: "event", state: null });
    assert.equal((await w.get("/people/search?q=dana")).people.length, 1);
  });

  it("a person who is also in a meeting that still counts stays, with the right counts", async () => {
    const w = await world({ extra: [{
      id: "dana-2", start: "2026-11-12T14:00:00.000Z", end: "2026-11-12T14:30:00.000Z", title: "Dana again", people: ["dana@exco.io"], hr: 71,
    }] });
    await w.set(E, { scope: "event", state: "not_joined" });
    const people = (await w.get("/people?" + RANGE)).people.find((p: any) => p.email === "dana@exco.io");
    assert.equal(people.meetings, 1);
    const company = (await w.get("/companies?" + RANGE)).companies.find((c: any) => c.domain === "exco.io");
    assert.equal(company.meetings, 1);
    assert.equal((await w.get("/people/search?q=dana")).people.length, 1);
  });

  it("a series choice removes every meeting of the series from every route", async () => {
    const w = await world();
    await w.set(S[1], { scope: "series", state: "not_joined" });
    const absent = await world({ omit: S });
    sameAnswers(await answers(w), await answers(absent), "series");
  });

  it("a Plaud recording of an excluded meeting does not come back in its place", async () => {
    const w = await world({ twin: true });
    await w.set(E, { scope: "event", state: "not_joined" });
    const absent = await world({ omit: [E] });
    sameAnswers(await answers(w), await answers(absent), "twin");
    const events: any[] = (await w.get("/view?date=2026-11-11")).day.calendar.events;
    assert.equal(events.filter((x) => x.title === "Board prep").length, 1, "only the excluded calendar copy is listed");
    assert.equal(events.find((x) => x.title === "Board prep").excluded, true);
    assert.ok(!events.some((x) => x.id === "plaud-board" && !x.excluded));
    const board = (await w.get("/briefing/day?date=2026-11-11")).calendar.events;
    assert.ok(!board.some((x: any) => x.title === "Board prep"));
  });

  it("a Plaud twin of a meeting that still counts is still folded into the calendar copy", async () => {
    const [withTwin, without] = [await world({ twin: true }), await world()];
    const path = "/briefing/day?date=2026-11-11";
    assert.deepEqual((await withTwin.get(path)).calendar.events.map((x: any) => x.id).sort(),
      (await without.get(path)).calendar.events.map((x: any) => x.id).sort());
  });
});

describe("undo restores everything", () => {
  it("clearing an event choice gives back the exact answers from before, on every route", async () => {
    const w = await world();
    const before = await Promise.all(SAME_AS_ABSENT.map(async (p) => (await w.call(p)).text));
    await w.set(E, { scope: "event", state: "not_joined" });
    const during = await Promise.all(SAME_AS_ABSENT.map(async (p) => (await w.call(p)).text));
    assert.notDeepEqual(during, before);
    await w.set(E, { scope: "event", state: null });
    const after = await Promise.all(SAME_AS_ABSENT.map(async (p) => (await w.call(p)).text));
    assert.deepEqual(after, before);
  });

  it("clearing a series choice does the same, and 'linked' on one meeting does not leave it behind", async () => {
    const w = await world();
    const snap = async () => Promise.all(SAME_AS_ABSENT.map(async (p) => (await w.call(p)).text));
    const before = await snap();
    await w.set(S[1], { scope: "series", state: "unlinked" });
    await w.set(S[2], { scope: "event", state: "linked" });
    await w.set(S[2], { scope: "event", state: null });
    await w.set(S[1], { scope: "series", state: null });
    assert.deepEqual(await snap(), before);
  });

  it("the heart rate and scores come back too", async () => {
    const w = await world();
    const hr = async () => (await w.get("/briefing/day?date=2026-11-11")).calendar.events.find((x: any) => x.id === E)?.hrStress;
    const before = await hr();
    assert.equal(before.coverage, "ok");
    await w.set(E, { scope: "event", state: "not_joined" });
    assert.equal(await hr(), undefined);
    await w.set(E, { scope: "event", state: null });
    assert.deepEqual(await hr(), before);
  });
});

describe("ask your data", () => {
  const KEY = "sk-ant-api03-test-test-test-test-test-test-0000";
  const realFetch = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  async function context(w: World): Promise<string> {
    const env = { ...w.env, AI_KEY_SECRET: "s".repeat(40) } as any;
    await saveAiKey(env, KEY);
    let text = "";
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const req = new Request(input, init);
      text = ((await req.json()) as any).system[1].text;
      return new Response(JSON.stringify({
        id: "m", type: "message", role: "assistant", model: "claude-opus-5-5", content: [{ type: "text", text: "ok" }],
        stop_reason: "end_turn", stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 },
      }), { status: 200, headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    const res = await api.request("https://app.example/ask", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ question: "How was the week?", start: "2026-11-09", end: "2026-11-13" }),
    }, env, { waitUntil() {}, passThroughOnException() {} } as never);
    assert.equal(res.status, 200, await res.clone().text());
    return text;
  }

  it("does not hand an excluded meeting to the model, and counts the day without it", async () => {
    const present = await context(await world());
    assert.match(present, /Board prep/);
    const excluded = await world();
    await excluded.set(E, { scope: "event", state: "not_joined" });
    const withIt = await context(excluded);
    const absent = await context(await world({ omit: [E] }));
    assert.doesNotMatch(withIt, /Board prep|dana|exco/i);
    assert.equal(withIt, absent);
  });

  it("uses the effective times for meetings that stay", async () => {
    const w = await world();
    // Planning is 15:00 local for an hour. Start it half an hour early, end it half an hour late.
    await w.set("f1", { scope: "event", startUtc: "2026-11-12T19:30:00.000Z", endUtc: "2026-11-12T21:30:00.000Z" });
    const text = await context(w);
    assert.match(text, /14:30 Planning \(client, 120m\)/);
    assert.doesNotMatch(text, /15:00 Planning/);
  });
});

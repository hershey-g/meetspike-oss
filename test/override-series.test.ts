import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { answers, sameAnswers, world, type Ev } from "./override-world.ts";

const DAY = "/view?date=2026-11-10";

/** Meetings on Tue 10 Nov, 8 am local onward, each at its own time and with its own title. */
function onTuesday(ids: string[]): Ev[] {
  return ids.map((id, i) => ({
    id,
    start: new Date(Date.parse("2026-11-10T13:00:00.000Z") + i * 20 * 60_000).toISOString(),
    end: new Date(Date.parse("2026-11-10T13:15:00.000Z") + i * 20 * 60_000).toISOString(),
    title: `Odd ${i}`,
    people: [],
    hr: null,
  }));
}

const events = async (w: Awaited<ReturnType<typeof world>>, path = DAY) =>
  new Map<string, any>((await w.get(path)).day.calendar.events.map((e: any) => [e.id, e]));

describe("series ids", () => {
  const CASES: Array<[string, string | null]> = [
    // Google instance ids: the series id plus _YYYYMMDDTHHMMSSZ (timed) or _YYYYMMDD (all day).
    ["abc123_20261110T150000Z", "abc123"],
    ["abc123_20261110", "abc123"],
    ["a_b_20261110T150000Z", "a_b"],
    ["a_b_20261110", "a_b"],
    // The odd underscore ids: not series.
    ["plain", null],
    ["abc_def", null],
    ["abc_", null],
    ["abc_20261110T150000", null],
    ["abc_2026111", null],
    ["abc_202611100", null],
    ["abc_20261110T15000Z", null],
    ["abc_20261110_x", null],
    ["abc_20261110T150000Z_x", null],
    ["abc_20261110T150000Zz", null],
    ["_20261110", null],
  ];

  it("reads the series id off an instance id and nothing else, on /view", async () => {
    const w = await world({ extra: onTuesday(CASES.map(([id]) => id)) });
    const byId = await events(w);
    for (const [id, series] of CASES) {
      const e = byId.get(id);
      assert.ok(e, `${id} is listed`);
      assert.equal(e.override?.seriesId ?? null, series, id);
      assert.equal(e.override?.state ?? null, null, `${id} has no state yet`);
      assert.equal(e.override?.scope ?? null, null, id);
      assert.ok(!e.excluded, id);
    }
  });

  it("stores a series choice under series:<id> and an event choice under event:<id>", async () => {
    const w = await world({ extra: onTuesday(["abc123_20261110T150000Z", "plain"]) });
    await w.set("abc123_20261110T150000Z", { scope: "series", state: "not_joined" });
    await w.set("plain", { scope: "event", state: "unlinked" });
    assert.deepEqual(w.rows().map((r) => [r.key, r.state]), [
      ["event:plain", "unlinked"],
      ["series:abc123", "not_joined"],
    ]);
  });

  it("refuses a series choice for an id that is not part of a series, and stores nothing", async () => {
    const w = await world({ extra: onTuesday(["abc_def", "abc_20261110T150000", "plain"]) });
    for (const id of ["abc_def", "abc_20261110T150000", "plain"]) {
      const r = await w.put(id, { scope: "series", state: "not_joined" });
      assert.equal(r.status, 400, id);
      assert.doesNotMatch(r.text, /—/);
    }
    assert.deepEqual(w.rows(), []);
    const byId = await events(w);
    assert.ok([...byId.values()].every((e) => !e.excluded));
  });

  it("matches the exact series id only: a longer or shorter id sharing a prefix is left alone", async () => {
    const ids = ["abc123_20261110T150000Z", "abc123_20261110", "abc12_20261110T150000Z", "abc1234_20261110T150000Z", "abc123_20261110_x", "abc123"];
    const w = await world({ extra: onTuesday(ids) });
    await w.set("abc123_20261110T150000Z", { scope: "series", state: "not_joined" });
    const byId = await events(w);
    assert.equal(byId.get("abc123_20261110T150000Z").excluded, true);
    assert.equal(byId.get("abc123_20261110").excluded, true, "the all-day form of the same series");
    for (const id of ["abc12_20261110T150000Z", "abc1234_20261110T150000Z", "abc123_20261110_x", "abc123"]) {
      assert.ok(!byId.get(id).excluded, `${id} is not in the series`);
    }
  });
});

describe("precedence: event over series, linked opts out", () => {
  const S = ["ser1_20261109T160000Z", "ser1_20261110T160000Z", "ser1_20261111T160000Z"];
  const states = async (w: Awaited<ReturnType<typeof world>>) => {
    const out: Record<string, { excluded: boolean; state: string | null; scope: string | null }> = {};
    for (const day of ["2026-11-09", "2026-11-10", "2026-11-11"]) {
      for (const [id, e] of await events(w, `/view?date=${day}`)) {
        if (id.startsWith("ser1_")) out[id] = { excluded: Boolean(e.excluded), state: e.override?.state ?? null, scope: e.override?.scope ?? null };
      }
    }
    return out;
  };

  it("a series choice reaches every meeting of the series, on every day", async () => {
    const w = await world();
    await w.set(S[1], { scope: "series", state: "not_joined" });
    const seen = await states(w);
    for (const id of S) assert.deepEqual(seen[id], { excluded: true, state: "not_joined", scope: "series" }, id);
    const other = await events(w, "/view?date=2026-11-09");
    assert.ok(!other.get("a1").excluded, "other meetings are untouched");
    assert.equal((await events(w, "/view?date=2026-11-11")).get("b1").excluded ?? false, false);
  });

  it("an event choice wins over the series, and linked puts one meeting back", async () => {
    const withSeries = await world();
    await withSeries.set(S[1], { scope: "series", state: "not_joined" });
    await withSeries.set(S[2], { scope: "event", state: "linked" });
    const seen = await states(withSeries);
    assert.deepEqual(seen[S[0]], { excluded: true, state: "not_joined", scope: "series" });
    assert.deepEqual(seen[S[1]], { excluded: true, state: "not_joined", scope: "series" });
    assert.deepEqual(seen[S[2]], { excluded: false, state: "linked", scope: "event" });
    // The linked one counts everywhere, the others nowhere.
    const absent = await world({ omit: [S[0], S[1]] });
    sameAnswers(await answers(withSeries), await answers(absent), "series excluded, one linked");
  });

  it("an event exclusion beats a series that says linked", async () => {
    const w = await world();
    await w.set(S[0], { scope: "series", state: "linked" });
    await w.set(S[1], { scope: "event", state: "not_joined" });
    const seen = await states(w);
    assert.equal(seen[S[0]].excluded, false);
    assert.deepEqual(seen[S[1]], { excluded: true, state: "not_joined", scope: "event" });
    assert.equal(seen[S[2]].excluded, false);
  });

  it("an event state of its own wins over the series' other exclusion, and clearing it falls back to the series", async () => {
    const w = await world();
    await w.set(S[1], { scope: "series", state: "unlinked" });
    await w.set(S[1], { scope: "event", state: "not_joined" });
    assert.deepEqual((await states(w))[S[1]], { excluded: true, state: "not_joined", scope: "event" });
    await w.set(S[1], { scope: "event", state: null });
    assert.deepEqual((await states(w))[S[1]], { excluded: true, state: "unlinked", scope: "series" });
    await w.set(S[1], { scope: "series", state: null });
    assert.deepEqual((await states(w))[S[1]], { excluded: false, state: null, scope: null });
  });

  it("the event and series choices are separate: changing one leaves the other", async () => {
    const w = await world();
    await w.set(S[0], { scope: "series", state: "not_joined" });
    await w.set(S[0], { scope: "event", state: "linked" });
    await w.set(S[0], { scope: "event", state: null });
    assert.equal((await states(w))[S[0]].excluded, true, "the series choice is still there");
    assert.equal(w.row("series:ser1")?.state, "not_joined");
  });
});

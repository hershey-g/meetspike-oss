// Regenerates shared/MeetspikeHRCore/Tests/MeetspikeHRCoreTests/Fixtures/override-parity.json from the Worker's own
// effectiveTimes and seriesIdOf (src/lib/meeting-override.ts). Keeps every existing input in order and appends the cases
// around the seen-time limits (H2 of fix9c.md). Run: node --experimental-strip-types test/fixtures/gen-override-parity.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dirname, "..", "..");
const { effectiveTimes, seriesIdOf } = await import(join(root, "src/lib/meeting-override.ts"));
const path = join(root, "shared/MeetspikeHRCore/Tests/MeetspikeHRCoreTests/Fixtures/override-parity.json");
const old = JSON.parse(readFileSync(path, "utf8"));
const ORIGINAL = Number(process.env.ORIGINAL_CASES ?? 544);

const iso = (ms) => new Date(ms).toISOString();
const ms = (s) => Date.parse(s);
const none = { startUtc: null, endUtc: null, seenStartUtc: null, seenEndUtc: null };
const added = [];
const add = (cal, chosen) => added.push({ cal, chosen: { ...none, ...chosen } });
const MIN = 60_000;
const H = 3_600_000;

// The seen rule: a seen value counts only inside [calendar start - 15 min, calendar end + 4 h], both inclusive.
const CAL = { startUtc: "2026-11-25T14:00:00.000Z", endUtc: "2026-11-25T15:00:00.000Z" };
const cs = ms(CAL.startUtc);
const ce = ms(CAL.endUtc);
for (const d of [-16 * MIN, -15 * MIN - 1000, -15 * MIN - 1, -15 * MIN, -15 * MIN + 1, -14 * MIN - 1000, -14 * MIN, 0, MIN]) {
  add(CAL, { seenStartUtc: iso(cs + d) });
  add(CAL, { seenStartUtc: iso(cs + d), seenEndUtc: iso(ce - 10 * MIN) });
  add(CAL, { seenStartUtc: iso(cs + d), seenEndUtc: iso(ce + 4 * H) });
}
for (const d of [0, -MIN, H, 4 * H - 1000, 4 * H - 1, 4 * H, 4 * H + 1, 4 * H + 1000, 5 * H]) {
  add(CAL, { seenEndUtc: iso(ce + d) });
  add(CAL, { seenStartUtc: iso(cs + 5 * MIN), seenEndUtc: iso(ce + d) });
}
// The review's case: the calendar moved to 16:00, the Mac's report is from the old time.
const MOVED = { startUtc: "2026-11-25T16:00:00.000Z", endUtc: "2026-11-25T17:00:00.000Z" };
add(MOVED, { seenStartUtc: "2026-11-25T15:02:00.000Z", seenEndUtc: "2026-11-25T15:55:00.000Z" });
add(MOVED, { seenStartUtc: "2026-11-25T15:44:59.000Z", seenEndUtc: "2026-11-25T16:40:00.000Z" });
add(MOVED, { seenStartUtc: "2026-11-25T15:45:00.000Z", seenEndUtc: "2026-11-25T16:40:00.000Z" });
add(MOVED, { seenStartUtc: "2026-11-25T15:02:00.000Z", seenEndUtc: "2026-11-25T16:40:00.000Z" });
add(MOVED, { seenStartUtc: "2026-11-25T16:07:00.000Z", seenEndUtc: "2026-11-25T15:55:00.000Z" });
// A seen end before the calendar window opens, with and without a seen start.
add(CAL, { seenStartUtc: iso(cs - 15 * MIN), seenEndUtc: iso(cs - 20 * MIN) });
add(CAL, { seenStartUtc: iso(cs - 20 * MIN), seenEndUtc: iso(cs - 10 * MIN) });
// The person's own times keep the old limits (2 h early, 4 h late), whatever was seen.
for (const d of [-2 * H - 1000, -2 * H, -2 * H + 1000, -H]) {
  add(CAL, { startUtc: iso(cs + d) });
  add(CAL, { startUtc: iso(cs + d), seenStartUtc: iso(cs - 10 * MIN), seenEndUtc: iso(ce + H) });
}
for (const d of [4 * H - 1000, 4 * H, 4 * H + 1000]) {
  add(CAL, { endUtc: iso(ce + d) });
  add(CAL, { endUtc: iso(ce + d), seenStartUtc: iso(cs + MIN), seenEndUtc: iso(ce + H) });
}
// The person's time next to a seen time that is out of range: the person's time stands alone.
add(CAL, { startUtc: iso(cs - 30 * MIN), seenStartUtc: iso(cs - 20 * MIN), seenEndUtc: iso(ce + 5 * H) });
add(CAL, { startUtc: iso(cs - 30 * MIN), endUtc: iso(ce + 30 * MIN), seenStartUtc: iso(cs - 16 * MIN), seenEndUtc: iso(ce + 4 * H + 1) });

// The OTHER side of the window: a seen END before calendar start - 15 min is ignored too (seenTimeFits checks both bounds
// for both values). The owner starts 2 h early, so a seen end below the seen-start limit would otherwise form a pair.
for (const d of [-H, -30 * MIN, -15 * MIN - 1000, -15 * MIN - 1, -15 * MIN, -15 * MIN + 1, -15 * MIN + 1000, -10 * MIN]) {
  add(CAL, { startUtc: iso(cs - 2 * H), seenEndUtc: iso(cs + d) });
  add(CAL, { startUtc: iso(cs - 2 * H), seenStartUtc: iso(cs - 15 * MIN), seenEndUtc: iso(cs + d) });
  add(CAL, { startUtc: iso(cs - 2 * H), endUtc: iso(ce), seenEndUtc: iso(cs + d) });
}
// A seen START after calendar end + 4 h is ignored too, with the owner's end absent, late or on the calendar.
for (const d of [4 * H - 1000, 4 * H - 1, 4 * H, 4 * H + 1, 4 * H + 1000, 6 * H]) {
  add(CAL, { seenStartUtc: iso(ce + d) });
  add(CAL, { endUtc: iso(ce + 4 * H), seenStartUtc: iso(ce + d) });
  add(CAL, { endUtc: iso(ce + H), seenStartUtc: iso(ce + d), seenEndUtc: iso(ce + 4 * H) });
  add(CAL, { startUtc: iso(cs - H), seenStartUtc: iso(ce + d) });
}
// A seen start past the calendar end but inside the limit (the end then comes from a later seen end or none).
add(CAL, { seenStartUtc: iso(ce + 10 * MIN), seenEndUtc: iso(ce + 50 * MIN) });
add(CAL, { seenStartUtc: iso(ce + 10 * MIN) });

const inputs = [...old.effective.slice(0, ORIGINAL).map((c) => ({ cal: c.cal, chosen: c.chosen })), ...added];
const rows = inputs.map(({ cal, chosen }) => {
  const { startUtc, endUtc } = effectiveTimes(cal, chosen);
  return { cal, chosen, expect: { startUtc, endUtc } };
});
const seriesIds = old.seriesIds.map((s) => ({ id: s.id, seriesId: seriesIdOf(s.id) ?? null }));

const generatedBy = `node --experimental-strip-types test/fixtures/gen-override-parity.mjs: effectiveTimes and seriesIdOf from src/lib/meeting-override.ts at test/build9f-fix (feat/build9-followup 6e9acf1 plus the H2 seen rule: seen values count only inside [calendar start - 15 min, calendar end + 4 h]). Regenerate with the same two calls if the Worker rules change. The first ${ORIGINAL} cases are the original inputs, the rest are the H2 limit cases.`;
const out = `{"generatedBy":${JSON.stringify(generatedBy)},"effective":[\n${rows.map((r) => JSON.stringify(r)).join(",\n")}],\n"seriesIds":[\n${seriesIds.map((r) => JSON.stringify(r)).join(",\n")}]}\n`;
writeFileSync(path, out);
const changed = rows.slice(0, ORIGINAL).filter((r, i) => JSON.stringify(r.expect) !== JSON.stringify(old.effective[i].expect)).length;
console.log(JSON.stringify({ oldCases: old.effective.length, added: added.length, total: rows.length, oldAnswersChanged: changed, seriesIds: seriesIds.length }));

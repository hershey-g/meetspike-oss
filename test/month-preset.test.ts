import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
// @ts-expect-error — browser module, plain JS on purpose.
import { addDays, presetRange } from "../public/range-presets.js";

describe("“This month” preset", () => {
  it("runs from the 1st to today, not to the last day of the month", () => {
    assert.deepEqual(presetRange("month", "2026-11-17"), { start: "2026-11-01", end: "2026-11-17" });
    assert.notEqual(presetRange("month", "2026-11-17").end, "2026-11-30");
  });

  it("never includes a day after today, whatever the month", () => {
    for (const today of ["2026-01-31", "2026-02-10", "2028-02-29", "2026-12-05", "2026-12-31", "2027-01-01"]) {
      const r = presetRange("month", today);
      assert.equal(r.end, today, today);
      assert.equal(r.start, `${today.slice(0, 7)}-01`, today);
      assert.ok(r.start <= r.end, today);
    }
  });

  it("is a single day on the 1st of the month", () => {
    assert.deepEqual(presetRange("month", "2026-12-01"), { start: "2026-12-01", end: "2026-12-01" });
  });

  it("leaves the other presets as they were", () => {
    assert.deepEqual(presetRange("7d", "2026-11-17"), { start: "2026-11-11", end: "2026-11-17" });
    assert.deepEqual(presetRange("7d", "2026-11-03"), { start: "2026-10-28", end: "2026-11-03" });
    assert.deepEqual(presetRange("day", "2026-11-17"), { start: "2026-11-17", end: "2026-11-17" });
    assert.equal(addDays("2026-12-31", 1), "2027-01-01");
  });

  it("is what the date picker actually uses", () => {
    const src = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");
    assert.match(src, /from "\.\/range-presets\.js"/);
    assert.match(src, /presetRange\("month", today\)/);
  });
});

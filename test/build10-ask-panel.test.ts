/**
 * Build 10 acceptance tests, web side (spec section F): the pure parts of public/ask-logic.js.
 *
 * Names the builder must export from public/ask-logic.js (same copy as the iPhone):
 *   rangeLine(range)                 -> "Ranking Nov 1 to Nov 25, compared with all history"
 *                                       or "Using all history, Jan 3 to Nov 25"; "" (falsy) when the range is unknown
 *                                       range = {start, end, baselineStart, baselineEnd, rangeSource?}, days as YYYY-MM-DD
 *   headerText(scope, allTime)       -> "Ranking all history" | "Ranking <scope.label>, compared with all history" | "Using all history"
 *                                       (scopeLabel goes; the existing tests now call headerText)
 *   askBody({question, history, sourceDisplay, scope, allTime, ignorePeriod})
 *                                    -> the JSON object POSTed to /api/ask/stream. start/end come from scope when there is one;
 *                                       allTime and ignorePeriod are present only when exactly true
 *   applyAskEvent(item, {event: "range", data})  returns "range" and sets item.range = {start, end, baselineStart, baselineEnd, ...};
 *                                       a `done` carrying all four fields sets it too; a `done` without them never clears it;
 *                                       a range event with a missing or non-day start/end is ignored (returns null)
 *   SUGGESTIONS                      has 4 items, the second is "Which meetings cost me the most, all time?"
 *   md(text)                         tables with 4+ columns render as a label/value list, not a <table>; 1 to 3 columns stay a <table>
 * public/ask-panel.css: no sideways scroll on answer tables.
 *
 * The panel's DOM (the All time pill, the range line under answers, "Ask over all time", retry keeping its settings) is not
 * testable without a browser; the lead's Playwright pass covers it.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { SUGGESTIONS, applyAskEvent, createScopeHolder, md } from "../public/ask-logic.js";
import * as askLogic from "../public/ask-logic.js";

// Reached through the namespace so a missing export fails the test that needs it, not the whole file.
const L = askLogic as Record<string, any>;
function fn(name: string): (...args: any[]) => any {
  assert.equal(typeof L[name], "function", `public/ask-logic.js exports ${name}`);
  return L[name];
}
const rangeLine = (range: unknown): string => fn("rangeLine")(range);
const headerText = (scope: unknown, allTime: boolean): string => fn("headerText")(scope, allTime);
const askBody = (opts: Record<string, unknown>): Record<string, any> => fn("askBody")(opts);

const RANGE = { start: "2026-11-01", end: "2026-11-25", baselineStart: "2026-01-03", baselineEnd: "2026-11-25", rangeSource: "question" };
const SOURCE = { oura: true, whoop: false };
const HISTORY = [{ role: "user", content: "How was this month?" }, { role: "assistant", content: "Busy." }];

describe("web: range line", () => {
  it("says what was ranked when it is smaller than all history", () => {
    assert.equal(rangeLine(RANGE), "Ranking Nov 1 to Nov 25, compared with all history");
    assert.equal(
      rangeLine({ ...RANGE, start: "2026-11-24", end: "2026-11-24" }),
      "Ranking Nov 24, compared with all history",
    );
    // Same history start, earlier end: still smaller than all history.
    assert.equal(
      rangeLine({ ...RANGE, start: "2026-01-03", end: "2026-10-31" }),
      "Ranking Jan 3 to Oct 31, compared with all history",
    );
  });

  it("says all history was used when the ranked dates cover it", () => {
    assert.equal(
      rangeLine({ ...RANGE, start: "2026-01-03", end: "2026-11-25", rangeSource: "allTime" }),
      "Using all history, Jan 3 to Nov 25",
    );
  });

  it("adds the year when the ends are in different years", () => {
    assert.equal(
      rangeLine({ start: "2025-12-30", end: "2026-01-02", baselineStart: "2024-03-01", baselineEnd: "2026-01-02" }),
      "Ranking Dec 30, 2025 to Jan 2, 2026, compared with all history",
    );
    assert.equal(
      rangeLine({ start: "2025-03-01", end: "2026-11-25", baselineStart: "2025-03-01", baselineEnd: "2026-11-25" }),
      "Using all history, Mar 1, 2025 to Nov 25, 2026",
    );
  });

  it("is empty when the range is not known, so an older Worker shows no line", () => {
    for (const bad of [null, undefined, {}, { start: "2026-11-01" }, { start: "tomorrow", end: "2026-11-25", baselineStart: "2026-01-03", baselineEnd: "2026-11-25" }]) {
      assert.ok(!rangeLine(bad), JSON.stringify(bad));
    }
  });

  it("has no em dashes", () => {
    assert.ok(!rangeLine(RANGE).includes("—"));
  });
});

describe("web: header text", () => {
  const scope = () => {
    const holder = createScopeHolder(() => ({ start: "2026-10-01", end: "2026-10-14", label: "Oct 1 to Oct 14" }));
    return holder.capture();
  };

  it("names the scope and says it is compared with all history", () => {
    assert.equal(headerText(scope(), false), "Ranking Oct 1 to Oct 14, compared with all history");
  });
  it("says all history is ranked when All time is on", () => {
    assert.equal(headerText(scope(), true), "Ranking all history");
    assert.equal(headerText(null, true), "Ranking all history");
  });
  it("says all history is used when there is no scope", () => {
    assert.equal(headerText(null, false), "Using all history");
    assert.equal(headerText(undefined, false), "Using all history");
  });
});

describe("web: question body", () => {
  const base = { question: "Which day cost me most?", history: HISTORY, sourceDisplay: SOURCE };
  const scope = { start: "2026-10-01", end: "2026-10-14", label: "Oct 1 to Oct 14" };

  it("sends the question, history, source setting and the scope's dates, and nothing else by default", () => {
    assert.deepEqual(askBody({ ...base, scope }), {
      question: "Which day cost me most?", history: HISTORY, sourceDisplay: SOURCE, start: "2026-10-01", end: "2026-10-14",
    });
  });

  it("sends no dates when there is no scope", () => {
    const body = askBody({ ...base, scope: null });
    assert.equal("start" in body, false);
    assert.equal("end" in body, false);
    assert.equal(body.question, base.question);
  });

  it("sends allTime and ignorePeriod only when they are exactly true", () => {
    const off = askBody({ ...base, scope, allTime: false, ignorePeriod: false });
    assert.equal("allTime" in off, false);
    assert.equal("ignorePeriod" in off, false);
    const unset = askBody({ ...base, scope });
    assert.equal("allTime" in unset, false);
    assert.equal("ignorePeriod" in unset, false);
    for (const odd of ["true", 1, "yes", {}]) {
      const body = askBody({ ...base, scope, allTime: odd, ignorePeriod: odd });
      assert.equal("allTime" in body, false, JSON.stringify(odd));
      assert.equal("ignorePeriod" in body, false, JSON.stringify(odd));
    }
    const on = askBody({ ...base, scope, allTime: true });
    assert.equal(on.allTime, true);
    assert.equal("ignorePeriod" in on, false);
    // "Ask over all time": the same question again, all time on, the question's own period skipped.
    const again = askBody({ ...base, scope, allTime: true, ignorePeriod: true });
    assert.equal(again.allTime, true);
    assert.equal(again.ignorePeriod, true);
    assert.equal(again.question, base.question, "the question goes unchanged");
  });

  it("can be sent as JSON", () => {
    const text = JSON.stringify(askBody({ ...base, scope, allTime: true }));
    assert.deepEqual(JSON.parse(text).sourceDisplay, SOURCE);
  });
});

describe("web: range event", () => {
  const fresh = () => ({ role: "assistant", content: "", steps: [] as unknown[] }) as Record<string, any>;
  const data = { start: "2026-11-01", end: "2026-11-25", baselineStart: "2026-01-03", baselineEnd: "2026-11-25", rangeSource: "question" };

  it("a range event sets the answer's range, which makes the line under it", () => {
    const item = fresh();
    assert.equal(applyAskEvent(item, { event: "range", data }), "range");
    assert.equal(item.range.start, "2026-11-01");
    assert.equal(item.range.end, "2026-11-25");
    assert.equal(item.range.baselineStart, "2026-01-03");
    assert.equal(item.range.baselineEnd, "2026-11-25");
    assert.equal(rangeLine(item.range), "Ranking Nov 1 to Nov 25, compared with all history");
  });

  it("is not terminal and does not disturb steps or text", () => {
    const item = fresh();
    applyAskEvent(item, { event: "range", data });
    applyAskEvent(item, { event: "text", data: { delta: "Hi" } });
    applyAskEvent(item, { event: "step", data: { id: "calendar", label: "Read 3 meetings", status: "done" } });
    assert.equal(item.content, "Hi");
    assert.equal(item.steps.length, 1);
    assert.ok(item.range);
  });

  it("ignores a range with a missing or non-day start or end", () => {
    for (const bad of [{}, { ...data, start: undefined }, { ...data, end: "tomorrow" }, { ...data, start: "" }, { ...data, end: "2026-13-45" }, "nope", null]) {
      const item = fresh();
      assert.equal(applyAskEvent(item, { event: "range", data: bad }), null, JSON.stringify(bad));
      assert.equal(item.range, undefined, JSON.stringify(bad));
    }
  });

  it("a done with the range fields sets it, and a done without them never clears it", () => {
    const viaDone = fresh();
    assert.equal(applyAskEvent(viaDone, { event: "done", data: { truncated: false, model: "m", ...data } }), "done");
    assert.equal(viaDone.range.baselineStart, "2026-01-03");

    const kept = fresh();
    applyAskEvent(kept, { event: "range", data });
    applyAskEvent(kept, { event: "done", data: { truncated: false, start: "2026-11-01", end: "2026-11-25" } });
    assert.ok(kept.range, "an older Worker's done has no baseline fields");
    assert.equal(kept.range.start, "2026-11-01");
    assert.equal(kept.range.baselineStart, "2026-01-03");
  });

  it("an older Worker never sends a range, so there is no line and no button", () => {
    const item = fresh();
    applyAskEvent(item, { event: "text", data: { delta: "Hi" } });
    applyAskEvent(item, { event: "done", data: { truncated: false, start: "2026-11-01", end: "2026-11-25" } });
    assert.equal(item.range, undefined);
    assert.ok(!rangeLine(item.range));
  });
});

describe("web: suggestions", () => {
  it("has four, with the all-time question second", () => {
    assert.equal(SUGGESTIONS.length, 4);
    assert.equal(SUGGESTIONS[1], "Which meetings cost me the most, all time?");
    assert.equal(SUGGESTIONS[0], "Which meetings cost me the most this month?");
    assert.ok(SUGGESTIONS.every((s: string) => !s.includes("—")));
  });
});

describe("web: wide tables", () => {
  const wide = [
    "| Day | Meetings | Recovery | Sleep |",
    "|---|---|---|---|",
    "| Nov 10 | CELL-A1 | CELL-B1 | CELL-C1 |",
    "| Nov 12 | CELL-A2 | CELL-B2 | CELL-C2 |",
  ].join("\n");

  it("renders four or more columns as a label and value list, not a table", () => {
    const html = md(wide);
    assert.doesNotMatch(html, /<table|<thead|<th|<td/);
    for (const label of ["Day", "Meetings", "Recovery", "Sleep"]) {
      assert.equal(html.split(label).length - 1, 2, `${label} is shown once per row`);
    }
    for (const value of ["Nov 10", "CELL-A1", "CELL-B1", "CELL-C1", "Nov 12", "CELL-A2", "CELL-B2", "CELL-C2"]) {
      assert.ok(html.includes(value), value);
    }
    // The first row comes before the second, and in it each value follows its own label.
    const row = html.slice(html.indexOf("Nov 10"), html.indexOf("Nov 12"));
    const at = (s: string) => row.indexOf(s);
    assert.ok(at("Meetings") >= 0 && at("Meetings") < at("CELL-A1"), row);
    assert.ok(at("CELL-A1") < at("Recovery") && at("Recovery") < at("CELL-B1"), row);
    assert.ok(at("CELL-B1") < at("Sleep") && at("Sleep") < at("CELL-C1"), row);
    assert.ok(html.indexOf("CELL-C1") < html.indexOf("Nov 12"));
  });

  it("keeps one to three columns as a table, exactly as before", () => {
    const three = md("| Day | Meetings | Recovery |\n|---|---|---|\n| Nov 10 | 6 | 31% |");
    assert.equal(
      three,
      "<table><thead><tr><th>Day</th><th>Meetings</th><th>Recovery</th></tr></thead><tbody><tr><td>Nov 10</td><td>6</td><td>31%</td></tr></tbody></table>",
    );
    assert.match(md("| a |\n|---|\n| b |"), /<table>/);
  });

  it("skips a blank value and a cell a short row does not have", () => {
    const html = md("| Day | Meetings | Recovery | Sleep |\n|---|---|---|---|\n| Nov 10 |  | CELL-B | CELL-C |\n| Nov 12 | CELL-A |");
    assert.doesNotMatch(html, /<table/);
    assert.equal(html.split("Meetings").length - 1, 1, "the blank value drops its label");
    assert.equal(html.split("Recovery").length - 1, 1, "the missing cell drops its label");
    assert.equal(html.split("Sleep").length - 1, 1);
    assert.ok(html.includes("CELL-A") && html.includes("CELL-B") && html.includes("CELL-C"));
  });

  it("escapes HTML in labels and values, and keeps bold", () => {
    const html = md("| <b>x</b> | B | C | D |\n|---|---|---|---|\n| <img src=x onerror=1> | **bold** | 3 | 4 |");
    assert.doesNotMatch(html, /<table/);
    assert.doesNotMatch(html, /<img|<b>/);
    assert.match(html, /&lt;img/);
    assert.match(html, /&lt;b&gt;x&lt;\/b&gt;/);
    assert.match(html, /<strong>bold<\/strong>/);
  });

  it("does not throw on a half-streamed wide table", () => {
    assert.doesNotThrow(() => md("| a | b | c | d |"));
    assert.doesNotThrow(() => md("| a | b | c | d |\n|---|---|---|---|"));
    assert.doesNotThrow(() => md("| a | b | c | d |\n|---|---|---|---|\n| 1 | 2"));
  });

  it("leaves paragraphs and bullets around a wide table alone", () => {
    const html = md(`Intro\n\n${wide}\n\n- after`);
    assert.match(html, /^<p>Intro<\/p>/);
    assert.match(html, /<ul><li>after<\/li><\/ul>$/);
  });
});

describe("web: answer tables fit the panel", () => {
  it("has no sideways scroll on tables, and lets them fill the panel width", () => {
    const css = readFileSync("public/ask-panel.css", "utf8");
    const rules = [...css.matchAll(/([^{}]*)\{([^}]*)\}/g)].map((m) => ({ selector: m[1].trim(), body: m[2] }));
    const tableRules = rules.filter((r) => /\btable\b|\bth\b|\btd\b/.test(r.selector));
    assert.ok(tableRules.length > 0, "answer tables are styled");
    for (const r of tableRules) {
      assert.doesNotMatch(r.body, /overflow-x\s*:\s*(auto|scroll)/, `${r.selector} scrolls sideways`);
    }
    assert.ok(
      tableRules.some((r) => /table-layout\s*:\s*fixed|width\s*:\s*100%/.test(r.body)),
      "a table rule makes the table fit the width",
    );
  });
});

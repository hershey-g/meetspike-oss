import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
// @ts-expect-error — browser module, plain JS on purpose.
import { addDays, presetRange } from "../public/range-presets.js";

// public/app.js runs the whole app on import (document listeners, fetches), so it cannot be imported in node.
// Instead this pulls the real source of renderPicker and the helpers it uses out of the file and runs them
// against a tiny DOM stub. app.js is an ES module, so an undeclared identifier throws ReferenceError, exactly
// as it does in the browser. Regression: renderPicker used an undeclared `tooLong`, so the picker never opened.

const source = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");

function extractFunction(name: string): string {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `public/app.js no longer defines ${name}()`);
  let depth = 0;
  let seen = false;
  for (let i = source.indexOf("{", source.indexOf(")", start)); i < source.length; i++) {
    const ch = source[i];
    if (ch === "{") {
      depth++;
      seen = true;
    } else if (ch === "}") {
      depth--;
      if (seen && depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`could not find the end of ${name}()`);
}

const MONTHS_LINE = source.split("\n").find((line) => line.startsWith("const MONTHS = "));

const HELPERS = ["fmtDay", "shortDay", "rangeLabel", "spanDays", "plural", "esc", "shiftMonth"];

interface Picker {
  start: string | null;
  end: string | null;
  month: string;
  editing: "start" | "end" | null;
}

function renderPickerHtml(picker: Picker, today = "2026-11-24"): string {
  assert.ok(MONTHS_LINE, "public/app.js no longer defines MONTHS");
  const sheet = { innerHTML: "" };
  const body = `
    "use strict";
    const TZ = "America/New_York";
    const todayET = () => ${JSON.stringify(today)};
    const qs = () => sheet;
    const state = { picker };
    ${MONTHS_LINE}
    ${HELPERS.map(extractFunction).join("\n")}
    ${extractFunction("renderPicker")}
    renderPicker();
  `;
  new Function("sheet", "picker", "addDays", "presetRange", body)(sheet, picker, addDays, presetRange);
  return sheet.innerHTML;
}

function applyButton(html: string): { text: string; disabled: boolean } {
  const match = html.match(/<button[^>]*data-action="pk-apply"([^>]*)>([^<]*)<\/button>/);
  assert.ok(match, "no apply button");
  return { text: match[2].trim(), disabled: /\bdisabled\b/.test(match[1]) };
}

describe("date picker: renderPicker does not throw", () => {
  it("opens on a single day (what the Today tab hands it)", () => {
    const html = renderPickerHtml({ start: "2026-11-24", end: "2026-11-24", month: "2026-11", editing: null });
    assert.match(html, /Pick dates/);
    assert.match(html, /November 2026/);
  });

  it("opens on a multi-day range", () => {
    const html = renderPickerHtml({ start: "2026-11-10", end: "2026-11-16", month: "2026-11", editing: null });
    assert.match(html, /data-pick="2026-11-10"/);
    assert.match(html, /data-pick="2026-11-16"/);
  });

  it("opens with nothing picked yet and with only a start picked", () => {
    assert.doesNotThrow(() => renderPickerHtml({ start: null, end: null, month: "2026-11", editing: null }));
    assert.doesNotThrow(() => renderPickerHtml({ start: "2026-11-03", end: null, month: "2026-11", editing: "end" }));
  });
});

describe("date picker: the apply button and note", () => {
  it("no start: apply is disabled and asks for an end date", () => {
    const html = renderPickerHtml({ start: null, end: null, month: "2026-11", editing: null });
    assert.deepEqual(applyButton(html), { text: "Pick an end date", disabled: true });
    assert.match(html, /Tap a start day, then an end day\./);
  });

  it("start only: apply stays disabled and the note says to tap the end", () => {
    const html = renderPickerHtml({ start: "2026-11-03", end: null, month: "2026-11", editing: "end" });
    assert.deepEqual(applyButton(html), { text: "Pick an end date", disabled: true });
    assert.match(html, /Now tap the end day\./);
  });

  it("one day: apply is enabled and names the day", () => {
    const html = renderPickerHtml({ start: "2026-11-05", end: "2026-11-05", month: "2026-11", editing: null });
    assert.deepEqual(applyButton(html), { text: "Show Nov 5", disabled: false });
    assert.match(html, /Nov 5 · 1 day</);
  });

  it("a range: apply is enabled and counts the days", () => {
    const html = renderPickerHtml({ start: "2026-11-10", end: "2026-11-16", month: "2026-11", editing: null });
    assert.deepEqual(applyButton(html), { text: "Show 7 days", disabled: false });
    assert.match(html, /Nov 10 – Nov 16 · 7 days/);
  });

  it("a long range is not blocked (the 92 day cap was removed in the People ranges release)", () => {
    const html = renderPickerHtml({ start: "2026-01-01", end: "2026-11-24", month: "2026-11", editing: null });
    const apply = applyButton(html);
    assert.equal(apply.disabled, false);
    assert.equal(apply.text, "Show 328 days");
    assert.doesNotMatch(html, /Too many days/);
    assert.doesNotMatch(html, /pick-note bad/);
  });
});

describe("date picker: calendar and chips still render", () => {
  it("disables future days and marks today", () => {
    const html = renderPickerHtml({ start: "2026-11-24", end: "2026-11-24", month: "2026-11", editing: null });
    assert.match(html, /data-pick="2026-11-25" disabled/);
    assert.doesNotMatch(html, /data-pick="2026-11-24" disabled/);
    assert.match(html, /class="(today sel|sel today)"[^>]*data-pick="2026-11-24"/);
  });

  it("offers the six quick chips with exact ranges", () => {
    const html = renderPickerHtml({ start: "2026-11-24", end: "2026-11-24", month: "2026-11", editing: null });
    const chips = [...html.matchAll(/data-quick="([^"]+)">([^<]+)<\/button>/g)].map((m) => [m[2], m[1]]);
    assert.deepEqual(chips, [
      ["Today", "2026-11-24|2026-11-24"],
      ["Yesterday", "2026-11-23|2026-11-23"],
      ["Last 7 days", "2026-11-18|2026-11-24"],
      ["Last 30 days", "2026-10-26|2026-11-24"],
      ["This month", "2026-11-01|2026-11-24"],
      ["Last month", "2026-10-01|2026-10-31"],
    ]);
  });

  it("Last month crosses a year boundary", () => {
    const html = renderPickerHtml({ start: "2026-01-15", end: "2026-01-15", month: "2026-01", editing: null }, "2026-01-15");
    assert.match(html, /data-quick="2025-12-01\|2025-12-31">Last month/);
  });

  it("the next month arrow is disabled on the current month", () => {
    const html = renderPickerHtml({ start: "2026-11-24", end: "2026-11-24", month: "2026-11", editing: null });
    assert.match(html, /data-month="1"[^>]*disabled/);
  });
});

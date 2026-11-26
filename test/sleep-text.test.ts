import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

// Regression: the sleep ring note showed "7 h 60 m" for 28790 s because minutes were rounded after hours were
// split off. public/app.js runs the whole app on import, so (like date-picker.test.ts) this pulls the real source
// out of the file. The sleep note is an inline template literal in renderToday (the `note:` line that reads
// totalSleepS); if it is moved into a function named sleepText, sleepNote or sleepLabel, that function is used.

const source = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");

function extractFunction(name: string): string | null {
  const start = source.indexOf(`function ${name}(`);
  if (start === -1) return null;
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
  return null;
}

/** Returns the text the sleep ring would show for `seconds` of sleep, running the real app.js code. */
function sleepNote(seconds: number): string {
  for (const name of ["sleepText", "sleepNote", "sleepLabel"]) {
    const fn = extractFunction(name);
    if (fn) return new Function(`"use strict"; ${fn}; return ${name}(${seconds});`)() as string;
  }
  const line = source.split("\n").find((l) => l.includes("morning?.totalSleepS") && l.includes("note:"));
  assert.ok(line, "public/app.js no longer has the sleep ring note (looked for a `note:` line using totalSleepS)");
  const match = line.match(/note:\s*morning\?\.totalSleepS\s*\?\s*(`[^`]*`)\s*:\s*("[^"]*")/);
  assert.ok(match, `could not read the sleep note expression from: ${line.trim()}`);
  return new Function("morning", `"use strict"; return morning?.totalSleepS ? ${match[1]} : ${match[2]};`)({
    totalSleepS: seconds,
  }) as string;
}

describe("sleep ring text", () => {
  it("never says 60 minutes: 28790 s is 8 h 0 m", () => {
    assert.equal(sleepNote(28790), "8 h 0 m");
  });

  it("rounds the total minutes, then splits hours and minutes", () => {
    assert.equal(sleepNote(3570), "1 h 0 m"); // 59.5 min
    assert.equal(sleepNote(86370), "24 h 0 m");
    assert.equal(sleepNote(26970), "7 h 30 m"); // 449.5 min
    assert.equal(sleepNote(26969), "7 h 29 m"); // 449.48 min
  });

  it("keeps the format for normal values", () => {
    assert.equal(sleepNote(27000), "7 h 30 m");
    assert.equal(sleepNote(28800), "8 h 0 m");
    assert.equal(sleepNote(23460), "6 h 31 m");
    assert.equal(sleepNote(1800), "0 h 30 m");
  });

  it("has no 60 minute text for any sleep length", () => {
    for (let s = 1; s <= 40_000; s += 7) {
      const text = sleepNote(s);
      assert.doesNotMatch(text, / 60 m$/, `${s} s gave ${text}`);
      const total = Math.round(s / 60);
      assert.equal(text, `${Math.floor(total / 60)} h ${total % 60} m`, `${s} s`);
    }
  });
});

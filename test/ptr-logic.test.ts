import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import {
  MAX_PULL,
  PULL_TABS,
  THRESHOLD,
  canStartPull,
  lockDirection,
  pullOffset,
  pullProgress,
  shouldRefresh,
} from "../public/ptr-logic.js";

const base = { standalone: true, tab: "today", scrollTop: 0 };

describe("pull to refresh: when a pull may start", () => {
  it("installed app, main screen, at the top", () => {
    for (const tab of ["today", "dates", "people", "person"]) assert.equal(canStartPull({ ...base, tab }), true, tab);
    assert.deepEqual(PULL_TABS, ["today", "dates", "people", "person"]);
  });

  it("never in a browser tab (the browser has its own)", () => {
    assert.equal(canStartPull({ ...base, standalone: false }), false);
  });

  it("not on Ask or More", () => {
    assert.equal(canStartPull({ ...base, tab: "ask" }), false);
    assert.equal(canStartPull({ ...base, tab: "more" }), false);
  });

  it("not while scrolled down, even by a pixel", () => {
    assert.equal(canStartPull({ ...base, scrollTop: 1 }), false);
    assert.equal(canStartPull({ ...base, scrollTop: 600 }), false);
  });

  it("not with the picker or install sheet open, a field focused, two fingers, or a refresh running", () => {
    assert.equal(canStartPull({ ...base, pickerOpen: true }), false);
    assert.equal(canStartPull({ ...base, sheetOpen: true }), false);
    assert.equal(canStartPull({ ...base, inputFocused: true }), false);
    assert.equal(canStartPull({ ...base, touches: 2 }), false);
    assert.equal(canStartPull({ ...base, refreshing: true }), false);
  });
});

describe("pull to refresh: gesture", () => {
  it("locks to a pull only for a mostly-downward move past the slop", () => {
    assert.equal(lockDirection(2, 5), null);
    assert.equal(lockDirection(3, 20), "pull");
    assert.equal(lockDirection(20, 20), "pull");
    assert.equal(lockDirection(30, 10), "cancel", "sideways: the date chips scroll");
    assert.equal(lockDirection(0, -20), "cancel", "upward: a normal scroll");
  });

  it("rubber-bands: grows with the finger, never past MAX_PULL, zero for upward moves", () => {
    assert.equal(pullOffset(0), 0);
    assert.equal(pullOffset(-50), 0);
    assert.equal(pullOffset(Number.NaN), 0);
    let prev = 0;
    for (const dy of [10, 40, 80, 120, 200, 400, 2000]) {
      const o = pullOffset(dy);
      assert.ok(o > prev && o < dy && o <= MAX_PULL, `dy=${dy} → ${o}`);
      prev = o;
    }
  });

  it("a short tug does not refresh; about 105px of finger travel does", () => {
    assert.equal(shouldRefresh(pullOffset(60)), false);
    assert.equal(shouldRefresh(pullOffset(110)), true);
    assert.equal(shouldRefresh(THRESHOLD), true);
    assert.equal(pullProgress(0), 0);
    assert.equal(pullProgress(THRESHOLD / 2), 0.5);
    assert.equal(pullProgress(THRESHOLD * 3), 1);
  });
});

describe("pull to refresh: wiring", () => {
  const pub = new URL("../public/", import.meta.url);
  const read = (f: string) => readFileSync(new URL(f, pub), "utf8");

  it("app.js refreshes update, calendar and screen data, with no new endpoints", () => {
    const app = read("app.js");
    assert.match(app, /initPullToRefresh\(\{ enabled: isInstalledApp/);
    const fn = /async function pullRefresh\(\) \{([\s\S]*?)\n\}/.exec(app)?.[1] ?? "";
    assert.match(fn, /checkForUpdate\(\)/);
    assert.match(fn, /resyncCalendar\(/);
    assert.match(fn, /await render\(\)/);
    assert.doesNotMatch(fn, /location\.reload|api\(|fetch\(/, "no full reload, no new requests of its own");
  });

  it("only stops native overscroll in the installed app", () => {
    assert.match(read("app.css"), /html\.ptr-on, html\.ptr-on body \{ overscroll-behavior-y: contain; \}/);
    assert.match(read("ptr.js"), /classList\.toggle\("ptr-on", enabled\(\)\)/);
  });

  it("the service worker caches the new modules and they revalidate", () => {
    const sw = read("sw.js");
    for (const f of ["/ptr.js", "/ptr-logic.js"]) assert.ok(sw.includes(`"${f}"`), f);
    const headers = read("_headers");
    for (const f of ["/ptr.js", "/ptr-logic.js"]) assert.match(headers, new RegExp(`^${f.replace(".", "\\.")}\\n  Cache-Control: no-cache$`, "m"));
  });
});

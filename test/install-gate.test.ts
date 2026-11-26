import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DISMISS_KEY,
  isStandalone,
  markDismissed,
  platformOf,
  shouldAutoShow,
  showInstallRow,
  wasDismissed,
} from "../public/install-gate.js";

const UA = {
  iphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1",
  ipadAsMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15",
  android: "Mozilla/5.0 (Linux; Android 16; Pixel 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36",
  desktop: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
};

function memoryStorage() {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) };
}

describe("install prompt gating", () => {
  it("detects the platform, including iPadOS reporting as a Mac", () => {
    assert.equal(platformOf({ userAgent: UA.iphone, maxTouchPoints: 5 }), "ios");
    assert.equal(platformOf({ userAgent: UA.ipadAsMac, maxTouchPoints: 5 }), "ios");
    assert.equal(platformOf({ userAgent: UA.ipadAsMac, maxTouchPoints: 0 }), "other", "a real Mac has no touch points");
    assert.equal(platformOf({ userAgent: UA.android, maxTouchPoints: 5 }), "android");
    assert.equal(platformOf({ userAgent: UA.desktop }), "other");
  });

  it("treats display-mode standalone or navigator.standalone as installed", () => {
    assert.equal(isStandalone({ displayModeStandalone: true }), true);
    assert.equal(isStandalone({ navigatorStandalone: true }), true);
    assert.equal(isStandalone({}), false);
  });

  it("iPhone Safari: shows on first visit, never when installed or dismissed", () => {
    assert.equal(shouldAutoShow({ platform: "ios", standalone: false, dismissed: false }), true);
    assert.equal(shouldAutoShow({ platform: "ios", standalone: true, dismissed: false }), false);
    assert.equal(shouldAutoShow({ platform: "ios", standalone: false, dismissed: true }), false);
  });

  it("Android: only once beforeinstallprompt has fired", () => {
    assert.equal(shouldAutoShow({ platform: "android", standalone: false, dismissed: false, canPrompt: false }), false);
    assert.equal(shouldAutoShow({ platform: "android", standalone: false, dismissed: false, canPrompt: true }), true);
    assert.equal(shouldAutoShow({ platform: "android", standalone: false, dismissed: true, canPrompt: true }), false);
    assert.equal(shouldAutoShow({ platform: "android", standalone: true, dismissed: false, canPrompt: true }), false);
  });

  it("desktop is never prompted uninvited", () => {
    assert.equal(shouldAutoShow({ platform: "other", standalone: false, dismissed: false, canPrompt: true }), false);
  });

  it("the More row is offered in any browser tab, not inside the installed app", () => {
    assert.equal(showInstallRow({ standalone: false }), true);
    assert.equal(showInstallRow({ standalone: true }), false);
  });

  it("remembers dismissal in storage, and survives blocked storage", () => {
    const s = memoryStorage();
    assert.equal(wasDismissed(s), false);
    markDismissed(s, 123);
    assert.equal(s.getItem(DISMISS_KEY), "123");
    assert.equal(wasDismissed(s), true);
    const blocked = { getItem: () => { throw new Error("SecurityError"); }, setItem: () => { throw new Error("SecurityError"); } };
    assert.equal(wasDismissed(blocked), false);
    assert.doesNotThrow(() => markDismissed(blocked));
    assert.equal(wasDismissed(null), false);
  });
});

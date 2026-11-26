/**
 * When to offer "install Meetspike as an app". Pure functions, no DOM, so the
 * rules can be tested in Node (test/install-gate.test.ts).
 */

export const DISMISS_KEY = "meetspike-install-dismissed";

/** "ios" (iPhone, iPad, iPod, and iPadOS that reports as a Mac), "android", or "other". */
export function platformOf({ userAgent = "", maxTouchPoints = 0 } = {}) {
  if (/iPhone|iPad|iPod/i.test(userAgent)) return "ios";
  if (/Macintosh/i.test(userAgent) && maxTouchPoints > 1) return "ios";
  if (/Android/i.test(userAgent)) return "android";
  return "other";
}

/** Already running as an installed app (home-screen icon), not in a browser tab. */
export function isStandalone({ displayModeStandalone = false, navigatorStandalone = false } = {}) {
  return displayModeStandalone === true || navigatorStandalone === true;
}

/**
 * Show the walkthrough on its own (first visit) only when:
 * - this is a phone or tablet browser tab, not the installed app,
 * - it was never dismissed on this device,
 * - and there is something to do: iOS always has Share → Add to Home Screen;
 *   Android only once Chrome has fired beforeinstallprompt (canPrompt).
 * Desktop never gets it uninvited.
 */
export function shouldAutoShow({ platform, standalone, dismissed, canPrompt = false }) {
  if (standalone || dismissed) return false;
  if (platform === "ios") return true;
  if (platform === "android") return canPrompt === true;
  return false;
}

/** The small "Install app" row in More: any browser tab, never inside the installed app. */
export function showInstallRow({ standalone }) {
  return !standalone;
}

/** Reads the dismissed flag; blocked storage counts as "not dismissed". */
export function wasDismissed(storage) {
  try {
    return Boolean(storage?.getItem(DISMISS_KEY));
  } catch {
    return false;
  }
}

export function markDismissed(storage, now = Date.now()) {
  try {
    storage?.setItem(DISMISS_KEY, String(now));
  } catch {
    /* private mode: it may show again next visit, which is acceptable */
  }
}

/**
 * Pull-to-refresh rules, no DOM, so they can be tested in Node
 * (test/ptr-logic.test.ts). The gesture itself lives in public/ptr.js.
 */

/** Screens that can be pulled. Ask (chat + text box) and More are left alone. */
export const PULL_TABS = ["today", "dates", "people", "person"];

/** How far the indicator must travel (px, after resistance) to refresh on release. */
export const THRESHOLD = 56;
/** The indicator never travels further than this. */
export const MAX_PULL = 140;
/** Finger travel before we decide whether the gesture is vertical or sideways. */
export const LOCK_SLOP = 8;

/**
 * May a touch that starts now become a pull? Only in the installed app, on a
 * main screen, scrolled to the very top, with nothing open or focused that a
 * pull would fight with, and not while a refresh is already running.
 */
export function canStartPull({
  standalone,
  tab,
  scrollTop,
  touches = 1,
  pickerOpen = false,
  sheetOpen = false,
  inputFocused = false,
  refreshing = false,
}) {
  if (!standalone || refreshing) return false;
  if (!PULL_TABS.includes(tab)) return false;
  if (touches !== 1) return false;
  if (scrollTop > 0) return false;
  if (pickerOpen || sheetOpen || inputFocused) return false;
  return true;
}

/**
 * After the finger has moved (dx, dy) from where it started: "pull" (downward,
 * mostly vertical), "cancel" (sideways, e.g. the date chips, or upward, i.e. a
 * normal scroll), or null (too small to tell yet).
 */
export function lockDirection(dx, dy, slop = LOCK_SLOP) {
  if (Math.abs(dx) < slop && Math.abs(dy) < slop) return null;
  if (dy > 0 && dy >= Math.abs(dx)) return "pull";
  return "cancel";
}

/**
 * Finger travel → indicator travel, with rubber-band resistance: 0.7× at
 * first, easing towards MAX_PULL, never past it. About 105px of finger travel
 * reaches THRESHOLD. 0 for upward moves.
 */
export function pullOffset(dy, max = MAX_PULL) {
  if (!(dy > 0)) return 0;
  return max * (1 - Math.exp((-dy * 0.7) / max));
}

/** Release far enough down → refresh. */
export function shouldRefresh(offset, threshold = THRESHOLD) {
  return offset >= threshold;
}

/** 0..1 for drawing the arrow as it fills up towards the threshold. */
export function pullProgress(offset, threshold = THRESHOLD) {
  return Math.max(0, Math.min(1, offset / threshold));
}

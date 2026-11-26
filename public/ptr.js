/**
 * Pull-to-refresh for the installed app (home-screen Meetspike has no browser
 * pull-to-refresh of its own). Pull down at the top of a main screen, let go
 * past the line, and `onRefresh` runs while a spinner shows. The rules for
 * when a pull may start are in ptr-logic.js.
 */
import { MAX_PULL, THRESHOLD, canStartPull, lockDirection, pullOffset, pullProgress, shouldRefresh } from "./ptr-logic.js";

const ARROW = `<svg viewBox="0 0 24 24" aria-hidden="true"><path class="arrow" d="M12 5v13M6.5 12.5 12 18l5.5-5.5"/><circle class="spin" cx="12" cy="12" r="8"/></svg>`;

/**
 * @param {object} o
 * @param {() => boolean} o.enabled     installed app? (checked on every touch)
 * @param {() => string}  o.tab         current screen
 * @param {() => Promise<unknown>} o.onRefresh
 */
export function initPullToRefresh({ enabled, tab, onRefresh }) {
  const el = document.createElement("div");
  el.className = "ptr";
  el.innerHTML = `<span class="ptr-dot">${ARROW}</span><span class="sr" role="status" aria-live="polite"></span>`;
  document.body.append(el);
  const dot = el.querySelector(".ptr-dot");
  const live = el.querySelector("[role=status]");
  const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)");

  let start = null; // { x, y }
  let mode = null; // null | "pull" | "cancel"
  let offset = 0;
  let refreshing = false;

  const scrollTop = () => Math.max(window.scrollY || 0, document.scrollingElement?.scrollTop || 0);

  function draw(y, { animate = false } = {}) {
    el.classList.toggle("animate", animate && !reduced?.matches);
    el.style.setProperty("--ptr-y", `${y.toFixed(1)}px`);
    el.style.setProperty("--ptr-p", pullProgress(y).toFixed(3));
    el.classList.toggle("ready", shouldRefresh(y));
    el.classList.toggle("shown", y > 0 || refreshing);
  }

  function reset() {
    start = null;
    mode = null;
    offset = 0;
    draw(0, { animate: true });
  }

  function onStart(ev) {
    start = null;
    mode = null;
    const ae = document.activeElement;
    const ok = canStartPull({
      standalone: enabled(),
      tab: tab(),
      scrollTop: scrollTop(),
      touches: ev.touches.length,
      pickerOpen: Boolean(document.getElementById("sheet") && !document.getElementById("sheet").hidden),
      sheetOpen: Boolean(document.querySelector(".isheet")),
      inputFocused: Boolean(ae && (ae.matches?.("input, textarea, select") || ae.isContentEditable)),
      refreshing,
    });
    if (!ok) return;
    const t = ev.touches[0];
    start = { x: t.clientX, y: t.clientY };
  }

  function onMove(ev) {
    if (!start || mode === "cancel") return;
    if (ev.touches.length !== 1) return reset();
    const t = ev.touches[0];
    const dx = t.clientX - start.x;
    const dy = t.clientY - start.y;
    if (!mode) {
      mode = lockDirection(dx, dy);
      if (mode !== "pull") return;
    }
    // Scrolled away (momentum) or pushed back above the start: give it back to the page.
    if (scrollTop() > 0 || dy <= 0) {
      if (offset) draw(0);
      offset = 0;
      return;
    }
    // Ours now: stop the page from rubber-banding under the indicator.
    if (ev.cancelable) ev.preventDefault();
    offset = pullOffset(dy);
    draw(offset);
  }

  async function onEnd() {
    if (!start) return;
    const go = mode === "pull" && shouldRefresh(offset);
    start = null;
    mode = null;
    if (!go) return reset();
    refreshing = true;
    offset = 0;
    el.classList.add("busy");
    draw(Math.min(THRESHOLD, MAX_PULL), { animate: true });
    live.textContent = "Refreshing…";
    try {
      await onRefresh();
      live.textContent = "Up to date";
    } catch {
      live.textContent = "Could not refresh";
    } finally {
      refreshing = false;
      el.classList.remove("busy");
      draw(0, { animate: true });
    }
  }

  document.addEventListener("touchstart", onStart, { passive: true });
  // Not passive: preventDefault is needed while pulling (and only then).
  document.addEventListener("touchmove", onMove, { passive: false });
  document.addEventListener("touchend", onEnd, { passive: true });
  document.addEventListener("touchcancel", reset, { passive: true });
  // While installed, keep the page from bouncing past the top, so the native
  // overscroll does not fight the indicator. Browser tabs keep their own
  // pull-to-refresh, so this class is set only in the installed app.
  const mark = () => document.documentElement.classList.toggle("ptr-on", enabled());
  mark();
  window.matchMedia?.("(display-mode: standalone)").addEventListener?.("change", mark);
}

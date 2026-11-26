/**
 * Installed-app plumbing for Meetspike:
 * - registers /sw.js and picks up every deploy without a reinstall,
 * - reloads quietly at a safe moment when a new version takes over,
 * - shows the first-visit "install as an app" sheet on phones.
 */
import { isStandalone, markDismissed, platformOf, shouldAutoShow, showInstallRow, wasDismissed } from "./install-gate.js";

const sw = "serviceWorker" in navigator ? navigator.serviceWorker : null;
const storage = (() => {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
})();

const platform = platformOf({ userAgent: navigator.userAgent, maxTouchPoints: navigator.maxTouchPoints || 0 });
const standaloneQuery = window.matchMedia?.("(display-mode: standalone)");
const standalone = () => isStandalone({ displayModeStandalone: Boolean(standaloneQuery?.matches), navigatorStandalone: navigator.standalone === true });

let deferredPrompt = null;
let autoShown = false;
let sheetEl = null;
let lastFocus = null;

/* ---------- updates ---------- */

let controlled = Boolean(sw?.controller);
let interacted = false;
let pendingReload = false;
let reloading = false;
// Set by checkForUpdate(): the user just asked for fresh data (pull to
// refresh), so a version that arrives now may reload even after a tap.
let applyRequested = false;

/** Something on screen the user would lose with a reload. */
function busy() {
  const el = document.activeElement;
  if (el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA") && el.value) return true;
  if (document.querySelector(".bubble.pending")) return true;
  const picker = document.getElementById("sheet");
  if (picker && !picker.hidden) return true;
  return false;
}

function reloadNow() {
  if (reloading) return;
  reloading = true;
  location.reload();
}

function showUpdatedToast() {
  if (document.getElementById("update-toast")) return;
  const t = document.createElement("div");
  t.id = "update-toast";
  t.className = "toast";
  t.setAttribute("role", "status");
  t.innerHTML = `<button type="button">Meetspike updated · <b>Tap to refresh</b></button>`;
  t.querySelector("button").addEventListener("click", reloadNow);
  document.body.append(t);
}

function onControllerChange() {
  if (!controlled) {
    // First install on this device: the page already runs the newest code.
    controlled = true;
    return;
  }
  const asked = applyRequested;
  applyRequested = false;
  if (document.visibilityState === "hidden" || ((!interacted || asked) && !busy())) reloadNow();
  else {
    pendingReload = true;
    showUpdatedToast();
  }
}

async function registerWorker() {
  if (!sw) return;
  try {
    // updateViaCache "none": the browser always asks the server for sw.js.
    const reg = await sw.register("/sw.js", { scope: "/", updateViaCache: "none" });
    const check = () => reg.update().catch(() => {});
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState !== "visible") return;
      if (pendingReload && !busy()) return reloadNow();
      interacted = false;
      check();
    });
    setInterval(() => document.visibilityState === "visible" && check(), 30 * 60 * 1000);
  } catch {
    /* blocked (private mode, Access expired): the app works without it */
  }
}

/**
 * Ask the server for a newer service worker now (pull to refresh). If one is
 * found it installs, takes over and the page reloads under the usual rules
 * (never while typing, waiting for Ask, or in the date picker; then the toast).
 * Resolves "reloading", "updated" (new version, reload deferred to the toast)
 * or "current". Waits at most `timeoutMs` for a new version to take over.
 */
export async function checkForUpdate({ timeoutMs = 6000 } = {}) {
  if (pendingReload) {
    if (!busy()) {
      reloadNow();
      return "reloading";
    }
    return "updated";
  }
  if (!sw) return "current";
  let reg;
  // Set before update(): a small new worker can take over before it returns.
  applyRequested = true;
  try {
    reg = await sw.getRegistration("/");
    if (reg) await reg.update();
  } catch {
    reg = null;
  }
  if (reloading) return "reloading";
  if (!reg || (!reg.installing && !reg.waiting)) {
    applyRequested = false;
    return pendingReload ? "updated" : "current";
  }
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, timeoutMs);
    sw.addEventListener(
      "controllerchange",
      () => {
        clearTimeout(timer);
        // onControllerChange runs first (registered earlier) and decides.
        setTimeout(resolve, 0);
      },
      { once: true },
    );
  });
  applyRequested = false;
  return reloading ? "reloading" : pendingReload ? "updated" : "current";
}

/** True inside the installed (home-screen) app, false in a browser tab. */
export function isInstalledApp() {
  return standalone();
}

/** The deployed version the service worker was stamped with, or null. */
export function appVersion() {
  const ctl = sw?.controller;
  if (!ctl) return Promise.resolve(null);
  return new Promise((resolve) => {
    const ch = new MessageChannel();
    const timer = setTimeout(() => resolve(null), 1500);
    ch.port1.onmessage = (e) => {
      clearTimeout(timer);
      resolve(e.data?.version ?? null);
    };
    ctl.postMessage({ type: "version" }, [ch.port2]);
  });
}

/* ---------- install sheet ---------- */

const SHARE_ICON = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v12M8 7l4-4 4 4"/><path d="M6 11H5a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-8a1 1 0 0 0-1-1h-1"/></svg>`;
const ADD_ICON = `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="16" height="16" rx="4"/><path d="M12 8v8M8 12h8"/></svg>`;
const CHECK_ICON = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5 10 17l9-10"/></svg>`;
const MENU_ICON = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="5" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="12" cy="19" r="1.6"/></svg>`;

/** The little animated phone: the Meetspike icon drops onto a home screen. */
const DEMO = `<div class="demo" aria-hidden="true">
  <div class="demo-phone">
    <span class="demo-island"></span>
    <span class="demo-app"></span><span class="demo-app"></span><span class="demo-app"></span>
    <span class="demo-app"></span><span class="demo-app"></span>
    <img class="demo-icon" src="/icons/icon-192.png?v=1" alt="" width="40" height="40" />
  </div>
</div>`;

const step = (n, icon, html) => `<li style="--i:${n}"><span class="ico">${icon}</span><span>${html}</span></li>`;

function sheetBody() {
  if (platform === "ios") {
    return {
      lead: "Put it on your Home Screen. It opens full screen like an app and updates itself.",
      steps: [
        step(0, SHARE_ICON, `Tap <b>Share</b> in Safari. On newer iOS it is under the <b>•••</b> button.`),
        step(1, ADD_ICON, `Scroll down and tap <b>Add to Home Screen</b>.`),
        step(2, CHECK_ICON, `Tap <b>Add</b>. Open Meetspike from its icon.`),
      ],
      actions: `<button type="button" class="primary" data-install="close">Got it</button>`,
    };
  }
  if (deferredPrompt) {
    return {
      lead: "Install it on this device. It opens full screen like an app and updates itself.",
      steps: [step(0, ADD_ICON, `Tap <b>Install</b> below, then confirm.`), step(1, CHECK_ICON, `Open Meetspike from your home screen.`)],
      actions: `<button type="button" class="primary" data-install="prompt">Install</button>
        <button type="button" class="secondary" data-install="close">Not now</button>`,
    };
  }
  if (platform === "android") {
    return {
      lead: "Install it on this device. It opens full screen like an app and updates itself.",
      steps: [
        step(0, MENU_ICON, `Open the browser menu <b>⋮</b>.`),
        step(1, ADD_ICON, `Tap <b>Install app</b> or <b>Add to Home screen</b>.`),
        step(2, CHECK_ICON, `Open Meetspike from your home screen.`),
      ],
      actions: `<button type="button" class="primary" data-install="close">Got it</button>`,
    };
  }
  return {
    lead: "Meetspike is built for your phone. Open this page there to add it to your Home Screen.",
    steps: [
      step(0, ADD_ICON, `On a computer, Chrome and Edge show an <b>install</b> icon in the address bar.`),
      step(1, SHARE_ICON, `Safari on a Mac: <b>File → Add to Dock</b>.`),
    ],
    actions: `<button type="button" class="primary" data-install="close">Got it</button>`,
  };
}

export function openInstallSheet({ auto = false } = {}) {
  if (sheetEl) return;
  const b = sheetBody();
  lastFocus = document.activeElement;
  sheetEl = document.createElement("div");
  sheetEl.className = "isheet";
  sheetEl.dataset.auto = auto ? "1" : "";
  sheetEl.innerHTML = `<div class="panel" role="dialog" aria-modal="true" aria-labelledby="install-title" aria-describedby="install-lead">
      <span class="grab" aria-hidden="true"></span>
      ${DEMO}
      <h2 id="install-title" class="title">Install Meetspike</h2>
      <p id="install-lead" class="lead">${b.lead}</p>
      <ol class="isteps">${b.steps.join("")}</ol>
      <div class="iactions">${b.actions}</div>
    </div>`;
  sheetEl.addEventListener("click", onSheetClick);
  sheetEl.addEventListener("keydown", onSheetKey);
  document.body.append(sheetEl);
  requestAnimationFrame(() => sheetEl?.classList.add("open"));
  sheetEl.querySelector(".iactions button")?.focus({ preventScroll: true });
}

function closeInstallSheet() {
  if (!sheetEl) return;
  markDismissed(storage);
  const el = sheetEl;
  sheetEl = null;
  el.classList.remove("open");
  const done = () => el.remove();
  if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) done();
  else {
    el.addEventListener("transitionend", done, { once: true });
    setTimeout(done, 400);
  }
  if (lastFocus && document.contains(lastFocus)) lastFocus.focus({ preventScroll: true });
}

async function onSheetClick(ev) {
  const btn = ev.target.closest("[data-install]");
  if (!btn) {
    if (ev.target === sheetEl) closeInstallSheet();
    return;
  }
  if (btn.dataset.install === "prompt" && deferredPrompt) {
    const p = deferredPrompt;
    deferredPrompt = null;
    try {
      await p.prompt();
      await p.userChoice;
    } catch {
      /* the browser refused; nothing to do */
    }
  }
  closeInstallSheet();
}

function onSheetKey(ev) {
  if (ev.key === "Escape") {
    ev.stopPropagation();
    closeInstallSheet();
  } else if (ev.key === "Tab") {
    const f = [...sheetEl.querySelectorAll("button")];
    if (!f.length) return;
    const first = f[0];
    const last = f[f.length - 1];
    if (ev.shiftKey && document.activeElement === first) {
      ev.preventDefault();
      last.focus();
    } else if (!ev.shiftKey && document.activeElement === last) {
      ev.preventDefault();
      first.focus();
    }
  }
}

function maybeAutoShow() {
  if (autoShown || sheetEl) return;
  if (!shouldAutoShow({ platform, standalone: standalone(), dismissed: wasDismissed(storage), canPrompt: Boolean(deferredPrompt) })) return;
  autoShown = true;
  setTimeout(() => {
    const picker = document.getElementById("sheet");
    if (document.visibilityState !== "visible" || (picker && !picker.hidden)) {
      autoShown = false; // try again next time the tab is shown
      return;
    }
    openInstallSheet({ auto: true });
  }, 1400);
}

/** Whether More should list "Install app". */
export function canOfferInstall() {
  return showInstallRow({ standalone: standalone() });
}

export function initPwa() {
  for (const type of ["pointerdown", "keydown"]) addEventListener(type, () => (interacted = true), { capture: true, passive: true });
  sw?.addEventListener("controllerchange", onControllerChange);
  if (document.readyState === "complete") registerWorker();
  else addEventListener("load", registerWorker, { once: true });

  addEventListener("beforeinstallprompt", (ev) => {
    ev.preventDefault();
    deferredPrompt = ev;
    maybeAutoShow();
  });
  addEventListener("appinstalled", () => {
    deferredPrompt = null;
    markDismissed(storage);
    if (sheetEl) closeInstallSheet();
  });
  document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && maybeAutoShow());
  maybeAutoShow();
}

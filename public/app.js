import { meetingHrLabel, scoreLabel } from "./wearable-labels.js";
/**
 * Meetspike front end. One request per screen (/api/view), cached so a screen
 * you have seen opens instantly and refreshes quietly behind it.
 */
import { addDays, presetRange } from "./range-presets.js";
import { appVersion, canOfferInstall, checkForUpdate, initPwa, isInstalledApp, openInstallSheet } from "./pwa.js";
import { initPullToRefresh } from "./ptr.js";
import { initAskPanel, openAsk, setAskSourceDisplay } from "./ask-panel.js";
import {
  PEOPLE_PRESETS, initPeopleSearch, peopleRangeDates, peopleRangeHtml, peopleSearchHtml,
  readPeopleRange, validPeopleDates, writePeopleRange,
} from "./people-ui.js";
import { liveChartHtml, meetingLiveWindow, mergeLivePoints } from "./live-hr.js";
import {
  actionsHtml, excludedRowHtml, isExcluded, looksSkipped, planAction, readTimes, saveOverride, skippedNoteHtml,
} from "./meeting-actions.js";

const TZ = "America/New_York";
const CACHE_MS = 5 * 60 * 1000;
const SOURCE_DISPLAY_PATH = "/api/settings/source-display";
const DEFAULT_RANGE_DAYS = 14;

class AccessNeededError extends Error {
  constructor() {
    super("Your sign-in expired.");
    this.name = "AccessNeededError";
  }
}

/* ---------- small helpers ---------- */

const qs = (sel, root = document) => root.querySelector(sel);

function esc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function todayET() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}

function fmtDay(day, opts = { weekday: "short", month: "short", day: "numeric" }) {
  return new Date(`${day}T12:00:00.000Z`).toLocaleDateString("en-US", { ...opts, timeZone: "UTC" });
}

function shortDay(day) {
  const thisYear = todayET().slice(0, 4) === day.slice(0, 4);
  return fmtDay(day, thisYear ? { month: "short", day: "numeric" } : { month: "short", day: "numeric", year: "numeric" });
}

function rangeLabel(start, end) {
  return start === end ? shortDay(start) : `${shortDay(start)} – ${shortDay(end)}`;
}

function spanDays(start, end) {
  return Math.round((Date.parse(`${end}T12:00:00Z`) - Date.parse(`${start}T12:00:00Z`)) / 86400000) + 1;
}

function plural(n, word, many = `${word}s`) {
  return `${n} ${n === 1 ? word : many}`;
}

function hoursText(seconds) {
  const h = Math.round((seconds / 3600) * 10) / 10;
  return `${h} h`;
}

// Round the total minutes first, then split: 28790 s is "8 h 0 m", never "7 h 60 m".
function sleepText(seconds) {
  const total = Math.round(seconds / 60);
  return `${Math.floor(total / 60)} h ${total % 60} m`;
}

function clockFromLocal(iso) {
  const m = /T(\d{2}):(\d{2})/.exec(iso ?? "");
  if (!m) return "";
  let h = Number(m[1]);
  const ap = h >= 12 ? "pm" : "am";
  h = h % 12 || 12;
  return `${h}:${m[2]} ${ap}`;
}

function hourFromLocal(iso) {
  const m = /T(\d{2}):(\d{2})/.exec(iso ?? "");
  return m ? Number(m[1]) + Number(m[2]) / 60 : null;
}

function initials(name, email) {
  const src = (name || email || "?").replace(/@.*/, "");
  const parts = src.split(/[\s._-]+/).filter(Boolean);
  return ((parts[0]?.[0] ?? "?") + (parts[1]?.[0] ?? "")).toUpperCase();
}

function round(n, places = 0) {
  if (n == null || !Number.isFinite(n)) return null;
  const f = 10 ** places;
  return Math.round(n * f) / f;
}

/* Recovery colour bands. WHOOP: 67+ green, 34–66 yellow. Oura readiness: 85+ / 70+. */
function band(score, w) {
  if (score == null) return null;
  const [hi, lo] = w?.source === "oura" ? [85, 70] : [67, 34];
  if (score >= hi) return { cls: "good", word: w?.source === "oura" ? "Optimal" : "Good" };
  if (score >= lo) return { cls: "warn", word: w?.source === "oura" ? "Fair" : "Fair" };
  return { cls: "bad", word: "Low" };
}

/* ---------- network and cache ---------- */

const memory = new Map();
const peopleSearchCache = new Map();

async function api(path, opts = {}) {
  let res;
  try {
    res = await fetch(path, {
      credentials: "same-origin",
      redirect: "manual",
      ...opts,
      headers: { Accept: "application/json", ...(opts.headers ?? {}) },
    });
  } catch {
    throw new Error("Could not reach Meetspike. Check your connection.");
  }
  if (res.type === "opaqueredirect" || res.status === 0 || res.status === 301 || res.status === 302) throw new AccessNeededError();
  if (res.status === 401) throw new AccessNeededError();
  const ct = res.headers.get("content-type") || "";
  if (ct.includes("text/html")) throw new AccessNeededError();
  const body = ct.includes("application/json") ? await res.json().catch(() => null) : null;
  if (!res.ok) {
    const err = new Error(body?.error || `Something went wrong (${res.status}).`);
    err.body = body;
    err.status = res.status;
    throw err;
  }
  if (!body) throw new AccessNeededError();
  return body;
}

const inflight = new Map();
let displayGeneration = 0;

function invalidateDisplayViews() {
  displayGeneration++;
  memory.clear();
  inflight.clear();
  hrDetails.clear();
  stopLivePanel();
}

/** Cached GET: returns what is cached (if any) right away through `onData`, then the fresh copy. */
async function load(path, onData, { force = false } = {}) {
  const generation = displayGeneration;
  const hit = memory.get(path);
  if (hit && !force) {
    onData(hit.data, true);
    if (Date.now() - hit.at < CACHE_MS) return hit.data;
  }
  let p = inflight.get(path);
  if (!p) {
    p = api(path).finally(() => {
      if (inflight.get(path) === p) inflight.delete(path);
    });
    inflight.set(path, p);
  }
  const data = await p;
  if (generation !== displayGeneration) return;
  memory.delete(path);
  memory.set(path, { at: Date.now(), data });
  if (memory.size > 24) memory.delete(memory.keys().next().value);
  onData(data, false);
  return data;
}

function prefetch(path) {
  if (memory.has(path) || inflight.has(path)) return;
  const run = () => load(path, () => {}).catch(() => {});
  if ("requestIdleCallback" in window) window.requestIdleCallback(run, { timeout: 2000 });
  else setTimeout(run, 300);
}

function viewPath(start, end) {
  return start === end ? `/api/view?date=${start}` : `/api/view?start=${start}&end=${end}`;
}

/* ---------- routing ---------- */

const state = {
  tab: "today",
  day: todayET(),
  start: addDays(todayET(), -(DEFAULT_RANGE_DAYS - 1)),
  end: todayET(),
  person: null,
  peopleRange: { preset: "28d" },
  wearable: null,
  status: null,
  sourceDisplay: null,
  sourceDisplaySaving: false,
  sourceDisplayError: "",
  openMeeting: undefined,
  /** The meeting menu that is open: { id, mode: "menu" | "scope" | "times", pending?, busy?, error? }. */
  meetingUi: null,
  picker: null,
  askInfo: null,
  showPrivacy: false,
};

function readLocation() {
  const p = new URLSearchParams(location.search);
  const hash = location.hash.replace(/^#/, "");
  state.peopleRange = readPeopleRange(p);
  const valid = (d) => validPeopleDates(d, d);
  const day = p.get("day") ?? p.get("date");
  state.day = valid(day) ? day : todayET();
  const start = p.get("start");
  const end = p.get("end");
  if (validPeopleDates(start, end)) {
    state.start = start;
    state.end = end;
  } else {
    state.end = todayET();
    state.start = addDays(state.end, 1 - DEFAULT_RANGE_DAYS);
  }
  if (hash.startsWith("person/")) {
    try {
      state.person = decodeURIComponent(hash.slice(7));
      state.tab = state.person ? "person" : "people";
    } catch {
      state.tab = "people";
    }
  } else if (["today", "dates", "people", "more"].includes(hash)) {
    state.tab = hash;
  } else if (hash === "ask") {
    // Old links to the Ask tab: open the popup over Today.
    state.tab = "today";
    state.openAskOnLoad = true;
  } else if (valid(start) && valid(end) && start !== end && !hash) {
    state.tab = "dates";
  } else {
    state.tab = "today";
  }
}

function writeLocation(replace = false) {
  const p = new URLSearchParams();
  if (state.day !== todayET()) p.set("day", state.day);
  const def = addDays(todayET(), -(DEFAULT_RANGE_DAYS - 1));
  if (state.start !== def || state.end !== todayET()) {
    p.set("start", state.start);
    p.set("end", state.end);
  }
  writePeopleRange(p, state.peopleRange);
  const hash = state.tab === "person" ? `#person/${encodeURIComponent(state.person)}` : state.tab === "today" ? "" : `#${state.tab}`;
  const url = `${location.pathname}${p.size ? `?${p}` : ""}${hash}`;
  if (url === `${location.pathname}${location.search}${location.hash}`) return;
  history[replace ? "replaceState" : "pushState"](null, "", url);
}

function go(changes, { replace = false } = {}) {
  Object.assign(state, changes);
  writeLocation(replace);
  render();
  qs("#screen").scrollTo?.(0, 0);
  window.scrollTo(0, 0);
}

/* ---------- shared pieces ---------- */

function setTabs() {
  for (const a of document.querySelectorAll("a[data-tab]")) {
    const tab = a.getAttribute("data-tab");
    const on = tab === state.tab || (tab === "people" && state.tab === "person");
    if (on) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  }
  const s = state.status;
  qs("#more-dot").hidden = !s || (s.wearableConnected && s.googleConnected);
}

function noteMeta(data) {
  if (data?.wearable) state.wearable = data.wearable;
  if (data?.status) state.status = data.status;
  const display = data?.status?.sourceDisplay ?? data?.sourceDisplay;
  if (display && !state.sourceDisplaySaving) {
    state.sourceDisplay = display;
    setAskSourceDisplay(display);
  }
  if (data?.status?.displayTitle) document.title = data.status.displayTitle;
  setTabs();
}

function screen(html) {
  qs("#screen").innerHTML = html;
  syncLivePanel();
}

function showError(err) {
  if (err instanceof AccessNeededError) {
    qs("#access").hidden = false;
    screen(`<p class="error">Sign in again to see your data.</p>`);
    return;
  }
  screen(`<p class="error">${esc(err.message || String(err))}</p>
    <button type="button" class="secondary" data-action="retry">Try again</button>`);
}

const CAL_ICON = `<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="1.5" y="2.5" width="13" height="12" rx="2.5"/><path d="M1.5 6h13M5 1v3M11 1v3"/></svg>`;

function dateBar({ label, sub, prevLabel, nextLabel, nextDisabled }) {
  return `<div class="datebar">
    <button type="button" class="nav" data-action="prev" aria-label="${esc(prevLabel)}">‹</button>
    <button type="button" class="pick" data-action="open-picker" aria-haspopup="dialog">${CAL_ICON}<span>${esc(label)}</span>${sub ? `<span class="sub">· ${esc(sub)}</span>` : ""}</button>
    <button type="button" class="nav" data-action="next" aria-label="${esc(nextLabel)}" ${nextDisabled ? "disabled" : ""}>›</button>
  </div>`;
}

function ring({ label, value, pct, color, note, aria }) {
  const C = 2 * Math.PI * 40;
  const len = Math.max(0, Math.min(1, pct ?? 0)) * C;
  return `<div class="ring">
    <svg viewBox="0 0 96 96" role="img" aria-label="${esc(aria)}">
      <circle class="track" cx="48" cy="48" r="40"/>
      <circle class="arc" cx="48" cy="48" r="40" stroke="${color}" stroke-dasharray="${len.toFixed(1)} ${C.toFixed(1)}"/>
      <text class="val" x="48" y="56" text-anchor="middle">${esc(value)}</text>
    </svg>
    <span class="label">${esc(label)}</span>
    <span class="note">${esc(note ?? "")}</span>
  </div>`;
}

function metricRow({ name, value, usual, unit = "", higherIs = "better", step = 1, words = ["higher", "lower"] }) {
  if (value == null) return "";
  if (value === 0 && !usual) return "";
  let trend = "";
  let cls = "flat-t";
  if (usual != null) {
    const d = value - usual;
    if (Math.abs(d) >= step) {
      const up = d > 0;
      const good = higherIs === "better" ? up : higherIs === "worse" ? !up : null;
      cls = good == null ? "flat-t" : good ? "good-t" : "bad-t";
      trend = up ? `▲ ${words[0]}` : `▼ ${words[1]}`;
    } else {
      trend = "usual";
    }
  }
  return `<div class="metric">
    <span class="name">${esc(name)}</span>
    <span class="num"><b>${esc(value)}${esc(unit)}</b>${usual != null ? `<small>usual ${esc(usual)}${esc(unit)}</small>` : ""}</span>
    <span class="trend ${cls}">${esc(trend)}</span>
  </div>`;
}

/** "Heart rate from 9:45 AM" when the strap covered only part of the meeting, else "". */
function partialNote(hr, timeZone = TZ) {
  const p = hr?.coverage === "ok" ? hr.partial : null;
  if (!p) return "";
  const clock = (iso) => new Date(iso).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone });
  if (p.lateStart && p.earlyEnd) return `HR between ${clock(p.fromUtc)} and ${clock(p.toUtc)}`;
  if (p.lateStart) return `HR from ${clock(p.fromUtc)}`;
  if (p.earlyEnd) return `HR until ${clock(p.toUtc)}`;
  return "Gaps in heart rate";
}

function zonePill(hr) {
  if (!hr || hr.coverage !== "ok") return `<span class="pill none">No HR</span>`;
  const cls = hr.zone === "high" ? "bad" : hr.zone === "moderate" ? "warn" : hr.zone === "low" ? "good" : "none";
  const note = partialNote(hr);
  return `<span class="pill ${cls}"${note ? ` title="${esc(note)}"` : ""}>${esc(`${hr.headline} · ${meetingHrLabel(hr)}`)}</span>`;
}

function sparkline(series) {
  if (!series?.length) return "";
  const bpms = series.map((p) => p.bpm);
  const min = Math.min(...bpms) - 4;
  const max = Math.max(...bpms) + 4;
  const ts = series.map((p) => Date.parse(p.t));
  const t0 = Math.min(...ts);
  const t1 = Math.max(...ts);
  const pts = series
    .map((p, i) => {
      const x = series.length === 1 ? 150 : 6 + ((ts[i] - t0) / Math.max(1, t1 - t0)) * 288;
      const y = 74 - ((p.bpm - min) / Math.max(1, max - min)) * 68;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");
  return `<svg class="spark" viewBox="0 0 300 80" role="img" aria-label="Heart-rate during the meeting, ${Math.round(Math.min(...bpms))} to ${Math.round(Math.max(...bpms))} bpm"><polyline points="${pts}" fill="none" stroke="var(--strain)" stroke-width="2.2" stroke-linejoin="round"/></svg>`;
}

/* ---------- one meeting's heart rate (WHOOP web) ---------- */

// Per-meeting detail from /api/meetings/:id/hr, kept for this visit.
const hrDetails = new Map();

const LIVE_POLL_MS = 5_000;
let liveWatch;
let nextLiveMeetingTimer;

function stopLivePanel() {
  if (!liveWatch) return;
  clearTimeout(liveWatch.timer);
  liveWatch.request?.abort();
  liveWatch = undefined;
}

function paintLivePanel(watch) {
  watch.host.innerHTML = liveChartHtml(watch.points, watch.window, Date.now(), watch.timeZone, watch.status);
}

function syncLivePanel() {
  const host = qs("[data-live-meeting]");
  if (!host || document.hidden) return stopLivePanel();
  const id = host.dataset.liveMeeting;
  if (liveWatch?.id === id) {
    liveWatch.host = host;
    paintLivePanel(liveWatch);
    return;
  }
  stopLivePanel();
  liveWatch = {
    id, host, points: [], cursor: 0, window: JSON.parse(host.dataset.window),
    timeZone: host.dataset.zone || TZ,
  };
  paintLivePanel(liveWatch);
  pollLivePanel(liveWatch);
}

async function pollLivePanel(watch) {
  if (watch !== liveWatch) return;
  if (Date.now() >= watch.window.toMs) {
    if (Date.now() >= JSON.parse(watch.host.dataset.window).toMs) {
      stopLivePanel();
      render();
    } else {
      watch.status = "Live window ended";
      paintLivePanel(watch);
    }
    return;
  }
  const requestedCursor = watch.cursor;
  const request = new AbortController();
  watch.request = request;
  const timeout = setTimeout(() => request.abort(), 10_000);
  try {
    const data = await api(`/api/meetings/${encodeURIComponent(watch.id)}/live-hr?since=${requestedCursor}`, {
      cache: "no-store", signal: request.signal,
    });
    if (watch !== liveWatch) return;
    const changed = data.window.fromMs !== watch.window.fromMs || data.window.toMs !== watch.window.toMs;
    watch.window = data.window;
    watch.status = "";
    if (changed && requestedCursor) {
      // A calendar edit can add time to the window on either side of the cursor.
      watch.points = [];
      watch.cursor = 0;
    } else if (data.active) {
      watch.points = mergeLivePoints(watch.points, data.points);
      watch.cursor = data.cursor;
    } else {
      watch.points = [];
      watch.cursor = 0;
      watch.status = "Outside the live window";
    }
  } catch (err) {
    if (watch !== liveWatch) return;
    if (err instanceof AccessNeededError || err.status === 403) {
      watch.points = [];
      watch.status = "Sign in to resume";
      qs("#access").hidden = false;
      paintLivePanel(watch);
      return;
    }
    if (err.status === 404) watch.points = [];
    watch.status = err.status === 404 ? "Live heart rate unavailable" : "Reconnecting…";
  } finally {
    clearTimeout(timeout);
    watch.request = null;
  }
  paintLivePanel(watch);
  watch.timer = setTimeout(() => pollLivePanel(watch), LIVE_POLL_MS);
}

function loadHrDetail(id) {
  const have = hrDetails.get(id);
  if (have && (have.loading || Date.now() - (have.at ?? 0) < 60_000)) return;
  const generation = displayGeneration;
  hrDetails.set(id, { loading: true, data: have?.data, at: have?.at });
  api(`/api/meetings/${encodeURIComponent(id)}/hr`)
    .then((data) => {
      if (generation === displayGeneration) hrDetails.set(id, { data, at: Date.now() });
    })
    .catch((err) => {
      if (generation === displayGeneration) hrDetails.set(id, { error: err.message || String(err), at: Date.now() });
    })
    .finally(() => {
      if (generation === displayGeneration && shownMeetingId() === id) render();
    });
}

function shownMeetingId() {
  return qs('[data-meeting][aria-expanded="true"]')?.dataset.meeting;
}

function fmtLevel(n) {
  return n == null ? "—" : (Math.round(n * 10) / 10).toFixed(1);
}

/** HR line over the meeting (with the 10 minutes either side), usual band behind it, stress line on a 0–3 scale. */
function hrChart(d) {
  const series = d.series ?? [];
  if (!series.length) return "";
  const W = 300;
  const H = 130;
  const top = 8;
  const bottom = 112;
  const t0 = Date.parse(d.window.fetchStartUtc);
  const t1 = Date.parse(d.window.fetchEndUtc);
  const x = (t) => 4 + ((t - t0) / Math.max(1, t1 - t0)) * (W - 8);
  const bpms = series.map((p) => p.bpm);
  const b = d.baseline ?? {};
  const lo = Math.min(...bpms, b.lowBpm ?? Infinity) - 4;
  const hi = Math.max(...bpms, b.highBpm ?? -Infinity) + 4;
  const y = (bpm) => bottom - ((bpm - lo) / Math.max(1, hi - lo)) * (bottom - top);
  const ys = (level) => bottom - (Math.max(0, Math.min(3, level)) / 3) * (bottom - top);
  const band =
    b.lowBpm != null && b.highBpm != null
      ? `<rect x="4" width="${W - 8}" y="${y(b.highBpm).toFixed(1)}" height="${Math.max(1, y(b.lowBpm) - y(b.highBpm)).toFixed(1)}" fill="var(--sleep)" opacity="0.16"/>`
      : "";
  const ms = x(Date.parse(d.window.startUtc));
  const me = x(Date.parse(d.window.endUtc));
  const meeting = `<rect x="${ms.toFixed(1)}" width="${Math.max(1, me - ms).toFixed(1)}" y="${top}" height="${bottom - top}" fill="var(--strain)" opacity="0.07"/>
    <line x1="${ms.toFixed(1)}" x2="${ms.toFixed(1)}" y1="${top}" y2="${bottom}" stroke="var(--faint)" stroke-dasharray="2 3"/>
    <line x1="${me.toFixed(1)}" x2="${me.toFixed(1)}" y1="${top}" y2="${bottom}" stroke="var(--faint)" stroke-dasharray="2 3"/>`;
  const source = meetingHrLabel(d.hrStress);
  const groups = [];
  for (const p of series) {
    const provider = p.source || source;
    const time = Date.parse(p.t);
    const previous = groups.at(-1);
    const gap = provider === "WHOOP" ? 180_000 : 600_000;
    const point = `${x(time).toFixed(1)},${y(p.bpm).toFixed(1)}`;
    if (previous?.provider === provider && time - previous.end <= gap) {
      previous.points.push(point);
      previous.end = time;
    } else {
      groups.push({ provider, end: time, points: [point] });
    }
  }
  const hrLines = groups.map(({ provider, points }) => {
    const color = provider === "Oura" && source === "WHOOP + Oura" ? "var(--sleep)" : "var(--strain)";
    if (points.length === 1) {
      const [cx, cy] = points[0].split(",");
      return `<circle cx="${cx}" cy="${cy}" r="2" fill="${color}"/>`;
    }
    return `<polyline points="${points.join(" ")}" fill="none" stroke="${color}" stroke-width="2.2" stroke-linejoin="round"/>`;
  }).join("");
  const stress = d.stress?.points ?? [];
  const stressLine = stress.length
    ? `<polyline points="${stress.map((p) => `${x(Date.parse(p.t)).toFixed(1)},${ys(p.level).toFixed(1)}`).join(" ")}" fill="none" stroke="var(--warn)" stroke-width="1.6" stroke-dasharray="4 3" opacity="0.9"/>`
    : "";
  const label = (t, anchor) =>
    `<text x="${x(t).toFixed(1)}" y="${H - 4}" font-size="9" fill="var(--faint)" text-anchor="${anchor}">${esc(new Date(t).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone: d.timeZone || TZ }))}</text>`;
  const aria = `${source} heart rate from ${Math.round(Math.min(...bpms))} to ${Math.round(Math.max(...bpms))} bpm during the meeting${
    b.meanBpm != null ? `, WHOOP usual about ${Math.round(b.meanBpm)}` : ""
  }${stress.length ? `, WHOOP stress up to ${fmtLevel(d.stress.peakLevel)} of 3` : ""}`;
  return `<svg class="spark hrchart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(aria)}">
    ${band}${meeting}${stressLine}
    ${hrLines}
    ${label(Date.parse(d.window.startUtc), "start")}${label(Date.parse(d.window.endUtc), "end")}
  </svg>
  <p class="legend"><span class="k hr"></span>${source === "WHOOP + Oura" ? 'WHOOP <span class="k band"></span>Oura' : esc(source)} heart rate${b.lowBpm != null ? ` <span class="k band"></span>Your WHOOP usual (${Math.round(b.lowBpm)}–${Math.round(b.highBpm)})` : ""}${
    stress.length ? ` <span class="k stress"></span>WHOOP Stress (0–3)` : ""
  }</p>`;
}

function hrDetailHtml(e) {
  const entry = hrDetails.get(e.id);
  if (!entry || (entry.loading && !entry.data)) {
    return `<div class="hrdetail">${sparkline(e.hrStress?.series)}<p class="lead">Loading heart rate…</p></div>`;
  }
  if (entry.error) return `<div class="hrdetail"><p class="lead">No heart rate for this meeting.</p></div>`;
  const d = entry.data;
  const hr = d.hrStress;
  const facts = [];
  if (hr?.coverage === "ok") {
    if (hr.meanBpm != null) facts.push(`${meetingHrLabel(hr)} avg ${Math.round(hr.meanBpm)} bpm`);
    if (hr.maxBpm != null) facts.push(`${meetingHrLabel(hr)} peak ${Math.round(hr.maxBpm)} bpm`);
  }
  if (d.stress?.meanLevel != null) facts.push(`WHOOP stress ${fmtLevel(d.stress.meanLevel)} avg, ${fmtLevel(d.stress.peakLevel)} peak`);
  const story = hr?.coverage === "ok" ? hr.story : d.message || "No heart rate for this meeting.";
  const note = partialNote(hr, d.timeZone || TZ);
  if (note) facts.unshift(note);
  return `<div class="hrdetail">${hrChart(d)}${facts.length ? `<p class="meta">${esc(facts.join(" · "))}</p>` : ""}<p class="lead">${esc(story)}</p></div>`;
}

function meetingMeta(e) {
  const people = (e.attendees ?? []).map((a) => a.name || a.email);
  const bits = [];
  if (e.sourceType && e.sourceType !== "calendar") bits.push(e.sourceType.startsWith("plaud_phone") ? "phone call" : "recording");
  else if (e.kind) bits.push(e.kind.replaceAll("_", " "));
  if (people.length) bits.push(people.length > 2 ? `${people.slice(0, 2).join(", ")} +${people.length - 2}` : people.join(", "));
  if (e.afterHours) bits.push("after 6 pm");
  return bits.join(" · ");
}

function meetingRows(events, w, openId, timeZone = TZ) {
  const now = Date.now();
  return events
    .map((e) => {
      const clock = clockFromLocal(e.startLocal);
      // Left out (not joined, not linked): dimmed, with a way back. No chart, no score.
      if (isExcluded(e)) return excludedRowHtml(e, clock, state.meetingUi);
      const open = openId === e.id;
      const mins = Math.round((e.durationS ?? 0) / 60);
      const len = mins >= 60 ? `${Math.floor(mins / 60)} h${mins % 60 ? ` ${mins % 60} m` : ""}` : `${mins} m`;
      const window = w?.whoopWebHr ? meetingLiveWindow(e) : null;
      const inProgress = window && now >= window.startMs && now < window.endMs;
      const hr = inProgress ? `<span class="pill live-meeting-pill">In progress</span>` : w?.hasIntradayHr ? zonePill(e.hrStress) : "";
      let detail = "";
      if (open && w?.hasIntradayHr) {
        const showLive = window && now >= window.fromMs && now < window.toMs;
        if (showLive) {
          detail = `<div data-live-meeting="${esc(e.id)}" data-window="${esc(JSON.stringify(window))}" data-zone="${esc(timeZone)}"></div>`;
        }
        if (!showLive || e.hrStress?.coverage === "ok") {
          loadHrDetail(e.id);
          detail += hrDetailHtml(e);
        }
      }
      const extras = open ? actionsHtml(e, state.meetingUi, timeZone) : "";
      const note = looksSkipped(e) ? skippedNoteHtml(e) : "";
      return `<button type="button" class="mrow" data-meeting="${esc(e.id)}" aria-expanded="${open}">
          <span class="t">${esc(clock)}</span>
          <span class="w"><b>${esc(e.title || "Untitled")}</b><small>${esc([meetingMeta(e), partialNote(e.hrStress, timeZone)].filter(Boolean).join(" · "))}</small></span>
          ${hr || `<span class="len">${esc(len)}</span>`}
        </button>${detail}${extras}${note}`;
    })
    .join("");
}

function timeline(events) {
  const from = 7;
  const to = 21;
  const bars = events
    .map((e) => {
      const s = hourFromLocal(e.startLocal);
      if (s == null) return "";
      const d = (e.durationS ?? 0) / 3600;
      const left = Math.max(0, Math.min(1, (s - from) / (to - from)));
      const width = Math.max(0.006, Math.min(1 - left, d / (to - from)));
      return `<span class="${s >= 18 ? "after" : ""}" style="left:${(left * 100).toFixed(2)}%;width:${(width * 100).toFixed(2)}%"></span>`;
    })
    .join("");
  return `<div class="timeline" role="img" aria-label="Meetings between 7 am and 9 pm">${bars}</div>
    <div class="timeline-axis" aria-hidden="true"><span>7 AM</span><span>11 AM</span><span>3 PM</span><span>6 PM</span><span>9 PM</span></div>`;
}

/* ---------- meeting choices ---------- */

/** The meeting as the loaded day has it. */
function dayTimeZone() {
  return memory.get(viewPath(state.day, state.day))?.data?.day?.timeZone ?? TZ;
}

function dayMeeting(id) {
  return memory.get(viewPath(state.day, state.day))?.data?.day?.calendar?.events?.find((e) => e.id === id);
}

function toggleMeetingMenu(id) {
  state.meetingUi = state.meetingUi?.id === id && state.meetingUi.mode ? null : { id, mode: "menu" };
  render().then(() => qs(`.mmenu[data-id="${CSS.escape(id)}"]`)?.focus());
}

function runMeetingAction(name, id) {
  const e = dayMeeting(id);
  if (!e || state.meetingUi?.busy) return;
  if (name === "close") {
    state.meetingUi = null;
    render().then(() => qs(`.mmenu[data-id="${CSS.escape(id)}"]`)?.focus());
    return;
  }
  const plan = planAction(name, e, { pending: state.meetingUi?.id === id ? state.meetingUi.pending : undefined });
  if (!plan) return;
  if (plan.body) commitMeetingChange(id, plan.body);
  else {
    state.meetingUi = { id, mode: plan.mode, pending: plan.pending };
    render();
  }
}

/** Save, then reload what is on screen. A failure leaves the old state and says so. */
async function commitMeetingChange(id, body) {
  state.meetingUi = { ...(state.meetingUi ?? { id }), id, busy: true, error: "" };
  const result = await saveOverride(api, id, body);
  if (!result.ok) {
    state.meetingUi = { ...state.meetingUi, busy: false, error: result.message };
    render();
    return;
  }
  state.meetingUi = null;
  // Today, dates, people, companies and what the Mac reads all change with a choice.
  invalidateDisplayViews();
  peopleSearchCache.clear();
  await render();
}

/* ---------- Today ---------- */

function renderToday(v) {
  const w = v.wearable;
  const b = v.day;
  const today = v.today;
  const morning = b.priorNight;
  const next = b.nextMorning;
  const cal = b.calendar;
  const listed = cal?.events ?? [];
  // Meetings left out are listed so they can be undone, but they are not on the timeline or in "in progress".
  const events = listed.filter((e) => !isExcluded(e));
  const R = scoreLabel(w);
  const u = v.usual;
  const isToday = b.date === today;
  const label = isToday ? "Today" : fmtDay(b.date, { weekday: "short", month: "short", day: "numeric" });
  let openId = state.openMeeting;
  if (isToday && openId === undefined && w.whoopWebHr) {
    const now = Date.now();
    const windows = events.map((event) => ({ id: event.id, window: meetingLiveWindow(event) })).filter((event) => event.window);
    const started = windows.filter(({ window }) => now >= window.startMs && now < window.toMs)
      .sort((a, b) => b.window.startMs - a.window.startMs);
    openId = (started.find(({ window }) => now < window.endMs) ?? started[0])?.id;
    const next = Math.min(...windows.map(({ window }) => window.startMs).filter((start) => start > now));
    clearTimeout(nextLiveMeetingTimer);
    if (Number.isFinite(next)) nextLiveMeetingTimer = setTimeout(render, next - now);
  }

  const scores = v.morningScores;
  const rings = [
    ...scores.map((score) => {
      const rec = score.morning;
      const rb = band(rec, score);
      const title = scoreLabel(score);
      return ring({
        label: title,
        value: rec == null ? "—" : `${rec}%`,
        pct: (rec ?? 0) / 100,
        color: rb ? `var(--${rb.cls})` : "var(--faint)",
        note: rb?.word ?? "No score",
        aria: rec == null ? `${title} has no score` : `${title} ${rec} percent, ${rb.word}`,
      });
    }),
    w.source ? ring({
      label: `Sleep (${w.label})`,
      value: morning?.sleepScore == null ? "—" : `${morning.sleepScore}%`,
      pct: (morning?.sleepScore ?? 0) / 100,
      color: "var(--sleep)",
      note: morning?.totalSleepS ? sleepText(morning.totalSleepS) : "No score",
      aria: morning?.sleepScore == null ? `${w.label} sleep has no score` : `${w.label} sleep ${morning.sleepScore} percent`,
    }) : "",
    w.strainLabel
      ? ring({
          label: w.strainLabel.toUpperCase(),
          value: morning?.strain == null ? "—" : String(morning.strain),
          pct: (morning?.strain ?? 0) / (w.strainMax || 21),
          color: "var(--strain)",
          note: `of ${w.strainMax || 21}`,
          aria: morning?.strain == null ? `${w.strainLabel}: none yet` : `${w.strainLabel} ${morning.strain} of ${w.strainMax || 21}`,
        })
      : ring({
          label: "MEETINGS",
          value: hoursText(cal?.totalDurationS ?? 0).replace(" ", ""),
          pct: (cal?.totalDurationS ?? 0) / (8 * 3600),
          color: "var(--strain)",
          note: plural(cal?.eventCount ?? 0, "meeting"),
          aria: `${hoursText(cal?.totalDurationS ?? 0)} of meetings`,
        }),
  ].join("");

  const heavy = (cal?.totalDurationS ?? 0) >= 4 * 3600 || (cal?.eventCount ?? 0) >= 5;
  const e = v.effect;
  let outlook = "";
  if (!w.source) {
    outlook = "";
  } else if (scores.some((score) => score.nextMorning != null)) {
    outlook = `<section class="card"><h2 class="kicker">The night after</h2>
      ${scores.map((score) => metricRow({
        name: scoreLabel(score), value: score.nextMorning, usual: score.usual.recovery,
        unit: "%", higherIs: "better", step: 3,
      })).join("")}</section>`;
  } else if (b.date >= addDays(today, -1)) {
    let line;
    if (e.cost != null && e.heavy.days >= 2 && e.lighter.days >= 2) {
      line = heavy
        ? `After your last ${e.heavy.days} heavy days you woke at ${e.heavy.nextRecovery}% ${R} on average, against ${e.lighter.nextRecovery}% after lighter days.`
        : `After lighter days you usually wake at ${e.lighter.nextRecovery}% ${R}, against ${e.heavy.nextRecovery}% after heavy ones.`;
    } else {
      line = `Not enough days with scores yet to say what a day like this usually costs.`;
    }
    outlook = `<section class="card"><p class="kicker">What to expect tomorrow</p>
      <h2 class="title">${heavy && e.cost != null && e.cost >= 3 ? `Heavy days usually cost you about ${e.cost} points of ${esc(R)}.` : heavy ? "A heavy day." : "A lighter day."}</h2>
      <p class="lead">${esc(line)}</p></section>`;
  } else {
    outlook = `<section class="card"><p class="kicker">The night after</p><p class="lead">No wearable scores for the next morning.</p></section>`;
  }

  const rows = [
    metricRow({ name: "Meeting hours", value: round((cal?.totalDurationS ?? 0) / 3600, 1), usual: u.meetingHours, higherIs: "worse", step: 0.5, words: ["more", "fewer"] }),
    metricRow({ name: "After 6 pm", value: cal?.afterHoursCount ?? 0, usual: u.afterHours, higherIs: "worse", step: 1, words: ["more", "fewer"] }),
    ...scores.map((score) => metricRow({
      name: scoreLabel(score), value: score.morning, usual: score.usual.recovery,
      unit: "%", higherIs: "better", step: 3,
    })),
    ...(w.source ? [
      metricRow({ name: `Heart rate variability (${w.label})`, value: round(morning?.avgHrv), usual: u.hrv, unit: " ms", higherIs: "better", step: 2 }),
      metricRow({ name: `Resting heart rate (${w.label})`, value: round(morning?.lowestHr), usual: u.restingHr, unit: " bpm", higherIs: "worse", step: 1 }),
    ] : []),
    w.strainLabel ? metricRow({ name: `Day ${w.strainLabel}`, value: morning?.strain ?? null, usual: u.strain, higherIs: "neutral", step: 1 }) : "",
  ].join("");

  const meetings = listed.length
    ? `<section class="card" aria-labelledby="m-h">
        <div class="head"><h2 class="kicker" id="m-h">${isToday ? "Today's meetings" : "Meetings"}</h2>
          <span class="meta">${esc(plural(cal.eventCount, "meeting"))} · ${esc(hoursText(cal.totalDurationS))}${cal.afterHoursCount ? ` · ${cal.afterHoursCount} after 6 pm` : ""}</span></div>
        ${timeline(events)}
        <div class="mlist">${meetingRows(listed, w, openId, b.timeZone)}</div>
      </section>`
    : `<section class="card"><p class="kicker">Meetings</p><p class="lead">No meetings on the calendar.</p></section>`;

  const hits = w.hasIntradayHr && v.hits?.length ? hitsCard(v.hits, w, "Meetings that spiked, last 28 days") : "";

  screen(`
    ${dateBar({ label, sub: isToday ? fmtDay(b.date, { weekday: "short", month: "short", day: "numeric" }) : "", prevLabel: "Previous day", nextLabel: "Next day", nextDisabled: b.date >= today })}
    <p class="kicker center">${esc(scores.length > 1 ? "Calendar × WHOOP and Oura" : w.tagline || `Calendar × ${w.label}`)}</p>
    <div class="today-grid${w.source ? "" : " calendar-only"}">
      <div class="t-rings"><div class="rings${scores.length > 1 ? " dual" : ""}">${rings}</div></div>
      <div class="t-meetings">${meetings}</div>
      ${outlook ? `<div class="t-outlook">${outlook}</div>` : ""}
      <section class="t-usual list" aria-label="This day against your usual">${rows}</section>
      ${hits ? `<div class="t-hits">${hits}</div>` : ""}
    </div>
    ${syncFoot()}
  `);
  prefetch(viewPath(addDays(b.date, -1), addDays(b.date, -1)));
}

function hitsCard(hits, w, title) {
  const meetingHits = hits.filter((h) => h.kind !== "day");
  // Only whole-day hits: no card, rather than an empty one.
  if (!meetingHits.length) return "";
  return `<section class="card"><p class="kicker">${esc(title)}</p>
    <div class="mlist">${meetingHits
      .slice(0, 5)
      .map(
        (h) => `<button type="button" class="mrow" data-goto-day="${esc(h.day)}">
          <span class="t">${esc(shortDay(h.day))}</span>
          <span class="w"><b>${esc(h.title || "Untitled")}</b><small>${esc(shortSentence(h))}</small></span>
          ${zonePill(h.hrStress)}
        </button>`,
      )
      .join("")}</div></section>`;
}

/** The first sentence that says something the pill does not ("Your heart averaged about 87 bpm…"). */
function shortSentence(hit) {
  const parts = String(hit.sentence || "").split(/(?<=\.)\s+/).filter(Boolean);
  const head = hit.hrStress?.headline?.replace(/\.$/, "");
  const first = parts.find((x) => x.replace(/\.$/, "") !== head) ?? "";
  return first.replace(/ beats per minute/g, " bpm");
}

function syncLine() {
  const s = state.status;
  const w = state.wearable;
  if (!s?.lastSync?.created_at) return w?.source ? `${w.label} and Google Calendar` : "Google Calendar";
  const at = new Date(s.lastSync.created_at).toLocaleString("en-US", { timeZone: TZ, month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  return `Last synced ${at}${s.sandbox ? " · sandbox data" : ""}`;
}

/** What the calendar sync is doing, in a few words: "Syncing…", "Synced just now", or the error. */
function calSyncText() {
  const c = state.calSync;
  if (!c) return syncLine();
  if (c.running) return "Syncing your calendar…";
  if (c.error) return `Calendar sync failed: ${c.error}`;
  const mins = Math.floor((Date.now() - c.at) / 60000);
  const ago = mins < 1 ? "just now" : mins === 1 ? "1 min ago" : mins < 60 ? `${mins} min ago` : syncLine();
  const whoop = state.sourceDisplay?.whoop && c.whoopFailed ? " · WHOOP did not refresh" : "";
  const oura = state.sourceDisplay?.oura && c.ouraFailed ? " · Oura did not refresh" : "";
  const synced = mins < 60 ? `Synced ${ago}${state.status?.sandbox ? " · sandbox data" : ""}` : ago;
  return `${synced}${whoop}${oura}`;
}

function syncFoot() {
  const c = state.calSync;
  return `<p class="foot sync-foot"><span id="sync-state" role="status" class="${c?.error ? "sync-err" : ""}">${esc(calSyncText())}</span>
    <button type="button" class="sync-btn" data-action="resync" ${c?.running ? "disabled" : ""} aria-label="Refresh data">↻ Refresh</button></p>`;
}

function paintSyncState() {
  const el = qs("#sync-state");
  if (el) {
    el.textContent = calSyncText();
    el.className = state.calSync?.error ? "sync-err" : "";
  }
  const btn = qs(".sync-btn");
  if (btn) btn.disabled = Boolean(state.calSync?.running);
}

let syncPromise = null;

/**
 * Pull new and moved meetings from Google and today's WHOOP sleep, recovery
 * and strain now (POST /api/refresh), then redraw the screen from fresh data.
 * `full` re-lists the whole calendar window instead (More, Sync calendar).
 * Runs on page load, on coming back to the app, on the Refresh button and on
 * pull to refresh.
 */
function resyncCalendar({ full = false, quiet = false } = {}) {
  if (syncPromise) return syncPromise;
  const noGoogle = Boolean(state.status && state.status.googleConnected === false);
  if (noGoogle && full) return Promise.resolve(null);
  const prev = state.calSync;
  state.calSync = { ...(prev ?? {}), running: true, error: null };
  if (!quiet) paintSyncState();
  syncPromise = postRefresh(full, noGoogle)
    .then(({ calendar: r, whoopFailed, ouraFailed }) => {
      // No calendar on this install: keep the footer as it was, but still redraw.
      state.calSync = !r && noGoogle ? (prev ?? null) : { running: false, error: null, at: Date.now(), result: r, whoopFailed, ouraFailed };
      rememberSync();
      // Keep what is on screen, but treat it as stale so every screen refetches.
      for (const v of memory.values()) v.at = 0;
      peopleSearchCache.clear();
      render();
      return r;
    })
    .catch((err) => {
      if (err instanceof AccessNeededError) {
        state.calSync = prev ?? null;
        qs("#access").hidden = false;
      } else if (err.body?.needsGoogle && quiet) {
        // Calendar not connected: nothing to sync, nothing to shout about.
        state.calSync = prev ?? null;
      } else {
        state.calSync = { ...(prev ?? {}), running: false, error: err.message || String(err) };
      }
      paintSyncState();
      if (err.wearableRefreshed) {
        for (const v of memory.values()) v.at = 0;
        render();
      }
      return null;
    })
    .finally(() => {
      syncPromise = null;
    });
  return syncPromise;
}

/**
 * One refresh call for the calendar and WHOOP. Resolves { calendar, whoopFailed }
 * or throws the same errors the calendar sync did, so the callers stay as they
 * were. An older Worker without /api/refresh gets the calendar-only sync.
 */
async function postRefresh(full, noGoogle) {
  const body = JSON.stringify(full ? { mode: "live", full: true } : { mode: "live" });
  const init = { method: "POST", headers: { "content-type": "application/json" }, body };
  let r;
  try {
    r = await api("/api/refresh", init);
  } catch (err) {
    if (err.status !== 404) throw err;
    if (noGoogle) return { calendar: null, whoopFailed: false };
    return { calendar: await api("/api/calendar/sync", init), whoopFailed: false };
  }
  const whoopFailed = r.whoop?.ok === false;
  const ouraFailed = r.oura?.ok === false;
  const cal = r.calendar ?? {};
  if (cal.ok === false) {
    // No Google on this install: WHOOP still refreshed, the calendar has nothing to do.
    if (noGoogle && cal.needsGoogle) return { calendar: null, whoopFailed, ouraFailed };
    const err = new Error(cal.error || "Calendar sync failed");
    err.body = { needsGoogle: Boolean(cal.needsGoogle), error: cal.error };
    // WHOOP may still have new scores: the caller redraws for them.
    err.wearableRefreshed = r.whoop?.ok || r.oura?.ok;
    throw err;
  }
  return { calendar: cal, whoopFailed, ouraFailed };
}

const SYNC_STORE = "meetspike-calsync-at";
const AUTO_SYNC_MS = 2 * 60 * 1000;

function rememberSync() {
  try {
    sessionStorage.setItem(SYNC_STORE, String(Date.now()));
  } catch {
    /* ignore */
  }
}

/** Sync on its own unless this tab synced in the last two minutes. */
function autoSync() {
  let last = state.calSync?.at ?? 0;
  try {
    last = Math.max(last, Number(sessionStorage.getItem(SYNC_STORE) || 0));
  } catch {
    /* ignore */
  }
  if (Date.now() - last < AUTO_SYNC_MS) return;
  resyncCalendar({ quiet: true });
}

/**
 * Pull to refresh (installed app): new version check, then calendar, then the
 * screen's own data (meetings, people, scores and heart rate), redrawn in
 * place. Only the read endpoints the screens already use, plus the same
 * incremental calendar sync that runs on open and on the Refresh button.
 */
async function pullRefresh() {
  const update = checkForUpdate();
  await resyncCalendar({ quiet: true });
  for (const v of memory.values()) v.at = 0;
  peopleSearchCache.clear();
  const openId = shownMeetingId();
  if (openId) hrDetails.delete(openId);
  await render();
  await update;
}

/* ---------- Dates ---------- */

function recoveryChart(series, usual, sourceLabel) {
  const n = series.length;
  const W = 358;
  const left = 26;
  const step = (W - left - 4) / n;
  const x = (i) => left + step * i + step / 2;
  const y = (v) => 100 - v * 0.8;
  const pts = series.map((d, i) => (d.nextRecovery == null ? null : [x(i), y(d.nextRecovery), d.nextRecovery]));
  const segs = [];
  let cur = [];
  for (const p of pts) {
    if (p) cur.push(`${p[0].toFixed(1)},${p[1].toFixed(1)}`);
    else if (cur.length) {
      segs.push(cur);
      cur = [];
    }
  }
  if (cur.length) segs.push(cur);
  const scored = pts.filter(Boolean);
  const lows = [...scored].sort((a, b) => a[2] - b[2]).slice(0, Math.min(3, scored.length));
  const usualLine = usual != null ? `<line x1="${left}" y1="${y(usual)}" x2="${W}" y2="${y(usual)}" stroke="var(--muted)" stroke-dasharray="4 4" stroke-width="1"/>` : "";
  return `<svg class="chart" viewBox="0 0 ${W} 120" role="img" aria-label="Next-morning ${esc(sourceLabel)} for each day${lows[0] ? `, lowest ${lows[0][2]} percent` : ""}">
    <line x1="${left}" y1="20" x2="${W}" y2="20" stroke="var(--line)"/>
    <line x1="${left}" y1="60" x2="${W}" y2="60" stroke="var(--line)"/>
    <line x1="${left}" y1="100" x2="${W}" y2="100" stroke="var(--line-2)"/>
    <text x="0" y="24">100</text><text x="6" y="64">50</text><text x="12" y="104">0</text>
    ${usualLine}
    ${segs.map((s) => `<polyline points="${s.join(" ")}" fill="none" stroke="var(--good)" stroke-width="2" stroke-linejoin="round"/>`).join("")}
    ${scored.map((p) => `<circle cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="${n > 31 ? 2.5 : 4}" fill="var(--card)" stroke="var(--good)" stroke-width="2"/>`).join("")}
    ${lows.map((p) => `<text class="lbl" x="${p[0].toFixed(1)}" y="${(p[1] + 16).toFixed(1)}" text-anchor="middle">${p[2]}%</text>`).join("")}
  </svg>`;
}

function hoursChart(series) {
  const n = series.length;
  const W = 358;
  const left = 26;
  const step = (W - left - 4) / n;
  const max = Math.max(6, ...series.map((d) => d.meetingHours));
  const bw = Math.max(2, Math.min(16, step * 0.6));
  const every = n <= 14 ? 1 : n <= 31 ? 3 : 7;
  return `<svg class="chart" viewBox="0 0 ${W} 110" role="img" aria-label="Hours of meetings each day">
    <line x1="${left}" y1="80" x2="${W}" y2="80" stroke="var(--line-2)"/>
    <text x="12" y="84">0</text><text x="${max >= 10 ? 4 : 12}" y="24">${Math.round(max)}</text>
    ${series
      .map((d, i) => {
        const cx = left + step * i + step / 2;
        const h = (d.meetingHours / max) * 60;
        const label =
          i % every === 0
            ? `<text x="${cx.toFixed(1)}" y="96" text-anchor="middle">${esc(fmtDay(d.day, { weekday: "narrow" }))}</text><text x="${cx.toFixed(1)}" y="107" text-anchor="middle">${Number(d.day.slice(8))}</text>`
            : "";
        return `<rect x="${(cx - bw / 2).toFixed(1)}" y="${(80 - h).toFixed(1)}" width="${bw.toFixed(1)}" height="${h.toFixed(1)}" rx="2" fill="var(--sleep)"/>${label}`;
      })
      .join("")}
  </svg>`;
}

function renderDates(v) {
  const w = v.wearable;
  const r = v.range;
  const e = v.effect;
  const R = scoreLabel(w);
  const s = r.summary;
  let headline;
  let lead;
  if (e.cost != null && e.heavy.days >= 1 && e.lighter.days >= 1) {
    headline =
      e.cost >= 3
        ? `Your ${e.heavy.days === 1 ? "heavy day" : `${e.heavy.days} heavy days`} cost you ${e.cost} points of ${R}.`
        : e.cost <= -3
          ? `You recovered better after heavy days here, by ${-e.cost} points.`
          : `Heavy days barely moved your ${R} here.`;
    lead = `After ${e.heavyHours}+ hours or ${e.heavyMeetings}+ meetings, the next morning averaged ${e.heavy.nextRecovery}% ${R}. After lighter days it averaged ${e.lighter.nextRecovery}%.${
      e.heavy.days < 3 || e.lighter.days < 3 ? " Only a few days, so treat this as a hint." : ""
    }`;
  } else if (s.meetingCount) {
    headline = `${plural(s.meetingCount, "meeting")} across ${plural(s.daysWithMeetings, "day")}.`;
    lead = w.source ? (r.recovery.nReadiness ? "No heavy days to compare in this range." : `No ${w.label} scores in this range yet.`) : "";
  } else {
    headline = "No meetings in this range.";
    lead = "";
  }
  const stats = [
    ["Meetings", `${s.meetingCount} · ${hoursText(s.totalDurationS)}`],
    ["After 6 pm", String(s.afterHoursCount)],
    ...v.morningScores.map((score) => [
      `Avg ${scoreLabel(score)}`,
      score.average == null ? "—" : `${Math.round(score.average)}%${score.usual.recovery == null ? "" : ` · usual ${score.usual.recovery}%`}`,
    ]),
    ...(w.source ? [[`Avg sleep (${w.label})`, r.recovery.avgSleepScore == null ? "—" : `${Math.round(r.recovery.avgSleepScore)}%`]] : []),
  ]
    .map(([k, val]) => `<div class="stat"><p class="kicker">${esc(k)}</p><b>${esc(val)}</b></div>`)
    .join("");

  const costly = v.costly.length
    ? `<section class="list" aria-labelledby="c-h"><h2 class="title" id="c-h">Days that cost you</h2>
        ${v.costly
          .map((c) => {
            const bd = band(c.nextRecovery, w);
            return `<button type="button" class="rowlink" data-goto-day="${esc(c.day)}">
              <span class="w"><b>${esc(fmtDay(c.day))}</b><small>${esc(plural(c.meetingCount, "meeting"))} · ${c.meetingHours} h${c.afterHours ? ` · ${c.afterHours} after 6 pm` : ""}</small></span>
              <span class="end"><b>${c.nextRecovery}%</b><span class="band-${bd.cls}">${esc(bd.word)} · ${esc(R)}</span></span>
            </button>`;
          })
          .join("")}</section>`
    : "";

  const people = v.people.length
    ? `<section class="list" aria-labelledby="p-h"><h2 class="title" id="p-h">People on your heaviest days</h2>
        ${v.people
          .map(
            (p) => `<a class="rowlink" href="#person/${encodeURIComponent(p.email)}">
              <span class="avatar" aria-hidden="true">${esc(initials(p.name, p.email))}</span>
              <span class="w"><b>${esc(p.name || p.email)}</b><small>On ${plural(p.heavyDays, "heavy day")} · ${plural(p.meetings, "meeting")}</small></span>
              <span class="chev" aria-hidden="true">›</span>
            </a>`,
          )
          .join("")}</section>`
    : "";

  const n = spanDays(v.start, v.end);
  screen(`
    ${dateBar({ label: rangeLabel(v.start, v.end), sub: plural(n, "day"), prevLabel: `Previous ${n} days`, nextLabel: `Next ${n} days`, nextDisabled: v.end >= v.today })}
    <section class="card">
      <p class="kicker">${esc(rangeLabel(v.start, v.end))}</p>
      <h1>${esc(headline)}</h1>
      ${lead ? `<p class="lead">${esc(lead)}</p>` : ""}
      <div class="stats">${stats}</div>
    </section>
    <section class="card" aria-labelledby="ch-h">
      <h2 class="kicker" id="ch-h">${w.source ? `Meetings, then next-morning ${esc(R)}` : "Meeting hours"}</h2>
      ${w.source ? `
      <p class="chart-label">Next-morning ${esc(R)}, %${v.usual.recovery != null ? `. Dashed line is your usual ${v.usual.recovery}%.` : ""}</p>
      ${recoveryChart(v.series, v.usual.recovery, R)}
      <p class="chart-label">Hours of meetings that day</p>` : ""}
      ${hoursChart(v.series)}
    </section>
    ${costly}
    ${people}
    ${w.hasIntradayHr && v.hits?.length ? hitsCard(v.hits, w, "Meetings that spiked") : ""}
    ${syncFoot()}
  `);
}

/* ---------- People ---------- */

function peopleScope() {
  const { start, end } = peopleRangeDates(state.peopleRange, todayET());
  const label = PEOPLE_PRESETS[state.peopleRange.preset]?.[1] ?? rangeLabel(start, end);
  return { start, end, label };
}

function personHref(email) {
  return `#person/${encodeURIComponent(email)}`;
}

async function findPeople(query, signal) {
  const key = query.normalize("NFC").toLowerCase();
  const cached = peopleSearchCache.get(key);
  if (cached && Date.now() - cached.at < CACHE_MS) return cached.people;
  const { people } = await api(`/api/people/search?${new URLSearchParams({ q: query })}`, { signal });
  peopleSearchCache.delete(key);
  peopleSearchCache.set(key, { at: Date.now(), people });
  if (peopleSearchCache.size > 40) peopleSearchCache.delete(peopleSearchCache.keys().next().value);
  return people;
}

let personPageSize = 40;

function showPeopleShell(path, range) {
  const existing = qs("#people-results");
  if (existing?.dataset.path === path && existing.dataset.preset === state.peopleRange.preset) return;
  const isPerson = state.tab === "person";
  personPageSize = 40;
  screen(`
    ${isPerson ? '<a class="link" href="#people">‹ People</a>' : `<h1>People</h1>${peopleSearchHtml}`}
    ${peopleRangeHtml(state.peopleRange, range.start, range.end)}
    <div class="people-results" id="people-results">
      <p class="placeholder">Loading ${esc(range.label.toLowerCase())}…</p>
    </div>
  `);
  qs("#people-results").dataset.path = path;
  qs("#people-results").dataset.preset = state.peopleRange.preset;
  if (!isPerson) initPeopleSearch(qs(".people-search"), findPeople, personHref);
}

function renderPeople(v) {
  const { wearable, people, usualRecovery } = v;
  qs("#people-results").innerHTML = `
    <p class="kicker">${esc(peopleScope().label)}</p>
    ${wearable.source ? `<p class="lead">Who you met and how you woke up the morning after.${usualRecovery != null ? ` Your usual ${esc(scoreLabel(wearable))} is ${usualRecovery}%.` : ""}</p>` : ""}
    <div class="list">${people.length
      ? people.map((p) => {
          const bd = band(p.avg, wearable);
          return `<a class="rowlink" href="${personHref(p.email)}">
            <span class="avatar" aria-hidden="true">${esc(initials(p.name, p.email))}</span>
            <span class="w"><b>${esc(p.name || p.email)}</b><small>${plural(p.meetings, "meeting")} on ${plural(p.days, "day")}</small></span>
            ${wearable.source ? `<span class="end">${p.avg != null ? `<b>${p.avg}%</b><span class="band-${bd.cls}">${esc(scoreLabel(wearable))}</span>` : '<span class="status-off">no scores</span>'}</span>` : ""}
          </a>`;
        }).join("")
      : '<p class="empty">No meetings with other people in this range.</p>'}
    </div>
  `;
}

/** Heart rate in meetings with this person, from the per-meeting readings. */
function personHrLine(p) {
  return (p.trendsByHrSource ?? []).filter((t) => t.withCoverage).map((t) => {
    const bits = [
      `${t.source} heart rate in ${plural(t.withCoverage, "meeting")}${t.medianAvgBpm != null ? `: median ${Math.round(t.medianAvgBpm)} bpm` : ""}`,
    ];
    if (t.source !== "WHOOP + Oura") {
      bits.push(`${t.elevated} elevated, ${t.watching} worth watching, ${t.restored} restored`);
    }
    const points = t.spark ?? [];
    const step = Math.max(1, Math.ceil(points.length / 120));
    const spark = points.filter((_, i) => i % step === 0).reverse();
    const line = spark.length > 1 ? sparkline(spark.map((bpm, i) => ({ t: new Date(i * 60_000).toISOString(), bpm }))) : "";
    return `<p class="lead">${esc(bits.join(". "))}.${t.badge ? ` <b>${esc(t.badge)}</b>.` : ""}</p>${line}`;
  }).join("");
}

function renderPerson(p) {
  const w = p.wearable || state.wearable;
  const R = w ? scoreLabel(w) : "Morning score";
  const meetings = p.meetings ?? [];
  const byDay = new Map();
  for (const m of meetings) if (m.nextReadinessScore != null) byDay.set(m.day, m.nextReadinessScore);
  const scores = [...byDay.values()];
  const avg = scores.length ? Math.round(scores.reduce((a, b) => a + b, 0) / scores.length) : null;
  qs("#people-results").innerHTML = `
    <section class="card">
      <p class="kicker">${esc(peopleScope().label)}</p>
      <h1>${esc(p.name || p.email)}</h1>
      <p class="lead">${esc(plural(meetings.length, "meeting"))}.${
        avg != null ? ` On mornings after a meeting with them you woke at ${avg}% ${esc(R)} on average, over ${plural(scores.length, "morning")}.` : ""
      }${scores.length && scores.length < 4 ? " Only a few mornings, so this is a hint, not a pattern." : ""}</p>
      ${personHrLine(p)}
    </section>
    <section class="card"><p class="kicker">Meetings</p><div class="mlist">${meetings.slice(0, personPageSize)
      .map((m) => {
        const bd = band(m.nextReadinessScore, w);
        const hr = m.hrStress;
        const showHr = w?.hasIntradayHr;
        const hrBit = showHr && hr?.coverage === "ok" && hr.meanBpm != null ? ` · ${meetingHrLabel(hr)} ${Math.round(hr.meanBpm)} bpm` : "";
        const pill = showHr
          ? zonePill(hr)
          : m.nextReadinessScore != null
            ? `<span class="pill ${bd.cls}">${m.nextReadinessScore}% · ${esc(R)}</span>`
            : w?.source ? `<span class="pill none">No score</span>` : "";
        return `<button type="button" class="mrow" data-goto-day="${esc(m.day)}">
          <span class="t">${esc(shortDay(m.day))}</span>
          <span class="w"><b>${esc(m.title || "Untitled")}</b><small>${esc(clockFromLocal(m.startLocal))}${esc(hrBit)}${
            showHr && m.nextReadinessScore != null ? ` · ${m.nextReadinessScore}% ${esc(R)}` : ""
          }</small></span>
          ${pill}
        </button>`;
      })
      .join("")}</div>
      ${!meetings.length ? '<p class="empty">No meetings with this person in this range.</p>' : ""}
      ${meetings.length > personPageSize ? '<button type="button" class="secondary" data-action="person-more">Show more meetings</button>' : ""}
    </section>
  `;
}

/* ---------- More ---------- */

function renderMore() {
  const s = state.status ?? {};
  const a = state.askInfo;
  const display = state.sourceDisplay;
  const saving = state.sourceDisplaySaving;
  const row = (title, sub, status, cls, attrs) =>
    `<${attrs.href ? `a href="${attrs.href}"` : `button type="button" data-action="${attrs.action}"`} class="rowlink">
      <span class="w"><b>${esc(title)}</b><small>${esc(sub)}</small></span>
      ${status ? `<span class="${cls}">${esc(status)}</span>` : ""}<span class="chev" aria-hidden="true">›</span>
    </${attrs.href ? "a" : "button"}>`;
  screen(`
    <h1>More</h1>
    <p class="kicker section-k">Data</p>
    <div class="list">
      ${row("Sync calendar", calSyncText() || "Re-read the last 3 weeks and the next month", "", "", { action: "sync" })}
    </div>
    <h2 class="kicker section-k" id="source-display-heading">Show data</h2>
    <div class="list" role="group" aria-labelledby="source-display-heading">
      ${[["oura", "Oura"], ["whoop", "WHOOP"]].map(([source, label]) => `
        <label class="rowlink source-toggle">
          <span class="w"><b>${label}</b></span>
          <input type="checkbox" role="switch" data-display-source="${source}" ${display?.[source] ? "checked" : ""} ${!display || saving ? "disabled" : ""}>
        </label>`).join("")}
    </div>
    <p class="lead source-display-note">Data keeps syncing when hidden.</p>
    ${saving || state.sourceDisplayError ? `<p class="lead" role="status">${esc(saving ? "Saving…" : state.sourceDisplayError)}</p>` : ""}
    <p class="kicker section-k">Connections</p>
    <div class="list">
      ${(s.wearables ?? []).map((wearable) => {
        const history = wearable.history?.min
          ? `Last data ${fmtDay(wearable.lastDataDay)} · History ${wearable.history.min} to ${wearable.history.max}`
          : "No data yet";
        return row(wearable.label, history, wearable.connected ? "Connected" : "Connect",
          wearable.connected ? "status-ok" : "status-todo", { href: `/setup?wearable=${wearable.source}` });
      }).join("")}
      ${row("Google Calendar", "Read-only", s.googleConnected ? "Connected" : "Connect", s.googleConnected ? "status-ok" : "status-todo", { href: "/setup" })}
    </div>
    <p class="kicker section-k">Ask your data</p>
    <div class="list">
      ${row("AI key", "Chat with your data", a?.connected ? `Key …${a.tail}` : a && !a.available ? "Not set up" : "Add key", a?.connected ? "status-ok" : "status-todo", { action: "open-ask" })}
    </div>
    <p class="kicker section-k">Setup</p>
    <div class="list">
      ${row("Setup guide", "Keys, redirect links, first import", "", "", { href: "/setup" })}
      ${row("Privacy", "What is stored and where", "", "", { action: "privacy" })}
      ${canOfferInstall() ? row("Install app", "Add Meetspike to your Home Screen", "", "", { action: "install" }) : ""}
    </div>
    ${
      state.showPrivacy
        ? `<section class="share-note"><span class="kicker">Privacy</span>
      <span>Everything lives in your own Cloudflare account: scores and meetings in D1, raw downloads in R2, sign-in tokens in KV.</span>
      <span>Google Calendar is read-only. Nothing is shared with anyone unless you use Ask your data, which sends Anthropic the numbers it needs to answer.</span></section>`
        : ""
    }
    <p id="more-msg" class="lead" role="status"></p>
    <p class="foot" id="app-version">${state.appVersion ? `Version ${esc(state.appVersion)}` : ""}</p>
  `);
  if (state.appVersion === undefined) {
    state.appVersion = null;
    appVersion().then((v) => {
      state.appVersion = v ?? undefined;
      const el = qs("#app-version");
      if (el && v) el.textContent = `Version ${v}`;
    });
  }
}

async function changeSourceDisplay(source, enabled) {
  if (state.sourceDisplaySaving || !state.sourceDisplay) return;
  state.sourceDisplaySaving = true;
  state.sourceDisplayError = "";
  qs("#screen").querySelectorAll("[data-display-source]").forEach((input) => { input.disabled = true; });
  try {
    const display = await api(SOURCE_DISPLAY_PATH, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ [source]: enabled }),
    });
    state.sourceDisplay = display;
    setAskSourceDisplay(display);
    renderToken++;
    invalidateDisplayViews();
    state.openMeeting = undefined;
  } catch (err) {
    if (err instanceof AccessNeededError) qs("#access").hidden = false;
    state.sourceDisplayError = `Could not save display setting. ${err.message}`;
  } finally {
    state.sourceDisplaySaving = false;
    if (state.tab === "more") {
      renderMore();
      qs(`[data-display-source="${source}"]`)?.focus({ preventScroll: true });
    } else {
      render();
    }
  }
}

async function syncCalendar() {
  const msg = qs("#more-msg");
  if (msg) msg.textContent = "Syncing your calendar…";
  const r = await resyncCalendar({ full: true });
  const m = qs("#more-msg");
  if (!m) return;
  if (r?.pending) {
    m.textContent = "Still syncing in the background. New meetings show up when it finishes.";
  } else if (r) {
    const changed = (r.written ?? 0) + (r.removed ?? 0);
    m.textContent = `Synced just now. ${plural(changed, "meeting")} updated.`;
  } else if (state.calSync?.error) m.textContent = `Calendar sync failed: ${state.calSync.error}`;
}

/* ---------- Ask (the popup lives in ask-panel.js) ---------- */

/** Key status for the More screen. The popup loads its own. */
async function loadAskInfo() {
  try {
    state.askInfo = await api("/api/ask/status");
  } catch (err) {
    if (err instanceof AccessNeededError) qs("#access").hidden = false;
    state.askInfo = { available: false, connected: false };
  }
  return state.askInfo;
}

function askScope() {
  if (state.tab === "people" || state.tab === "person") return peopleScope();
  return state.tab === "dates" ? { start: state.start, end: state.end, label: rangeLabel(state.start, state.end) } : null;
}

/* ---------- Date picker ---------- */

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

function openPicker() {
  const single = state.tab !== "dates";
  const start = single ? state.day : state.start;
  const end = single ? state.day : state.end;
  state.picker = { start, end, editing: null, month: end.slice(0, 7) };
  renderPicker();
  qs("#sheet").hidden = false;
  qs("#sheet .panel")?.focus();
}

function closePicker() {
  state.picker = null;
  qs("#sheet").hidden = true;
  qs("#sheet").innerHTML = "";
  qs('[data-action="open-picker"]')?.focus();
}

function shiftMonth(ym, n) {
  let y = Number(ym.slice(0, 4));
  let m = Number(ym.slice(5, 7)) - 1 + n;
  y += Math.floor(m / 12);
  m = ((m % 12) + 12) % 12;
  return `${y}-${String(m + 1).padStart(2, "0")}`;
}

function renderPicker() {
  const p = state.picker;
  const today = todayET();
  const thisMonth = today.slice(0, 7);
  const [y, mo] = [Number(p.month.slice(0, 4)), Number(p.month.slice(5, 7))];
  const first = `${p.month}-01`;
  const offset = (new Date(`${first}T12:00:00Z`).getUTCDay() + 6) % 7;
  const daysIn = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  const cells = [];
  for (let i = 0; i < offset; i++) cells.push(`<span class="cell"></span>`);
  for (let d = 1; d <= daysIn; d++) {
    const day = `${p.month}-${String(d).padStart(2, "0")}`;
    const sel = day === p.start || day === p.end;
    const edge = p.start && p.end && p.start !== p.end;
    const inBand = edge && day >= p.start && day <= p.end;
    const cls = ["cell", inBand ? "band" : "", inBand && day === p.start ? "first" : "", inBand && day === p.end ? "last" : ""].filter(Boolean).join(" ");
    const btnCls = [sel ? "sel" : "", day === today ? "today" : ""].filter(Boolean).join(" ");
    cells.push(
      `<span class="${cls}"><button type="button" class="${btnCls}" data-pick="${day}" ${day > today ? "disabled" : ""} aria-label="${esc(fmtDay(day, { weekday: "long", month: "long", day: "numeric" }))}${day === today ? ", today" : ""}" aria-pressed="${sel}">${d}</button></span>`,
    );
  }
  const complete = Boolean(p.start && p.end);
  const n = complete ? spanDays(p.start, p.end) : 0;
  const note = !p.start
    ? "Tap a start day, then an end day."
    : !p.end
      ? "Now tap the end day."
      : `${rangeLabel(p.start, p.end)} · ${plural(n, "day")}`;
  const ready = complete;
  const lastMonth = shiftMonth(thisMonth, -1);
  const lastMonthEnd = `${lastMonth}-${String(new Date(Date.UTC(Number(lastMonth.slice(0, 4)), Number(lastMonth.slice(5, 7)), 0)).getUTCDate()).padStart(2, "0")}`;
  const quick = [
    ["Today", today, today],
    ["Yesterday", addDays(today, -1), addDays(today, -1)],
    ["Last 7 days", ...Object.values(presetRange("7d", today))],
    ["Last 30 days", addDays(today, -29), today],
    ["This month", ...Object.values(presetRange("month", today))],
    ["Last month", `${lastMonth}-01`, lastMonthEnd],
  ];
  qs("#sheet").innerHTML = `<div class="panel" role="dialog" aria-modal="true" aria-labelledby="pk-h" tabindex="-1">
    <div class="grab" aria-hidden="true"></div>
    <div class="top"><h2 class="title" id="pk-h">Pick dates</h2>
      <span><button type="button" class="link" data-action="pk-clear">Clear</button> &nbsp; <button type="button" class="link" data-action="pk-close">Close</button></span></div>
    <div class="fields">
      <button type="button" class="field" data-field="start" aria-pressed="${p.editing === "start" || !p.start}"><small>From</small><b>${p.start ? esc(shortDay(p.start)) : "Pick"}</b></button>
      <button type="button" class="field" data-field="end" aria-pressed="${p.editing === "end"}"><small>To</small><b>${p.end ? esc(shortDay(p.end)) : "Pick"}</b></button>
    </div>
    <div class="chips">${quick.map(([l, s, e]) => `<button type="button" class="chip" data-quick="${s}|${e}">${esc(l)}</button>`).join("")}</div>
    <div class="month">
      <button type="button" data-month="-1" aria-label="Previous month">‹</button>
      <b>${MONTHS[mo - 1]} ${y}</b>
      <button type="button" data-month="1" aria-label="Next month" ${p.month >= thisMonth ? "disabled" : ""}>›</button>
    </div>
    <div class="cal">${["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"].map((d) => `<span class="dow" aria-hidden="true">${d}</span>`).join("")}${cells.join("")}</div>
    <p class="pick-note" aria-live="polite">${esc(note)}</p>
    <button type="button" class="primary" data-action="pk-apply" ${ready ? "" : "disabled"}>${
      !complete ? "Pick an end date" : p.start === p.end ? `Show ${esc(shortDay(p.start))}` : `Show ${plural(n, "day")}`
    }</button>
  </div>`;
}

function pickDay(day) {
  const p = state.picker;
  if (p.editing === "end" && p.start) {
    if (day < p.start) Object.assign(p, { end: p.start, start: day });
    else p.end = day;
    p.editing = null;
  } else if (p.editing === "start" && p.end && day <= p.end) {
    p.start = day;
    p.editing = null;
  } else {
    Object.assign(p, { start: day, end: null, editing: "end" });
  }
  renderPicker();
}

function applyPicker() {
  const { start, end } = state.picker;
  closePicker();
  if (start === end) go({ tab: "today", day: start });
  else go({ tab: "dates", start, end });
}

/* ---------- render loop ---------- */

let renderToken = 0;

async function render() {
  const token = ++renderToken;
  clearTimeout(nextLiveMeetingTimer);
  setTabs();
  qs("#screen").dataset.tab = state.tab;
  const fresh = (fn) => (data) => {
    if (token !== renderToken) return;
    noteMeta(data);
    fn(data);
  };
  try {
    if (state.tab === "today") {
      if (!memory.has(viewPath(state.day, state.day))) screen(`<p class="placeholder">Loading ${esc(shortDay(state.day))}…</p>`);
      await load(viewPath(state.day, state.day), fresh(renderToday));
    } else if (state.tab === "dates") {
      if (!memory.has(viewPath(state.start, state.end))) screen(`<p class="placeholder">Loading ${esc(rangeLabel(state.start, state.end))}…</p>`);
      await load(viewPath(state.start, state.end), fresh(renderDates));
    } else if (state.tab === "people" || state.tab === "person") {
      const range = peopleScope();
      const isPerson = state.tab === "person";
      const path = `/api/people${isPerson ? `/${encodeURIComponent(state.person)}/meetings` : ""}?start=${range.start}&end=${range.end}${isPerson ? "&compact=1" : ""}`;
      showPeopleShell(path, range);
      await load(path, fresh(isPerson ? renderPerson : renderPeople));
    } else if (state.tab === "more") {
      renderMore();
      load(viewPath(todayET(), todayET()), fresh(renderMore)).catch(async () => {
        if (token !== renderToken) return;
        try {
          const sourceDisplay = await api(SOURCE_DISPLAY_PATH);
          if (token === renderToken) noteMeta({ sourceDisplay });
        } catch (err) {
          if (token !== renderToken) return;
          if (err instanceof AccessNeededError) qs("#access").hidden = false;
          state.sourceDisplayError = "Could not load display settings.";
        }
        if (token === renderToken) renderMore();
      });
      loadAskInfo().then(() => token === renderToken && state.tab === "more" && renderMore());
    }
  } catch (err) {
    if (token === renderToken) {
      const results = qs("#people-results");
      if (results && !(err instanceof AccessNeededError)) {
        results.innerHTML = `<p class="error">${esc(err.message)}</p><button type="button" class="secondary" data-action="retry">Try again</button>`;
      } else showError(err);
    }
  }
}

/* ---------- events ---------- */

function stepDates(dir) {
  if (state.tab === "today") {
    const next = addDays(state.day, dir);
    if (next > todayET()) return;
    go({ day: next, openMeeting: undefined });
  } else if (state.tab === "dates") {
    const n = spanDays(state.start, state.end);
    let start = addDays(state.start, dir * n);
    let end = addDays(state.end, dir * n);
    if (end > todayET()) {
      end = todayET();
      start = addDays(end, -(n - 1));
    }
    go({ start, end });
  }
}

document.addEventListener("click", (ev) => {
  const t = ev.target.closest("[data-action],[data-meeting],[data-goto-day],[data-pick],[data-quick],[data-month],[data-field],a[data-tab]");
  if (!t) {
    if (ev.target === qs("#sheet")) closePicker();
    return;
  }
  if (t.dataset.tab) {
    ev.preventDefault();
    const tab = t.dataset.tab;
    if (tab === "ask") openAsk();
    else go({ tab });
    return;
  }
  const a = t.dataset.action;
  if (a === "prev") stepDates(-1);
  else if (a === "next") stepDates(1);
  else if (a === "open-picker") openPicker();
  else if (a === "pk-close") closePicker();
  else if (a === "pk-clear") Object.assign(state.picker, { start: null, end: null, editing: null }) && renderPicker();
  else if (a === "pk-apply") applyPicker();
  else if (a === "retry") render();
  else if (a === "person-more") {
    const results = qs("#people-results");
    const model = memory.get(results.dataset.path)?.data;
    if (model) {
      const firstNew = personPageSize;
      personPageSize += 40;
      renderPerson(model);
      results.querySelectorAll(".mrow")[firstNew]?.focus();
    }
  }
  else if (a === "mmenu") toggleMeetingMenu(t.dataset.id);
  else if (a === "mact") runMeetingAction(t.dataset.act, t.dataset.id);
  else if (a === "reload") location.reload();
  else if (a === "sync") syncCalendar();
  else if (a === "install") openInstallSheet();
  else if (a === "resync") resyncCalendar();
  else if (a === "privacy") {
    state.showPrivacy = !state.showPrivacy;
    renderMore();
  } else if (a === "open-ask") openAsk();
  else if (t.dataset.meeting) {
    state.openMeeting = t.getAttribute("aria-expanded") === "true" ? null : t.dataset.meeting;
    state.meetingUi = null;
    render();
  } else if (t.dataset.gotoDay) go({ tab: "today", day: t.dataset.gotoDay, openMeeting: null });
  else if (t.dataset.pick) pickDay(t.dataset.pick);
  else if (t.dataset.quick) {
    const [s, e] = t.dataset.quick.split("|");
    Object.assign(state.picker, { start: s, end: e, editing: null, month: e.slice(0, 7) });
    renderPicker();
  } else if (t.dataset.month) {
    state.picker.month = shiftMonth(state.picker.month, Number(t.dataset.month));
    renderPicker();
  } else if (t.dataset.field) {
    const p = state.picker;
    if (t.dataset.field === "end" && !p.start) return;
    p.editing = t.dataset.field;
    p.month = (t.dataset.field === "start" ? p.start : p.end || p.start)?.slice(0, 7) ?? p.month;
    renderPicker();
  }
});

document.addEventListener("change", (event) => {
  const source = event.target.dataset.displaySource;
  if (source === "oura" || source === "whoop") {
    changeSourceDisplay(source, event.target.checked);
    return;
  }
  if (event.target.id !== "people-range") return;
  const preset = event.target.value;
  if (preset === "custom") {
    const form = qs("#people-custom-range");
    form.hidden = false;
    form.elements.start.focus();
  } else {
    go({ peopleRange: { preset } });
    qs("#people-range")?.focus({ preventScroll: true });
  }
});

document.addEventListener("submit", (event) => {
  const form = event.target;
  if (form.classList?.contains("mtimes")) {
    event.preventDefault();
    const picked = readTimes(form, dayTimeZone(), dayMeeting(form.dataset.id));
    if (picked.error) {
      // Keep what was typed, so fixing one field does not mean typing both again.
      state.meetingUi = { ...state.meetingUi, error: picked.error, typed: { start: form.elements.start.value, end: form.elements.end.value } };
      render();
    } else {
      // A save the server refuses keeps the typed times too.
      state.meetingUi = { ...state.meetingUi, typed: { start: form.elements.start.value, end: form.elements.end.value } };
      commitMeetingChange(form.dataset.id, picked.body);
    }
    return;
  }
  if (form.id !== "people-custom-range") return;
  event.preventDefault();
  const start = form.elements.start.value;
  const end = form.elements.end.value;
  if (!validPeopleDates(start, end)) {
    form.elements.end.setCustomValidity("Choose a valid date on or after the start date.");
    form.elements.end.reportValidity();
    return;
  }
  go({ peopleRange: { preset: "custom", start, end } });
  qs("#people-range")?.focus({ preventScroll: true });
});

document.addEventListener("input", (event) => {
  if (event.target.form?.id === "people-custom-range") event.target.form.elements.end.setCustomValidity("");
});

document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape" && state.picker) closePicker();
  else if (ev.key === "Escape" && state.meetingUi && !state.meetingUi.busy) {
    const id = state.meetingUi.id;
    state.meetingUi = null;
    render().then(() => qs(`.mmenu[data-id="${CSS.escape(id)}"]`)?.focus());
  }
});

window.addEventListener("popstate", () => {
  readLocation();
  if (state.openAskOnLoad) {
    state.openAskOnLoad = false;
    openAsk();
  }
  render();
});

// Coming back to the tab after a while: refresh what is on screen.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return stopLivePanel();
  invalidateDisplayViews();
  if (state.tab === "person" || state.tab === "people") {
    const results = qs("#people-results");
    if (results) results.dataset.path = "";
  }
  render();
  autoSync();
});

initPwa();
initAskPanel({ getScope: askScope });
initPullToRefresh({ enabled: isInstalledApp, tab: () => state.tab, onRefresh: pullRefresh });
readLocation();
writeLocation(true);
if (state.openAskOnLoad) {
  state.openAskOnLoad = false;
  openAsk();
}
render();
// A refresh (or opening the installed app) also asks Google for anything new,
// then redraws. Without this a reload only re-read what was already stored.
autoSync();

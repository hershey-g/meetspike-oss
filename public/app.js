/**
 * Meetspike front end. One request per screen (/api/view), cached so a screen
 * you have seen opens instantly and refreshes quietly behind it.
 */
import { addDays, presetRange } from "./range-presets.js";

const TZ = "America/New_York";
const CACHE_MS = 5 * 60 * 1000;
const STORE = "meetspike-cache-v1";
const CHAT_STORE = "meetspike-chat-v1";
const MAX_RANGE_DAYS = 92;
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

function loadStore() {
  try {
    const raw = sessionStorage.getItem(STORE);
    if (!raw) return;
    // A full page load (refresh, new tab, opening the installed app) shows
    // what this tab last saw at once, but treats all of it as stale so every
    // screen refetches. Only in-app navigation within CACHE_MS skips the fetch.
    for (const [k, v] of Object.entries(JSON.parse(raw))) memory.set(k, { ...v, at: 0 });
  } catch {
    /* private mode or blocked storage: memory cache only */
  }
}

function saveStore() {
  try {
    const keep = [...memory.entries()].slice(-24);
    sessionStorage.setItem(STORE, JSON.stringify(Object.fromEntries(keep)));
  } catch {
    /* ignore */
  }
}

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
    throw err;
  }
  if (!body) throw new AccessNeededError();
  return body;
}

const inflight = new Map();

/** Cached GET: returns what is cached (if any) right away through `onData`, then the fresh copy. */
async function load(path, onData, { force = false } = {}) {
  const hit = memory.get(path);
  if (hit && !force) {
    onData(hit.data, true);
    if (Date.now() - hit.at < CACHE_MS) return hit.data;
  }
  let p = inflight.get(path);
  if (!p) {
    p = api(path).finally(() => inflight.delete(path));
    inflight.set(path, p);
  }
  const data = await p;
  memory.set(path, { at: Date.now(), data });
  saveStore();
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
  wearable: null,
  status: null,
  openMeeting: null,
  picker: null,
  ask: null,
  chat: loadChat(),
  pending: false,
  showPrivacy: false,
};

function readLocation() {
  const p = new URLSearchParams(location.search);
  const hash = location.hash.replace(/^#/, "");
  const valid = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d ?? "");
  const day = p.get("day") ?? p.get("date");
  if (valid(day)) state.day = day;
  const start = p.get("start");
  const end = p.get("end");
  if (valid(start) && valid(end) && start <= end && spanDays(start, end) <= MAX_RANGE_DAYS) {
    state.start = start;
    state.end = end;
  }
  if (hash.startsWith("person/")) {
    state.tab = "person";
    state.person = decodeURIComponent(hash.slice(7));
  } else if (["today", "dates", "people", "more", "ask"].includes(hash)) {
    state.tab = hash;
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
  for (const a of document.querySelectorAll("[data-tab]")) {
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
  if (data?.status?.displayTitle) document.title = data.status.displayTitle;
  setTabs();
}

function screen(html) {
  qs("#screen").innerHTML = html;
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

function zonePill(hr) {
  if (!hr || hr.coverage !== "ok" || !hr.zone) return `<span class="pill none">No HR</span>`;
  const cls = hr.zone === "high" ? "bad" : hr.zone === "moderate" ? "warn" : "good";
  return `<span class="pill ${cls}">${esc(hr.headline)}</span>`;
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

function meetingMeta(e) {
  const people = (e.attendees ?? []).map((a) => a.name || a.email.split("@")[0]);
  const bits = [];
  if (e.sourceType && e.sourceType !== "calendar") bits.push(e.sourceType.startsWith("plaud_phone") ? "phone call" : "recording");
  else if (e.kind) bits.push(e.kind.replaceAll("_", " "));
  if (people.length) bits.push(people.length > 2 ? `${people.slice(0, 2).join(", ")} +${people.length - 2}` : people.join(", "));
  if (e.afterHours) bits.push("after 6 pm");
  return bits.join(" · ");
}

function meetingRows(events, w) {
  return events
    .map((e) => {
      const open = state.openMeeting === e.id;
      const mins = Math.round((e.durationS ?? 0) / 60);
      const len = mins >= 60 ? `${Math.floor(mins / 60)} h${mins % 60 ? ` ${mins % 60} m` : ""}` : `${mins} m`;
      const hr = w?.hasIntradayHr ? zonePill(e.hrStress) : "";
      const detail =
        open && w?.hasIntradayHr
          ? `<div>${sparkline(e.hrStress?.series)}<p class="lead">${esc(e.hrStress?.story || "No ring heart-rate in this window.")}</p></div>`
          : "";
      return `<button type="button" class="mrow" data-meeting="${esc(e.id)}" aria-expanded="${open}">
          <span class="t">${esc(clockFromLocal(e.startLocal))}</span>
          <span class="w"><b>${esc(e.title || "Untitled")}</b><small>${esc(meetingMeta(e))}</small></span>
          ${hr || `<span class="len">${esc(len)}</span>`}
        </button>${detail}`;
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

/* ---------- Today ---------- */

function renderToday(v) {
  const w = v.wearable;
  const b = v.day;
  const today = v.today;
  const morning = b.priorNight;
  const next = b.nextMorning;
  const cal = b.calendar;
  const events = cal?.events ?? [];
  const R = w.readinessLabel;
  const u = v.usual;
  const isToday = b.date === today;
  const label = isToday ? "Today" : fmtDay(b.date, { weekday: "short", month: "short", day: "numeric" });

  const rec = morning?.readinessScore ?? null;
  const rb = band(rec, w);
  const rings = [
    ring({
      label: R.toUpperCase(),
      value: rec == null ? "—" : `${rec}%`,
      pct: (rec ?? 0) / 100,
      color: rb ? `var(--${rb.cls})` : "var(--faint)",
      note: rb?.word ?? "No score",
      aria: rec == null ? `${R}: no score` : `${R} ${rec} percent, ${rb.word}`,
    }),
    ring({
      label: "SLEEP",
      value: morning?.sleepScore == null ? "—" : `${morning.sleepScore}%`,
      pct: (morning?.sleepScore ?? 0) / 100,
      color: "var(--sleep)",
      note: morning?.totalSleepS ? `${Math.floor(morning.totalSleepS / 3600)} h ${Math.round((morning.totalSleepS % 3600) / 60)} m` : "No score",
      aria: morning?.sleepScore == null ? "Sleep: no score" : `Sleep ${morning.sleepScore} percent`,
    }),
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
  const r = R.toLowerCase();
  if (next?.readinessScore != null) {
    const diff = u.recovery != null ? next.readinessScore - u.recovery : null;
    const vs =
      diff == null ? "" : Math.abs(diff) < 3 ? ` That is about your usual ${u.recovery}%.` : ` That is ${Math.abs(diff)} ${diff < 0 ? "under" : "over"} your usual ${u.recovery}%.`;
    outlook = `<section class="card"><p class="kicker">The night after</p>
      <h2 class="title">You woke at ${next.readinessScore}% ${esc(r)}${next.sleepScore != null ? `, sleep ${next.sleepScore}%` : ""}.</h2>
      <p class="lead">${esc(vs.trim())}</p></section>`;
  } else if (b.date >= addDays(today, -1)) {
    let line;
    if (e.cost != null && e.heavy.days >= 2 && e.lighter.days >= 2) {
      line = heavy
        ? `After your last ${e.heavy.days} heavy days you woke at ${e.heavy.nextRecovery}% on average, against ${e.lighter.nextRecovery}% after lighter days.`
        : `After lighter days you usually wake at ${e.lighter.nextRecovery}%, against ${e.heavy.nextRecovery}% after heavy ones.`;
    } else {
      line = `Not enough days with scores yet to say what a day like this usually costs.`;
    }
    outlook = `<section class="card"><p class="kicker">What to expect tomorrow</p>
      <h2 class="title">${heavy && e.cost != null && e.cost >= 3 ? `Heavy days usually cost you about ${e.cost} points.` : heavy ? "A heavy day." : "A lighter day."}</h2>
      <p class="lead">${esc(line)}</p></section>`;
  } else {
    outlook = `<section class="card"><p class="kicker">The night after</p><p class="lead">No ${esc(w.label)} score for the next morning.</p></section>`;
  }

  const rows = [
    metricRow({ name: "Meeting hours", value: round((cal?.totalDurationS ?? 0) / 3600, 1), usual: u.meetingHours, higherIs: "worse", step: 0.5, words: ["more", "fewer"] }),
    metricRow({ name: "After 6 pm", value: cal?.afterHoursCount ?? 0, usual: u.afterHours, higherIs: "worse", step: 1, words: ["more", "fewer"] }),
    metricRow({ name: "Heart rate variability", value: round(morning?.avgHrv), usual: u.hrv, unit: " ms", higherIs: "better", step: 2 }),
    metricRow({ name: "Resting heart rate", value: round(morning?.lowestHr), usual: u.restingHr, unit: " bpm", higherIs: "worse", step: 1 }),
    w.strainLabel ? metricRow({ name: `Day ${w.strainLabel}`, value: morning?.strain ?? null, usual: u.strain, higherIs: "neutral", step: 1 }) : "",
  ].join("");

  const meetings = events.length
    ? `<section class="card" aria-labelledby="m-h">
        <div class="head"><h2 class="kicker" id="m-h">${isToday ? "Today's meetings" : "Meetings"}</h2>
          <span class="meta">${esc(plural(cal.eventCount, "meeting"))} · ${esc(hoursText(cal.totalDurationS))}${cal.afterHoursCount ? ` · ${cal.afterHoursCount} after 6 pm` : ""}</span></div>
        ${timeline(events)}
        <div class="mlist">${meetingRows(events, w)}</div>
      </section>`
    : `<section class="card"><p class="kicker">Meetings</p><p class="lead">No meetings on the calendar.</p></section>`;

  const hits = w.hasIntradayHr && v.hits?.length ? hitsCard(v.hits, w, "Meetings that spiked, last 28 days") : "";

  screen(`
    ${dateBar({ label, sub: isToday ? fmtDay(b.date, { weekday: "short", month: "short", day: "numeric" }) : "", prevLabel: "Previous day", nextLabel: "Next day", nextDisabled: b.date >= today })}
    <p class="kicker center">${esc(w.tagline || `Calendar × ${w.label}`)}</p>
    <div class="rings">${rings}</div>
    ${meetings}
    ${outlook}
    <section class="list" aria-label="This day against your usual">${rows}</section>
    ${hits}
    <p class="foot">${esc(syncLine())}</p>
  `);
  prefetch(viewPath(addDays(b.date, -1), addDays(b.date, -1)));
}

function hitsCard(hits, w, title) {
  return `<section class="card"><p class="kicker">${esc(title)}</p>
    <div class="mlist">${hits
      .filter((h) => h.kind !== "day")
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
  if (!s?.lastSync?.created_at) return w ? `${w.label} and Google Calendar` : "";
  const at = new Date(s.lastSync.created_at).toLocaleString("en-US", { timeZone: TZ, month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  return `Last synced ${at}${s.sandbox ? " · sandbox data" : ""}`;
}

/* ---------- Dates ---------- */

function recoveryChart(series, usual) {
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
  return `<svg class="chart" viewBox="0 0 ${W} 120" role="img" aria-label="Next-morning recovery for each day${lows[0] ? `, lowest ${lows[0][2]} percent` : ""}">
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
  const R = w.readinessLabel.toLowerCase();
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
    lead = `After ${e.heavyHours}+ hours or ${e.heavyMeetings}+ meetings, the next morning averaged ${e.heavy.nextRecovery}%. After lighter days it averaged ${e.lighter.nextRecovery}%.${
      e.heavy.days < 3 || e.lighter.days < 3 ? " Only a few days, so treat this as a hint." : ""
    }`;
  } else if (s.meetingCount) {
    headline = `${plural(s.meetingCount, "meeting")} across ${plural(s.daysWithMeetings, "day")}.`;
    lead = r.recovery.nReadiness ? `No heavy days to compare in this range.` : `No ${w.label} scores in this range yet.`;
  } else {
    headline = "No meetings in this range.";
    lead = "";
  }
  const stats = [
    ["Meetings", `${s.meetingCount} · ${hoursText(s.totalDurationS)}`],
    ["After 6 pm", String(s.afterHoursCount)],
    [`Avg ${R}`, r.recovery.avgReadinessScore == null ? "—" : `${Math.round(r.recovery.avgReadinessScore)}%`],
    ["Avg sleep", r.recovery.avgSleepScore == null ? "—" : `${Math.round(r.recovery.avgSleepScore)}%`],
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
              <span class="end"><b>${c.nextRecovery}%</b><span class="band-${bd.cls}">${esc(bd.word)} next morning</span></span>
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
      <h2 class="kicker" id="ch-h">Meetings, then next-morning ${esc(R)}</h2>
      <p class="chart-label">Next-morning ${esc(R)}, %${v.usual.recovery != null ? `. Dashed line is your usual ${v.usual.recovery}%.` : ""}</p>
      ${recoveryChart(v.series, v.usual.recovery)}
      <p class="chart-label">Hours of meetings that day</p>
      ${hoursChart(v.series)}
    </section>
    ${costly}
    ${people}
    ${w.hasIntradayHr && v.hits?.length ? hitsCard(v.hits, w, "Meetings that spiked") : ""}
    <p class="foot">${esc(syncLine())}</p>
  `);
}

/* ---------- People ---------- */

function renderPeople(v) {
  const w = v.wearable;
  const byEmail = new Map();
  for (const d of v.range?.days ?? []) {
    for (const m of d.meetings ?? []) {
      for (const a of m.attendees ?? []) {
        const p = byEmail.get(a.email) ?? { email: a.email, name: a.name, meetings: 0, days: new Map() };
        p.meetings += 1;
        if (!p.name && a.name) p.name = a.name;
        p.days.set(d.day, d.nextMorning?.readinessScore ?? null);
        byEmail.set(a.email, p);
      }
    }
  }
  const people = [...byEmail.values()]
    .map((p) => {
      const scores = [...p.days.values()].filter((x) => x != null);
      return { ...p, avg: scores.length ? Math.round(scores.reduce((a, b) => a + b, 0) / scores.length) : null, n: scores.length };
    })
    .sort((a, b) => b.meetings - a.meetings || (a.name || a.email).localeCompare(b.name || b.email))
    .slice(0, 30);
  const u = v.usual.recovery;
  screen(`
    <h1>People</h1>
    <p class="lead">Who you met in the last 28 days, and how you woke up the morning after.${u != null ? ` Your usual is ${u}%.` : ""}</p>
    <div class="list">${
      people.length
        ? people
            .map((p) => {
              const bd = band(p.avg, w);
              return `<a class="rowlink" href="#person/${encodeURIComponent(p.email)}">
                <span class="avatar" aria-hidden="true">${esc(initials(p.name, p.email))}</span>
                <span class="w"><b>${esc(p.name || p.email)}</b><small>${esc(plural(p.meetings, "meeting"))} on ${esc(plural(p.days.size, "day"))}</small></span>
                <span class="end">${p.avg != null ? `<b>${p.avg}%</b><span class="band-${bd.cls}">next morning</span>` : `<span class="status-off">no scores</span>`}</span>
              </a>`;
            })
            .join("")
        : `<p class="empty">No meetings with other people in the last 28 days.</p>`
    }</div>
  `);
}

function renderPerson(p) {
  const w = state.wearable;
  const R = (w?.readinessLabel ?? "Recovery").toLowerCase();
  const meetings = p.meetings ?? [];
  const byDay = new Map();
  for (const m of meetings) if (m.nextReadinessScore != null) byDay.set(m.day, m.nextReadinessScore);
  const scores = [...byDay.values()];
  const avg = scores.length ? Math.round(scores.reduce((a, b) => a + b, 0) / scores.length) : null;
  screen(`
    <a class="link" href="#people">‹ People</a>
    <section class="card">
      <p class="kicker">Last 60 days</p>
      <h1>${esc(p.name || p.email)}</h1>
      <p class="lead">${esc(plural(meetings.length, "meeting"))}.${
        avg != null ? ` On mornings after a meeting with them you woke at ${avg}% ${esc(R)} on average, over ${plural(scores.length, "morning")}.` : ""
      }${scores.length && scores.length < 4 ? " Only a few mornings, so this is a hint, not a pattern." : ""}</p>
    </section>
    <section class="card"><p class="kicker">Meetings</p><div class="mlist">${meetings
      .map((m) => {
        const bd = band(m.nextReadinessScore, w);
        return `<button type="button" class="mrow" data-goto-day="${esc(m.day)}">
          <span class="t">${esc(shortDay(m.day))}</span>
          <span class="w"><b>${esc(m.title || "Untitled")}</b><small>${esc(clockFromLocal(m.startLocal))}</small></span>
          ${m.nextReadinessScore != null ? `<span class="pill ${bd.cls}">${m.nextReadinessScore}%</span>` : `<span class="pill none">No score</span>`}
        </button>`;
      })
      .join("")}</div></section>
  `);
}

/* ---------- More ---------- */

function renderMore() {
  const s = state.status ?? {};
  const w = state.wearable;
  const a = state.ask;
  const row = (title, sub, status, cls, attrs) =>
    `<${attrs.href ? `a href="${attrs.href}"` : `button type="button" data-action="${attrs.action}"`} class="rowlink">
      <span class="w"><b>${esc(title)}</b><small>${esc(sub)}</small></span>
      ${status ? `<span class="${cls}">${esc(status)}</span>` : ""}<span class="chev" aria-hidden="true">›</span>
    </${attrs.href ? "a" : "button"}>`;
  screen(`
    <h1>More</h1>
    <p class="kicker section-k">Data</p>
    <div class="list">
      ${row("Sync calendar", syncLine() || "Pull the last 3 weeks and the next week", "", "", { action: "sync" })}
    </div>
    <p class="kicker section-k">Connections</p>
    <div class="list">
      ${row(w?.label ?? "Wearable", w?.strainLabel ? "Recovery, sleep, strain" : "Readiness, sleep, heart-rate", s.wearableConnected ? "Connected" : "Connect", s.wearableConnected ? "status-ok" : "status-todo", { href: "/setup" })}
      ${row("Google Calendar", "Read-only", s.googleConnected ? "Connected" : "Connect", s.googleConnected ? "status-ok" : "status-todo", { href: "/setup" })}
    </div>
    <p class="kicker section-k">Ask your data</p>
    <div class="list">
      ${row("AI key", "Chat with your meetings and recovery", a?.connected ? `Key …${a.tail}` : a && !a.available ? "Not set up" : "Add key", a?.connected ? "status-ok" : "status-todo", { href: "#ask" })}
    </div>
    <p class="kicker section-k">Setup</p>
    <div class="list">
      ${row("Setup guide", "Keys, redirect links, first import", "", "", { href: "/setup" })}
      ${row("Privacy", "What is stored and where", "", "", { action: "privacy" })}
    </div>
    ${
      state.showPrivacy
        ? `<section class="share-note"><span class="kicker">Privacy</span>
      <span>Everything lives in your own Cloudflare account: scores and meetings in D1, raw downloads in R2, sign-in tokens in KV.</span>
      <span>Google Calendar is read-only. Nothing is shared with anyone unless you use Ask your data, which sends Anthropic the numbers it needs to answer.</span></section>`
        : ""
    }
    <p id="more-msg" class="lead" role="status"></p>
  `);
}

async function syncCalendar() {
  const msg = qs("#more-msg");
  const today = todayET();
  if (msg) msg.textContent = "Syncing your calendar…";
  try {
    const r = await api("/api/calendar/sync", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mode: "live", startDay: addDays(today, -21), endDay: addDays(today, 7) }),
    });
    memory.clear();
    saveStore();
    if (msg) msg.textContent = `Done. ${plural(r.written ?? 0, "meeting")} updated.`;
  } catch (err) {
    if (err instanceof AccessNeededError) qs("#access").hidden = false;
    if (msg) msg.textContent = err.message || String(err);
  }
}

/* ---------- Ask ---------- */

function loadChat() {
  try {
    return JSON.parse(sessionStorage.getItem(CHAT_STORE) || "[]");
  } catch {
    return [];
  }
}

function saveChat() {
  try {
    sessionStorage.setItem(CHAT_STORE, JSON.stringify(state.chat.slice(-30)));
  } catch {
    /* ignore */
  }
}

/** Just enough Markdown for short answers: paragraphs, bold, bullet lists, pipe tables. */
function md(text) {
  const inline = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  const out = [];
  const lines = text.replace(/\r/g, "").split("\n");
  for (let i = 0; i < lines.length; ) {
    const line = lines[i];
    if (/^\s*\|.*\|\s*$/.test(line)) {
      const rows = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) rows.push(lines[i++]);
      const cells = rows.filter((r) => !/^\s*\|[\s:|-]+\|\s*$/.test(r)).map((r) => r.trim().slice(1, -1).split("|").map((c) => c.trim()));
      const [head, ...body] = cells;
      out.push(
        `<table><thead><tr>${head.map((c) => `<th>${inline(c)}</th>`).join("")}</tr></thead><tbody>${body
          .map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`)
          .join("")}</tbody></table>`,
      );
      continue;
    }
    if (/^\s*[-*]\s+/.test(line)) {
      const items = [];
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*[-*]\s+/, ""));
      out.push(`<ul>${items.map((t) => `<li>${inline(t)}</li>`).join("")}</ul>`);
      continue;
    }
    const para = [];
    while (i < lines.length && lines[i].trim() && !/^\s*[-*]\s+/.test(lines[i]) && !/^\s*\|.*\|\s*$/.test(lines[i])) para.push(lines[i++]);
    if (para.length) out.push(`<p>${para.map(inline).join("<br>")}</p>`);
    else i += 1;
  }
  return out.join("");
}

const SUGGESTIONS = [
  "Which meetings cost me the most this month?",
  "Is it the number of hours or the people?",
  "How do days with after-hours calls compare?",
];

function askScope() {
  return state.lastScreen === "dates" ? { start: state.start, end: state.end } : null;
}

function renderAsk() {
  const a = state.ask;
  if (!a) {
    screen(`<p class="placeholder">Loading…</p>`);
    return;
  }
  const head = `<h1>Ask your data</h1>`;
  if (!a.available) {
    screen(`${head}<p class="lead">This needs one setting on your Worker first: a secret named AI_KEY_SECRET (any 32 or more random characters). It encrypts your API key. Run this once, then reload:</p>
      <pre class="card">wrangler secret put AI_KEY_SECRET</pre>`);
    return;
  }
  if (!a.connected || state.replaceKey) {
    screen(`${head}
      <p class="lead">Ask things like "which meetings cost me the most this month". Add your own Claude API key: you pay Anthropic directly for what you use.</p>
      <form class="keyform" data-form="key">
        <label class="kicker" for="key-in">Claude API key</label>
        <input id="key-in" name="key" type="password" autocomplete="off" spellcheck="false" placeholder="sk-ant-…" required />
        <span class="lead">Get one at console.anthropic.com, under API keys.</span>
        <button type="submit" class="primary">Check and save</button>
        <p class="error" id="key-err" role="alert" hidden></p>
      </form>
      <section class="share-note"><span class="kicker">What is shared</span>
        <span>Your key is stored encrypted in your own Cloudflare Worker, never in the browser.</span>
        <span>Each question sends Anthropic the days it needs: dates, meeting titles and times, who attended, and your scores. No email addresses, transcripts or audio.</span>
      </section>
      ${a.connected ? `<button type="button" class="link" data-action="cancel-key">Keep the current key</button>` : ""}`);
    return;
  }
  const scope = askScope();
  const bubbles = state.chat
    .map((m) => (m.role === "user" ? `<div class="bubble me">${esc(m.content)}</div>` : `<div class="bubble ai">${md(m.content)}</div>`))
    .join("");
  screen(`${head}
    <p class="lead">Using ${scope ? esc(rangeLabel(scope.start, scope.end)) : "your last 60 days"}. Key …${esc(a.tail)} ·
      <button type="button" class="link" data-action="replace-key">Change</button> ·
      <button type="button" class="link" data-action="remove-key">Remove</button>
      ${state.chat.length ? ` · <button type="button" class="link" data-action="clear-chat">Clear chat</button>` : ""}</p>
    <div class="chat" id="chat">${bubbles}${state.pending ? `<div class="bubble ai pending">Looking at your data…</div>` : ""}</div>
    ${state.chat.length || state.pending ? "" : `<div class="suggest">${SUGGESTIONS.map((q) => `<button type="button" data-suggest="${esc(q)}">${esc(q)}</button>`).join("")}</div>`}
    <form class="composer" data-form="ask">
      <label for="ask-in" class="sr">Your question</label>
      <input id="ask-in" name="q" type="text" autocomplete="off" placeholder="Ask about your meetings and recovery" ${state.pending ? "disabled" : ""} />
      <button type="submit" aria-label="Send" ${state.pending ? "disabled" : ""}>↑</button>
    </form>`);
  qs("#chat")?.lastElementChild?.scrollIntoView({ block: "nearest" });
}

async function loadAskStatus(force = false) {
  if (state.ask && !force) return state.ask;
  try {
    state.ask = await api("/api/ask/status");
  } catch (err) {
    if (err instanceof AccessNeededError) qs("#access").hidden = false;
    state.ask = { available: false, connected: false };
  }
  return state.ask;
}

async function sendQuestion(question) {
  const q = question.trim();
  if (!q || state.pending) return;
  const history = state.chat.slice(-12);
  state.chat.push({ role: "user", content: q });
  state.pending = true;
  saveChat();
  renderAsk();
  try {
    const r = await api("/api/ask", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ question: q, history, ...(askScope() ?? {}) }),
    });
    state.chat.push({ role: "assistant", content: r.answer + (r.truncated ? "\n\n(The answer was cut short.)" : "") });
  } catch (err) {
    if (err.body?.needsKey) {
      state.ask = { ...state.ask, connected: false };
      state.chat.pop();
    } else {
      state.chat.push({ role: "assistant", content: err instanceof AccessNeededError ? "Your sign-in expired. Reload the page." : err.message || String(err) });
    }
  } finally {
    state.pending = false;
    saveChat();
    if (state.tab === "ask") renderAsk();
  }
}

async function saveKey(form) {
  const errEl = qs("#key-err");
  const btn = form.querySelector("button[type=submit]");
  const key = form.key.value.trim();
  errEl.hidden = true;
  btn.disabled = true;
  btn.textContent = "Checking…";
  try {
    const r = await api("/api/ask/key", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ key }) });
    state.ask = { ...state.ask, connected: true, tail: r.tail, savedAt: r.savedAt };
    state.replaceKey = false;
    renderAsk();
  } catch (err) {
    errEl.textContent = err.message || String(err);
    errEl.hidden = false;
    btn.disabled = false;
    btn.textContent = "Check and save";
  }
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
  const tooLong = n > MAX_RANGE_DAYS;
  const note = !p.start
    ? "Tap a start day, then an end day."
    : !p.end
      ? "Now tap the end day."
      : tooLong
        ? `That is ${n} days. Pick up to ${MAX_RANGE_DAYS}.`
        : `${rangeLabel(p.start, p.end)} · ${plural(n, "day")}`;
  const ready = complete && !tooLong;
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
    <p class="pick-note ${tooLong ? "bad" : ""}" aria-live="polite">${esc(note)}</p>
    <button type="button" class="primary" data-action="pk-apply" ${ready ? "" : "disabled"}>${
      !complete ? "Pick an end date" : tooLong ? "Too many days" : p.start === p.end ? `Show ${esc(shortDay(p.start))}` : `Show ${plural(n, "day")}`
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
  setTabs();
  if (state.tab !== "ask") state.lastScreen = state.tab;
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
    } else if (state.tab === "people") {
      const t = todayET();
      await load(viewPath(addDays(t, -27), t), fresh(renderPeople));
    } else if (state.tab === "person") {
      screen(`<p class="placeholder">Loading…</p>`);
      await load(`/api/people/${encodeURIComponent(state.person)}/meetings?days=60`, fresh(renderPerson));
    } else if (state.tab === "more") {
      renderMore();
      if (!state.status) load(viewPath(todayET(), todayET()), fresh(() => state.tab === "more" && renderMore())).catch(() => {});
      loadAskStatus().then(() => token === renderToken && state.tab === "more" && renderMore());
    } else if (state.tab === "ask") {
      renderAsk();
      await loadAskStatus();
      if (token === renderToken) renderAsk();
    }
  } catch (err) {
    if (token === renderToken) showError(err);
  }
}

/* ---------- events ---------- */

function stepDates(dir) {
  if (state.tab === "today") {
    const next = addDays(state.day, dir);
    if (next > todayET()) return;
    go({ day: next, openMeeting: null });
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
  const t = ev.target.closest("[data-action],[data-meeting],[data-goto-day],[data-pick],[data-quick],[data-month],[data-field],[data-suggest],[data-tab]");
  if (!t) {
    if (ev.target === qs("#sheet")) closePicker();
    return;
  }
  if (t.dataset.tab) {
    ev.preventDefault();
    const tab = t.dataset.tab;
    go({ tab });
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
  else if (a === "reload") location.reload();
  else if (a === "sync") syncCalendar();
  else if (a === "privacy") {
    state.showPrivacy = !state.showPrivacy;
    renderMore();
  } else if (a === "replace-key") {
    state.replaceKey = true;
    renderAsk();
  } else if (a === "cancel-key") {
    state.replaceKey = false;
    renderAsk();
  } else if (a === "remove-key") {
    api("/api/ask/key", { method: "DELETE" })
      .then(() => {
        state.ask = { ...state.ask, connected: false, tail: null };
        renderAsk();
      })
      .catch((err) => alert(err.message || String(err)));
  } else if (a === "clear-chat") {
    state.chat = [];
    saveChat();
    renderAsk();
  } else if (t.dataset.meeting) {
    if (!state.wearable?.hasIntradayHr) return;
    state.openMeeting = state.openMeeting === t.dataset.meeting ? null : t.dataset.meeting;
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
  } else if (t.dataset.suggest) sendQuestion(t.dataset.suggest);
});

document.addEventListener("submit", (ev) => {
  const form = ev.target.closest("[data-form]");
  if (!form) return;
  ev.preventDefault();
  if (form.dataset.form === "ask") {
    const q = form.q.value;
    form.q.value = "";
    sendQuestion(q);
  } else if (form.dataset.form === "key") saveKey(form);
});

document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape" && state.picker) closePicker();
});

window.addEventListener("popstate", () => {
  readLocation();
  render();
});

// Coming back to the tab after a while: refresh what is on screen.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && ["today", "dates", "people"].includes(state.tab)) render();
});

loadStore();
readLocation();
writeLocation(true);
render();

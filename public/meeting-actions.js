import { esc } from "./ask-logic.js";

/**
 * What you can say about a meeting: you did not join it, do not link it, or it
 * ran at other times. Pure helpers and markup; app.js owns the state and the
 * network. The calendar itself is never edited.
 */

export const isExcluded = (e) => e?.excluded === true;

const EXCLUDED = new Set(["not_joined", "unlinked"]);

/** The same limits as the server: start up to 2 h before the calendar start, end up to 4 h after its end, at most 12 h. */
const MAX_EARLY_START_MS = 2 * 3600_000;
const MAX_LATE_END_MS = 4 * 3600_000;
const MAX_WINDOW_MS = 12 * 3600_000;

/** The words for a meeting that is left out. */
export function excludedLabel(e) {
  return e?.override?.state === "unlinked" ? "Not linked" : "Didn't join";
}

/** The Mac saw no Zoom around this meeting and nothing has been decided yet. */
export function looksSkipped(e) {
  const o = e?.override;
  return Boolean(o && o.seenNone && !o.state && !isExcluded(e));
}

function partsInZone(ms, tz) {
  const out = {};
  for (const p of new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date(ms))) out[p.type] = p.value;
  return out;
}

/** "2026-11-12T15:30" as the clock reads in `tz` at this instant. Empty text for a bad time. */
export function wallInZone(iso, tz) {
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return "";
  const p = partsInZone(ms, tz);
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
}

/** The instant (ISO, UTC) when the clock in `tz` reads this wall time. Null for a bad value. */
export function zonedWallToUtc(wall, tz) {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(wall ?? "");
  if (!m) return null;
  const asUtc = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]));
  if (!Number.isFinite(asUtc)) return null;
  let guess = asUtc;
  // The zone's offset depends on the instant, so settle it in two passes (covers the changeover hours).
  for (let i = 0; i < 2; i++) {
    const p = partsInZone(guess, tz);
    const shown = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour), Number(p.minute));
    guess += asUtc - shown;
  }
  return new Date(guess).toISOString();
}

/** The request body for the choices the menu offers. */
export function overrideBody(scope, fields) {
  return { scope, ...fields };
}

const url = (id) => `/api/meetings/${encodeURIComponent(id)}/override`;
export const overrideUrl = url;

/**
 * Save through `api` (app.js's fetch helper). Resolves to { ok: true } or
 * { ok: false, message }: a failure leaves the old state, and says so.
 */
export async function saveOverride(api, id, body) {
  try {
    await api(url(id), { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    return { ok: true };
  } catch (err) {
    const why = err && err.status && err.status < 500 && err.message ? ` ${err.message}` : "";
    return { ok: false, message: `Could not save. Nothing changed.${why}` };
  }
}

/* ---------- markup ---------- */

function button(label, attrs, cls = "link") {
  return `<button type="button" class="${cls}" ${attrs}>${esc(label)}</button>`;
}

const act = (id, name) => `data-action="mact" data-act="${name}" data-id="${esc(id)}"`;

/** The "..." button and what it opens, inside an opened meeting. */
export function actionsHtml(e, ui, tz) {
  const id = e.id;
  const mine = ui && ui.id === id ? ui : null;
  const o = e.override;
  const error = mine?.error ? `<p class="error" role="alert">${esc(mine.error)}</p>` : "";
  const busy = mine?.busy ? " disabled" : "";
  let body = "";
  if (mine?.mode === "scope") {
    const what = mine.pending?.undo ? "Put it back" : mine.pending?.state === "unlinked" ? "Don't link" : "I didn't join";
    body = `<div class="mchoice" role="group" aria-label="${esc(what)}">
        <p class="meta">${esc(what)} for</p>
        ${button("Just this one", act(id, "scope-event") + busy, "secondary")}
        ${button("All of them", act(id, "scope-series") + busy, "secondary")}
        ${button("Cancel", act(id, "close") + busy)}
      </div>`;
  } else if (mine?.mode === "times") {
    // What was typed wins over the saved times, so a refused save keeps it ("" stays empty).
    const typed = mine.typed;
    const start = typed && typeof typed.start === "string" ? typed.start : wallInZone(e.startUtc, tz);
    const end = typed && typeof typed.end === "string" ? typed.end : wallInZone(e.endUtc, tz);
    body = `<form class="mtimes" data-id="${esc(id)}" aria-label="Meeting times">
        <label>Start<input type="datetime-local" name="start" value="${esc(start)}" required /></label>
        <label>End<input type="datetime-local" name="end" value="${esc(end)}" required /></label>
        <p class="meta">Times are in ${esc(tz.replace("_", " "))}. This only changes Meetspike, not your calendar.</p>
        <div class="mrowbtns">
          <button type="submit" class="secondary"${busy}>Save times</button>
          ${o && (o.startUtc || o.endUtc) ? button("Use calendar times", act(id, "calendar-times") + busy) : ""}
          ${button("Cancel", act(id, "close") + busy)}
        </div>
      </form>`;
  } else if (mine?.mode === "menu") {
    const items = [
      button("I didn't join", act(id, "not_joined")),
      button("Don't link this meeting", act(id, "unlinked")),
      button("Meeting times", act(id, "times")),
      o && (o.startUtc || o.endUtc) ? button("Use calendar times", act(id, "calendar-times")) : "",
      o && o.state && o.scope === "event" ? button("Undo", act(id, "undo")) : "",
    ].filter(Boolean);
    body = `<div class="mmenu-list" role="group" aria-label="Meeting options">${items.join("")}</div>`;
  }
  const open = Boolean(mine?.mode);
  return `<div class="mactions">
      <button type="button" class="link mmenu" data-action="mmenu" data-id="${esc(id)}" aria-expanded="${open}" aria-label="Meeting options">&hellip;</button>
      ${body}${error}
    </div>`;
}

/** A left-out meeting in the day's list: dimmed, with a way back. */
export function excludedRowHtml(e, clock, ui) {
  const mine = ui && ui.id === e.id ? ui : null;
  const scoped = mine?.mode === "scope"
    ? `<div class="mchoice" role="group" aria-label="Put it back">
        <p class="meta">Put it back for</p>
        ${button("Just this one", act(e.id, "scope-event"), "secondary")}
        ${button("All of them", act(e.id, "scope-series"), "secondary")}
        ${button("Cancel", act(e.id, "close"))}
      </div>`
    : "";
  const error = mine?.error ? `<p class="error" role="alert">${esc(mine.error)}</p>` : "";
  return `<div class="mrow excluded">
      <span class="t">${esc(clock)}</span>
      <span class="w"><b>${esc(e.title || "Untitled")}</b><small>${esc(excludedLabel(e))}</small></span>
      ${button("Undo", act(e.id, "undo"), "link undo")}
    </div>${scoped}${error}`;
}

/** The quiet question under a meeting the Mac never saw Zoom for. */
export function skippedNoteHtml(e) {
  return `<div class="mnote" role="group" aria-label="Did you join?">
      <span>Looks like you didn't join. Unlink it?</span>
      ${button("Yes", act(e.id, "skip-yes"))}
      ${button("No", act(e.id, "skip-no"))}
    </div>`;
}

/**
 * What a menu choice becomes. Returns { body } to save, { mode } to ask
 * something first, or null. `e` is the meeting as the API gave it.
 */
export function planAction(name, e, extra = {}) {
  const series = Boolean(e.override?.seriesId);
  switch (name) {
    case "not_joined":
    case "unlinked":
      return series ? { mode: "scope", pending: { state: name } } : { body: overrideBody("event", { state: name }) };
    case "times":
      return { mode: "times" };
    case "calendar-times":
      return { body: overrideBody("event", { startUtc: null, endUtc: null }) };
    case "undo":
      if (e.override?.scope === "series") return { mode: "scope", pending: { undo: true } };
      // Left out by its own choice. When its series is left out too, clearing the choice would hand it to the series, so say linked.
      return { body: overrideBody("event", { state: isExcluded(e) && EXCLUDED.has(e.override?.seriesState) ? "linked" : null }) };
    case "skip-yes":
      return { body: overrideBody("event", { state: "unlinked" }) };
    case "skip-no":
      return { body: overrideBody("event", { state: "linked" }) };
    case "scope-event":
      if (extra.pending?.undo) return { body: overrideBody("event", { state: e.override?.scope === "series" ? "linked" : null }) };
      return extra.pending?.state ? { body: overrideBody("event", { state: extra.pending.state }) } : null;
    case "scope-series":
      if (extra.pending?.undo) return { body: overrideBody("series", { state: null }) };
      return extra.pending?.state ? { body: overrideBody("series", { state: extra.pending.state }) } : null;
    default:
      return null;
  }
}

/**
 * Start and end from the times form, as UTC ISO text, or an error to show.
 * `e` is the meeting: its calendar times (not the times it was moved to) set the limits.
 */
export function readTimes(form, tz, e) {
  const start = zonedWallToUtc(form.elements.start.value, tz);
  const end = zonedWallToUtc(form.elements.end.value, tz);
  if (!start || !end) return { error: "Pick a start and an end." };
  const [startMs, endMs] = [Date.parse(start), Date.parse(end)];
  if (endMs <= startMs) return { error: "The end has to be after the start." };
  if (e) {
    const calStart = Date.parse(e.override?.calendarStartUtc ?? e.startUtc);
    const calEnd = Date.parse(e.override?.calendarEndUtc ?? e.endUtc);
    if (Number.isFinite(calStart) && startMs < calStart - MAX_EARLY_START_MS) {
      return { error: "The start can be at most 2 hours before the calendar start." };
    }
    if (Number.isFinite(calEnd) && endMs > calEnd + MAX_LATE_END_MS) {
      return { error: "The end can be at most 4 hours after the calendar end." };
    }
  }
  if (endMs - startMs > MAX_WINDOW_MS) return { error: "A meeting can last at most 12 hours." };
  return { body: overrideBody("event", { startUtc: start, endUtc: end }) };
}

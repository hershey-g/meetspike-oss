/**
 * Pure helpers for the Ask panel (public/ask-panel.js): SSE parsing, the small
 * Markdown renderer, escaping and the copy that rotates while Claude works.
 * No DOM here, so test/ask-panel.test.ts can import it directly.
 */

export const SUGGESTIONS = [
  "Which meetings cost me the most this month?",
  "Which meetings cost me the most, all time?",
  "Is it the number of hours or the people?",
  "How do days with after-hours calls compare?",
];

/** Playful words shown while waiting, one every VERB_MS. */
export const VERBS = ["Tinkering", "Pulling your calendar", "Counting heartbeats", "Lining up the nights", "Cross-checking", "Mulling it over"];
export const VERB_MS = 1800;

export const CHAT_STORE = "meetspike-chat-v1";
export const MAX_STORED_TURNS = 30;
export const MAX_HISTORY_TURNS = 12;
/** The Worker keeps this many characters of each earlier turn; sending more only grows the request. */
export const MAX_TURN_CHARS = 8000;

export function esc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function verbAt(ms) {
  return VERBS[Math.floor(Math.max(0, ms) / VERB_MS) % VERBS.length];
}

/** Only well-formed {role, content} turns, the last `max`, starting with the user. */
export function cleanTurns(raw, max = MAX_HISTORY_TURNS) {
  if (!Array.isArray(raw)) return [];
  const turns = raw
    .filter((t) => t && (t.role === "user" || t.role === "assistant") && typeof t.content === "string" && t.content.trim())
    .map((t) => ({ role: t.role, content: t.content.slice(0, MAX_TURN_CHARS) }))
    .slice(-max);
  while (turns.length && turns[0].role !== "user") turns.shift();
  return turns;
}

/**
 * Incremental Server-Sent Events parser. Feed it decoded text chunks in any
 * split; it calls onEvent({ event, data }) once per complete event. `data` is
 * JSON-parsed when it parses, else the raw string. Comment lines (":") and
 * events without data are ignored.
 */
export function createSseParser(onEvent) {
  let buf = "";
  let event = "";
  let data = [];
  function dispatch() {
    if (data.length) {
      const raw = data.join("\n");
      let parsed = raw;
      try {
        parsed = JSON.parse(raw);
      } catch {
        /* keep the string */
      }
      onEvent({ event: event || "message", data: parsed });
    }
    event = "";
    data = [];
  }
  function line(l) {
    if (l === "") return dispatch();
    if (l.startsWith(":")) return;
    const i = l.indexOf(":");
    const field = i === -1 ? l : l.slice(0, i);
    let value = i === -1 ? "" : l.slice(i + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") event = value;
    else if (field === "data") data.push(value);
  }
  return {
    push(chunk) {
      buf += chunk;
      let nl;
      while ((nl = buf.search(/\r\n|\r|\n/)) !== -1) {
        const len = buf[nl] === "\r" && buf[nl + 1] === "\n" ? 2 : 1;
        // A lone \r at the very end may be the first half of \r\n: wait for more.
        if (buf[nl] === "\r" && nl === buf.length - 1) break;
        line(buf.slice(0, nl));
        buf = buf.slice(nl + len);
      }
    },
    end() {
      if (buf) line(buf);
      buf = "";
      dispatch();
    },
  };
}

/** Tables wider than this become a label/value list. */
export const MAX_TABLE_COLUMNS = 3;

/**
 * A wide table as one card per row. Each cell is a label (its column's header) and a value.
 * A blank value is skipped, a cell a short row does not have is skipped, and a cell past the
 * header has no label.
 */
function statsList(head, body, inline) {
  const cards = body
    .map((row) => {
      const pairs = row
        .map((value, i) => ({ label: head[i] ?? "", value }))
        .filter((p) => p.value.trim())
        .map((p) => (p.label.trim()
          ? `<dt>${inline(p.label)}</dt><dd>${inline(p.value)}</dd>`
          : `<dd class="ask-wide">${inline(p.value)}</dd>`))
        .join("");
      return pairs ? `<dl class="ask-card">${pairs}</dl>` : "";
    })
    .join("");
  return cards ? `<div class="ask-cards">${cards}</div>` : "";
}

/** Just enough Markdown for short answers: paragraphs, bold, bullet lists, pipe tables. */
export function md(text) {
  const inline = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  const out = [];
  const lines = String(text ?? "").replace(/\r/g, "").split("\n");
  const isRow = (l) => /^\s*\|.*\|\s*$/.test(l);
  const isBullet = (l) => /^\s*[-*]\s+/.test(l);
  for (let i = 0; i < lines.length; ) {
    const line = lines[i];
    if (isRow(line)) {
      const rows = [];
      while (i < lines.length && isRow(lines[i])) rows.push(lines[i++]);
      const cells = rows.filter((r) => !/^\s*\|[\s:|-]+\|\s*$/.test(r)).map((r) => r.trim().slice(1, -1).split("|").map((c) => c.trim()));
      if (!cells.length) continue;
      const [head, ...body] = cells;
      // Four or more columns do not fit a phone: one label/value card per row instead.
      if (Math.max(...cells.map((r) => r.length)) > MAX_TABLE_COLUMNS) {
        out.push(statsList(head, body, inline));
        continue;
      }
      out.push(
        `<table><thead><tr>${head.map((c) => `<th>${inline(c)}</th>`).join("")}</tr></thead><tbody>${body
          .map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`)
          .join("")}</tbody></table>`,
      );
      continue;
    }
    if (isBullet(line)) {
      const items = [];
      while (i < lines.length && isBullet(lines[i])) items.push(lines[i++].replace(/^\s*[-*]\s+/, ""));
      out.push(`<ul>${items.map((t) => `<li>${inline(t)}</li>`).join("")}</ul>`);
      continue;
    }
    const para = [];
    while (i < lines.length && lines[i].trim() && !isBullet(lines[i]) && !isRow(lines[i])) para.push(lines[i++]);
    if (para.length) out.push(`<p>${para.map(inline).join("<br>")}</p>`);
    else i += 1;
  }
  return out.join("");
}

/** "Thought for 6s" / "Stopped after 3s". */
export function thoughtLabel(seconds, stoppedEarly) {
  const s = Math.max(1, Math.round(seconds));
  return stoppedEarly ? `Stopped after ${s}s` : `Thought for ${s}s`;
}

/** Upsert a step by id, keeping order of first appearance. */
export function applyStep(steps, step) {
  if (!step || typeof step.id !== "string") return steps;
  const next = steps.slice();
  const i = next.findIndex((s) => s.id === step.id);
  const merged = { id: step.id, label: String(step.label ?? (i >= 0 ? next[i].label : "")), status: step.status === "done" ? "done" : "active" };
  if (i >= 0) next[i] = merged;
  else next.push(merged);
  return next;
}

/* ---------- date scope ---------- */

/**
 * Holds the date range a chat uses. It is read from the dashboard once, when
 * the panel opens (or a new chat starts), and the header and every request use
 * that same copy, so moving around the dashboard behind an open panel cannot
 * make the shown range and the sent range differ.
 */
export function createScopeHolder(read) {
  let scope = null;
  return {
    capture() {
      const s = typeof read === "function" ? read() : null;
      scope = s && s.start && s.end ? { start: s.start, end: s.end, label: s.label || `${s.start} to ${s.end}` } : null;
      return scope;
    },
    get current() {
      return scope;
    },
  };
}

/**
 * Header text. All time on: ranking all history. A scope: ranking it, compared with all history.
 * Neither: all history is already what Ask uses.
 */
export function headerText(scope, allTime = false) {
  if (allTime === true) return "Ranking all history";
  if (scope?.start && scope?.end) return `Ranking ${scope.label || `${scope.start} to ${scope.end}`}, compared with all history`;
  return "Using all history";
}

/** The start/end fields sent with a question for a scope. */
export function scopeRange(scope) {
  return scope?.start && scope?.end ? { start: scope.start, end: scope.end } : {};
}

/**
 * The JSON body POSTed to /api/ask/stream. Dates come from the scope when there is one;
 * allTime and ignorePeriod are sent only when exactly true.
 */
export function askBody({ question, history, sourceDisplay, scope, allTime, ignorePeriod } = {}) {
  const body = { question, history, sourceDisplay, ...scopeRange(scope) };
  if (allTime === true) body.allTime = true;
  if (ignorePeriod === true) body.ignorePeriod = true;
  return body;
}

/* ---------- ranked dates ---------- */

const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** True for a real calendar day written YYYY-MM-DD. */
export function isDay(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

/** The ranked dates from a range event or a `done`, or null unless all four days are real. */
export function readRange(data) {
  if (!data || typeof data !== "object") return null;
  const { start, end, baselineStart, baselineEnd } = data;
  if (![start, end, baselineStart, baselineEnd].every(isDay)) return null;
  const range = { start, end, baselineStart, baselineEnd };
  if (typeof data.rangeSource === "string") range.rangeSource = data.rangeSource;
  return range;
}

function dayText(day, withYear) {
  const [y, m, d] = day.split("-").map(Number);
  return `${MONTH_NAMES[m - 1]} ${d}${withYear ? `, ${y}` : ""}`;
}

function spanText(start, end) {
  const years = start.slice(0, 4) !== end.slice(0, 4);
  return start === end ? dayText(start, years) : `${dayText(start, years)} to ${dayText(end, years)}`;
}

/** True when the ranked dates are less than all history. */
export function rankedLessThanAll(range) {
  const r = readRange(range);
  return Boolean(r) && (r.start > r.baselineStart || r.end < r.baselineEnd);
}

/** The line under an answer. Empty when the range is not known (an older Worker). */
export function rangeLine(range) {
  const r = readRange(range);
  if (!r) return "";
  return rankedLessThanAll(r)
    ? `Ranking ${spanText(r.start, r.end)}, compared with all history`
    : `Using all history, ${spanText(r.start, r.end)}`;
}

/* ---------- stream events ---------- */

/**
 * Applies one /api/ask/stream event to an answer in progress. Returns the
 * kind it handled ("range", "step", "text", "done", "error") or null when ignored.
 * Error events are only reported; the caller decides what to show.
 */
export function applyAskEvent(item, { event, data } = {}) {
  if (event === "step") {
    item.steps = applyStep(item.steps || [], data);
    return "step";
  }
  if (event === "text") {
    const delta = typeof data === "string" ? data : (data?.delta ?? "");
    if (!delta) return null;
    item.content = (item.content || "") + delta;
    return "text";
  }
  if (event === "range") {
    const range = readRange(data);
    if (!range) return null;
    item.range = range;
    return "range";
  }
  if (event === "done") {
    const range = readRange(data);
    if (range) item.range = range;
    if (data?.truncated) item.truncated = true;
    if (data?.interrupted) item.interrupted = true;
    return "done";
  }
  if (event === "error") return "error";
  return null;
}

/**
 * Called when the response body ends. Without a done or error event first,
 * the connection dropped: the answer is marked interrupted and keeps its text.
 */
export function endAskStream(item, sawTerminal) {
  if (!sawTerminal && !item.error) item.interrupted = true;
  return item;
}

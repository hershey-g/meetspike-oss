import { addCalendarDays, offsetMinutesInZone, wallClockToUtcIso } from "../../lib/time.ts";

/** [unix_ms, bpm] */
export type HrPoint = [number, number];
/** [unix_ms, level 0–3] */
export type StressPoint = [number, number];

export type ParsedHr = {
  /** False when the body is not a shape we know. An empty `values` list is recognised. */
  recognized: boolean;
  points: HrPoint[];
};

export type ParsedStressDay = {
  recognized: boolean;
  points: StressPoint[];
  currentLevel: number | null;
  peakLevel: number | null;
  minLevel: number | null;
};

function isRecord(v: unknown): v is Record<string, unknown> {
  return Boolean(v) && typeof v === "object" && !Array.isArray(v);
}

function num(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) return Number(v);
  return null;
}

/** Unix ms from a number (ms, or seconds if it is clearly seconds) or an ISO string. */
function timeMs(v: unknown): number | null {
  const n = num(v);
  if (n != null) return n < 1e11 ? n * 1000 : n;
  if (typeof v === "string") {
    const t = Date.parse(v);
    return Number.isFinite(t) ? t : null;
  }
  return null;
}

function hrPointOf(raw: unknown): HrPoint | null {
  if (Array.isArray(raw) && raw.length >= 2) {
    const t = timeMs(raw[0]);
    const bpm = num(raw[1]);
    return t != null && bpm != null ? [t, bpm] : null;
  }
  if (!isRecord(raw)) return null;
  const t = timeMs(raw.time ?? raw.timestamp ?? raw.t);
  const bpm = num(raw.data ?? raw.value ?? raw.bpm ?? raw.heart_rate);
  return t != null && bpm != null ? [t, bpm] : null;
}

/**
 * GET /metrics-service/v1/metrics/user/{id}?name=heart_rate answers
 * `{ values: [{ time: unix_ms, data: bpm }, ...] }`. Points outside a human
 * range are dropped; duplicates keep the first; output is time-ordered.
 */
export function parseHeartRate(body: unknown): ParsedHr {
  let list: unknown[] | null = null;
  if (Array.isArray(body)) list = body;
  else if (isRecord(body)) {
    if (Array.isArray(body.values)) list = body.values;
    else if (Array.isArray(body.data)) list = body.data;
  }
  if (!list) return { recognized: false, points: [] };
  const seen = new Set<number>();
  const points: HrPoint[] = [];
  for (const raw of list) {
    const p = hrPointOf(raw);
    if (!p) continue;
    const [t, bpm] = p;
    if (bpm < 25 || bpm > 250 || seen.has(t)) continue;
    seen.add(t);
    points.push([t, Math.round(bpm)]);
  }
  // A non-empty list where nothing parsed is a shape change, not "no data".
  if (list.length > 0 && points.length === 0) return { recognized: false, points: [] };
  points.sort((a, b) => a[0] - b[0]);
  return { recognized: true, points };
}

/** "9:38 AM" / "12:05 pm" / "14:20" → minutes after local midnight. */
export function clockLabelMinutes(label: unknown): number | null {
  if (typeof label !== "string") return null;
  const m = /^\s*(\d{1,2}):(\d{2})\s*([AaPp][Mm])?\s*$/.exec(label);
  if (!m) return null;
  let h = Number(m[1]);
  const min = Number(m[2]);
  if (min > 59) return null;
  const ampm = m[3]?.toUpperCase();
  if (ampm) {
    if (h < 1 || h > 12) return null;
    if (ampm === "AM") h = h === 12 ? 0 : h;
    else h = h === 12 ? 12 : h + 12;
  } else if (h > 23) return null;
  return h * 60 + min;
}

/** Local wall time (day + minutes, may run past midnight) in `timeZone` → unix ms. DST-safe. */
export function localMinutesToUtcMs(day: string, minutes: number, timeZone: string): number {
  const dayOffset = Math.floor(minutes / 1440);
  const d = addCalendarDays(day, dayOffset);
  const rem = minutes - dayOffset * 1440;
  const hh = String(Math.floor(rem / 60)).padStart(2, "0");
  const mm = String(rem % 60).padStart(2, "0");
  const wall = `${d}T${hh}:${mm}:00`;
  let guess = `${wall}.000Z`;
  for (let i = 0; i < 4; i += 1) {
    const utc = wallClockToUtcIso(wall, offsetMinutesInZone(guess, timeZone));
    if (utc === guess) break;
    guess = utc;
  }
  return Date.parse(guess);
}

function asArray(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

/** stress_graph.graph.plots[].plot.segments[].points[].data_scrubber_details */
function graphPoints(graph: unknown, day: string, timeZone: string): StressPoint[] | null {
  if (!isRecord(graph) || !Array.isArray(graph.plots)) return null;
  const plots = graph.plots
    .map((p) => (isRecord(p) && isRecord(p.plot) ? p.plot : null))
    .filter((p): p is Record<string, unknown> => p != null);
  const stressPlots = plots.filter(
    (p) => String(p.id ?? "").toLowerCase() === "stress" || String(p.style ?? "").toUpperCase() === "STRESS",
  );
  const out: StressPoint[] = [];
  let prevMin: number | null = null;
  let rollover = 0;
  for (const plot of stressPlots.length ? stressPlots : plots) {
    for (const seg of asArray(plot.segments)) {
      if (!isRecord(seg)) continue;
      for (const pt of asArray(seg.points)) {
        if (!isRecord(pt) || !isRecord(pt.data_scrubber_details)) continue;
        const dsd = pt.data_scrubber_details;
        const clock = clockLabelMinutes(dsd.primary_contextual_display);
        const level = num(dsd.value_display);
        if (clock == null || level == null) continue;
        // The graph runs forward in time; a clock that jumps back by
        // more than 12 h has crossed midnight.
        if (prevMin != null && clock + rollover < prevMin - 720) rollover += 1440;
        const minutes = clock + rollover;
        prevMin = minutes;
        out.push([localMinutesToUtcMs(day, minutes, timeZone), level]);
      }
    }
  }
  return out;
}

/** Older shape: stress_state.timeline[] = { started_at, ended_at, level }. */
function timelinePoints(root: Record<string, unknown>): StressPoint[] | null {
  const state = root.stress_state;
  if (!isRecord(state) || !Array.isArray(state.timeline)) return null;
  const out: StressPoint[] = [];
  for (const raw of state.timeline) {
    if (!isRecord(raw)) continue;
    const t = timeMs(raw.started_at);
    const level = num(raw.level);
    if (t != null && level != null) out.push([t, level]);
  }
  return out;
}

/**
 * GET /health-service/v2/stress-bff/{day}. The intraday line is a chart
 * description with local clock labels, so `day` and the user's `timeZone`
 * turn labels back into instants. Levels are 0–3.
 */
export function parseStressDay(body: unknown, day: string, timeZone: string): ParsedStressDay {
  const empty: ParsedStressDay = { recognized: false, points: [], currentLevel: null, peakLevel: null, minLevel: null };
  if (!isRecord(body)) return empty;
  const graph = isRecord(body.stress_graph) ? body.stress_graph.graph : undefined;
  let points = graphPoints(graph, day, timeZone);
  if (points == null) points = timelinePoints(body);
  const gauge = isRecord(body.gauge) ? body.gauge : null;
  const gaugeLevel = gauge ? num(gauge.gauge_score_display) : null;
  if (points == null && gaugeLevel == null) return empty;
  const list = (points ?? []).filter(([, l]) => l >= 0 && l <= 3.5).sort((a, b) => a[0] - b[0]);
  const levels = list.map(([, l]) => l);
  return {
    recognized: true,
    points: list,
    currentLevel: gaugeLevel ?? (levels.length ? levels[levels.length - 1] : null),
    peakLevel: levels.length ? Math.max(...levels) : null,
    minLevel: levels.length ? Math.min(...levels) : null,
  };
}

/** Thin a time-ordered list to at most `max` points, keeping the last. */
export function thinPoints<T>(points: T[], max: number): T[] {
  if (points.length <= max || max < 2) return points;
  const step = (points.length - 1) / (max - 1);
  const out: T[] = [];
  for (let i = 0; i < max; i += 1) out.push(points[Math.round(i * step)]);
  return out;
}

import { calendarDayInZone, toUtcIso } from "./time.ts";

/** Honest label: we do not have Oura's per-minute daytime stress series. */
export const HR_METHOD = "heartrate_proxy" as const;
export const HR_METHOD_NOTE =
  "This uses heart-rate from your ring during the meeting. It is not Oura's daytime stress score.";
export const NO_HR_HEADLINE = "No ring HR in this window";
export const MEETING_SERIES_MAX = 80;
/** Compact sparkline for person history — enough to read, small enough to ship. */
export const PERSON_SERIES_MAX = 24;
/** bpm above that day's awake mean that counts as elevated. Resting is reported, not the zone line. */
export const ELEVATED_ABOVE_AWAKE = 8;
/** Skip restored meetings from the spiked feed unless impact is at least this. */
export const MIN_HR_SPIKE_IMPACT = 8;

export type HrSample = {
  bpm: number;
  timestampMs: number;
  timestamp: string;
  source: string | null;
};

export type MeetingHrZone = "low" | "moderate" | "high";

export type DayHrPoint = {
  t: string;
  bpm: number;
  minutes: number;
};

export type MeetingHrStress = {
  coverage: "ok" | "none";
  method: typeof HR_METHOD;
  methodNote: string;
  sampleCount: number;
  meanBpm: number | null;
  maxBpm: number | null;
  dayAwakeMeanBpm: number | null;
  restingBpm: number | null;
  elevatedThresholdBpm: number | null;
  elevatedPct: number | null;
  elevatedMinutes: number | null;
  meanVsAwake: number | null;
  zone: MeetingHrZone | null;
  headline: string;
  story: string;
  /** Ranking key only — elevated minutes + mean-vs-awake + elevated %. */
  impact: number;
  /** Downsampled ring HR inside the meeting window. Empty when coverage is none. */
  series: DayHrPoint[];
};

function asRecord(doc: unknown): Record<string, unknown> | null {
  return doc && typeof doc === "object" ? (doc as Record<string, unknown>) : null;
}

function num(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) return Number(v);
  return null;
}

function parseOneSample(raw: unknown): HrSample | null {
  const rec = asRecord(raw);
  if (!rec) return null;
  const bpm = num(rec.bpm) ?? num(rec.heart_rate) ?? num(rec.hr);
  const timestamp = typeof rec.timestamp === "string" ? rec.timestamp : typeof rec.time === "string" ? rec.time : null;
  if (bpm == null || bpm <= 0 || bpm > 250 || !timestamp) return null;
  let timestampMs: number;
  try {
    timestampMs = new Date(toUtcIso(timestamp)).getTime();
  } catch {
    timestampMs = Date.parse(timestamp);
  }
  if (!Number.isFinite(timestampMs)) return null;
  const source = typeof rec.source === "string" && rec.source.length ? rec.source : null;
  return { bpm, timestampMs, timestamp, source };
}

/**
 * Accept fixture day-bundles `{ id, day, data: samples }`, production
 * one-sample docs `{ bpm, source, timestamp }`, and bare sample arrays.
 */
export function parseHeartrateDoc(doc: unknown): HrSample[] {
  if (Array.isArray(doc)) {
    return doc.map(parseOneSample).filter((s): s is HrSample => s != null);
  }
  const rec = asRecord(doc);
  if (!rec) return [];
  if (Array.isArray(rec.data)) {
    return rec.data.map(parseOneSample).filter((s): s is HrSample => s != null);
  }
  if (Array.isArray(rec.samples)) {
    return rec.samples.map(parseOneSample).filter((s): s is HrSample => s != null);
  }
  const one = parseOneSample(rec);
  return one ? [one] : [];
}

export function dayFromHeartrateDoc(doc: unknown, timeZone = "America/New_York"): string | null {
  const rec = asRecord(doc);
  if (typeof rec?.day === "string" && /^\d{4}-\d{2}-\d{2}$/.test(rec.day)) return rec.day;
  const samples = parseHeartrateDoc(doc);
  if (!samples.length) return null;
  try {
    return calendarDayInZone(new Date(samples[0].timestampMs).toISOString(), timeZone);
  } catch {
    return null;
  }
}

export function samplesInWindow(samples: HrSample[], startUtc: string, endUtc: string): HrSample[] {
  const start = Date.parse(startUtc);
  const end = Date.parse(endUtc);
  if (!Number.isFinite(start) || !Number.isFinite(end)) return [];
  return samples.filter((s) => s.timestampMs >= start && s.timestampMs <= end);
}

export function samplesOnLocalDay(samples: HrSample[], day: string, timeZone = "America/New_York"): HrSample[] {
  return samples.filter((s) => {
    try {
      return calendarDayInZone(new Date(s.timestampMs).toISOString(), timeZone) === day;
    } catch {
      return false;
    }
  });
}

function mean(values: number[]): number | null {
  if (!values.length) return null;
  return Math.round((values.reduce((a, b) => a + b, 0) / values.length) * 10) / 10;
}

function percentile(values: number[], p: number): number | null {
  const xs = values.filter((n) => Number.isFinite(n)).sort((a, b) => a - b);
  if (!xs.length) return null;
  const idx = Math.min(xs.length - 1, Math.max(0, Math.floor((xs.length - 1) * p)));
  return xs[idx];
}

export function dayRestingBpm(daySamples: HrSample[], lowestHrHint?: number | null): number | null {
  if (lowestHrHint != null && lowestHrHint > 0 && lowestHrHint < 120) {
    return Math.round(lowestHrHint * 10) / 10;
  }
  const sleep = daySamples.filter((s) => s.source === "sleep").map((s) => s.bpm);
  const fromSleep = percentile(sleep, 0.1);
  if (fromSleep != null) return fromSleep;
  return percentile(
    daySamples.map((s) => s.bpm),
    0.1,
  );
}

export function dayAwakeMeanBpm(daySamples: HrSample[]): number | null {
  const awake = daySamples.filter((s) => s.source === "awake" || s.source === "workout");
  const pool = awake.length ? awake : daySamples.filter((s) => s.source !== "sleep");
  return mean((pool.length ? pool : daySamples).map((s) => s.bpm));
}

function elevatedMinutesOf(windowSamples: HrSample[], threshold: number): number {
  if (!windowSamples.length) return 0;
  const ordered = [...windowSamples].sort((a, b) => a.timestampMs - b.timestampMs);
  let minutes = 0;
  for (let i = 0; i < ordered.length; i++) {
    const cur = ordered[i];
    if (cur.bpm < threshold) continue;
    const next = ordered[i + 1];
    const gapMin = next ? (next.timestampMs - cur.timestampMs) / 60_000 : 5;
    minutes += Math.min(10, Math.max(2.5, gapMin));
  }
  return Math.round(minutes * 10) / 10;
}

export function noHrCoverage(): MeetingHrStress {
  return {
    coverage: "none",
    method: HR_METHOD,
    methodNote: HR_METHOD_NOTE,
    sampleCount: 0,
    meanBpm: null,
    maxBpm: null,
    dayAwakeMeanBpm: null,
    restingBpm: null,
    elevatedThresholdBpm: null,
    elevatedPct: null,
    elevatedMinutes: null,
    meanVsAwake: null,
    zone: null,
    headline: NO_HR_HEADLINE,
    story: "The ring did not save heart-rate during this meeting, so there is nothing to graph.",
    impact: 0,
    series: [],
  };
}

export function thinHrSeries(series: DayHrPoint[], maxPoints = PERSON_SERIES_MAX): DayHrPoint[] {
  if (series.length <= maxPoints) return series;
  if (maxPoints <= 1) return series.slice(-1);
  const last = series.length - 1;
  const picked: DayHrPoint[] = [];
  let prev = -1;
  for (let i = 0; i < maxPoints; i++) {
    const idx = Math.round((i * last) / (maxPoints - 1));
    if (idx === prev) continue;
    picked.push(series[idx]);
    prev = idx;
  }
  return picked;
}

export function downsampleWindowHr(samples: HrSample[], maxPoints = MEETING_SERIES_MAX): DayHrPoint[] {
  if (!samples.length) return [];
  const ordered = [...samples].sort((a, b) => a.timestampMs - b.timestampMs);
  const pick =
    ordered.length <= maxPoints
      ? ordered
      : ordered.filter((_, i) => i === ordered.length - 1 || Math.floor(i / (ordered.length / maxPoints)) !== Math.floor((i - 1) / (ordered.length / maxPoints)));
  return pick.map((s) => ({
    t: new Date(s.timestampMs).toISOString(),
    bpm: s.bpm,
    minutes: 0,
  }));
}

function plainHrStory(opts: {
  avgBpm: number | null;
  peakBpm: number | null;
  awakeMean: number | null;
  vsAwake: number | null;
  elevatedMinutes: number;
  sampleCount: number;
}): string {
  const bits: string[] = [];
  if (opts.avgBpm != null) {
    bits.push(`Your heart averaged about ${Math.round(opts.avgBpm)} beats per minute in this meeting.`);
  }
  if (opts.peakBpm != null && opts.avgBpm != null && opts.peakBpm - opts.avgBpm >= 4) {
    bits.push(`Highest in this window: ${Math.round(opts.peakBpm)}.`);
  }
  if (opts.vsAwake != null && opts.awakeMean != null) {
    const abs = Math.abs(Math.round(opts.vsAwake));
    const usual = Math.round(opts.awakeMean);
    if (abs <= 1) bits.push(`About even with your usual daytime average that day (${usual}).`);
    else if (opts.vsAwake > 0) bits.push(`About ${abs} above your usual daytime average that day (${usual}).`);
    else bits.push(`About ${abs} below your usual daytime average that day (${usual}).`);
  }
  if (opts.elevatedMinutes > 0) {
    bits.push(`About ${Math.round(opts.elevatedMinutes)} minutes ran higher than usual for that day.`);
  }
  if (!bits.length) bits.push(`${opts.sampleCount} ring samples in this window.`);
  return bits.join(" ");
}

export function scoreMeetingHr(
  windowSamples: HrSample[],
  daySamples: HrSample[],
  lowestHrHint?: number | null,
): MeetingHrStress {
  if (!windowSamples.length) return noHrCoverage();

  const resting = dayRestingBpm(daySamples.length ? daySamples : windowSamples, lowestHrHint);
  const awakeMean = dayAwakeMeanBpm(daySamples.length ? daySamples : windowSamples);
  const threshold =
    awakeMean != null
      ? awakeMean + ELEVATED_ABOVE_AWAKE
      : resting != null
        ? resting + 20
        : null;
  const bpms = windowSamples.map((s) => s.bpm);
  const meanBpm = mean(bpms);
  const maxBpm = Math.max(...bpms);
  const elevated = threshold != null ? windowSamples.filter((s) => s.bpm >= threshold) : [];
  const elevatedPct =
    threshold != null ? Math.round((elevated.length / windowSamples.length) * 1000) / 10 : null;
  const elevatedMin = threshold != null ? elevatedMinutesOf(windowSamples, threshold) : 0;
  const meanVsAwake =
    meanBpm != null && awakeMean != null ? Math.round((meanBpm - awakeMean) * 10) / 10 : null;

  let zone: MeetingHrZone = "low";
  if ((elevatedPct != null && elevatedPct >= 50) || (meanVsAwake != null && meanVsAwake >= 12)) {
    zone = "high";
  } else if ((elevatedPct != null && elevatedPct >= 20) || (meanVsAwake != null && meanVsAwake >= 5)) {
    zone = "moderate";
  }

  const headline = zone === "high" ? "Elevated" : zone === "moderate" ? "Worth watching" : "Restored";
  const impact = Math.round((elevatedMin + Math.max(0, meanVsAwake ?? 0) + (elevatedPct ?? 0) / 5) * 10) / 10;

  return {
    coverage: "ok",
    method: HR_METHOD,
    methodNote: HR_METHOD_NOTE,
    sampleCount: windowSamples.length,
    meanBpm,
    maxBpm,
    dayAwakeMeanBpm: awakeMean,
    restingBpm: resting,
    elevatedThresholdBpm: threshold,
    elevatedPct,
    elevatedMinutes: elevatedMin,
    meanVsAwake,
    zone,
    headline,
    story: plainHrStory({
      avgBpm: meanBpm,
      peakBpm: maxBpm,
      awakeMean,
      vsAwake: meanVsAwake,
      elevatedMinutes: elevatedMin,
      sampleCount: windowSamples.length,
    }),
    impact,
    series: downsampleWindowHr(windowSamples),
  };
}

export function isHrSpike(hr: MeetingHrStress): boolean {
  if (hr.coverage !== "ok") return false;
  if (hr.zone === "high" || hr.zone === "moderate") return true;
  return hr.impact >= MIN_HR_SPIKE_IMPACT;
}

export function downsampleDayHr(samples: HrSample[], bucketMinutes = 15): DayHrPoint[] {
  if (!samples.length) return [];
  const buckets = new Map<number, number[]>();
  for (const s of samples) {
    const key = Math.floor(s.timestampMs / (bucketMinutes * 60_000));
    const list = buckets.get(key) ?? [];
    list.push(s.bpm);
    buckets.set(key, list);
  }
  return [...buckets.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([key, bpms]) => {
      const t = new Date(key * bucketMinutes * 60_000).toISOString();
      const avg = bpms.reduce((a, b) => a + b, 0) / bpms.length;
      return { t, bpm: Math.round(avg * 10) / 10, minutes: key * bucketMinutes };
    });
}

export function attachMeetingHr(
  meetings: Array<{ id: string; startUtc: string; endUtc: string; day: string }>,
  samples: HrSample[],
  lowestHrByDay: Map<string, number | null>,
  timeZone = "America/New_York",
): Map<string, MeetingHrStress> {
  const out = new Map<string, MeetingHrStress>();
  const dayCache = new Map<string, HrSample[]>();
  const daySamplesFor = (day: string) => {
    const cached = dayCache.get(day);
    if (cached) return cached;
    const list = samplesOnLocalDay(samples, day, timeZone);
    dayCache.set(day, list);
    return list;
  };
  for (const m of meetings) {
    const window = samplesInWindow(samples, m.startUtc, m.endUtc);
    out.set(m.id, scoreMeetingHr(window, daySamplesFor(m.day), lowestHrByDay.get(m.day) ?? null));
  }
  return out;
}

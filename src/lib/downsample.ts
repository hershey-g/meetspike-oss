/**
 * Thin a heart-rate series for a chart without changing its shape.
 *
 * Rules:
 *  - At most `max` points. A series that already fits is returned as is.
 *  - The result is an ordered subset of the input. Kept points are the input
 *    objects themselves, so every field (`minutes`, `source`, ...) is untouched.
 *  - The first and last point are kept.
 *  - Points are never merged across a provider change, or across a gap the
 *    chart draws as a break: more than 180 s between consecutive WHOOP points,
 *    more than 600 s otherwise. Those thresholds match the clients, which split
 *    their line on the same rule. WHOOP points often carry no `source`, so the
 *    caller names the series' provider in `fallbackSource`.
 *  - Each such run keeps its first, last, lowest and highest point, so the
 *    overall min and max survive and so does a lone reading between two gaps.
 *  - Inside a run, time is cut into buckets that each keep their min and max.
 *    Thinning never creates a fake gap: if two kept points of one run would
 *    end up further apart than the run's gap threshold, the original points in
 *    between are added back (greedily, as few as possible). If that does not
 *    fit the budget the buckets get wider until it does.
 *  - Bounded no matter what. When the runs alone cannot each keep their four
 *    essential points (a series where every reading is its own run), the
 *    essential points of all runs are sampled evenly, keeping the overall
 *    first, last, lowest and highest. Last resort for one run whose bridging
 *    still does not fit: an even sample of its points (may show a gap).
 */
export type SeriesPoint = { t: string; bpm: number; source?: string };

export type DownsampleOptions = {
  /** Provider assumed for points without a `source`. */
  fallbackSource?: string;
};

const WHOOP_GAP_MS = 180_000;
const OTHER_GAP_MS = 600_000;
const ESSENTIAL = 4;

type Run = { from: number; to: number; gapMs: number };

export function downsampleSeries<T extends SeriesPoint>(points: readonly T[], max: number, opts: DownsampleOptions = {}): T[] {
  const n = points.length;
  const limit = Math.max(2, Math.floor(max));
  if (n <= limit) return points.slice();

  const ms = new Array<number>(n);
  const bpm = new Array<number>(n);
  const provider = new Array<string | undefined>(n);
  for (let i = 0; i < n; i += 1) {
    const parsed = Date.parse(points[i].t);
    ms[i] = Number.isFinite(parsed) ? parsed : i > 0 ? ms[i - 1] : 0;
    bpm[i] = points[i].bpm;
    provider[i] = points[i].source ?? opts.fallbackSource;
  }

  // Split into runs: a provider change or a gap the chart draws as a break.
  const runs: Run[] = [];
  let from = 0;
  for (let i = 1; i <= n; i += 1) {
    let split = i === n;
    if (!split) {
      const whoop = provider[i - 1] === "WHOOP" && provider[i] === "WHOOP";
      split = provider[i] !== provider[i - 1] || ms[i] - ms[i - 1] > (whoop ? WHOOP_GAP_MS : OTHER_GAP_MS);
    }
    if (split) {
      runs.push({ from, to: i, gapMs: provider[from] === "WHOOP" ? WHOOP_GAP_MS : OTHER_GAP_MS });
      from = i;
    }
  }

  const extremes = (a: number, b: number): { lo: number; hi: number } => {
    let lo = a;
    let hi = a;
    for (let i = a + 1; i < b; i += 1) {
      if (bpm[i] < bpm[lo]) lo = i;
      if (bpm[i] > bpm[hi]) hi = i;
    }
    return { lo, hi };
  };

  const essentials = (r: Run): number[] => {
    const { lo, hi } = extremes(r.from, r.to);
    return [...new Set([r.from, r.to - 1, lo, hi])].sort((a, b) => a - b);
  };

  const base = runs.reduce((sum, r) => sum + Math.min(r.to - r.from, ESSENTIAL), 0);
  let kept: number[];

  if (base > limit) {
    // Too many runs for each to keep its essentials: sample them evenly.
    const flat = runs.flatMap(essentials);
    const must = new Set<number>([0, n - 1]);
    const all = extremes(0, n);
    must.add(all.lo);
    must.add(all.hi);
    const rest = flat.filter((i) => !must.has(i));
    const room = Math.max(0, limit - must.size);
    const chosen = new Set(must);
    if (rest.length <= room) for (const i of rest) chosen.add(i);
    else for (let k = 0; k < room; k += 1) chosen.add(rest[Math.floor(((k + 0.5) * rest.length) / room)]);
    kept = [...chosen].sort((a, b) => a - b);
  } else {
    // Share what is left over between the runs, in proportion to their length.
    const capacity = runs.reduce((sum, r) => sum + (r.to - r.from) - Math.min(r.to - r.from, ESSENTIAL), 0);
    const spare = limit - base;
    kept = [];
    for (const r of runs) {
      const len = r.to - r.from;
      const floor = Math.min(len, ESSENTIAL);
      const budget = floor + (capacity > 0 ? Math.floor((spare * (len - floor)) / capacity) : 0);
      for (const i of thinRun(r, Math.min(budget, len))) kept.push(i);
    }
  }

  return kept.map((i) => points[i]);

  /** Indexes (ascending) kept from one run, at most `budget` of them. */
  function thinRun(r: Run, budget: number): number[] {
    const len = r.to - r.from;
    if (len <= budget) return range(r.from, r.to);
    const { lo, hi } = extremes(r.from, r.to);
    const t0 = ms[r.from];
    const span = ms[r.to - 1] - t0;

    let buckets = Math.max(1, Math.floor((budget - 2) / 2));
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const picked = bucketPick(r, buckets, t0, span, lo, hi);
      const bridged = bridge(picked, r.gapMs);
      if (bridged.length <= budget) return bridged;
      if (buckets === 1) break;
      buckets = Math.max(1, Math.min(buckets - 1, Math.floor(buckets * 0.9 * (budget / bridged.length))));
    }
    return evenSample(r, budget, lo, hi);
  }

  function bucketPick(r: Run, buckets: number, t0: number, span: number, lo: number, hi: number): number[] {
    const bucketLo = new Array<number>(buckets).fill(-1);
    const bucketHi = new Array<number>(buckets).fill(-1);
    for (let i = r.from; i < r.to; i += 1) {
      const b = span > 0 ? Math.min(buckets - 1, Math.floor(((ms[i] - t0) * buckets) / span)) : 0;
      if (bucketLo[b] < 0 || bpm[i] < bpm[bucketLo[b]]) bucketLo[b] = i;
      if (bucketHi[b] < 0 || bpm[i] > bpm[bucketHi[b]]) bucketHi[b] = i;
    }
    const set = new Set<number>([r.from, r.to - 1, lo, hi]);
    for (let b = 0; b < buckets; b += 1) {
      if (bucketLo[b] >= 0) set.add(bucketLo[b]);
      if (bucketHi[b] >= 0) set.add(bucketHi[b]);
    }
    return [...set].sort((a, b) => a - b);
  }

  /** Add back original points so no two neighbours are further apart than `gapMs`. */
  function bridge(picked: number[], gapMs: number): number[] {
    const out: number[] = [picked[0]];
    for (let k = 1; k < picked.length; k += 1) {
      let a = out[out.length - 1];
      const b = picked[k];
      while (ms[b] - ms[a] > gapMs) {
        let j = a;
        while (j + 1 < b && ms[j + 1] - ms[a] <= gapMs) j += 1;
        if (j === a) break; // the input itself has a wider step here
        out.push(j);
        a = j;
      }
      out.push(b);
    }
    return out;
  }

  function evenSample(r: Run, budget: number, lo: number, hi: number): number[] {
    const must = new Set<number>([r.from, r.to - 1, lo, hi]);
    const chosen = new Set(must);
    const room = Math.max(0, budget - must.size);
    for (let k = 0; k < room; k += 1) chosen.add(r.from + Math.floor(((k + 0.5) * (r.to - r.from)) / room));
    return [...chosen].sort((a, b) => a - b).slice(0, Math.max(budget, 0));
  }
}

function range(a: number, b: number): number[] {
  const out: number[] = [];
  for (let i = a; i < b; i += 1) out.push(i);
  return out;
}

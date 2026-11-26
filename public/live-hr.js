const PAD_MS = 10 * 60_000;
const MAX_MEETING_MS = 8 * 60 * 60_000;
const STALE_MS = 45_000;
const GAP_MS = 15_000;

export function meetingLiveWindow(event) {
  if (event.sourceType && event.sourceType !== "calendar") return null;
  const startMs = Date.parse(event.startUtc);
  const endMs = Date.parse(event.endUtc);
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs || endMs - startMs > MAX_MEETING_MS) return null;
  return { startMs, endMs, fromMs: startMs - PAD_MS, toMs: endMs + PAD_MS };
}

export function mergeLivePoints(previous, batch) {
  if (!batch.length) return previous;
  const points = new Map(previous);
  for (const [ts, bpm] of batch) points.set(ts, bpm);
  return [...points].sort((a, b) => a[0] - b[0]);
}

export function liveChartData(points, window, now) {
  const { startMs, endMs, fromMs, toMs } = window;
  const segments = [];
  let last = null;
  let count = 0, sum = 0, min = Infinity, max = -Infinity;
  let low = Infinity, high = -Infinity;
  for (const point of points) {
    const [ts, bpm] = point;
    if (ts < fromMs || ts > Math.min(toMs, now)) continue;
    if (!last || ts - last[0] > GAP_MS) segments.push([]);
    segments.at(-1).push(point);
    last = point;
    low = Math.min(low, bpm);
    high = Math.max(high, bpm);
    if (ts >= startMs && ts <= endMs) {
      count++;
      sum += bpm;
      min = Math.min(min, bpm);
      max = Math.max(max, bpm);
    }
  }
  return {
    current: last && now - last[0] < STALE_MS ? last[1] : null,
    last,
    stats: count ? { min, avg: Math.round(sum / count), max } : null,
    extent: last ? [low, high] : null,
    segments,
  };
}

// Preserve extrema while limiting how many points the plot draws on a phone.
export function plotSegment(points, bucketMs) {
  const result = [];
  let bucket, min, max;
  const flush = () => {
    if (!min) return;
    if (min !== max && min[0] > max[0]) result.push(max, min);
    else if (min !== max) result.push(min, max);
    else result.push(min);
  };
  for (const point of points) {
    const key = Math.floor(point[0] / bucketMs);
    if (key !== bucket) {
      flush();
      bucket = key;
      min = max = point;
    } else {
      if (point[1] < min[1]) min = point;
      if (point[1] > max[1]) max = point;
    }
  }
  flush();
  if (points.length && result[0] !== points[0]) result.unshift(points[0]);
  if (points.length && result.at(-1) !== points.at(-1)) result.push(points.at(-1));
  return result;
}

function plot(window, data, timeZone) {
  const width = 360, height = 156, left = 28, right = 352, top = 9, bottom = 130;
  const { startMs, endMs, fromMs, toMs } = window;
  const [minimum, maximum] = data.extent;
  const step = Math.max(5, Math.ceil((maximum - minimum + 8) / 20) * 5);
  const low = Math.floor((minimum - 4) / step) * step;
  const high = Math.ceil((maximum + 4) / step) * step;
  const x = (t) => left + (right - left) * (t - fromMs) / (toMs - fromMs);
  const y = (bpm) => bottom - (bottom - top) * (bpm - low) / (high - low);
  const grid = [];
  for (let bpm = low; bpm <= high; bpm += step) {
    grid.push(`<line x1="${left}" x2="${right}" y1="${y(bpm)}" y2="${y(bpm)}" class="live-grid"/>
      <text x="${left - 6}" y="${y(bpm) + 3}" text-anchor="end">${bpm}</text>`);
  }
  const line = data.segments.map((group) => {
    const points = plotSegment(group, (toMs - fromMs) / 250).map(([t, bpm]) => [x(t), y(bpm)]);
    const [firstX, firstY] = points[0];
    if (points.length === 1) return `<circle cx="${firstX}" cy="${firstY}" r="2" class="live-dot"/>`;
    const [lastX, lastY] = points.at(-1);
    let path = `M${firstX},${firstY}`;
    for (let i = 1; i < points.length - 1; i++) {
      const [px, py] = points[i], [nx, ny] = points[i + 1];
      path += ` Q${px.toFixed(2)},${py.toFixed(2)} ${((px + nx) / 2).toFixed(2)},${((py + ny) / 2).toFixed(2)}`;
    }
    path += ` L${lastX},${lastY}`;
    return `<path d="${path} V${bottom} H${firstX} Z" fill="url(#live-hr-fill)"/>
      <path d="${path}" class="live-trace"/>`;
  }).join("");
  const time = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", timeZone });
  return `<svg viewBox="0 0 ${width} ${height}" class="live-plot" role="img" aria-label="WHOOP heart rate ranged from ${minimum} to ${maximum} beats per minute across the padded meeting window">
    <defs><linearGradient id="live-hr-fill" x2="0" y2="1"><stop stop-color="var(--strain)" stop-opacity="0.32"/><stop offset="100%" stop-color="var(--strain)" stop-opacity="0.03"/></linearGradient></defs>
    <rect x="${left}" y="${top}" width="${x(startMs) - left}" height="${bottom - top}" class="live-pad"/>
    <rect x="${x(endMs)}" y="${top}" width="${right - x(endMs)}" height="${bottom - top}" class="live-pad"/>
    ${grid.join("")}
    <line x1="${x(startMs)}" x2="${x(startMs)}" y1="${top}" y2="${bottom}" class="live-start"/>
    ${line}
    <circle cx="${x(data.last[0])}" cy="${y(data.last[1])}" r="3.3" class="live-dot live-endpoint"/>
    <text x="${left}" y="149">${time.format(fromMs)}</text><text x="${right}" y="149" text-anchor="end">${time.format(toMs)}</text>
  </svg>`;
}

export function liveChartHtml(points, window, now, timeZone, status) {
  const data = liveChartData(points, window, now);
  const stats = data.stats;
  const message = status || (data.current != null ? "Receiving readings" : data.last ? "Waiting for new readings" : "Waiting for Meetspike HR on your Mac");
  const show = (n) => n ?? "—";
  return `<div class="live-panel">
    <div class="live-head"><h3>Live WHOOP heart rate</h3><span class="live-status${data.current != null && !status ? " receiving" : ""}">${message}</span></div>
    <div class="live-readout">
      <div class="live-bpm"><strong>${show(data.current ?? data.last?.[1])}</strong> <span>bpm</span>${data.last && data.current == null ? ' <small>Last reading</small>' : ""}</div>
      <dl class="live-stats" aria-label="During meeting, beats per minute"><div><dt>Min</dt><dd>${show(stats?.min)}</dd></div><div><dt>Avg</dt><dd>${show(stats?.avg)}</dd></div><div><dt>Max</dt><dd>${show(stats?.max)}</dd></div></dl>
    </div>
    ${data.last ? `${plot(window, data, timeZone)}<p class="live-key"><span><i class="start"></i>Meeting start</span><span><i class="pad"></i>10-min pads</span></p>` : ""}
  </div>`;
}

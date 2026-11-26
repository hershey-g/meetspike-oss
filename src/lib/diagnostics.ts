/**
 * Build 8: crash and diagnostic reports from the iPhone app. Pure helpers, no
 * I/O. The report body is a MetricKit diagnostic; only an allowlist of keys and
 * only numbers, booleans and strings survive, so no personal text is stored.
 */

export const DIAGNOSTIC_KINDS = ["crash", "hang", "cpu", "disk", "exit", "error", "test"] as const;
export type DiagnosticKind = (typeof DIAGNOSTIC_KINDS)[number];

export const MAX_REPORT_DEPTH = 300;
export const MAX_REPORT_NODES = 20_000;
export const MAX_REPORT_STRING = 500;
export const MAX_CRUMBS = 150;
export const MAX_CRUMB_CHARS = 200;
export const MAX_FUTURE_MS = 86_400_000;

/** Keys that may appear anywhere in `report`. Everything else is dropped. */
export const REPORT_KEYS: ReadonlySet<string> = new Set([
  "callStackTree",
  "callStacks",
  "callStackPerThread",
  "threadAttributed",
  "callStackRootFrames",
  "subFrames",
  "binaryUUID",
  "binaryName",
  "offsetIntoBinaryTextSegment",
  "address",
  "sampleCount",
  "diagnosticMetaData",
  "appBuildVersion",
  "appVersion",
  "osVersion",
  "deviceType",
  "platformArchitecture",
  "exceptionType",
  "exceptionCode",
  "signal",
  "terminationReason",
  "hangDuration",
  "totalCPUTime",
  "totalSampledTime",
  "writesCaused",
  "exits",
  "message",
  "code",
  "path",
]);

export interface SanitizedDiagnostic {
  id: string;
  kind: DiagnosticKind;
  /** Normalised to ISO with milliseconds, UTC. */
  at: string;
  app: "ios";
  build: number;
  version: string;
  os: string;
  device: string;
  signature?: string;
  report: Record<string, unknown>;
  crumbs: string[];
}

export type SanitizeResult = { ok: true; doc: SanitizedDiagnostic } | { ok: false; error: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const LONE_SURROGATE_RE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g;

export function isDiagnosticId(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

/** Cut first (cheap on huge input), then repair a split or lone surrogate. */
function cut(s: string, max: number): string {
  return s.slice(0, max).replace(LONE_SURROGATE_RE, "�");
}

function clip(s: string, max: number): string {
  return cut(s.trim(), max).trim();
}

/** Header-safe text for R2 customMetadata: printable ASCII only. */
export function metadataText(s: string): string {
  return s.replace(/[^\x20-\x7e]/g, "?");
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

interface Frame {
  src: unknown;
  keys: string[] | null;
  i: number;
  dst: Record<string, unknown> | unknown[];
  exits: boolean;
  depth: number;
}

function openFrame(src: unknown, dst: Record<string, unknown> | unknown[], exits: boolean, depth: number): Frame {
  return { src, keys: Array.isArray(src) ? null : Object.keys(src as object), i: 0, dst, exits, depth };
}

/**
 * Iterative so a 100k-deep body cannot overflow the stack; bounded by depth and
 * node limits so a 100k-wide one cannot run long. Never throws.
 */
export function sanitizeReport(report: Record<string, unknown>): Record<string, unknown> {
  const root: Record<string, unknown> = {};
  let nodes = 0;
  try {
    const stack: Frame[] = [openFrame(report, root, false, 1)];
    while (stack.length > 0 && nodes < MAX_REPORT_NODES) {
      const f = stack[stack.length - 1];
      const len = f.keys ? f.keys.length : (f.src as unknown[]).length;
      if (f.i >= len) {
        stack.pop();
        continue;
      }
      const index = f.i++;
      const key = f.keys ? f.keys[index] : null;
      let value: unknown;
      if (key !== null) {
        if (f.exits) {
          if (key === "__proto__") continue;
        } else if (!REPORT_KEYS.has(key)) {
          continue;
        }
        value = (f.src as Record<string, unknown>)[key];
      } else {
        value = (f.src as unknown[])[index];
      }

      let out: unknown;
      if (typeof value === "number") {
        if (!Number.isFinite(value)) continue;
        out = value;
      } else if (f.exits) {
        continue; // exits is a map of string -> number, nothing else
      } else if (typeof value === "string") {
        out = cut(value, MAX_REPORT_STRING);
      } else if (typeof value === "boolean") {
        out = value;
      } else if (Array.isArray(value) || isPlainObject(value)) {
        if (f.depth + 1 > MAX_REPORT_DEPTH) continue;
        const child: Record<string, unknown> | unknown[] = Array.isArray(value) ? [] : {};
        nodes += 1;
        if (Array.isArray(f.dst)) f.dst.push(child);
        else f.dst[key as string] = child;
        stack.push(openFrame(value, child, key === "exits" && !Array.isArray(value), f.depth + 1));
        continue;
      } else {
        continue;
      }
      nodes += 1;
      if (Array.isArray(f.dst)) f.dst.push(out);
      else f.dst[key as string] = out;
    }
  } catch {
    // A hostile getter or proxy: keep whatever was built so far.
  }
  return root;
}

function sanitizeCrumbs(raw: unknown): string[] | null {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) return null;
  // The newest lines are the ones next to the crash: keep the last 150.
  const tail = raw.length > MAX_CRUMBS ? raw.slice(raw.length - MAX_CRUMBS) : raw;
  const lines: string[] = [];
  for (const line of tail) {
    if (typeof line !== "string") continue;
    const text = clip(line, MAX_CRUMB_CHARS);
    if (text) lines.push(text);
  }
  return lines;
}

/** Day folder (UTC, YYYY-MM-DD) for a stored report. */
export function diagnosticDay(at: string): string {
  return at.slice(0, 10);
}

export function diagnosticKey(at: string, id: string): string {
  return `diagnostics/${diagnosticDay(at)}/${id}.json`;
}

/**
 * Validate and clean a report body. Pure and never throws. `now` is injectable
 * for tests.
 */
export function sanitizeDiagnostic(body: unknown, now: number = Date.now()): SanitizeResult {
  try {
    if (!isPlainObject(body)) return { ok: false, error: "JSON object body required" };
    const id = body.id;
    if (!isDiagnosticId(id)) return { ok: false, error: "id must be a uuid" };
    const kind = body.kind;
    if (typeof kind !== "string" || !(DIAGNOSTIC_KINDS as readonly string[]).includes(kind)) {
      return { ok: false, error: `kind must be one of ${DIAGNOSTIC_KINDS.join(", ")}` };
    }
    if (typeof body.at !== "string") return { ok: false, error: "at must be an ISO date string" };
    const atMs = Date.parse(body.at);
    if (!Number.isFinite(atMs)) return { ok: false, error: "at is not a valid date" };
    if (atMs > now + MAX_FUTURE_MS) return { ok: false, error: "at is more than a day in the future" };
    const at = new Date(atMs).toISOString();
    if (!DAY_RE.test(diagnosticDay(at))) return { ok: false, error: "at is out of range" };
    if (body.app !== "ios") return { ok: false, error: "app must be ios" };
    const build = body.build;
    if (typeof build !== "number" || !Number.isSafeInteger(build) || build < 0) {
      return { ok: false, error: "build must be a whole number" };
    }
    for (const field of ["version", "os", "device"] as const) {
      if (typeof body[field] !== "string") return { ok: false, error: `${field} must be a string` };
    }
    if (body.signature !== undefined && body.signature !== null && typeof body.signature !== "string") {
      return { ok: false, error: "signature must be a string" };
    }
    if (!isPlainObject(body.report)) return { ok: false, error: "report must be an object" };
    const crumbs = sanitizeCrumbs(body.crumbs);
    if (crumbs === null) return { ok: false, error: "crumbs must be a list of strings" };

    const doc: SanitizedDiagnostic = {
      id: id.toLowerCase(),
      kind: kind as DiagnosticKind,
      at,
      app: "ios",
      build,
      version: clip(body.version as string, 40),
      os: clip(body.os as string, 40),
      device: clip(body.device as string, 40),
      report: sanitizeReport(body.report),
      crumbs,
    };
    if (typeof body.signature === "string") {
      const signature = clip(body.signature, 200);
      if (signature) doc.signature = signature;
    }
    return { ok: true, doc };
  } catch {
    return { ok: false, error: "could not read the report" };
  }
}

/** R2 customMetadata for a stored report: strings only. */
export function diagnosticMetadata(doc: SanitizedDiagnostic): Record<string, string> {
  const meta: Record<string, string> = {
    kind: doc.kind,
    build: String(doc.build),
    os: metadataText(doc.os),
    device: metadataText(doc.device),
    at: doc.at,
  };
  if (doc.signature) meta.signature = metadataText(doc.signature);
  return meta;
}

export interface DiagnosticSummary {
  id: string;
  key: string;
  kind: string | null;
  build: number | null;
  os: string | null;
  device: string | null;
  signature: string | null;
  at: string | null;
  size: number;
}

const KEY_RE = /^diagnostics\/(\d{4}-\d{2}-\d{2})\/([^/]+)\.json$/;

/** The day folder of a stored key, or null when the key is not a report. */
export function keyDay(key: string): string | null {
  return KEY_RE.exec(key)?.[1] ?? null;
}

export function keyId(key: string): string | null {
  return KEY_RE.exec(key)?.[2] ?? null;
}

export function summarize(obj: { key: string; size: number; uploaded?: Date; customMetadata?: Record<string, string> }): DiagnosticSummary | null {
  const id = keyId(obj.key);
  if (!id) return null;
  const m = obj.customMetadata ?? {};
  const build = Number(m.build);
  const at = m.at && Number.isFinite(Date.parse(m.at)) ? m.at : obj.uploaded ? obj.uploaded.toISOString() : null;
  return {
    id,
    key: obj.key,
    kind: m.kind ?? null,
    build: m.build !== undefined && Number.isFinite(build) ? build : null,
    os: m.os ?? null,
    device: m.device ?? null,
    signature: m.signature ? m.signature : null,
    at,
    size: obj.size,
  };
}

/** Newest first; ties broken by key so the order is stable. */
export function sortNewestFirst(rows: DiagnosticSummary[]): DiagnosticSummary[] {
  const time = (r: DiagnosticSummary) => (r.at ? Date.parse(r.at) : 0);
  return rows.sort((a, b) => time(b) - time(a) || (a.key < b.key ? 1 : a.key > b.key ? -1 : 0));
}

export const RETENTION_DAYS = 90;
export const RETENTION_MAX_DELETES = 200;

/** Day folders strictly before this are past retention. */
export function retentionCutoffDay(now: number): string {
  return new Date(now - RETENTION_DAYS * 86_400_000).toISOString().slice(0, 10);
}

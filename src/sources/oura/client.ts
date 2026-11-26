import type { Env } from "../../env.ts";
import { sandboxMode } from "../../env.ts";
import { OURA_API, addUtcDays, endpointByKey, endpointByDataType } from "./endpoints.ts";
import { getValidAccessToken, MembershipLapsedError, refreshOuraToken, getOuraTokens } from "../../lib/tokens.ts";

export class RateLimitError extends Error {
  retryAfterS: number;
  constructor(retryAfterS: number) {
    super(`oura 429 retry after ${retryAfterS}s`);
    this.name = "RateLimitError";
    this.retryAfterS = retryAfterS;
  }
}

function collectionBase(env: Env): string {
  return sandboxMode(env)
    ? `${OURA_API}/v2/sandbox/usercollection`
    : `${OURA_API}/v2/usercollection`;
}

export type OuraPacing = { minMs: number; lastRequestAt?: number };

export function ouraRetryAfter(headers: Headers, now = Date.now()): number {
  const delay = Number(headers.get("Retry-After"));
  if (Number.isFinite(delay) && delay > 0) return Math.ceil(delay);
  const reset = Number(headers.get("X-RateLimit-Reset")) - now / 1000;
  return Number.isFinite(reset) && reset > 0 ? Math.ceil(reset) : 60;
}

export async function ouraFetch(env: Env, pathWithQuery: string, token: string, pacing?: OuraPacing): Promise<Response> {
  const url = pathWithQuery.startsWith("http") ? pathWithQuery : `${collectionBase(env)}/${pathWithQuery}`;
  const request = async (accessToken: string) => {
    if (pacing) {
      const wait = (pacing.lastRequestAt ?? 0) + pacing.minMs - Date.now();
      if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
      pacing.lastRequestAt = Date.now();
    }
    const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
    if (res.status === 429) throw new RateLimitError(ouraRetryAfter(res.headers));
    if (res.status === 403) throw new MembershipLapsedError();
    return res;
  };
  let res = await request(token);
  if (res.status === 401) {
    const bundle = await getOuraTokens(env);
    if (!bundle) throw new Error("oura 401 and no tokens");
    res = await request(await refreshOuraToken(env, bundle));
  }
  if (!res.ok) throw new Error(`oura HTTP ${res.status}`);
  return res;
}

export async function fetchDocument(env: Env, dataType: string, objectId: string): Promise<unknown> {
  const spec = endpointByKey(dataType) ?? endpointByDataType(dataType);
  if (!spec) throw new Error(`unknown data_type ${dataType}`);
  const token = await getValidAccessToken(env);
  const res = await ouraFetch(env, `${spec.path}/${encodeURIComponent(objectId)}`, token);
  return res.json();
}

export type ListedDoc = Record<string, unknown>;

export async function listDocuments(
  env: Env,
  endpointKey: string,
  window: { start: string; end: string },
  pacing?: OuraPacing,
): Promise<ListedDoc[]> {
  const spec = endpointByKey(endpointKey);
  if (!spec) throw new Error(`unknown endpoint ${endpointKey}`);
  const out: ListedDoc[] = [];
  const hrByDay = new Map<string, ListedDoc[]>();
  const endExclusive = addUtcDays(window.end, 1);
  const seen = new Set<string>();
  let next: string | null = null;
  do {
    const params = new URLSearchParams();
    if (spec.dateStyle === "date") {
      params.set("start_date", window.start);
      params.set("end_date", endExclusive);
    } else if (spec.dateStyle === "datetime") {
      params.set("start_datetime", `${window.start}T00:00:00Z`);
      params.set("end_datetime", `${endExclusive}T00:00:00Z`);
    }
    if (next) params.set("next_token", next);
    const path = spec.dateStyle === "none" ? spec.path : `${spec.path}?${params.toString()}`;
    const res = await ouraFetch(env, path, await getValidAccessToken(env), pacing);
    const json = (await res.json()) as { data?: ListedDoc[]; next_token?: string | null };
    if (spec.key === "personal_info") {
      out.push(json as unknown as ListedDoc);
      break;
    }
    if (!Array.isArray(json.data)) throw new Error(`Oura ${spec.key} returned an invalid collection`);
    if (spec.key === "heartrate") {
      for (const sample of json.data) {
        const timestamp = typeof sample?.timestamp === "string" ? Date.parse(sample.timestamp) : NaN;
        if (!Number.isFinite(timestamp)) continue;
        const day = new Date(timestamp).toISOString().slice(0, 10);
        if (day < window.start || day > window.end) continue;
        const points = hrByDay.get(day);
        if (points) points.push(sample);
        else hrByDay.set(day, [sample]);
      }
    } else {
      out.push(...json.data.filter((doc) => typeof doc?.day !== "string" || (doc.day >= window.start && doc.day <= window.end)));
    }
    next = json.next_token ?? null;
    if (next) {
      if (seen.has(next)) throw new Error(`Oura ${spec.key} repeated a pagination token`);
      seen.add(next);
    }
  } while (next);
  for (const [day, data] of hrByDay) {
    data.sort((a, b) => String(a.timestamp).localeCompare(String(b.timestamp)));
    out.push({ id: `hr-${day}-daily`, day, data });
  }
  return out;
}

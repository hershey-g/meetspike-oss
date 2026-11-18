import type { Env } from "../../env.ts";
import { sandboxMode } from "../../env.ts";
import { OURA_API, endpointByKey, endpointByDataType } from "./endpoints.ts";
import { getValidAccessToken, MembershipLapsedError, refreshOuraToken, getOuraTokens } from "../../lib/tokens.ts";
import { calendarDayInZone, toUtcIso } from "../../lib/time.ts";

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

export async function ouraFetch(env: Env, pathWithQuery: string, token: string): Promise<Response> {
  const url = pathWithQuery.startsWith("http") ? pathWithQuery : `${collectionBase(env)}/${pathWithQuery}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (res.status === 429) {
    const retry = Number(res.headers.get("Retry-After") ?? "2");
    throw new RateLimitError(Number.isFinite(retry) ? retry : 2);
  }
  if (res.status === 403) throw new MembershipLapsedError();
  if (res.status === 401) {
    const bundle = await getOuraTokens(env);
    if (!bundle) throw new Error("oura 401 and no tokens");
    const next = await refreshOuraToken(env, bundle);
    const retryRes = await fetch(url, { headers: { Authorization: `Bearer ${next}` } });
    if (retryRes.status === 403) throw new MembershipLapsedError();
    if (!retryRes.ok) throw new Error(`oura ${retryRes.status} after refresh: ${await retryRes.text()}`);
    return retryRes;
  }
  if (!res.ok) throw new Error(`oura ${res.status}: ${await res.text()}`);
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
): Promise<ListedDoc[]> {
  const spec = endpointByKey(endpointKey);
  if (!spec) throw new Error(`unknown endpoint ${endpointKey}`);
  const token = await getValidAccessToken(env);
  const out: ListedDoc[] = [];
  let next: string | null = null;
  do {
    const params = new URLSearchParams();
    if (spec.dateStyle === "date") {
      params.set("start_date", window.start);
      params.set("end_date", window.end);
    } else if (spec.dateStyle === "datetime") {
      params.set("start_datetime", `${window.start}T00:00:00-04:00`);
      params.set("end_datetime", `${window.end}T23:59:59-04:00`);
    }
    if (next) params.set("next_token", next);
    const path = spec.dateStyle === "none" ? spec.path : `${spec.path}?${params.toString()}`;
    const res = await ouraFetch(env, path, token);
    const json = (await res.json()) as { data?: ListedDoc[]; next_token?: string | null };
    if (spec.key === "personal_info") {
      out.push(json as unknown as ListedDoc);
      break;
    }
    if (spec.key === "heartrate") {
      const page = Array.isArray(json.data) ? json.data : [];
      if (page.length) {
        const first = page[0] as ListedDoc;
        const ts = typeof first.timestamp === "string" ? first.timestamp : `${window.start}T00:00:00-04:00`;
        let day = window.start;
        try {
          day = calendarDayInZone(toUtcIso(ts));
        } catch {
          /* keep window.start */
        }
        out.push({
          id: `hr-${day}-p${out.length}`,
          day,
          data: page,
        });
      }
    } else if (Array.isArray(json.data)) {
      out.push(...json.data);
    }
    next = json.next_token ?? null;
  } while (next);
  return out;
}

/**
 * Public-build stand-in for ../web-api/index.ts. Same exports, same types, no
 * network. The private build signs in to WHOOP's web app (its Cognito login)
 * and reads minute heart rate from it. That code is not part of this build,
 * so everything here says so and does nothing else.
 */
import type { ParsedHr, ParsedStressDay } from "../parse.ts";
import type { SessionStore, WhoopWebDeps, WhoopWebLoginState, WhoopWebResult, WhoopWebSession } from "../web-api-types.ts";

export { WhoopWebAuthError } from "../web-api-types.ts";
export type {
  SessionStore,
  WhoopWebAuthCode,
  WhoopWebAuthEnv,
  WhoopWebDeps,
  WhoopWebLoginState,
  WhoopWebResult,
  WhoopWebSession,
} from "../web-api-types.ts";

/** True in the build that carries the web API client. */
export const webApiIncluded = false;
/** What routes and results say when the web API is not part of the build. */
export const WEB_API_NOT_INCLUDED = "WHOOP web API is not included in this build";

const notIncluded = { ok: false, status: 501, reason: WEB_API_NOT_INCLUDED } as const;

export async function readWhoopWebSession(_env: { TOKENS: SessionStore }): Promise<WhoopWebSession | null> {
  return null;
}

export async function readLoginState(_env: { TOKENS: SessionStore }): Promise<WhoopWebLoginState | null> {
  return null;
}

export async function resetLoginBackoff(_env: { TOKENS: SessionStore }): Promise<boolean> {
  return false;
}

export async function storeManualToken(
  _env: { TOKENS: SessionStore },
  _input: { accessToken: unknown; refreshToken?: unknown; userId?: unknown; expiresInS?: unknown },
  _now = Date.now(),
): Promise<{ ok: true; userId: string; expiresAt: string; hasRefresh: boolean } | { ok: false; error: string }> {
  return { ok: false, error: WEB_API_NOT_INCLUDED };
}

export async function webApiCanAuth(
  _env: { TOKENS: SessionStore; WHOOP_WEB_EMAIL?: string; WHOOP_WEB_PASSWORD?: string },
  _deps: WhoopWebDeps,
): Promise<boolean> {
  return false;
}

export async function fetchHeartRate(
  _env: unknown,
  _startMs: number,
  _endMs: number,
  _deps: WhoopWebDeps = {},
): Promise<WhoopWebResult<ParsedHr>> {
  return notIncluded;
}

export async function fetchStressDay(
  _env: unknown,
  _day: string,
  _timeZone: string,
  _deps: WhoopWebDeps = {},
): Promise<WhoopWebResult<ParsedStressDay>> {
  return notIncluded;
}

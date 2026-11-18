import type { Env } from "../env.ts";
import { redirectUri } from "../env.ts";
import { getGoogleTokens, getOuraTokens, getWhoopTokens } from "../lib/tokens.ts";
import { parseWearable, wearableChoice, wearableInfo } from "../lib/wearable.ts";
import { OAUTH_SCOPES } from "../sources/oura/endpoints.ts";
import { GOOGLE_SCOPES } from "../sources/calendar/endpoints.ts";
import { WHOOP_CALLBACK_PATH, WHOOP_SCOPES, WHOOP_START_PATH } from "../sources/whoop/endpoints.ts";

function has(v: string | undefined): boolean {
  return typeof v === "string" && v.trim() !== "";
}

export type SetupProvider = {
  /** Where to create the developer app. */
  appUrl: string;
  /** The exact address to paste into the app's redirect field. */
  redirectUri: string;
  /** Where "Connect" sends the browser. */
  startPath: string;
  scopes: string[];
  /** Secret name → whether the Worker has a value. Never the value itself. */
  secrets: Record<string, boolean>;
  connected: boolean;
};

export type SetupStatus = {
  ok: true;
  origin: string;
  wearable: ReturnType<typeof wearableInfo> & {
    chosenBy: "configured" | "legacy_oura" | "default";
    /** Raw WEARABLE value when it is set but not one we recognise. */
    unrecognised: string | null;
  };
  whoop: SetupProvider;
  oura: SetupProvider;
  google: SetupProvider;
  /** True once the active wearable and Google Calendar are both connected. */
  ready: boolean;
};

/**
 * What the first-run page needs: which wearable is active, the exact redirect
 * addresses, and which keys are still missing. It reports only whether each
 * secret exists — a Worker cannot read a secret back out for display, and
 * cannot set its own secrets, so the page explains where to paste them.
 */
export async function setupStatus(env: Env, requestUrl: string): Promise<SetupStatus> {
  const choice = wearableChoice(env);
  const [whoopTokens, ouraTokens, googleTokens] = await Promise.all([
    getWhoopTokens(env),
    getOuraTokens(env),
    getGoogleTokens(env),
  ]);
  const whoop: SetupProvider = {
    appUrl: "https://developer-dashboard.whoop.com/apps/create",
    redirectUri: redirectUri(env.WHOOP_REDIRECT_URI, requestUrl, WHOOP_CALLBACK_PATH),
    startPath: WHOOP_START_PATH,
    scopes: [...WHOOP_SCOPES],
    secrets: { WHOOP_CLIENT_ID: has(env.WHOOP_CLIENT_ID), WHOOP_CLIENT_SECRET: has(env.WHOOP_CLIENT_SECRET) },
    connected: Boolean(whoopTokens),
  };
  const oura: SetupProvider = {
    appUrl: "https://cloud.ouraring.com/oauth/applications",
    redirectUri: redirectUri(env.OURA_REDIRECT_URI, requestUrl, "/auth/oura/callback"),
    startPath: "/auth/oura/start",
    scopes: [...OAUTH_SCOPES],
    secrets: { OURA_CLIENT_ID: has(env.OURA_CLIENT_ID), OURA_CLIENT_SECRET: has(env.OURA_CLIENT_SECRET) },
    connected: Boolean(ouraTokens),
  };
  const google: SetupProvider = {
    appUrl: "https://console.cloud.google.com/apis/credentials",
    redirectUri: redirectUri(env.GOOGLE_REDIRECT_URI, requestUrl, "/auth/google/callback"),
    startPath: "/auth/google/start",
    scopes: [...GOOGLE_SCOPES],
    secrets: { GOOGLE_CLIENT_ID: has(env.GOOGLE_CLIENT_ID), GOOGLE_CLIENT_SECRET: has(env.GOOGLE_CLIENT_SECRET) },
    connected: Boolean(googleTokens),
  };
  const active = choice.source === "whoop" ? whoop : oura;
  return {
    ok: true,
    origin: new URL(requestUrl).origin,
    wearable: {
      ...wearableInfo(choice.source),
      chosenBy: choice.reason,
      unrecognised: has(env.WEARABLE) && !parseWearable(env.WEARABLE) ? String(env.WEARABLE) : null,
    },
    whoop,
    oura,
    google,
    ready: active.connected && google.connected,
  };
}

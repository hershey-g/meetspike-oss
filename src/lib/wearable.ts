import { whoopWebHrFlag } from "../env.ts";
import { SOURCE_OURA, SOURCE_WHOOP, type WearableSource } from "../types.ts";

export type Wearable = WearableSource;

export const DEFAULT_WEARABLE: Wearable = SOURCE_WHOOP;

type WearableEnv = {
  WEARABLE?: string;
  WHOOP_WEB_HR?: string;
  OURA_CLIENT_ID?: string;
  WHOOP_CLIENT_ID?: string;
};

function present(v: string | undefined): boolean {
  return typeof v === "string" && v.trim() !== "";
}

/** "whoop" / "oura" (any case, surrounding space ignored). Anything else is null. */
export function parseWearable(raw: string | null | undefined): Wearable | null {
  const v = raw?.trim().toLowerCase();
  if (v === SOURCE_WHOOP || v === SOURCE_OURA) return v;
  return null;
}

/**
 * Which wearable is the primary source for dashboard comparisons.
 *
 * 1. `WEARABLE=whoop|oura` decides, when set to a value we know.
 * 2. Unset (or unrecognised): an install that has Oura credentials and no WHOOP
 *    credentials keeps running on Oura. This is what stops an install that
 *    predates the setting from flipping over on deploy.
 * 3. Otherwise WHOOP — the default for a new install.
 */
export function activeWearable(env: WearableEnv): Wearable {
  const explicit = parseWearable(env.WEARABLE);
  if (explicit) return explicit;
  if (present(env.OURA_CLIENT_ID) && !present(env.WHOOP_CLIENT_ID)) return SOURCE_OURA;
  return DEFAULT_WEARABLE;
}

/** How the active wearable was chosen, for the setup page and /api/health. */
export function wearableChoice(env: WearableEnv): { source: Wearable; reason: "configured" | "legacy_oura" | "default" } {
  const explicit = parseWearable(env.WEARABLE);
  if (explicit) return { source: explicit, reason: "configured" };
  const source = activeWearable(env);
  return { source, reason: source === SOURCE_OURA ? "legacy_oura" : "default" };
}

/**
 * Everything the aggregator and the dashboard need to know about a wearable,
 * as data. Range aggregation, briefings and the UI read these fields; they do
 * not ask which brand it is.
 */
export type WearableInfo = {
  source: Wearable;
  /** Brand name for copy. */
  label: string;
  /** True when the wearable shares heart-rate samples fine enough to slice per meeting. */
  hasIntradayHr: boolean;
  /**
   * Where per-meeting heart rate comes from: the Oura ring archive, WHOOP's
   * web app API (WHOOP_WEB_HR, fetched per meeting and cached), or nowhere.
   */
  hrSource: "oura_ring" | "whoop_web" | null;
  ouraHr: boolean;
  whoopWebHr: boolean;
  /** What the morning 0–100 score is called ("Readiness", "Recovery"). */
  readinessLabel: string;
  /** What whole-day exertion is called, or null when the wearable has none. */
  strainLabel: string | null;
  /** Largest value of the strain scale, for drawing it. */
  strainMax: number | null;
  /** One line under the title. */
  tagline: string;
  /** Plain-English account of what the meeting view is built from. */
  note: string;
};

const OURA_INFO: WearableInfo = {
  source: SOURCE_OURA,
  label: "Oura",
  hasIntradayHr: true,
  hrSource: "oura_ring",
  ouraHr: true,
  whoopWebHr: false,
  readinessLabel: "Readiness",
  strainLabel: null,
  strainMax: null,
  tagline: "Calendar × ring heart-rate",
  note: "Stress during the meeting uses your ring’s heart-rate. That is not Oura’s daytime stress score.",
};

const WHOOP_INFO: WearableInfo = {
  source: SOURCE_WHOOP,
  label: "WHOOP",
  hasIntradayHr: false,
  hrSource: null,
  ouraHr: false,
  whoopWebHr: false,
  readinessLabel: "Recovery",
  strainLabel: "Strain",
  strainMax: 21,
  tagline: "Calendar × WHOOP recovery and strain",
  note:
    "WHOOP does not share minute-by-minute heart rate with other apps, so Meetspike cannot show what your heart did inside one meeting. " +
    "Instead, each day shows how recovered you woke up and how much strain the day added, next to how many meetings you had.",
};

/** WHOOP with WHOOP_WEB_HR on: minute heart rate per meeting from WHOOP's web app API. */
const WHOOP_WEB_INFO: WearableInfo = {
  ...WHOOP_INFO,
  hasIntradayHr: true,
  hrSource: "whoop_web",
  whoopWebHr: true,
  tagline: "Calendar × WHOOP heart rate and recovery",
  note:
    "Heart rate during the meeting is your WHOOP strap's, minute by minute, next to WHOOP's Stress Monitor. " +
    "It is compared with your usual heart rate in other meetings over the past two weeks.",
};

export function wearableInfo(source: Wearable, opts: { whoopWebHr?: boolean } = {}): WearableInfo {
  if (source === SOURCE_WHOOP) return opts.whoopWebHr ? WHOOP_WEB_INFO : WHOOP_INFO;
  return OURA_INFO;
}

export function activeWearableInfo(env: WearableEnv): WearableInfo {
  const primary = wearableInfo(activeWearable(env), { whoopWebHr: whoopWebHrFlag(env) });
  const ouraHr = primary.ouraHr || present(env.OURA_CLIENT_ID);
  const whoopWebHr = whoopWebHrActive(env);
  return { ...primary, ouraHr, whoopWebHr, hasIntradayHr: ouraHr || whoopWebHr };
}

/** WHOOP web and Bluetooth ingest are enabled independently of score preference. */
export function whoopWebHrActive(env: WearableEnv): boolean {
  return whoopWebHrFlag(env);
}

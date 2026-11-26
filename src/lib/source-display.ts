import type { Env } from "../env.ts";
import { SOURCE_OURA, SOURCE_WHOOP, type WearableSource } from "../types.ts";
import { activeWearable, wearableInfo, type WearableInfo } from "./wearable.ts";

export type SourceDisplay = Record<WearableSource, boolean>;
export type DisplayWearableInfo = Omit<WearableInfo, "source"> & { source: WearableSource | null };

// Separate keys let clients update different sources concurrently.
const key = (source: WearableSource) => `settings:source_display:${source}`;

export async function isSourceDisplayed(env: Env, source: WearableSource): Promise<boolean> {
  return await env.TOKENS.get(key(source)) === "true";
}

export async function loadSourceDisplay(env: Env): Promise<SourceDisplay> {
  const [oura, whoop] = await Promise.all([
    isSourceDisplayed(env, SOURCE_OURA),
    isSourceDisplayed(env, SOURCE_WHOOP),
  ]);
  return { oura, whoop };
}

export async function setSourceDisplay(env: Env, source: WearableSource, enabled: boolean): Promise<SourceDisplay> {
  const other = await isSourceDisplayed(env, source === SOURCE_OURA ? SOURCE_WHOOP : SOURCE_OURA);
  await env.TOKENS.put(key(source), String(enabled));
  return source === SOURCE_OURA ? { oura: enabled, whoop: other } : { oura: other, whoop: enabled };
}

export function displayedSources(env: Env, display: SourceDisplay): WearableSource[] {
  const primary = activeWearable(env);
  const secondary = primary === SOURCE_OURA ? SOURCE_WHOOP : SOURCE_OURA;
  return [primary, secondary].filter((source) => display[source]);
}

export function displayWearableInfo(source: WearableSource | null): DisplayWearableInfo {
  return source ? wearableInfo(source) : {
    source: null,
    label: "",
    readinessLabel: "Morning score",
    strainLabel: null,
    strainMax: null,
    hasIntradayHr: false,
    hrSource: null,
    ouraHr: false,
    whoopWebHr: false,
    tagline: "Calendar",
    note: "Wearable display is off.",
  };
}

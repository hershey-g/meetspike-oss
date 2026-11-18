export const SOURCE_TYPE_CALENDAR = "calendar" as const;
export const SOURCE_TYPE_PLAUD_PHONE = "plaud_phone" as const;
export const SOURCE_TYPE_PLAUD_TAGGED = "plaud_tagged" as const;
export const SOURCE_TYPE_PLAUD_BOTH = "plaud_both" as const;

export type EventSourceType =
  | typeof SOURCE_TYPE_CALENDAR
  | typeof SOURCE_TYPE_PLAUD_PHONE
  | typeof SOURCE_TYPE_PLAUD_TAGGED
  | typeof SOURCE_TYPE_PLAUD_BOTH;

export type SourceFilter = "all" | "calendar" | "phone" | "tagged";

export function normalizeSourceType(value: string | null | undefined): EventSourceType {
  if (value === SOURCE_TYPE_PLAUD_PHONE) return SOURCE_TYPE_PLAUD_PHONE;
  if (value === SOURCE_TYPE_PLAUD_TAGGED) return SOURCE_TYPE_PLAUD_TAGGED;
  if (value === SOURCE_TYPE_PLAUD_BOTH) return SOURCE_TYPE_PLAUD_BOTH;
  return SOURCE_TYPE_CALENDAR;
}

/** Phone filter includes titles that also have [meetspike] (`plaud_both`). */
export function matchesSourceFilter(
  sourceType: string | null | undefined,
  filter: SourceFilter,
): boolean {
  const t = normalizeSourceType(sourceType);
  if (filter === "all") return true;
  if (filter === "calendar") return t === SOURCE_TYPE_CALENDAR;
  if (filter === "phone") return t === SOURCE_TYPE_PLAUD_PHONE || t === SOURCE_TYPE_PLAUD_BOTH;
  if (filter === "tagged") return t === SOURCE_TYPE_PLAUD_TAGGED || t === SOURCE_TYPE_PLAUD_BOTH;
  return true;
}

export function parseSourceFilter(raw: string | null | undefined): SourceFilter {
  if (raw === "calendar" || raw === "phone" || raw === "tagged") return raw;
  return "all";
}

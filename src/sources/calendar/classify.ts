export { SOURCE_GOOGLE, SOURCE_SANDBOX_CAL as SOURCE_CALENDAR } from "../../types.ts";

export type WorkKind = "client" | "internal" | "deep_work" | "admin" | "personal" | "unknown";

export const WORK_KIND_LABEL: Record<WorkKind, string> = {
  client: "Client",
  internal: "Internal",
  deep_work: "Deep work",
  admin: "Admin",
  personal: "Personal",
  unknown: "Unclassified",
};

/** Title heuristics for Google events. Sandbox fixtures set kind explicitly. */
export function classifyTitle(
  title: string,
  opts: { externalAttendee?: boolean } = {},
): WorkKind {
  const t = title.toLowerCase();
  if (/\b(focus|deep work|hold for|blocked)\b/.test(t)) return "deep_work";
  if (/\b(standup|stand-up|internal|team sync|1:1|one.on.one|weekly staff)\b/.test(t)) {
    return "internal";
  }
  if (/\b(lunch|personal|doctor|dentist|pickup|school|family)\b/.test(t)) return "personal";
  if (/\b(invoice|bookkeep|admin|accounting|taxes|payroll)\b/.test(t)) return "admin";
  if (
    /\b(discovery|proposal|kickoff|retainer|client|customer|pitch)\b/.test(t) ||
    opts.externalAttendee
  ) {
    return "client";
  }
  return "unknown";
}

/** Local clock after 18:00 in the event's own offset. */
export function isAfterHours(localHour: number, localMinute = 0): boolean {
  return localHour + localMinute / 60 >= 18;
}

export function durationSeconds(startUtc: string, endUtc: string): number {
  const a = Date.parse(startUtc);
  const b = Date.parse(endUtc);
  if (!Number.isFinite(a) || !Number.isFinite(b) || b <= a) return 0;
  return Math.round((b - a) / 1000);
}

import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { Env } from "../env.ts";
import type { CalendarEventRow } from "../types.ts";
import { loadTimeZone } from "../lib/db.ts";
import { calendarDayInZone, DEFAULT_TIME_ZONE } from "../lib/time.ts";
import { isDateRangeError } from "../lib/date-range.ts";
import { parseHistoryRange } from "../lib/history-range.ts";
import { INSIGHTS_DEFAULT_DAYS, parseInsightsDays } from "../lib/insights.ts";
import { loadSourceDisplay, type DisplayWearableInfo, type SourceDisplay } from "../lib/source-display.ts";
import type { MeetingHrStress } from "../lib/heartrate.ts";
import { otherAttendees, parseAttendeesJson, summarizePerson, type PersonTrend } from "../lib/people.ts";
import { rankPeople } from "../lib/people-search.ts";
import { loadMorningScores, nextMorningAverage, usualMorningScore } from "../lib/people-history.ts";
import {
  companiesForAttendees,
  companyDomain,
  companyName,
  loadCompanyNames,
  loadSelfDomains,
  normalizeCompanyDomain,
  normalizeCompanyName,
  saveCompanyName,
  type CompanyContext,
} from "../lib/companies.ts";
import { joinEvents, loadCalendarEvents, loadCalendarEventsByDomain } from "../sources/calendar/query.ts";
import { grainNote, stressScore, toMeetingJson, toPersonMeetingJson, type BriefingLabels } from "../sources/calendar/meetings.ts";
import type { JoinedMeeting } from "../sources/calendar/join.ts";
import { exclusionClause, loadExclusionRules, openRangeOverrides, type OverrideScopeHandle } from "../lib/meeting-override.ts";

/** What the company routes borrow from api.ts, so the heart rate and wearable rules stay in one place. */
export type CompanyRouteDeps = {
  dashboardWearable(env: Env, display?: SourceDisplay): Promise<DisplayWearableInfo>;
  meetingHrMap(
    env: Env, w: DisplayWearableInfo, events: CalendarEventRow[], tz: string, overrides?: OverrideScopeHandle,
  ): Promise<Map<string, MeetingHrStress>>;
  labelsFor(w: DisplayWearableInfo): BriefingLabels;
  methodNoteFor(w: DisplayWearableInfo): string;
};

/** Most companies the list answers with. */
export const COMPANY_LIST_LIMIT = 50;
const HR_SOURCES = ["WHOOP", "Oura", "WHOOP + Oura"] as const;

/** summarizePerson, worded for a company. Same math. */
export function summarizeCompany(rows: Array<{ hrStress: MeetingHrStress | null }>): PersonTrend {
  const trend = summarizePerson(rows);
  return {
    ...trend,
    badgeNote: trend.badgeNote.replace("a person pattern", "a company pattern").replace(" — ", ", "),
  };
}

/** Heart rate trends per provider, as the person page has them. */
export function trendsBySource(meetings: Array<{ hrStress: MeetingHrStress | null }>) {
  return HR_SOURCES.flatMap((source) => {
    const sourced = meetings.filter((m) => m.hrStress?.source === source);
    return sourced.length ? [{ source, ...summarizeCompany(sourced) }] : [];
  });
}

/** One person-page meeting row, plus the companies on it. Shared by the person and company pages. */
export function personMeetingRow(
  row: JoinedMeeting, hr: MeetingHrStress | null, compact: boolean, ctx: CompanyContext,
) {
  const json = toMeetingJson(row, stressScore(row), compact && hr ? { ...hr, series: [] } : hr);
  const attendees = otherAttendees(parseAttendeesJson(row.event.attendees_json));
  return {
    ...toPersonMeetingJson(json, json.signals.nextSleepScore, json.signals.nextReadinessScore),
    companies: companiesForAttendees(attendees, ctx),
  };
}

export function companyRoutes(deps: CompanyRouteDeps) {
  const companies = new Hono<{ Bindings: Env }>();

  companies.get("/", async (c) => {
    const db = c.env.DB;
    const tz = await loadTimeZone(db).catch(() => DEFAULT_TIME_ZONE);
    const today = calendarDayInZone(new Date().toISOString(), tz);
    const range = parseHistoryRange({ start: c.req.query("start"), end: c.req.query("end") }, today, INSIGHTS_DEFAULT_DAYS);
    if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
    const sourceDisplay = await loadSourceDisplay(c.env);
    const overrides = openRangeOverrides(db, range.start, range.end, tz);
    const w = await deps.dashboardWearable(c.env, sourceDisplay);
    const [events, scores, selfDomains] = await Promise.all([
      loadCalendarEvents(db, range.start, range.end, tz, { overrides }),
      loadMorningScores(db, range.start, range.end, w.source),
      loadSelfDomains(db),
    ]);
    type Row = { domain: string; meetings: number; people: Set<string>; days: Set<string>; events: CalendarEventRow[] };
    const byDomain = new Map<string, Row>();
    for (const event of events) {
      const seen = new Set<string>();
      for (const attendee of otherAttendees(parseAttendeesJson(event.attendees_json))) {
        const domain = companyDomain(attendee.email, selfDomains);
        if (!domain) continue;
        const row = byDomain.get(domain) ?? { domain, meetings: 0, people: new Set(), days: new Set(), events: [] };
        row.people.add(attendee.email);
        if (!seen.has(domain)) {
          seen.add(domain);
          row.meetings++;
          row.days.add(event.day);
          row.events.push(event);
        }
        byDomain.set(domain, row);
      }
    }
    const top = [...byDomain.values()]
      .sort((a, b) => b.meetings - a.meetings || b.people.size - a.people.size || a.domain.localeCompare(b.domain))
      .slice(0, COMPANY_LIST_LIMIT);
    const names = await loadCompanyNames(db, top.map((r) => r.domain));
    // Heart rate in meetings only means something with intraday heart rate. `?hr=0` skips it.
    const withHr = w.hasIntradayHr && c.req.query("hr") !== "0";
    const hr = withHr
      ? await deps.meetingHrMap(c.env, w, [...new Map(top.flatMap((r) => r.events).map((e) => [e.id, e])).values()], tz, overrides)
      : null;
    return c.json({
      ok: true,
      ...range,
      wearable: w,
      sourceDisplay,
      companies: top.map((r) => ({
        domain: r.domain,
        name: companyName(r.domain, names),
        meetings: r.meetings,
        people: r.people.size,
        days: r.days.size,
        avg: nextMorningAverage(r.days, scores),
        // Newest first, as on the company page, so the spark lines match.
        trend: hr
          ? summarizeCompany([...r.events]
            .sort((a, b) => b.start_utc.localeCompare(a.start_utc) || a.id.localeCompare(b.id))
            .map((e) => ({ hrStress: hr.get(e.id) ?? null })))
          : null,
      })),
      usualRecovery: usualMorningScore(scores, range.end),
    });
  });

  companies.get("/search", async (c) => {
    const query = (c.req.query("q") ?? "").trim().slice(0, 120);
    const headers = { "Cache-Control": "private, no-store" };
    if (!query) return c.json({ ok: true, companies: [] }, { headers });
    const db = c.env.DB;
    const [selfDomains, names, rules] = await Promise.all([
      loadSelfDomains(db),
      loadCompanyNames(db),
      loadExclusionRules(db),
    ]);
    // A company only seen in meetings the owner left out is not offered. Same SQL as before when nothing is left out.
    const left = exclusionClause(rules, "e");
    const hosts = await db.prepare(
      `SELECT DISTINCT lower(substr(a.email, instr(a.email, '@') + 1)) AS host
       FROM calendar_attendee a JOIN calendar_event e ON e.id = a.event_id AND e.source = a.source
       WHERE a.self = 0 AND e.deleted_at IS NULL${left?.sql ?? ""}`,
    ).bind(...(left?.params ?? []))
      .all<{ host: string }>().then((r) => r.results ?? []);
    const domains = new Set(hosts.flatMap(({ host }) => companyDomain(`x@${host}`, selfDomains) ?? []));
    // Same ranking as people search: the domain stands in for the address.
    const ranked = rankPeople([...domains].map((domain) => ({ email: domain, name: companyName(domain, names) })), query);
    return c.json({ ok: true, companies: ranked.map((r) => ({ domain: r.email, name: r.name })) }, { headers });
  });

  companies.get("/:domain/meetings", async (c) => {
    const db = c.env.DB;
    const selfDomains = await loadSelfDomains(db);
    const domain = normalizeCompanyDomain(c.req.param("domain") ?? "", selfDomains);
    if (!domain) return c.json({ error: "That is not a company domain." }, 404);
    const tz = await loadTimeZone(db).catch(() => DEFAULT_TIME_ZONE);
    const today = calendarDayInZone(new Date().toISOString(), tz);
    const range = parseHistoryRange(
      { start: c.req.query("start"), end: c.req.query("end") }, today, parseInsightsDays(c.req.query("days")),
    );
    if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
    const { start: from, end: to } = range;
    const sourceDisplay = await loadSourceDisplay(c.env);
    const overrides = openRangeOverrides(db, from, to, tz);
    const w = await deps.dashboardWearable(c.env, sourceDisplay);
    const events = (await loadCalendarEventsByDomain(db, domain, from, to, tz, { overrides })).filter((event) =>
      otherAttendees(parseAttendeesJson(event.attendees_json)).some((a) => companyDomain(a.email, selfDomains) === domain),
    );
    const [joined, hrByMeetingId] = await Promise.all([
      joinEvents(db, events, w.source),
      deps.meetingHrMap(c.env, w, events, tz, overrides),
    ]);
    const ctx: CompanyContext = { selfDomains, names: await loadCompanyNames(db) };
    const compact = c.req.query("compact") === "1";
    const people = new Map<string, { email: string; name: string | null; meetings: number }>();
    const meetings = joined
      .map((row) => {
        const companyAttendees = otherAttendees(parseAttendeesJson(row.event.attendees_json))
          .filter((a) => companyDomain(a.email, selfDomains) === domain)
          .map(({ email, name }) => ({ email, name }));
        for (const a of companyAttendees) {
          const person = people.get(a.email) ?? { email: a.email, name: null, meetings: 0 };
          person.name ??= a.name;
          person.meetings++;
          people.set(a.email, person);
        }
        return { ...personMeetingRow(row, hrByMeetingId.get(row.event.id) ?? null, compact, ctx), companyAttendees };
      })
      .sort((a, b) => b.startUtc.localeCompare(a.startUtc));
    return c.json({
      ok: true,
      domain,
      name: companyName(domain, ctx.names),
      from,
      to,
      timeZone: tz,
      wearable: w,
      sourceDisplay,
      grain: grainNote(deps.labelsFor(w)),
      methodNote: deps.methodNoteFor(w),
      trend: summarizeCompany(meetings),
      trendsByHrSource: trendsBySource(meetings),
      people: [...people.values()].sort((a, b) =>
        b.meetings - a.meetings || (a.name ?? a.email).localeCompare(b.name ?? b.email)),
      meetings,
    });
  });

  // Rename a company. An empty or null name goes back to the name from the domain.
  companies.put("/:domain/name", bodyLimit({ maxSize: 1024 }), async (c) => {
    const db = c.env.DB;
    const selfDomains = await loadSelfDomains(db);
    const domain = normalizeCompanyDomain(c.req.param("domain") ?? "", selfDomains);
    if (!domain) return c.json({ error: "That is not a company domain." }, 404);
    const body = (await c.req.json().catch(() => null)) as { name?: unknown } | null;
    if (!body || typeof body !== "object" || !("name" in body)) return c.json({ error: "Send a name." }, 400);
    const cleared = body.name == null || (typeof body.name === "string" && !body.name.trim());
    const name = cleared ? null : normalizeCompanyName(body.name);
    if (!cleared && !name) return c.json({ error: "Use a name up to 80 characters, not an email." }, 400);
    if (!(await saveCompanyName(db, domain, name))) {
      return c.json({ error: "Company names need the database update first." }, 503);
    }
    return c.json({ ok: true, domain, name: companyName(domain, await loadCompanyNames(db, [domain])) });
  });

  return companies;
}

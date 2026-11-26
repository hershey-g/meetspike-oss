/**
 * Companies, tagged from attendee email domains.
 *
 * A company is the registrable domain of an attendee address ("mail.acme.co.uk"
 * becomes "acme.co.uk"). Never a company: the calendar owner's own domains,
 * free and personal mail (gmail.com, outlook.com, ...), and Google Calendar
 * resource or group addresses. The display name is an override from the
 * company_name table when one is saved, otherwise a readable name built from
 * the domain ("acme-corp.com" is "Acme Corp").
 */
import { normalizeEmail } from "./people.ts";

export type Company = { domain: string; name: string };

/** Personal and free mail providers. Matched on the registrable domain. */
const FREE_MAIL = new Set([
  "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "passport.com",
  "icloud.com", "me.com", "mac.com", "aol.com", "aim.com", "proton.me", "protonmail.com", "protonmail.ch",
  "pm.me", "tutanota.com", "tuta.io", "fastmail.com", "fastmail.fm", "hey.com", "zoho.com", "zohomail.com",
  "mail.com", "email.com", "inbox.com", "yandex.com", "yandex.ru", "ya.ru", "mail.ru", "qq.com", "163.com",
  "126.com", "sina.com", "rediffmail.com", "comcast.net", "verizon.net", "att.net", "sbcglobal.net",
  "bellsouth.net", "cox.net", "charter.net", "optonline.net", "earthlink.net", "juno.com", "rocketmail.com",
  "ymail.com", "web.de", "t-online.de", "orange.fr", "free.fr", "laposte.net", "libero.it", "btinternet.com",
  "sky.com", "virginmedia.com", "walla.co.il", "bezeqint.net", "naver.com", "hanmail.net", "duck.com",
  // Not mailboxes at a company: Google Groups lists and Sign in with Apple relays (privaterelay.appleid.com).
  "googlegroups.com", "appleid.com",
]);

/** Providers that run the same free service under many country endings (yahoo.co.uk, gmx.de, hotmail.fr). */
const FREE_MAIL_LABELS = new Set(["yahoo", "gmx", "hotmail", "outlook", "live", "aol", "yandex", "protonmail"]);

/** Google Calendar rooms, groups and imported calendars, never people at a company. */
const CALENDAR_SYSTEM_SUFFIXES = ["calendar.google.com", "calendar.goog"];

/**
 * Two-part public suffixes common enough to matter. Not the full Public Suffix
 * List on purpose: a short list covers the meetings this app sees.
 */
const MULTI_PART_SUFFIXES = new Set([
  "co.uk", "org.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "me.uk", "net.uk", "nhs.uk", "sch.uk",
  "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
  "co.il", "org.il", "ac.il", "gov.il", "net.il", "muni.il",
  "co.nz", "org.nz", "net.nz", "ac.nz", "govt.nz",
  "co.za", "org.za", "gov.za", "ac.za",
  "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
  "co.kr", "or.kr", "ac.kr",
  "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in", "ac.in", "gov.in",
  "com.br", "net.br", "org.br", "gov.br",
  "com.mx", "org.mx", "gob.mx",
  "com.ar", "com.co", "com.pe", "com.ve", "com.ec", "com.uy", "com.py", "com.bo",
  "com.cn", "net.cn", "org.cn", "com.hk", "org.hk", "com.tw", "org.tw", "com.sg", "edu.sg", "gov.sg",
  "com.my", "com.ph", "co.th", "co.id", "com.vn", "com.pk", "com.bd", "com.np", "com.lk",
  "com.tr", "org.tr", "com.sa", "com.eg", "com.ng", "co.ke", "co.ug", "co.tz", "com.gh",
  "com.ua", "com.pl", "co.at", "or.at", "com.cy", "com.mt", "com.gr", "co.hu",
]);

/** Lowercase host with no trailing dot, or null when it is not a usable host name. */
function cleanHost(raw: string): string | null {
  const host = raw.trim().toLowerCase().replace(/\.+$/, "");
  if (!host || !/^[a-z0-9.-]+$/.test(host) || !host.includes(".") || host.includes("..")) return null;
  if (host.startsWith(".") || host.startsWith("-")) return null;
  return host;
}

/** "mail.acme.co.uk" -> "acme.co.uk", "eu.acme.com" -> "acme.com". Null for a bare suffix or junk. */
export function registrableDomain(rawHost: string): string | null {
  const host = cleanHost(rawHost);
  if (!host) return null;
  const labels = host.split(".");
  const lastTwo = labels.slice(-2).join(".");
  const take = MULTI_PART_SUFFIXES.has(lastTwo) ? 3 : 2;
  if (labels.length < take) return null;
  return labels.slice(-take).join(".");
}

/** The domain part of an email address, or null. */
export function emailHost(email: string): string | null {
  const norm = normalizeEmail(email);
  if (!norm) return null;
  return cleanHost(norm.slice(norm.lastIndexOf("@") + 1));
}

export function isCalendarSystemHost(host: string): boolean {
  return CALENDAR_SYSTEM_SUFFIXES.some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
}

export function isFreeMailDomain(domain: string): boolean {
  if (FREE_MAIL.has(domain)) return true;
  return FREE_MAIL_LABELS.has(domain.split(".")[0]);
}

/** The calendar owner's own company domains, from their own addresses. Free mail is never one. */
export function selfDomainsFrom(emails: Iterable<string>): Set<string> {
  const out = new Set<string>();
  for (const email of emails) {
    const host = emailHost(email);
    const domain = host ? registrableDomain(host) : null;
    if (domain && !isFreeMailDomain(domain)) out.add(domain);
  }
  return out;
}

/**
 * The company domain for one address, or null when it is not a company:
 * junk, a calendar room or group, free mail, or one of the owner's domains.
 */
export function companyDomain(email: string, selfDomains: ReadonlySet<string> = new Set()): string | null {
  const host = emailHost(email);
  if (!host || isCalendarSystemHost(host)) return null;
  const domain = registrableDomain(host);
  if (!domain || isFreeMailDomain(domain) || selfDomains.has(domain)) return null;
  return domain;
}

/** A company domain from a URL path. Only a registrable company domain is accepted. */
export function normalizeCompanyDomain(raw: string, selfDomains: ReadonlySet<string> = new Set()): string | null {
  let value: string;
  try {
    value = decodeURIComponent(raw);
  } catch {
    return null;
  }
  const host = cleanHost(value);
  if (!host) return null;
  return companyDomain(`x@${host}`, selfDomains) === host ? host : null;
}

const SHORT_WORD = /^[a-z]{1,3}$/;

/** "acme-corp.com" -> "Acme Corp", "ibm.com" -> "IBM", "foo_bar.co.uk" -> "Foo Bar". */
export function companyNameFromDomain(domain: string): string {
  const label = domain.split(".")[0] ?? domain;
  const words = label.split(/[-_]+/).filter(Boolean);
  if (!words.length) return domain;
  if (words.length === 1 && SHORT_WORD.test(words[0])) return words[0].toUpperCase();
  return words.map((w) => w.charAt(0).toUpperCase() + w.slice(1)).join(" ");
}

/** A saved name, trimmed. Null when empty, too long, or an address. */
export function normalizeCompanyName(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const name = raw.trim().replace(/\s+/g, " ");
  if (!name || name.length > 80 || name.includes("@")) return null;
  return name;
}

export type CompanyContext = {
  selfDomains: ReadonlySet<string>;
  names: ReadonlyMap<string, string>;
};

export function companyName(domain: string, names: ReadonlyMap<string, string>): string {
  return names.get(domain) ?? companyNameFromDomain(domain);
}

/** The companies on one meeting, in attendee order, each once. Self attendees never count. */
export function companiesForAttendees(
  attendees: Array<{ email: string; self?: boolean }>, ctx: CompanyContext,
): Company[] {
  const seen = new Set<string>();
  const out: Company[] = [];
  for (const a of attendees) {
    if (a.self) continue;
    const domain = companyDomain(a.email, ctx.selfDomains);
    if (!domain || seen.has(domain)) continue;
    seen.add(domain);
    out.push({ domain, name: companyName(domain, ctx.names) });
  }
  return out;
}

// MARK: D1

/** D1 allows 100 bound parameters per statement. */
const CHUNK = 90;

/**
 * The owner's domains: every address marked `self` on a stored meeting, plus
 * every connected Google account (migration 0018), so a second account's
 * company counts as the owner's even before a meeting from it is stored.
 * Read on every call: the tables are small and a stale answer would tag the
 * owner's own company.
 */
export async function loadSelfDomains(db: D1Database): Promise<Set<string>> {
  const { results } = await db
    .prepare(`SELECT DISTINCT email FROM calendar_attendee WHERE self = 1`)
    .all<{ email: string }>();
  const emails = (results ?? []).map((r) => r.email);
  try {
    const accounts = await db.prepare(`SELECT email FROM google_account`).all<{ email: string }>();
    for (const row of accounts.results ?? []) emails.push(row.email);
  } catch (error) {
    if (!String(error).includes("no such table: google_account")) throw error;
  }
  return selfDomainsFrom(emails);
}

function missingNameTable(error: unknown): boolean {
  return String(error).includes("no such table: company_name");
}

/** Saved display names for these domains (or all of them). A missing company_name table is "none". */
export async function loadCompanyNames(db: D1Database, domains?: Iterable<string>): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const keep = (rows: Array<{ domain: string; name: string }> | undefined) => {
    for (const row of rows ?? []) {
      const name = normalizeCompanyName(row.name);
      if (name) out.set(row.domain, name);
    }
  };
  try {
    if (!domains) {
      keep((await db.prepare(`SELECT domain, name FROM company_name`).all<{ domain: string; name: string }>()).results);
      return out;
    }
    const list = [...new Set(domains)];
    for (let i = 0; i < list.length; i += CHUNK) {
      const part = list.slice(i, i + CHUNK);
      keep((await db
        .prepare(`SELECT domain, name FROM company_name WHERE domain IN (${part.map(() => "?").join(", ")})`)
        .bind(...part)
        .all<{ domain: string; name: string }>()).results);
    }
  } catch (error) {
    if (!missingNameTable(error)) throw error;
  }
  return out;
}

/** Self domains plus saved names for the given domains (or every saved name). */
export async function loadCompanyContext(db: D1Database, domains?: Iterable<string>): Promise<CompanyContext> {
  const [selfDomains, names] = await Promise.all([loadSelfDomains(db), loadCompanyNames(db, domains)]);
  return { selfDomains, names };
}

/** Save, or clear with `name` null, a display name. Returns false when the table is missing. */
export async function saveCompanyName(
  db: D1Database, domain: string, name: string | null, at: string = new Date().toISOString(),
): Promise<boolean> {
  try {
    if (name == null) {
      await db.prepare(`DELETE FROM company_name WHERE domain = ?`).bind(domain).run();
    } else {
      await db.prepare(
        `INSERT INTO company_name (domain, name, updated_at) VALUES (?, ?, ?)
         ON CONFLICT (domain) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at`,
      ).bind(domain, name, at).run();
    }
    return true;
  } catch (error) {
    if (missingNameTable(error)) return false;
    throw error;
  }
}

// MARK: Payload tagging

type WithAttendees = { attendees: unknown[]; companies?: unknown };

function hasAttendees(value: unknown): value is WithAttendees {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value) &&
    Array.isArray((value as Record<string, unknown>).attendees);
}

function attendeeList(node: WithAttendees): Array<{ email: string; self: boolean }> {
  return node.attendees.flatMap((a) => {
    if (!a || typeof a !== "object") return [];
    const rec = a as Record<string, unknown>;
    return typeof rec.email === "string" ? [{ email: rec.email, self: rec.self === true }] : [];
  });
}

function walkMeetings(payload: unknown, visit: (node: WithAttendees) => void) {
  if (Array.isArray(payload)) {
    for (const v of payload) walkMeetings(v, visit);
    return;
  }
  if (!payload || typeof payload !== "object") return;
  if (hasAttendees(payload)) visit(payload);
  for (const v of Object.values(payload)) walkMeetings(v, visit);
}

/** Every company domain on objects in a payload that carry `attendees`. */
export function collectCompanyDomains(payload: unknown, selfDomains: ReadonlySet<string>): Set<string> {
  const out = new Set<string>();
  walkMeetings(payload, (node) => {
    for (const a of attendeeList(node)) {
      if (a.self) continue;
      const domain = companyDomain(a.email, selfDomains);
      if (domain) out.add(domain);
    }
  });
  return out;
}

/**
 * Add `companies: [{domain, name}]` next to every `attendees` array that does
 * not already have one. Returns how many objects were tagged.
 */
export function tagCompanies(payload: unknown, ctx: CompanyContext): number {
  let tagged = 0;
  walkMeetings(payload, (node) => {
    if (Array.isArray(node.companies)) return;
    node.companies = companiesForAttendees(attendeeList(node), ctx);
    tagged += 1;
  });
  return tagged;
}

/** Load what tagging needs and tag the payload in place. */
export async function resolvePayloadCompanies(db: D1Database, payload: unknown): Promise<number> {
  let found = false;
  walkMeetings(payload, () => {
    found = true;
  });
  if (!found) return 0;
  const selfDomains = await loadSelfDomains(db);
  const names = await loadCompanyNames(db, collectCompanyDomains(payload, selfDomains));
  return tagCompanies(payload, { selfDomains, names });
}

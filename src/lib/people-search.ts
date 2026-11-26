export type PersonSearchResult = { email: string; name: string | null };

const RESULT_LIMIT = 8;
const CANDIDATE_LIMIT = 96;

function fold(value: string): string {
  return value.normalize("NFKD").replace(/\p{M}+/gu, "").toLowerCase();
}

function words(value: string): string[] {
  return fold(value).match(/[\p{L}\p{N}]+/gu) ?? [];
}

/** Rank a single typo in a word prefix, favoring adjacent swaps. */
function spellingCost(query: string, word: string): number {
  if (query.length < 3) return Infinity;
  let i = 0;
  while (i < query.length && query[i] === word[i]) i++;
  if (i === query.length) return 0;
  if (i + 1 < query.length && word[i] === query[i + 1] && word[i + 1] === query[i] &&
    word.startsWith(query.slice(i + 2), i + 2)) return 10;
  const rest = query.slice(i + 1);
  if (i < word.length && word.startsWith(rest, i + 1)) return 11;
  if (word.startsWith(rest, i) || (i < word.length && word.startsWith(query.slice(i), i + 1))) return 12;
  return Infinity;
}

function scorePerson(person: PersonSearchResult, query: string, terms: string[]): number {
  const name = fold(person.name ?? "");
  const email = fold(person.email);
  if (name === query) return 0;
  if (email === query) return 1;
  if (name.startsWith(query)) return 2;
  if (email.startsWith(query)) return 3;
  const nameWords = words(name);
  const emailWords = words(email);
  let score = 4;
  for (const term of terms) {
    if (nameWords.some((word) => word.startsWith(term))) continue;
    if (emailWords.some((word) => word.startsWith(term))) score += 1;
    else {
      const cost = Math.min(...nameWords.map((word) => spellingCost(term, word)),
        ...emailWords.map((word) => 1 + spellingCost(term, word)));
      if (!Number.isFinite(cost)) return Infinity;
      score += cost;
    }
  }
  return score;
}

export function rankPeople(people: PersonSearchResult[], query: string): PersonSearchResult[] {
  const normalized = fold(query.trim());
  const terms = words(normalized).slice(0, 8);
  if (!terms.length) return [];
  return people
    .map((person) => ({ person, score: scorePerson(person, normalized, terms) }))
    .filter(({ score }) => Number.isFinite(score))
    .sort((a, b) => a.score - b.score ||
      (a.person.name ?? a.person.email).localeCompare(b.person.name ?? b.person.email) ||
      a.person.email.localeCompare(b.person.email))
    .slice(0, RESULT_LIMIT)
    .map(({ person }) => person);
}

/**
 * `keep` narrows the candidates before they are ranked, so a person it drops
 * never takes a place in the top results.
 */
export async function searchPeople(
  db: D1Database, query: string, keep?: (people: PersonSearchResult[]) => Promise<PersonSearchResult[]>,
): Promise<PersonSearchResult[]> {
  const terms = words(query).slice(0, 8);
  if (!terms.length) return [];

  const prefix = (word: string) => `"${word}"*`;
  const exact = terms.map(prefix).join(" AND ");
  const fallback = terms.flatMap((term, index) => {
    if (term.length < 3) return [];
    const others = terms.filter((_, i) => i !== index).map(prefix);
    const shorter = prefix(term.slice(0, Math.max(1, term.length - 3)));
    return [`(${[...others, shorter].join(" AND ")})`, ...(others.length ? [`(${others.join(" AND ")})`] : [])];
  }).join(" OR ");

  const trigrams = new Set<string>();
  for (const term of terms) {
    const chars = [...term];
    for (let i = 0; i + 3 <= chars.length; i++) trigrams.add(chars.slice(i, i + 3).join(""));
  }
  const fragments = [...trigrams].slice(0, 24).map((trigram) => `"${trigram}"`).join(" OR ");

  // FTS limits the work to directory entries. One D1 request returns bounded
  // candidates, with fuzzy lookups skipped when prefix matches fill the menu.
  const result = await db.prepare(
    `WITH exact AS MATERIALIZED (
       SELECT rowid FROM people_search WHERE people_search MATCH ?1 ORDER BY rank LIMIT ?4
     ), short_prefix AS (
       SELECT rowid FROM people_search
       WHERE ?2 <> '' AND (SELECT count(*) FROM exact) < ?5 AND people_search MATCH ?2
       ORDER BY rank LIMIT ?4
     ), shared_fragments AS (
       SELECT rowid FROM people_search_trigrams
       WHERE ?3 <> '' AND (SELECT count(*) FROM exact) < ?5 AND people_search_trigrams MATCH ?3
       ORDER BY rank LIMIT ?4
     ), candidates AS (
       SELECT rowid FROM exact UNION SELECT rowid FROM short_prefix UNION SELECT rowid FROM shared_fragments
     )
     SELECT people_directory.email, people_directory.name
     FROM candidates JOIN people_directory ON people_directory.id = candidates.rowid`,
  ).bind(exact, fallback, fragments, CANDIDATE_LIMIT, RESULT_LIMIT).all<PersonSearchResult>();
  const candidates = result.results ?? [];
  return rankPeople(keep && candidates.length ? await keep(candidates) : candidates, query);
}

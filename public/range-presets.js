/** Date-range presets for the dashboard. Pure, so the tests can import it. */

export function addDays(day, n) {
  const d = new Date(`${day}T12:00:00.000Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/**
 * Inclusive { start, end } for a preset, given today's local date (YYYY-MM-DD).
 * "month" is month to date: it starts on the 1st and ends today, never on the
 * last day of the month, so days that have not happened yet are not included.
 */
export function presetRange(preset, today) {
  if (preset === "7d") return { start: addDays(today, -6), end: today };
  if (preset === "month") return { start: `${today.slice(0, 7)}-01`, end: today };
  return { start: today, end: today };
}

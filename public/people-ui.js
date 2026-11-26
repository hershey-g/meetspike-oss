import { addDays } from "./range-presets.js";
import { esc } from "./ask-logic.js";

export const PEOPLE_PRESETS = {
  "7d": ["Past 7 days", "Last 7 days", 7],
  "28d": ["Past 28 days", "Last 28 days", 28],
  "90d": ["Past 90 days", "Last 90 days", 90],
  year: ["Past year", "Last year", 365],
};

export function validPeopleDates(start, end) {
  const valid = (day) => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day ?? "") || day < "0100-01-01" || day > "9999-12-30") return false;
    const parsed = new Date(`${day}T00:00:00Z`);
    return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === day;
  };
  return valid(start) && valid(end) && start <= end;
}

export function readPeopleRange(params) {
  const preset = params.get("peopleRange");
  if (preset && Object.hasOwn(PEOPLE_PRESETS, preset)) return { preset };
  const start = params.get("peopleStart");
  const end = params.get("peopleEnd");
  if (preset === "custom" && validPeopleDates(start, end)) return { preset, start, end };
  return { preset: "28d" };
}

export function writePeopleRange(params, range) {
  if (range.preset === "28d") return;
  params.set("peopleRange", range.preset);
  if (range.preset === "custom") {
    params.set("peopleStart", range.start);
    params.set("peopleEnd", range.end);
  }
}

export function peopleRangeDates(range, today) {
  if (range.preset === "custom") return { start: range.start, end: range.end };
  return { start: addDays(today, 1 - PEOPLE_PRESETS[range.preset][2]), end: today };
}

export function peopleRangeHtml(range, start, end) {
  const options = Object.entries(PEOPLE_PRESETS).map(([key, [label]]) =>
    `<option value="${key}"${key === range.preset ? " selected" : ""}>${label}</option>`).join("");
  const custom = range.preset === "custom";
  return `<div class="people-range">
    <label for="people-range">Date range</label>
    <select id="people-range">${options}<option value="custom"${custom ? " selected" : ""}>Custom</option></select>
    <form id="people-custom-range"${custom ? "" : " hidden"}>
      <label>Start date <input type="date" name="start" value="${esc(start)}" required></label>
      <label>End date <input type="date" name="end" value="${esc(end)}" required></label>
      <button type="submit">Apply</button>
    </form>
  </div>`;
}

export const peopleSearchHtml = `<div class="people-search">
  <label for="people-search">Search people</label>
  <input id="people-search" type="search" role="combobox" placeholder="Name or email"
    autocomplete="off" autocapitalize="none" spellcheck="false" aria-autocomplete="list"
    aria-controls="people-suggestions" aria-expanded="false" enterkeyhint="search">
  <div id="people-suggestions" role="listbox" aria-label="Matching people" hidden></div>
  <p class="people-search-status" role="status"></p>
</div>`;

export function initPeopleSearch(root, find, personHref) {
  const input = root.querySelector("input");
  const list = root.querySelector("[role=listbox]");
  const status = root.querySelector("[role=status]");
  let active = -1;
  let request;
  let timer;

  function close() {
    clearTimeout(timer);
    request?.abort();
    input.setAttribute("aria-expanded", "false");
    input.removeAttribute("aria-activedescendant");
    list.hidden = true;
    list.replaceChildren();
    status.textContent = "";
    active = -1;
  }

  function select(index) {
    active = index;
    for (const [i, option] of [...list.children].entries()) option.setAttribute("aria-selected", String(i === active));
    const current = list.children[active];
    input.setAttribute("aria-activedescendant", current.id);
    current.scrollIntoView?.({ block: "nearest" });
  }

  function lookup() {
    close();
    const query = input.value.trim();
    if (!query) return;
    const pending = new AbortController();
    request = pending;
    timer = setTimeout(async () => {
      try {
        const people = await find(query, pending.signal);
        if (pending.signal.aborted || !root.isConnected) return;
        status.textContent = people.length ? `${people.length} matching ${people.length === 1 ? "person" : "people"}.` : "No matching people.";
        list.innerHTML = people.map((p, i) =>
          `<a id="person-option-${i}" role="option" aria-selected="false" tabindex="-1" href="${esc(personHref(p.email))}">
            <b>${esc(p.name || p.email)}</b>${p.name ? `<small>${esc(p.email)}</small>` : ""}
          </a>`).join("");
        list.hidden = !people.length;
        input.setAttribute("aria-expanded", String(people.length > 0));
      } catch (error) {
        if (!pending.signal.aborted && root.isConnected) status.textContent = error.message;
      }
    }, 20);
  }

  input.addEventListener("input", (event) => { if (!event.isComposing) lookup(); });
  input.addEventListener("compositionend", lookup);
  input.addEventListener("focus", lookup);
  input.addEventListener("keydown", (event) => {
    if (event.isComposing) return;
    const length = list.children.length;
    if (event.key === "Escape") {
      if (length) event.preventDefault();
      close();
    } else if (length && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
      event.preventDefault();
      select(active === -1 ? (event.key === "ArrowDown" ? 0 : length - 1) :
        (active + (event.key === "ArrowDown" ? 1 : -1) + length) % length);
    } else if (length && event.key === "Enter") {
      event.preventDefault();
      list.children[Math.max(0, active)].click();
    }
  });
  root.addEventListener("focusout", (event) => {
    if (!root.contains(event.relatedTarget)) close();
  });
  // Keep focus on the combobox for mouse clicks and allow touch users to scroll the list.
  list.addEventListener("mousedown", (event) => event.preventDefault());
}

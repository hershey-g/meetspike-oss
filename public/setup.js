/** First-run setup page. Reads /api/setup/status; never sees or sends a secret. */

import { qrSvg } from "/qrcode.js";

const selectedProvider = new URLSearchParams(location.search).get("wearable");
const state = { status: null, picked: ["whoop", "oura"].includes(selectedProvider) ? selectedProvider : null };

function qs(sel) {
  return document.querySelector(sel);
}

function esc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

async function getJson(path, opts) {
  const res = await fetch(path, { credentials: "same-origin", headers: { Accept: "application/json" }, ...opts });
  const type = res.headers.get("content-type") || "";
  if (!type.includes("application/json")) throw new Error("Sign in first, then reload this page.");
  const body = await res.json();
  if (!res.ok) throw new Error(body?.error || `Something went wrong (${res.status}).`);
  return body;
}

function showError(message) {
  const el = qs("#setup-error");
  el.textContent = message || "";
  el.hidden = !message;
}

function markDone(id, done) {
  qs(id).classList.toggle("done", Boolean(done));
}

function keyList(el, secrets) {
  el.innerHTML = Object.entries(secrets)
    .map(
      ([name, present]) =>
        `<li><code id="key-${esc(name)}">${esc(name)}</code>
          <button type="button" class="btn ghost" data-copy="key-${esc(name)}">Copy name</button>
          <span class="${present ? "tick" : "todo"}">${present ? "✓ saved" : "not added yet"}</span></li>`,
    )
    .join("");
}

function commands(secrets) {
  return Object.keys(secrets)
    .map((name) => `npx wrangler secret put ${name}`)
    .join("\n");
}

function allPresent(secrets) {
  return Object.values(secrets).every(Boolean);
}

function render() {
  const s = state.status;
  if (!s) return;
  const active = s.wearable.source;
  const picked = state.picked ?? active;
  const provider = s[picked];
  const label = picked === "whoop" ? "WHOOP" : "Oura";

  for (const input of document.querySelectorAll('input[name="wearable"]')) input.checked = input.value === picked;
  for (const el of document.querySelectorAll('[data-w="label"]')) el.textContent = label;

  const connected = ["whoop", "oura"].filter((source) => s[source].connected)
    .map((source) => source === "whoop" ? "WHOOP" : "Oura");
  qs("#wearable-current").textContent = connected.length ? `Connected: ${connected.join(" and ")}.` : "Choose a wearable to start.";
  qs("#wearable-why").textContent = `${s.wearable.label} is preferred for dashboard comparisons. You can connect either wearable here.`;
  markDone("#step-wearable", connected.length > 0);

  qs("#app-url").href = provider.appUrl;
  qs("#app-url").textContent = provider.appUrl.replace(/^https:\/\//, "");
  qs("#app-redirect").textContent = provider.redirectUri;
  qs("#app-scopes").textContent = provider.scopes.join(" ");
  markDone("#step-app", allPresent(provider.secrets));

  keyList(qs("#wearable-keys"), provider.secrets);
  qs("#wearable-commands").textContent = commands(provider.secrets);
  markDone("#step-keys", allPresent(provider.secrets));

  const connect = qs("#connect-wearable");
  const canConnect = allPresent(provider.secrets);
  connect.href = provider.startPath;
  connect.textContent = provider.connected ? `Reconnect ${label}` : `Connect ${label}`;
  connect.setAttribute("aria-disabled", canConnect ? "false" : "true");
  qs("#connect-state").textContent = provider.connected
    ? `${label} is connected.`
    : canConnect
      ? `Press the button and approve access on the ${label} page. You will be sent back here.`
      : "Add the two keys in step 3 first, then press Check again.";
  markDone("#step-connect", provider.connected);

  qs("#google-redirect").textContent = s.google.redirectUri;
  keyList(qs("#google-keys"), s.google.secrets);
  qs("#google-commands").textContent = commands(s.google.secrets);
  const googleReady = allPresent(s.google.secrets);
  qs("#connect-google").setAttribute("aria-disabled", googleReady ? "false" : "true");
  qs("#connect-google").textContent = s.google.connected ? "Connect another Google account" : "Connect Google Calendar";
  qs("#google-state").textContent = s.google.connected
    ? "Google Calendar is connected. To add a second account, press the button and pick it on the Google page."
    : googleReady
      ? "Press the button and choose the Google account whose calendar you want to use."
      : "Add the two Google keys first, then press Check again.";
  markDone("#step-google", s.google.connected);

  qs("#lock-origin").textContent = s.origin;
  qs("#lock-bypass").textContent = [s.whoop.redirectUri, s.oura.redirectUri, s.google.redirectUri, `${s.origin}/hooks/*`]
    .filter((v, i, all) => all.indexOf(v) === i)
    .join("   ");
  qs("#lock-public").textContent = ["/manifest.webmanifest", "/icons/*", "/favicon.ico"].map((p) => `${s.origin}${p}`).join("   ");
}

async function load() {
  showError("");
  try {
    state.status = await getJson("/api/setup/status");
    render();
    if (state.status.google.connected) await loadCalendars();
    else qs("#calendars").hidden = true;
  } catch (err) {
    showError(err.message || String(err));
  }
}

/* ---------- Google accounts and calendars (/api/calendars) ---------- */

function safeColor(value) {
  return /^#[0-9a-f]{3,8}$/i.test(value || "") ? value : "transparent";
}

function syncedText(iso) {
  if (!iso) return "Not synced yet";
  const when = new Date(iso);
  return Number.isNaN(when.getTime()) ? "Not synced yet" : `Synced ${when.toLocaleString()}`;
}

function renderCalendars(data) {
  const accounts = data?.accounts ?? [];
  qs("#calendars").hidden = accounts.length === 0;
  qs("#calendar-accounts").innerHTML = accounts
    .map(
      (a) => `<fieldset class="cal-account">
        <legend>${esc(a.email)}</legend>
        ${a.error ? `<p class="todo">${esc(a.error)}</p>` : ""}
        <ul class="cal-list">${a.calendars
          .map(
            (c) => `<li><label>
              <input type="checkbox" data-cal data-account="${esc(a.email)}" data-calendar="${esc(c.id)}"${c.selected ? " checked" : ""} />
              <span class="swatch" style="background:${safeColor(c.color)}"></span>
              <span>${esc(c.name)}${c.primary ? ' <span class="muted">main</span>' : ""}</span>
            </label>${c.error ? ` <span class="todo">${esc(c.error)}</span>` : ""}</li>`,
          )
          .join("")}</ul>
        <p class="cal-foot"><span class="stat">${esc(syncedText(a.lastSyncAt))}</span>
          <button type="button" class="btn ghost" data-action="disconnect" data-account="${esc(a.email)}">Disconnect</button></p>
      </fieldset>`,
    )
    .join("");
  if (data?.legacyError) qs("#calendars-state").textContent = `Could not read the connected account yet: ${data.legacyError}`;
}

let calendarsScrolled = false;

async function loadCalendars() {
  try {
    renderCalendars(await getJson("/api/calendars"));
  } catch (err) {
    qs("#calendars").hidden = false;
    qs("#calendars-state").textContent = err.message || String(err);
  }
  // /setup#calendars (after Google sign-in, or from the iPhone): the section is
  // hidden while the page loads, so the browser could not jump to it. Do it now.
  if (!calendarsScrolled && location.hash === "#calendars" && !qs("#calendars").hidden) {
    calendarsScrolled = true;
    qs("#calendars").scrollIntoView({ block: "start" });
  }
}

async function chooseCalendar(input) {
  const out = qs("#calendars-state");
  const selected = input.checked;
  input.disabled = true;
  out.textContent = selected ? "Adding calendar…" : "Removing calendar…";
  try {
    const data = await getJson("/api/calendars/selection", {
      method: "PUT",
      headers: { Accept: "application/json", "content-type": "application/json" },
      body: JSON.stringify({ selections: [{ account: input.dataset.account, calendarId: input.dataset.calendar, selected }] }),
    });
    renderCalendars(data);
    out.textContent = data.syncError ? `Saved. Sync failed: ${data.syncError}` : selected ? "Calendar added." : "Calendar removed.";
  } catch (err) {
    input.checked = !selected;
    input.disabled = false;
    out.textContent = err.message || String(err);
  }
}

async function disconnect(email) {
  if (!confirm(`Disconnect ${email}? Its meetings leave Meetspike unless another calendar has them.`)) return;
  const out = qs("#calendars-state");
  out.textContent = "Disconnecting…";
  try {
    renderCalendars(await getJson(`/api/calendars/accounts/${encodeURIComponent(email)}`, { method: "DELETE" }));
    out.textContent = `${email} disconnected.`;
    state.status = await getJson("/api/setup/status");
    render();
  } catch (err) {
    out.textContent = err.message || String(err);
  }
}

document.addEventListener("change", (ev) => {
  const input = ev.target instanceof HTMLInputElement && ev.target.hasAttribute("data-cal") ? ev.target : null;
  if (input) chooseCalendar(input);
});

async function post(path, body) {
  return getJson(path, {
    method: "POST",
    headers: { Accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function importData(sample) {
  const out = qs("#data-state");
  out.textContent = "Working…";
  try {
    const source = state.picked ?? state.status.wearable.source;
    const wearable = await post("/api/backfill", { source, ...(sample ? { mode: "fixtures" } : {}) });
    const calendar = await post("/api/calendar/sync", sample ? { mode: "fixtures" } : { mode: "live" });
    out.textContent = sample
      ? `Sample data loaded (${wearable.written ?? 0} wearable records, ${calendar.written ?? 0} calendar events). Open Meetspike to look around.`
      : wearable.workflowId
        ? `Import started. Wearable data arrives over the next few minutes; ${calendar.written ?? 0} calendar events are in.`
        : `Done: ${wearable.written ?? 0} wearable records, ${calendar.written ?? 0} calendar events.`;
    markDone("#step-data", true);
  } catch (err) {
    out.textContent = err.message || String(err);
  }
}

/**
 * Step 8: a ten-minute, single-use code for the iPhone. The QR holds only the
 * Worker's address and the code; the phone trades it for its keys itself.
 */
let pairTimer = null;

function pairCountdown(expiresAt) {
  const left = Math.max(0, Math.round((Date.parse(expiresAt) - Date.now()) / 1000));
  const expiry = qs("#pair-expiry");
  if (left === 0) {
    clearInterval(pairTimer);
    pairTimer = null;
    qs("#pair-qr").classList.add("expired");
    expiry.textContent = "This code has expired. Press Show setup code for a new one.";
    return;
  }
  const m = Math.floor(left / 60);
  const s = String(left % 60).padStart(2, "0");
  expiry.textContent = `Expires in ${m}:${s}. Works once.`;
}

async function showPairing() {
  const error = qs("#pair-error");
  error.hidden = true;
  try {
    const pair = await post("/api/pair/start", {});
    qs("#pair-qr").innerHTML = qrSvg(pair.url, "Setup code for the Meetspike iPhone app");
    qs("#pair-qr").classList.remove("expired");
    qs("#pair-open").href = pair.url;
    qs("#pair-access").textContent = pair.includesAccessToken
      ? "Your Access service token is included, so the phone needs nothing else."
      : "No Access service token is saved for the phone. After scanning, add its client ID and secret in Phone settings. Or save them on the Worker as PHONE_ACCESS_CLIENT_ID and PHONE_ACCESS_CLIENT_SECRET and make a new code.";
    qs("#pair-box").hidden = false;
    clearInterval(pairTimer);
    pairCountdown(pair.expiresAt);
    pairTimer = setInterval(() => pairCountdown(pair.expiresAt), 1000);
    markDone("#step-phone", true);
  } catch (err) {
    error.textContent = err.message || String(err);
    error.hidden = false;
  }
}

document.addEventListener("click", async (ev) => {
  const target = ev.target instanceof Element ? ev.target.closest("[data-copy], [data-action]") : null;
  if (!target) return;
  const copy = target.getAttribute("data-copy");
  if (copy) {
    const text = document.getElementById(copy)?.textContent ?? "";
    try {
      await navigator.clipboard.writeText(text);
      const before = target.textContent;
      target.textContent = "Copied";
      setTimeout(() => (target.textContent = before), 1200);
    } catch {
      /* clipboard blocked — the text is on screen to select by hand */
    }
    return;
  }
  const action = target.getAttribute("data-action");
  if (action === "recheck") load();
  if (action === "disconnect") disconnect(target.getAttribute("data-account") || "");
  if (action === "import") importData(false);
  if (action === "sample") importData(true);
  if (action === "pair") showPairing();
});

for (const input of document.querySelectorAll('input[name="wearable"]')) {
  input.addEventListener("change", () => {
    state.picked = input.value;
    render();
  });
}

load();

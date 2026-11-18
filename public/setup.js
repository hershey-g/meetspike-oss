/** First-run setup page. Reads /api/setup/status; never sees or sends a secret. */

const state = { status: null, picked: null };

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

  const how =
    s.wearable.chosenBy === "configured"
      ? "because the WEARABLE setting says so"
      : s.wearable.chosenBy === "legacy_oura"
        ? "because it already has Oura keys and no WEARABLE setting"
        : "the default for a new install";
  qs("#wearable-current").textContent = `This install is using ${s.wearable.label} — ${how}.`;
  qs("#wearable-switch").hidden = picked === active;
  qs("#wearable-active").textContent = s.wearable.label;
  qs("#wearable-wanted").textContent = label;
  qs("#wearable-value").textContent = picked;
  qs("#wearable-value-2").textContent = picked;
  qs("#wearable-why").textContent = s.wearable.unrecognised
    ? `WEARABLE is set to “${s.wearable.unrecognised}”, which is not “whoop” or “oura”, so it is being ignored.`
    : picked === "whoop"
      ? "WHOOP shares daily recovery, strain, sleep and workouts — not heart rate minute by minute. Meetspike shows recovery and strain next to your meeting load."
      : "Oura shares heart rate through the day, so Meetspike can show what your heart did inside each meeting.";
  markDone("#step-wearable", picked === active);

  qs("#app-url").href = provider.appUrl;
  qs("#app-url").textContent = provider.appUrl.replace(/^https:\/\//, "");
  qs("#app-redirect").textContent = provider.redirectUri;
  qs("#app-scopes").textContent = provider.scopes.join(" ");
  markDone("#step-app", allPresent(provider.secrets));

  keyList(qs("#wearable-keys"), provider.secrets);
  qs("#wearable-commands").textContent = commands(provider.secrets);
  markDone("#step-keys", allPresent(provider.secrets));

  const connect = qs("#connect-wearable");
  const canConnect = picked === active && allPresent(provider.secrets);
  connect.href = provider.startPath;
  connect.textContent = provider.connected ? `Reconnect ${label}` : `Connect ${label}`;
  connect.setAttribute("aria-disabled", canConnect ? "false" : "true");
  qs("#connect-state").textContent = provider.connected
    ? `${label} is connected.`
    : picked !== active
      ? `Finish step 1 first: this install is still set to ${s.wearable.label}.`
      : canConnect
        ? `Press the button and approve access on the ${label} page. You will be sent back here.`
        : "Add the two keys in step 3 first, then press Check again.";
  markDone("#step-connect", provider.connected && picked === active);

  qs("#google-redirect").textContent = s.google.redirectUri;
  keyList(qs("#google-keys"), s.google.secrets);
  qs("#google-commands").textContent = commands(s.google.secrets);
  const googleReady = allPresent(s.google.secrets);
  qs("#connect-google").setAttribute("aria-disabled", googleReady ? "false" : "true");
  qs("#connect-google").textContent = s.google.connected ? "Reconnect Google Calendar" : "Connect Google Calendar";
  qs("#google-state").textContent = s.google.connected
    ? "Google Calendar is connected."
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
  } catch (err) {
    showError(err.message || String(err));
  }
}

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
    const wearable = await post("/api/backfill", sample ? { mode: "fixtures" } : {});
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
  if (action === "import") importData(false);
  if (action === "sample") importData(true);
});

for (const input of document.querySelectorAll('input[name="wearable"]')) {
  input.addEventListener("change", () => {
    state.picked = input.value;
    render();
  });
}

load();

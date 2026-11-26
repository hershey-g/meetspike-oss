/**
 * Ask your data, as a pop-up. A floating panel bottom-right on a desktop, a
 * full-screen sheet on a phone. While Claude works it shows a spinning spark,
 * a rotating playful verb, the seconds so far and the real steps the Worker
 * reports (POST /api/ask/stream, Server-Sent Events). Stop aborts the request
 * and keeps whatever text already arrived.
 *
 * API: initAskPanel({ getScope }), openAsk({ question }), closeAsk(), isAskOpen().
 */
import {
  CHAT_STORE,
  MAX_STORED_TURNS,
  SUGGESTIONS,
  applyAskEvent,
  applyStep,
  cleanTurns,
  createScopeHolder,
  createSseParser,
  endAskStream,
  esc,
  askBody,
  headerText,
  md,
  rangeLine,
  rankedLessThanAll,
  readRange,
  thoughtLabel,
  verbAt,
} from "./ask-logic.js";

const SIGNED_OUT = "Your sign-in expired. Reload the page.";
const DESKTOP = "(min-width: 1024px)";

const ICON = {
  spark: `<svg class="ask-spark" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v18M3 12h18M5.6 5.6l12.8 12.8M18.4 5.6 5.6 18.4"/></svg>`,
  plus: `<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 4v12M4 10h12"/></svg>`,
  expand: `<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M12 3h5v5M8 17H3v-5M17 3l-6 6M3 17l6-6"/></svg>`,
  shrink: `<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M17 8h-5V3M3 12h5v5M12 8l5-5M8 12l-5 5"/></svg>`,
  down: `<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m5 8 5 5 5-5"/></svg>`,
  close: `<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M5 5l10 10M15 5 5 15"/></svg>`,
  send: `<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 16V4M5 9l5-5 5 5"/></svg>`,
  check: `<svg class="ask-check" viewBox="0 0 14 14" aria-hidden="true"><path d="m3 7.5 2.5 2.5L11 4.5"/></svg>`,
  chevDown: `<svg class="ask-chev" viewBox="0 0 12 12" aria-hidden="true"><path d="m3 4.5 3 3 3-3"/></svg>`,
  chevUp: `<svg class="ask-chev" viewBox="0 0 12 12" aria-hidden="true"><path d="m3 7.5 3-3 3 3"/></svg>`,
  retry: `<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M16 10a6 6 0 1 1-1.8-4.3M16 3.5v3h-3"/></svg>`,
};

const S = {
  open: false,
  expanded: false,
  status: null, // { available, connected, tail } from /api/ask/status
  statusError: null,
  replaceKey: false,
  keyError: null,
  keyBusy: false,
  sourceDisplay: null,
  // The All time switch: applies to the next question. Off when the panel opens and on a new chat.
  allTime: false,
  // Assistant turns also carry the question and scope they answer, for Try again.
  chat: [], // { role, content, steps?, thought?, stopped?, stoppedEarly?, interrupted?, stepsOpen?, error?, question?, scope?, allTime?, ignorePeriod?, range? }
  run: null, // { controller, t0, item, phase: "thinking" | "streaming", question }
  opener: null,
};

let root;
let getScope = () => null;
/** The range this chat uses, captured when the panel opens. */
const scope = createScopeHolder(() => getScope?.());
let ticker = null;
let paintQueued = false;

/* ---------- storage ---------- */

function loadChat() {
  try {
    const saved = JSON.parse(sessionStorage.getItem(CHAT_STORE) || "null");
    if (saved?.sourceDisplay?.oura !== S.sourceDisplay.oura || saved?.sourceDisplay?.whoop !== S.sourceDisplay.whoop) return [];
    return Array.isArray(saved.chat) ? saved.chat.filter((t) => t && (t.role === "user" || t.role === "assistant") && typeof t.content === "string") : [];
  } catch {
    return [];
  }
}

function saveChat() {
  try {
    const keep = S.chat.filter((t) => !t.error && (t.role === "user" || t.content)).map((t) => ({ role: t.role, content: t.content }));
    sessionStorage.setItem(CHAT_STORE, JSON.stringify({ sourceDisplay: S.sourceDisplay, chat: keep.slice(-MAX_STORED_TURNS) }));
  } catch {
    /* ignore */
  }
}

export function setAskSourceDisplay(display) {
  if (!display || (display.oura === S.sourceDisplay?.oura && display.whoop === S.sourceDisplay?.whoop)) return;
  if (S.run) stop();
  const initial = S.sourceDisplay === null;
  S.sourceDisplay = display;
  S.chat = initial ? loadChat() : [];
  saveChat();
  if (S.open) render();
}

/* ---------- network ---------- */

class SignedOut extends Error {
  constructor() {
    super(SIGNED_OUT);
  }
}

function looksSignedOut(res) {
  if (res.type === "opaqueredirect" || res.status === 0 || res.status === 301 || res.status === 302 || res.status === 401) return true;
  return (res.headers.get("content-type") || "").includes("text/html");
}

async function call(path, init = {}) {
  const res = await fetch(path, { credentials: "same-origin", redirect: "manual", ...init });
  if (looksSignedOut(res)) throw new SignedOut();
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    const err = new Error(body?.error || `Request failed (${res.status})`);
    err.body = body;
    err.status = res.status;
    throw err;
  }
  return body ?? {};
}

async function loadStatus(force = false) {
  if (S.status && !force) return;
  try {
    S.status = await call("/api/ask/status");
    setAskSourceDisplay(S.status.sourceDisplay);
    S.statusError = null;
  } catch (err) {
    S.status = null;
    S.statusError = err instanceof SignedOut ? SIGNED_OUT : err.message || String(err);
  }
}

/* ---------- render ---------- */

function scopeText() {
  return headerText(scope.current, S.allTime);
}

function isDesktop() {
  return window.matchMedia(DESKTOP).matches;
}

function stepsList(steps, { live }) {
  if (!steps?.length) return "";
  return `<ol class="ask-steps">${steps
    .map(
      (s) => `<li class="${s.status === "done" ? "done" : "active"}">${
        s.status === "done" ? ICON.check : live ? `<span class="ask-dot" aria-hidden="true"></span>` : `<span class="ask-dot idle" aria-hidden="true"></span>`
      }<span>${esc(s.label)}</span></li>`,
    )
    .join("")}</ol>`;
}

function assistantInner(item, idx) {
  const run = S.run && S.run.item === item ? S.run : null;
  const thinking = run && run.phase === "thinking";
  let html = "";
  if (thinking) {
    const ms = Date.now() - run.t0;
    html += `<div class="ask-thinking"><span class="ask-spin">${ICON.spark}</span>
      <span class="ask-verb">${esc(verbAt(ms))}…</span>
      <span class="ask-elapsed">${Math.floor(ms / 1000)}s</span></div>${stepsList(item.steps, { live: true })}`;
  } else if (item.steps?.length || item.thought) {
    const open = Boolean(item.stepsOpen);
    html += `<button type="button" class="ask-thought" data-ask="toggle-steps" data-idx="${idx}" aria-expanded="${open}">
      ${ICON.spark}<span>${esc(thoughtLabel(item.thought || 1, item.stoppedEarly))}</span>${open ? ICON.chevUp : ICON.chevDown}</button>
      ${open ? stepsList(item.steps, { live: false }) : ""}`;
  }
  if (item.content) {
    const caret = run && run.phase === "streaming" ? `<span class="ask-caret" aria-hidden="true"></span>` : "";
    // The caret sits inside the last block so it follows the text.
    let body = md(item.content);
    if (caret) body = /<\/(p|li|td|dd)>(?!.*<\/(p|li|td|dd)>)/s.test(body) ? body.replace(/<\/(p|li|td|dd)>(?!.*<\/(p|li|td|dd)>)/s, `${caret}</$1>`) : body + caret;
    html += `<div class="ask-answer">${body}</div>`;
  }
  if (item.error) html += `<p class="ask-error" role="alert">${esc(item.error)}</p>`;
  // Each Try again repeats its own question over its own range, not the latest one.
  const retry = item.question ? `<button type="button" class="ask-chip btn" data-ask="retry" data-idx="${idx}">${ICON.retry}Try again</button>` : "";
  if (item.stopped) {
    html += `<div class="ask-stopped"><span class="ask-chip"><span class="ask-square" aria-hidden="true"></span>${
      item.stoppedEarly ? "You stopped it before it answered" : "You stopped the answer here"
    }</span>${retry}</div>`;
  } else if (item.interrupted && !run) {
    html += `<div class="ask-stopped"><span class="ask-chip"><span class="ask-square" aria-hidden="true"></span>${
      item.content ? "The connection dropped, so this answer is incomplete" : "The connection dropped before it answered"
    }</span>${retry}</div>`;
  } else if (item.truncated) html += `<p class="ask-note">The answer was cut short.</p>`;
  // What this answer ranked. An older Worker sends no range, so there is no line and no button.
  const line = rangeLine(item.range);
  if (line) html += `<p class="ask-range">${esc(line)}</p>`;
  if (line && item.question && !item.error && !S.run && rankedLessThanAll(item.range)) {
    html += `<button type="button" class="ask-chip btn ask-alltime" data-ask="ask-all-time" data-idx="${idx}">Ask over all time</button>`;
  }
  return html;
}

function messagesHtml() {
  if (!S.chat.length) {
    return `<div class="ask-empty">${ICON.spark}
      <p class="ask-empty-h">What do you want to know about your meetings and recovery?</p>
      ${SUGGESTIONS.map((q) => `<button type="button" class="ask-suggest" data-ask="suggest" data-q="${esc(q)}">${esc(q)}</button>`).join("")}
    </div>`;
  }
  return S.chat
    .map((t, i) =>
      t.role === "user"
        ? `<div class="ask-me">${esc(t.content)}</div>`
        : `<div class="ask-ai"${S.run && S.run.item === t ? ` id="ask-live"` : ""}>${assistantInner(t, i)}</div>`,
    )
    .join("");
}

function bodyHtml() {
  if (S.statusError) {
    return `<div class="ask-msgs"><p class="ask-error" role="alert">${esc(S.statusError)}</p>
      ${S.statusError === SIGNED_OUT ? `<button type="button" class="ask-chip btn" data-ask="reload">Reload</button>` : `<button type="button" class="ask-chip btn" data-ask="recheck">Try again</button>`}</div>`;
  }
  const a = S.status;
  if (!a) return `<div class="ask-msgs"><p class="ask-muted">Loading…</p></div>`;
  if (!a.available) {
    return `<div class="ask-msgs ask-setup"><p>This needs one setting on your Worker first: a secret named AI_KEY_SECRET (any 32 or more random characters). It encrypts your API key. Run this once, then reload:</p>
      <pre class="ask-pre">wrangler secret put AI_KEY_SECRET</pre></div>`;
  }
  if (!a.connected || S.replaceKey) {
    return `<div class="ask-msgs ask-setup">
      <p>Ask things like "which meetings cost me the most this month". Add your own Claude API key: you pay Anthropic directly for what you use.</p>
      <form class="ask-keyform" data-ask-form="key">
        <label class="ask-kicker" for="ask-key">Claude API key</label>
        <input id="ask-key" name="key" type="password" autocomplete="off" spellcheck="false" placeholder="sk-ant-…" required ${S.keyBusy ? "disabled" : ""} />
        <span class="ask-muted">Get one at console.anthropic.com, under API keys.</span>
        <button type="submit" class="ask-primary" ${S.keyBusy ? "disabled" : ""}>${S.keyBusy ? "Checking…" : "Check and save"}</button>
        ${S.keyError ? `<p class="ask-error" role="alert">${esc(S.keyError)}</p>` : ""}
      </form>
      <div class="ask-share"><span class="ask-kicker">What is shared</span>
        <span>Your key is stored encrypted in your own Cloudflare Worker, never in the browser.</span>
        <span>Each question sends Anthropic the days it needs: dates, meeting titles and times, who attended, and your scores. No email addresses, transcripts or audio.</span></div>
      ${a.connected ? `<button type="button" class="ask-link" data-ask="cancel-key">Keep the current key</button>` : ""}
    </div>`;
  }
  const running = Boolean(S.run);
  return `<div class="ask-msgs" id="ask-msgs">${messagesHtml()}</div>
    <form class="ask-composer" data-ask-form="ask">
      <div class="ask-field">
        <label for="ask-in" class="ask-sr">Your question</label>
        <input id="ask-in" name="q" type="text" autocomplete="off" enterkeyhint="send" placeholder="${running ? "Answering… you can stop it" : "Ask about your meetings and recovery"}" />
        ${
          running
            ? `<button type="button" class="ask-stop" data-ask="stop" aria-label="Stop answering"><span aria-hidden="true"></span></button>`
            : `<button type="submit" class="ask-send" aria-label="Send">${ICON.send}</button>`
        }
      </div>
      <p class="ask-foot">Key …${esc(a.tail || "")} · <button type="button" class="ask-link" data-ask="replace-key">Change</button> · <button type="button" class="ask-link" data-ask="remove-key">Remove</button></p>
      <p class="ask-foot">Sends dates, titles, names and scores. No emails or audio.</p>
    </form>`;
}

function render() {
  if (!root) return;
  const panel = root.querySelector(".ask-panel");
  const launch = root.querySelector(".ask-launch");
  launch.hidden = S.open;
  panel.hidden = !S.open;
  panel.classList.toggle("expanded", S.expanded);
  document.documentElement.classList.toggle("ask-open", S.open);
  if (!S.open) return;
  const input = panel.querySelector("#ask-in");
  const draft = input ? input.value : "";
  const hadFocus = input && document.activeElement === input;
  panel.querySelector(".ask-scope").textContent = scopeText();
  // With no scope all history is already used, so there is nothing to switch.
  const pill = panel.querySelector(".ask-pill");
  pill.hidden = !scope.current;
  pill.setAttribute("aria-pressed", String(S.allTime));
  const exp = panel.querySelector('[data-ask="expand"]');
  exp.innerHTML = S.expanded ? ICON.shrink : ICON.expand;
  exp.setAttribute("aria-label", S.expanded ? "Shrink chat" : "Expand chat");
  panel.querySelector(".ask-main").innerHTML = bodyHtml();
  const next = panel.querySelector("#ask-in");
  if (next) {
    next.value = draft;
    if (hadFocus) next.focus();
  }
  scrollToEnd(true);
}

function nearBottom(el) {
  return el.scrollHeight - el.scrollTop - el.clientHeight < 80;
}

function scrollToEnd(force) {
  const m = root?.querySelector("#ask-msgs");
  if (m && (force || nearBottom(m))) m.scrollTop = m.scrollHeight;
}

/** Repaint only the answer that is in progress. */
function paintLive() {
  paintQueued = false;
  const el = root?.querySelector("#ask-live");
  if (!el || !S.run) return;
  const m = root.querySelector("#ask-msgs");
  const stick = m ? nearBottom(m) : false;
  el.innerHTML = assistantInner(S.run.item, S.chat.indexOf(S.run.item));
  if (stick) m.scrollTop = m.scrollHeight;
}

function queuePaint() {
  if (paintQueued) return;
  paintQueued = true;
  requestAnimationFrame(paintLive);
}

function announce(text) {
  const live = root?.querySelector(".ask-announce");
  if (!live) return;
  live.textContent = "";
  setTimeout(() => (live.textContent = text), 50);
}

/* ---------- asking ---------- */

function startTicker() {
  stopTicker();
  ticker = setInterval(() => {
    if (S.run?.phase === "thinking") queuePaint();
  }, 250);
}

function stopTicker() {
  if (ticker) clearInterval(ticker);
  ticker = null;
}

/**
 * `opts` carries a turn's own settings: allTime (default: the switch as it is now) and
 * ignorePeriod, which Ask over all time sets so the question's own period does not win.
 */
async function ask(question, askScope = scope.current, opts = {}) {
  const q = String(question ?? "").trim();
  if (!q || S.run) return;
  if (!S.status?.connected) {
    await loadStatus(true);
    if (!S.status?.connected) return render();
  }
  const history = cleanTurns(S.chat.filter((t) => !t.error && t.content));
  const userTurn = { role: "user", content: q };
  const allTime = opts.allTime ?? S.allTime;
  const ignorePeriod = opts.ignorePeriod === true;
  const item = { role: "assistant", content: "", steps: [], thought: 0, question: q, scope: askScope, allTime, ignorePeriod };
  S.chat.push(userTurn, item);
  const controller = new AbortController();
  S.run = { controller, t0: Date.now(), item, phase: "thinking", question: q };
  saveChat();
  render();
  root.querySelector("#ask-in")?.focus();
  startTicker();

  const body = JSON.stringify(askBody({ question: q, history, sourceDisplay: S.sourceDisplay, scope: askScope, allTime, ignorePeriod }));
  try {
    const res = await fetch("/api/ask/stream", {
      method: "POST",
      headers: { "content-type": "application/json", accept: "text/event-stream" },
      body,
      credentials: "same-origin",
      redirect: "manual",
      signal: controller.signal,
    });
    if (looksSignedOut(res)) throw new SignedOut();
    if (res.status === 404 || res.status === 405) {
      await askJson(body, controller.signal, item);
    } else if (!(res.headers.get("content-type") || "").includes("text/event-stream")) {
      const data = await res.json().catch(() => null);
      handleError(data?.error || `Request failed (${res.status})`, Boolean(data?.needsKey), userTurn, item);
    } else {
      await readStream(res, item, userTurn);
    }
  } catch (err) {
    if (err?.name === "AbortError") return; // stop() already finished the turn
    handleError(err instanceof SignedOut ? SIGNED_OUT : "Could not reach your Worker. Check your connection and try again.", false, userTurn, item);
  }
  finish(item);
}

async function readStream(res, item, userTurn) {
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let ended = false;
  const parser = createSseParser((ev) => {
    if (ended || S.run?.item !== item) return;
    const kind = applyAskEvent(item, ev);
    if (kind === "text" && S.run.phase === "thinking") {
      S.run.phase = "streaming";
      item.thought = (Date.now() - S.run.t0) / 1000;
    }
    if (kind === "done") ended = true;
    else if (kind === "error") {
      ended = true;
      handleError(ev.data?.error || "Something went wrong. Try again.", Boolean(ev.data?.needsKey), userTurn, item);
    } else if (kind) queuePaint();
  });
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      parser.push(decoder.decode(value, { stream: true }));
    }
    parser.push(decoder.decode());
    parser.end();
  } catch (err) {
    if (err?.name === "AbortError") throw err; // Stop
    // The connection broke mid-read: same as ending without done.
  }
  // Ending without done or error means the answer was cut off: keep its text.
  if (S.run?.item === item) endAskStream(item, ended);
}

/** Older Worker without /api/ask/stream: one JSON answer, with local steps. */
async function askJson(body, signal, item) {
  item.steps = applyStep(item.steps, { id: "data", label: "Reading your meetings and recovery", status: "active" });
  queuePaint();
  const res = await fetch("/api/ask", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
    credentials: "same-origin",
    redirect: "manual",
    signal,
  });
  if (looksSignedOut(res)) throw new SignedOut();
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    const userTurn = S.chat[S.chat.indexOf(item) - 1];
    handleError(data?.error || `Request failed (${res.status})`, Boolean(data?.needsKey), userTurn, item);
    return;
  }
  item.steps = applyStep(item.steps, { id: "data", status: "done" });
  item.thought = (Date.now() - S.run.t0) / 1000;
  item.content = String(data?.answer || "No answer came back. Try again.");
  if (data?.truncated) item.truncated = true;
  const range = readRange(data);
  if (range) item.range = range;
}

function handleError(message, needsKey, userTurn, item) {
  if (needsKey) {
    S.chat = S.chat.filter((t) => t !== userTurn && t !== item);
    S.status = { ...(S.status ?? { available: true }), connected: false, tail: null };
    S.replaceKey = false;
    S.keyError = message;
    return;
  }
  item.error = message;
}

function finish(item) {
  if (!S.run || S.run.item !== item) return;
  if (!item.thought) item.thought = (Date.now() - S.run.t0) / 1000;
  S.run = null;
  stopTicker();
  saveChat();
  render();
  if (item.error) announce(item.error);
  else if (item.interrupted) announce("The connection dropped. The answer is incomplete. You can try again.");
  else if (item.content) announce("Answer ready.");
}

function stop() {
  const run = S.run;
  if (!run) return;
  const item = run.item;
  item.stopped = true;
  item.stoppedEarly = !item.content;
  if (run.phase === "thinking") item.thought = (Date.now() - run.t0) / 1000;
  S.run = null;
  stopTicker();
  run.controller.abort();
  saveChat();
  render();
  announce("Stopped.");
  root.querySelector("#ask-in")?.focus();
}

function newChat() {
  if (S.run) stop();
  S.chat = [];
  S.allTime = false;
  scope.capture();
  saveChat();
  render();
  root.querySelector("#ask-in")?.focus();
}

/* ---------- key ---------- */

async function saveKey(form) {
  const key = form.key.value.trim();
  if (!key) return;
  S.keyBusy = true;
  S.keyError = null;
  render();
  try {
    const r = await call("/api/ask/key", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ key }) });
    S.status = { ...(S.status ?? {}), available: true, connected: true, tail: r.tail ?? null };
    S.replaceKey = false;
  } catch (err) {
    S.keyError = err.message || String(err);
  }
  S.keyBusy = false;
  render();
  (root.querySelector("#ask-in") || root.querySelector("#ask-key"))?.focus();
}

async function removeKey() {
  try {
    await call("/api/ask/key", { method: "DELETE" });
    S.status = { ...(S.status ?? {}), connected: false, tail: null };
    S.keyError = null;
  } catch (err) {
    S.keyError = err.message || String(err);
  }
  render();
}

/* ---------- open / close ---------- */

export function isAskOpen() {
  return S.open;
}

export async function openAsk({ question } = {}) {
  if (!root) initAskPanel({});
  // The range shown in the header is the range sent with every question.
  scope.capture();
  S.allTime = false;
  if (!S.open) {
    S.opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    S.open = true;
    S.status = null;
    S.statusError = null;
  }
  render();
  (root.querySelector("#ask-in") || root.querySelector("#ask-key") || root.querySelector(".ask-panel"))?.focus();
  await loadStatus(true);
  if (!S.open) return;
  render();
  (root.querySelector("#ask-in") || root.querySelector("#ask-key"))?.focus();
  if (question) ask(question);
}

export function closeAsk() {
  if (!S.open) return;
  S.open = false;
  render();
  const back = S.opener && document.contains(S.opener) ? S.opener : root.querySelector(".ask-launch");
  S.opener = null;
  if (back && !back.hidden) back.focus();
}

function toggle() {
  if (S.open) closeAsk();
  else openAsk();
}

/* ---------- wiring ---------- */

export function initAskPanel({ getScope: scope } = {}) {
  if (typeof scope === "function") getScope = scope;
  if (root) return;
  root = document.createElement("div");
  root.id = "askpanel";
  root.innerHTML = `
    <button type="button" class="ask-launch" data-ask="open" aria-haspopup="dialog">${ICON.spark}<span>Ask your data</span><kbd>${/Mac|iPhone|iPad/.test(navigator.platform) ? "⌘K" : "Ctrl K"}</kbd></button>
    <section class="ask-panel" role="dialog" aria-labelledby="ask-title" tabindex="-1" hidden>
      <header class="ask-head">
        <div class="ask-titles"><h2 id="ask-title">Ask your data</h2><span class="ask-scope"></span>
          <button type="button" class="ask-pill" data-ask="all-time" aria-pressed="false" hidden>All time</button></div>
        <button type="button" class="ask-icon" data-ask="new" aria-label="New chat" title="New chat">${ICON.plus}</button>
        <button type="button" class="ask-icon ask-expand" data-ask="expand" aria-label="Expand chat" title="Expand">${ICON.expand}</button>
        <button type="button" class="ask-icon ask-min" data-ask="close" aria-label="Minimize chat" title="Minimize">${ICON.down}</button>
        <button type="button" class="ask-icon ask-x" data-ask="close" aria-label="Close chat">${ICON.close}</button>
      </header>
      <div class="ask-main"></div>
      <div class="ask-announce ask-sr" aria-live="polite"></div>
    </section>`;
  document.body.appendChild(root);

  root.addEventListener("click", (ev) => {
    const t = ev.target.closest("[data-ask]");
    if (!t) return;
    const a = t.dataset.ask;
    if (a === "open") openAsk();
    else if (a === "close") closeAsk();
    else if (a === "expand") {
      S.expanded = !S.expanded;
      render();
    } else if (a === "new") newChat();
    else if (a === "stop") stop();
    else if (a === "retry") {
      const item = S.chat[Number(t.dataset.idx)];
      // Try again keeps the question, the dates and the All time setting of that answer.
      if (item?.question) ask(item.question, item.scope ?? null, { allTime: item.allTime === true, ignorePeriod: item.ignorePeriod === true });
    } else if (a === "all-time") {
      S.allTime = !S.allTime;
      render();
      root.querySelector('[data-ask="all-time"]')?.focus();
    } else if (a === "ask-all-time") {
      // The same question again over all history; its own period must not win.
      const item = S.chat[Number(t.dataset.idx)];
      if (item?.question) ask(item.question, item.scope ?? null, { allTime: true, ignorePeriod: true });
    }
    else if (a === "suggest") ask(t.dataset.q);
    else if (a === "replace-key") {
      S.replaceKey = true;
      S.keyError = null;
      render();
      root.querySelector("#ask-key")?.focus();
    } else if (a === "cancel-key") {
      S.replaceKey = false;
      render();
    } else if (a === "remove-key") removeKey();
    else if (a === "reload") location.reload();
    else if (a === "recheck") loadStatus(true).then(render);
    else if (a === "toggle-steps") {
      const item = S.chat[Number(t.dataset.idx)];
      if (item) {
        item.stepsOpen = !item.stepsOpen;
        if (S.run?.item === item) paintLive();
        else render();
        root.querySelector(`[data-ask="toggle-steps"][data-idx="${t.dataset.idx}"]`)?.focus();
      }
    }
  });

  root.addEventListener("submit", (ev) => {
    const form = ev.target.closest("[data-ask-form]");
    if (!form) return;
    ev.preventDefault();
    if (form.dataset.askForm === "key") saveKey(form);
    else if (!S.run) {
      const q = form.q.value;
      if (!q.trim()) return;
      form.q.value = "";
      ask(q);
    }
  });

  document.addEventListener("keydown", (ev) => {
    if ((ev.metaKey || ev.ctrlKey) && !ev.altKey && !ev.shiftKey && ev.key.toLowerCase() === "k") {
      const el = document.activeElement;
      const typingElsewhere = el && !root.contains(el) && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
      if (typingElsewhere) return;
      ev.preventDefault();
      toggle();
      return;
    }
    if (ev.key === "Escape" && S.open) {
      const el = document.activeElement;
      if (el && el !== document.body && !root.contains(el)) return; // something else (a picker) owns Esc
      ev.preventDefault();
      if (S.run) stop();
      else closeAsk();
    }
  });

  // Moving from desktop to phone width drops the expanded size.
  window.matchMedia(DESKTOP).addEventListener?.("change", () => {
    if (!isDesktop()) S.expanded = false;
    render();
  });
  render();
}

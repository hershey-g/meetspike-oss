import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import {
  MAX_TURN_CHARS,
  SUGGESTIONS,
  VERBS,
  VERB_MS,
  applyAskEvent,
  applyStep,
  cleanTurns,
  createScopeHolder,
  createSseParser,
  endAskStream,
  esc,
  md,
  scopeRange,
  thoughtLabel,
  verbAt,
} from "../public/ask-logic.js";
import * as askLogic from "../public/ask-logic.js";

// headerText(scope, allTime) replaces scopeLabel(scope) in build 10. It is reached through the namespace so a
// missing export fails the tests that use it, not the whole file.
const headerText = (scope: unknown, allTime: boolean): string => (askLogic as any).headerText(scope, allTime);

function collect(chunks: string[], end = true) {
  const got: { event: string; data: unknown }[] = [];
  const p = createSseParser((e: { event: string; data: unknown }) => got.push(e));
  for (const c of chunks) p.push(c);
  if (end) p.end();
  return got;
}

describe("ask panel: SSE parser", () => {
  it("parses named events with JSON data", () => {
    const got = collect(['event: step\ndata: {"id":"calendar","label":"Read 41 meetings","status":"done"}\n\n', 'event: text\ndata: {"delta":"Hi"}\n\n']);
    assert.deepEqual(got, [
      { event: "step", data: { id: "calendar", label: "Read 41 meetings", status: "done" } },
      { event: "text", data: { delta: "Hi" } },
    ]);
  });

  it("handles events split across chunks, CRLF and comments", () => {
    const got = collect([": ping\r\n\r\nevent: te", "xt\r\ndata: {\"delta\":", "\"a b\"}\r", "\n\r\nevent: done\ndata: {}\n\n"]);
    assert.deepEqual(got, [
      { event: "text", data: { delta: "a b" } },
      { event: "done", data: {} },
    ]);
  });

  it("joins multi-line data and keeps non-JSON as a string", () => {
    assert.deepEqual(collect(["data: one\ndata: two\n\n"]), [{ event: "message", data: "one\ntwo" }]);
  });

  it("flushes a final event without a trailing blank line on end()", () => {
    assert.deepEqual(collect(['event: done\ndata: {"truncated":true}']), [{ event: "done", data: { truncated: true } }]);
    assert.deepEqual(collect(['event: done\ndata: {"truncated":true}'], false), []);
  });
});

describe("ask panel: markdown and escaping", () => {
  it("escapes HTML, including inside bold", () => {
    assert.equal(md("<b>x</b> **<i>y</i>**"), "<p>&lt;b&gt;x&lt;/b&gt; <strong>&lt;i&gt;y&lt;/i&gt;</strong></p>");
    assert.equal(esc(`"'&`), "&quot;&#39;&amp;");
  });

  it("renders paragraphs, bullets and pipe tables", () => {
    const html = md("Intro\n\n- one\n- **two**\n\n| Meeting | HR |\n|---|---|\n| Pitch | 96 |");
    assert.equal(
      html,
      "<p>Intro</p><ul><li>one</li><li><strong>two</strong></li></ul><table><thead><tr><th>Meeting</th><th>HR</th></tr></thead><tbody><tr><td>Pitch</td><td>96</td></tr></tbody></table>",
    );
  });

  it("does not throw on a half-streamed table", () => {
    assert.doesNotThrow(() => md("| a |\n|---|"));
  });
});

describe("ask panel: thinking copy and steps", () => {
  it("rotates the verb every VERB_MS and wraps", () => {
    assert.equal(verbAt(0), VERBS[0]);
    assert.equal(verbAt(VERB_MS + 1), VERBS[1]);
    assert.equal(verbAt(VERB_MS * VERBS.length), VERBS[0]);
    assert.ok(VERBS.includes("Tinkering"));
  });

  it("labels the folded thought", () => {
    assert.equal(thoughtLabel(6.4, false), "Thought for 6s");
    assert.equal(thoughtLabel(0.2, true), "Stopped after 1s");
  });

  it("upserts steps by id in first-seen order", () => {
    let s = applyStep([], { id: "calendar", label: "Reading your calendar", status: "active" });
    s = applyStep(s, { id: "body", label: "Lining up nights", status: "active" });
    s = applyStep(s, { id: "calendar", label: "Read 41 meetings", status: "done" });
    assert.deepEqual(s, [
      { id: "calendar", label: "Read 41 meetings", status: "done" },
      { id: "body", label: "Lining up nights", status: "active" },
    ]);
    assert.equal(applyStep(s, null), s);
  });

  it("history starts with the user and keeps the last turns", () => {
    const raw = [{ role: "assistant", content: "x" }, { role: "user", content: "q" }, { role: "assistant", content: "" }, { role: "system", content: "no" }];
    assert.deepEqual(cleanTurns(raw), [{ role: "user", content: "q" }]);
    const many = Array.from({ length: 20 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", content: String(i) }));
    assert.equal(cleanTurns(many).length, 12);
  });
});

describe("ask panel: copy", () => {
  it("has no em dashes in the panel copy", () => {
    for (const f of ["public/ask-panel.js", "public/ask-logic.js", "public/ask-panel.css"]) {
      assert.ok(!readFileSync(f, "utf8").includes("—"), f);
    }
    assert.equal(SUGGESTIONS.length, 4);
  });
});

describe("ask panel: date scope", () => {
  it("keeps the range captured at open, so the shown range is the sent range after the dashboard moves", () => {
    // The dashboard: on Dates with a picked range, then the user switches to Today.
    let dashboard: { start: string; end: string; label: string } | null = { start: "2026-10-01", end: "2026-10-14", label: "Oct 1 to Oct 14" };
    const scope = createScopeHolder(() => dashboard);
    scope.capture(); // panel opens from Dates
    dashboard = null; // Today tab: no range

    assert.equal(headerText(scope.current, false), "Ranking Oct 1 to Oct 14, compared with all history");
    assert.deepEqual(scopeRange(scope.current), { start: "2026-10-01", end: "2026-10-14" });

    // Opening again (or a new chat) takes the dashboard's range at that moment, for both.
    scope.capture();
    assert.equal(headerText(scope.current, false), "Using all history");
    assert.deepEqual(scopeRange(scope.current), {});
  });

  it("is a copy: later changes to the dashboard's object do not leak in", () => {
    const live = { start: "2026-10-01", end: "2026-10-14", label: "Oct 1 to Oct 14" };
    const scope = createScopeHolder(() => live);
    scope.capture();
    live.start = "2026-01-01";
    live.label = "Jan 1 to Oct 14";
    assert.equal(scope.current!.start, "2026-10-01");
    assert.equal(headerText(scope.current, false), "Ranking Oct 1 to Oct 14, compared with all history");
  });

  it("never shows a range it would not send", () => {
    for (const s of [null, undefined, {}, { label: "Oct" }, { start: "2026-10-01", label: "Oct" }, { start: "2026-10-01", end: "2026-10-02" }]) {
      const scope = createScopeHolder(() => s);
      scope.capture();
      const sends = Object.keys(scopeRange(scope.current)).length > 0;
      assert.equal(headerText(scope.current, false) !== "Using all history", sends, JSON.stringify(s));
    }
    const scope = createScopeHolder(undefined);
    assert.equal(scope.capture(), null);
  });
});

describe("ask panel: stream outcome", () => {
  const fresh = () => ({ role: "assistant", content: "", steps: [] as unknown[] }) as Record<string, any>;

  it("treats EOF without done or error as interrupted and keeps the partial text", () => {
    const item = fresh();
    const got = collect(['event: step\ndata: {"id":"think","label":"Thinking","status":"active"}\n\n', 'event: text\ndata: {"delta":"Your Thursday "}\n\n']);
    let terminal = false;
    for (const ev of got) if (["done", "error"].includes(applyAskEvent(item, ev) ?? "")) terminal = true;
    endAskStream(item, terminal);
    assert.equal(item.interrupted, true);
    assert.equal(item.content, "Your Thursday ");
  });

  it("treats EOF before any text as interrupted too", () => {
    const item = fresh();
    endAskStream(item, false);
    assert.equal(item.interrupted, true);
    assert.equal(item.content, "");
  });

  it("honours the server's interrupted flag on done", () => {
    const item = fresh();
    applyAskEvent(item, { event: "text", data: { delta: "Part" } });
    assert.equal(applyAskEvent(item, { event: "done", data: { truncated: true, interrupted: true } }), "done");
    endAskStream(item, true);
    assert.equal(item.interrupted, true);
    assert.equal(item.content, "Part");
  });

  it("does not flag a complete answer, an error, or a plain max_tokens cut", () => {
    const ok = fresh();
    applyAskEvent(ok, { event: "text", data: { delta: "All" } });
    applyAskEvent(ok, { event: "done", data: { truncated: false } });
    endAskStream(ok, true);
    assert.equal(ok.interrupted, undefined);

    const cut = fresh();
    applyAskEvent(cut, { event: "done", data: { truncated: true } });
    endAskStream(cut, true);
    assert.equal(cut.truncated, true);
    assert.equal(cut.interrupted, undefined);

    const failed = fresh();
    assert.equal(applyAskEvent(failed, { event: "error", data: { error: "x" } }), "error");
    failed.error = "x";
    endAskStream(failed, false);
    assert.equal(failed.interrupted, undefined);
  });

  it("ignores unknown and empty events", () => {
    const item = fresh();
    assert.equal(applyAskEvent(item, { event: "message", data: "hi" }), null);
    assert.equal(applyAskEvent(item, { event: "text", data: {} }), null);
    assert.equal(item.content, "");
  });
});

describe("ask panel: history size", () => {
  it("trims each turn to what the Worker keeps", () => {
    const turns = cleanTurns([{ role: "user", content: "q" }, { role: "assistant", content: "a".repeat(MAX_TURN_CHARS * 3) }]);
    assert.equal(turns[1].content.length, MAX_TURN_CHARS);
  });
});

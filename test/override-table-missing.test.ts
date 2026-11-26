import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import { fingerprint, PATHS, world } from "./override-world.ts";

/**
 * Code ships before the migration is applied. With no meeting_override table
 * every route must say exactly what it said before build 9 (same bytes), and
 * writes must say 503.
 *
 * The fingerprints in fixtures/override-table-missing.json were taken from the
 * build 8 code over this same world and clock. A change to the world in
 * override-world.ts means taking them again from a checkout without the
 * override code.
 */
const NOW = Date.parse("2026-11-14T15:00:00.000Z");

describe("the table is not there yet", () => {
  beforeEach(() => mock.timers.enable({ apis: ["Date"], now: NOW }));
  afterEach(() => mock.timers.reset());

  it("every read answers byte for byte as it did before the table existed", async () => {
    const golden = JSON.parse(readFileSync(join(import.meta.dirname, "fixtures", "override-table-missing.json"), "utf8")) as Record<string, string>;
    const w = await world();
    w.raw.exec("DROP TABLE IF EXISTS meeting_override");
    const seen: Record<string, string> = {};
    for (const path of PATHS) {
      const r = await w.call(path);
      assert.ok(r.status === 200 || r.status === 404, `${path}: ${r.status}`);
      seen[path] = `${r.status} ${fingerprint(path, r.text)}`;
    }
    assert.deepEqual(Object.keys(seen), Object.keys(golden));
    for (const path of PATHS) assert.equal(seen[path], golden[path], `${path} changed without the table`);
  });

  it("no route invents an override or excluded field when there is nothing to read", async () => {
    const w = await world();
    w.raw.exec("DROP TABLE IF EXISTS meeting_override");
    for (const path of PATHS) {
      const r = await w.call(path);
      assert.doesNotMatch(r.text, /"override"|"excluded"|"seenNone"/, path);
    }
  });

  it("the live, reminder and ingest routes carry on with calendar times", async () => {
    const start = new Date(NOW - 10 * 60_000).toISOString();
    const end = new Date(NOW + 50 * 60_000).toISOString();
    const w = await world({ extra: [{ id: "now1", start, end, title: "Right now", people: [], hr: null }] });
    w.raw.exec("DROP TABLE IF EXISTS meeting_override");
    const auth = { authorization: "Bearer admin-secret-xyz", "content-type": "application/json" };
    const live = await w.call("/whoop-web/live", {
      method: "POST", headers: auth, body: JSON.stringify({ version: 1, points: [[NOW, 80]], includeMeeting: true }),
    }, { ...w.env, LIVE_HR: { idFromName: () => "x", get: () => ({ fetch: async () => Response.json({ ok: true, points: [], cursor: 0 }) }) } });
    assert.equal(live.status, 200, live.text);
    assert.equal(live.body.meeting.id, "now1");
    const reminder = await w.call("/whoop-web/reminder", { headers: auth });
    assert.equal(reminder.status, 200, reminder.text);
    assert.equal(reminder.body.meeting.id, "now1");
  });

  it("writes say 503 and read routes do not mention the table", async () => {
    const w = await world();
    w.raw.exec("DROP TABLE IF EXISTS meeting_override");
    assert.equal((await w.put("f1", { scope: "event", state: "not_joined" })).status, 503);
    assert.equal((await w.attend({
      meetingStartUtc: "2026-11-12T20:00:00.000Z", seenStartUtc: "2026-11-12T20:01:00.000Z", seenEndUtc: "2026-11-12T20:50:00.000Z", seenNone: false,
    })).status, 503);
    for (const path of ["/view?date=2026-11-12", "/briefing/day?date=2026-11-12"]) {
      assert.doesNotMatch((await w.call(path)).text, /meeting_override|no such table/i);
    }
  });
});

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  AI_KEY_KV,
  aiKeyInfo,
  canStoreAiKey,
  deleteAiKey,
  loadAiKey,
  looksLikeAnthropicKey,
  saveAiKey,
} from "../src/lib/ai-key.ts";
import { buildAskContext } from "../src/lib/ask-context.ts";
import type { DayRow } from "../src/lib/usual.ts";
import type { Env } from "../src/env.ts";
import type { CalendarEventRow } from "../src/types.ts";

function kv() {
  const store = new Map<string, string>();
  return {
    store,
    async get(k: string) {
      return store.get(k) ?? null;
    },
    async put(k: string, v: string) {
      store.set(k, v);
    },
    async delete(k: string) {
      store.delete(k);
    },
  };
}

const SECRET = "x".repeat(40);
const KEY = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789-WXYZ";

describe("AI key storage", () => {
  it("needs a 32+ character secret", () => {
    assert.equal(canStoreAiKey({ AI_KEY_SECRET: "short" } as Env), false);
    assert.equal(canStoreAiKey({ AI_KEY_SECRET: SECRET } as Env), true);
    assert.equal(canStoreAiKey({} as Env), false);
  });

  it("checks the key shape before any network call", () => {
    assert.equal(looksLikeAnthropicKey(KEY), true);
    assert.equal(looksLikeAnthropicKey("sk-proj-123"), false);
    assert.equal(looksLikeAnthropicKey(""), false);
  });

  it("stores the key sealed, reads it back, and exposes only the last four characters", async () => {
    const TOKENS = kv();
    const env = { AI_KEY_SECRET: SECRET, TOKENS } as unknown as Env;
    const saved = await saveAiKey(env, KEY, new Date("2026-11-17T12:00:00Z"));
    assert.equal(saved.tail, "WXYZ");
    const raw = TOKENS.store.get(AI_KEY_KV)!;
    assert.ok(!raw.includes("sk-ant"), "plain key is not in KV");
    assert.deepEqual(await aiKeyInfo(env), { tail: "WXYZ", savedAt: "2026-11-17T12:00:00.000Z" });
    assert.equal(await loadAiKey(env), KEY);
  });

  it("cannot open the key under a different secret, and delete removes it", async () => {
    const TOKENS = kv();
    await saveAiKey({ AI_KEY_SECRET: SECRET, TOKENS } as unknown as Env, KEY);
    assert.equal(await loadAiKey({ AI_KEY_SECRET: "y".repeat(40), TOKENS } as unknown as Env), null);
    const env = { AI_KEY_SECRET: SECRET, TOKENS } as unknown as Env;
    await deleteAiKey(env);
    assert.equal(await loadAiKey(env), null);
    assert.equal(await aiKeyInfo(env), null);
  });
});

describe("Ask data block", () => {
  const rows: DayRow[] = [
    {
      day: "2026-11-16",
      weekday: true,
      meetingCount: 1,
      meetingS: 3600,
      afterHours: 0,
      morning: { sleepScore: 80, readinessScore: 70, avgHrv: 41.2, lowestHr: 58, strain: 9.4 },
      next: { sleepScore: 60, readinessScore: 49, avgHrv: null, lowestHr: null },
      people: [],
    },
  ];
  const events = [
    {
      id: "e1",
      start_utc: "2026-11-16T16:00:00.000Z",
      end_utc: "2026-11-16T17:00:00.000Z",
      start_local: "2026-11-16T11:00:00-05:00",
      title: "Proposal review",
      kind: "client",
      attendees_json: JSON.stringify([
        { email: "me@x.com", self: true },
        { email: "sam@client.example", displayName: "Sam Okafor" },
      ]),
    },
  ] as CalendarEventRow[];

  it("lists each day with woke and next-morning scores, and meetings with names but no emails", () => {
    const text = buildAskContext({
      rows,
      events,
      usual: { from: "2026-10-20", to: "2026-11-16", days: 28, recovery: 72, sleep: 80, hrv: 40, restingHr: 59, strain: 8.5, meetingHours: 3, afterHours: 0.2 },
      effect: { heavyHours: 4, heavyMeetings: 5, heavy: { days: 3, nextRecovery: 54 }, lighter: { days: 9, nextRecovery: 76 }, cost: 22 },
      labels: { wearable: "WHOOP", readiness: "recovery", strain: "strain" },
      timeZone: "America/New_York",
      today: "2026-11-17",
    });
    assert.match(text, /2026-11-16 Mon \| woke recovery 70, sleep 80, HRV 41, RHR 58, strain 9\.4 \| next recovery 49, sleep 60 \| 1 meetings, 1\.0 h/);
    assert.match(text, /11:00 Proposal review \(client, 60m\) with Sam Okafor/);
    assert.doesNotMatch(text, /@/, "no email addresses are sent");
    assert.match(text, /Heavy days .* 3, next-morning recovery averaged 54\. Other days: 9, averaged 76\./);
  });
});

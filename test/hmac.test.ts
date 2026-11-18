import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { hmacSha256Hex, verifyOuraSignature } from "../src/lib/hmac.ts";

describe("oura hmac", () => {
  it("accepts a matching timestamp+body signature", async () => {
    const secret = "test-client-secret";
    const timestamp = "1710000000";
    const body = '{"event_type":"create","data_type":"daily_sleep","object_id":"abc"}';
    const signature = await hmacSha256Hex(secret, `${timestamp}${body}`);
    const result = await verifyOuraSignature({
      secret,
      signature,
      timestamp,
      rawBody: body,
      nowMs: 1710000000 * 1000,
    });
    assert.equal(result.ok, true);
  });

  it("rejects a tampered body", async () => {
    const secret = "test-client-secret";
    const timestamp = "1710000000";
    const signature = await hmacSha256Hex(secret, `${timestamp}{"ok":true}`);
    const result = await verifyOuraSignature({
      secret,
      signature,
      timestamp,
      rawBody: '{"ok":false}',
      nowMs: 1710000000 * 1000,
    });
    assert.equal(result.ok, false);
    if (!result.ok) assert.equal(result.reason, "signature mismatch");
  });

  it("rejects a stale timestamp", async () => {
    const secret = "s";
    const timestamp = "1000";
    const body = "{}";
    const signature = await hmacSha256Hex(secret, `${timestamp}${body}`);
    const result = await verifyOuraSignature({
      secret,
      signature,
      timestamp,
      rawBody: body,
      nowMs: Date.now(),
    });
    assert.equal(result.ok, false);
    if (!result.ok) assert.match(result.reason, /replay/);
  });

  it("rejects missing headers", async () => {
    const result = await verifyOuraSignature({
      secret: "s",
      signature: null,
      timestamp: null,
      rawBody: "{}",
    });
    assert.equal(result.ok, false);
  });
});

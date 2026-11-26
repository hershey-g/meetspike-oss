import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";
import { accessConfig, clearAccessKeyCache, requireAccessUser, verifyAccessJwt } from "../src/lib/access-jwt.ts";
import { ACCESS_ENV, AUD, TEAM, makeAccessTeam } from "./access-fixture.ts";

const config = accessConfig(ACCESS_ENV)!;

describe("accessConfig", () => {
  it("needs both values and a cloudflareaccess.com team", () => {
    assert.deepEqual(config, { issuer: TEAM, certsUrl: `${TEAM}/cdn-cgi/access/certs`, aud: [AUD] });
    assert.equal(accessConfig({ ACCESS_TEAM_DOMAIN: "meetspike-test.cloudflareaccess.com/", ACCESS_AUD: AUD })?.issuer, TEAM);
    assert.deepEqual(accessConfig({ ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: " a , b ," })?.aud, ["a", "b"]);
    for (const bad of [
      {},
      { ACCESS_TEAM_DOMAIN: TEAM },
      { ACCESS_AUD: AUD },
      { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: " , " },
      { ACCESS_TEAM_DOMAIN: "https://evil.example", ACCESS_AUD: AUD },
      { ACCESS_TEAM_DOMAIN: "https://team.cloudflareaccess.com.evil.example", ACCESS_AUD: AUD },
      { ACCESS_TEAM_DOMAIN: "http://team.cloudflareaccess.com", ACCESS_AUD: AUD },
      { ACCESS_TEAM_DOMAIN: "https://x@team.cloudflareaccess.com", ACCESS_AUD: AUD },
      { ACCESS_TEAM_DOMAIN: "https://team.cloudflareaccess.com/keys", ACCESS_AUD: AUD },
      { ACCESS_TEAM_DOMAIN: "https://team.cloudflareaccess.com:8443", ACCESS_AUD: AUD },
    ]) {
      assert.equal(accessConfig(bad), null, JSON.stringify(bad));
    }
  });
});

describe("verifyAccessJwt", () => {
  beforeEach(() => clearAccessKeyCache());

  it("accepts a token signed by the team key with the right iss, aud and times", async () => {
    const team = await makeAccessTeam();
    const res = await verifyAccessJwt(await team.userToken(), config, { fetcher: team.fetcher, requireUser: true });
    assert.equal(res.ok, true);
    assert.deepEqual(team.calls, [`${TEAM}/cdn-cgi/access/certs`]);
    // Cached: a second check does not refetch.
    await verifyAccessJwt(await team.userToken(), config, { fetcher: team.fetcher });
    assert.equal(team.calls.length, 1);
  });

  it("accepts a string aud", async () => {
    const team = await makeAccessTeam();
    const res = await verifyAccessJwt(await team.userToken({ aud: AUD }), config, { fetcher: team.fetcher });
    assert.equal(res.ok, true);
  });

  it("rejects a forged header, another key, and tampering", async () => {
    const team = await makeAccessTeam();
    const other = await makeAccessTeam(team.kid);
    const fetcher = team.fetcher;
    const check = async (token: string | null) => {
      const res = await verifyAccessJwt(token, config, { fetcher });
      return res.ok ? "ok" : res.reason;
    };
    assert.equal(await check(null), "missing");
    assert.equal(await check(""), "missing");
    assert.equal(await check("header.payload.signature"), "malformed");
    assert.equal(await check("a.b"), "malformed");
    assert.equal(await check(await other.userToken()), "bad_signature", "same kid, different key");
    const good = await team.userToken();
    const [h, p] = good.split(".");
    const evilPayload = Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(p, "base64url").toString()), email: "x@evil.example" })).toString("base64url");
    assert.equal(await check(`${h}.${evilPayload}.${good.split(".")[2]}`), "bad_signature");
    assert.equal(await check(await team.sign({ iss: TEAM, aud: AUD, exp: 9e9 }, { alg: "none", kid: team.kid })), "malformed");
    assert.equal(await check(await team.sign({ iss: TEAM, aud: AUD, exp: 9e9 }, { alg: "HS256", kid: team.kid })), "malformed");
    assert.equal(await check(await team.sign({ iss: TEAM, aud: AUD, exp: 9e9 }, { alg: "RS256" })), "malformed");
    assert.equal(await check(await team.sign({ iss: TEAM, aud: AUD, exp: 9e9 }, { alg: "RS256", kid: "nope" })), "unknown_key");
  });

  it("checks iss, aud, exp and nbf", async () => {
    const team = await makeAccessTeam();
    const now = Math.floor(Date.now() / 1000);
    const reason = async (over: Record<string, unknown>) => {
      const res = await verifyAccessJwt(await team.userToken(over), config, { fetcher: team.fetcher });
      return res.ok ? "ok" : res.reason;
    };
    assert.equal(await reason({ iss: "https://other.cloudflareaccess.com" }), "bad_claims");
    assert.equal(await reason({ aud: ["another-app"] }), "bad_claims");
    assert.equal(await reason({ aud: undefined }), "bad_claims");
    assert.equal(await reason({ exp: now - 120 }), "bad_claims");
    assert.equal(await reason({ exp: undefined }), "bad_claims");
    assert.equal(await reason({ exp: "9999999999" }), "bad_claims");
    assert.equal(await reason({ nbf: now + 600 }), "bad_claims");
    assert.equal(await reason({ exp: now - 10 }), "ok", "small clock skew is fine");
  });

  it("with requireUser, refuses service tokens", async () => {
    const team = await makeAccessTeam();
    const service = await team.userToken({ email: undefined, sub: "", common_name: "phone.access" });
    const res = await verifyAccessJwt(service, config, { fetcher: team.fetcher, requireUser: true });
    assert.deepEqual(res, { ok: false, reason: "not_user" });
    assert.equal((await verifyAccessJwt(service, config, { fetcher: team.fetcher })).ok, true);
  });

  it("fails closed when the keys cannot be fetched", async () => {
    const team = await makeAccessTeam();
    const down = async () => new Response("down", { status: 502 });
    const res = await verifyAccessJwt(await team.userToken(), config, { fetcher: down });
    assert.deepEqual(res, { ok: false, reason: "keys_unavailable" });
    const throws = async (): Promise<Response> => {
      throw new Error("offline");
    };
    assert.deepEqual(await verifyAccessJwt(await team.userToken(), config, { fetcher: throws }), { ok: false, reason: "keys_unavailable" });
  });

  it("refetches keys for a new kid after a rotation, but not on every request", async () => {
    const first = await makeAccessTeam("k1");
    const second = await makeAccessTeam("k2");
    let current = first;
    let calls = 0;
    const fetcher = async (input: string) => {
      calls += 1;
      return current.fetcher(input);
    };
    const t0 = Date.now();
    assert.equal((await verifyAccessJwt(await first.userToken(), config, { fetcher, now: t0 })).ok, true);
    current = second;
    const rotated = await second.userToken();
    assert.equal((await verifyAccessJwt(rotated, config, { fetcher, now: t0 + 1000 })).ok, false, "too soon to refetch");
    assert.equal(calls, 1);
    assert.equal((await verifyAccessJwt(rotated, config, { fetcher, now: t0 + 31_000 })).ok, true);
    assert.equal(calls, 2);
  });
});

describe("requireAccessUser", () => {
  beforeEach(() => clearAccessKeyCache());

  it("fails closed without config, except plain-http localhost", async () => {
    const none = new Headers();
    const res = await requireAccessUser(none, "https://meetspike.example/api/pair/start", {});
    assert.equal(res.ok, false);
    assert.equal(!res.ok && res.status, 503);
    assert.equal((await requireAccessUser(none, "http://localhost:8787/api/pair/start", {})).ok, true);
    assert.equal((await requireAccessUser(none, "http://127.0.0.1:8787/api/pair/start", {})).ok, true);
    assert.equal((await requireAccessUser(none, "https://localhost.evil.example/api/pair/start", {})).ok, false);
    const forged = new Headers({ "cf-access-jwt-assertion": "header.payload.signature" });
    assert.equal((await requireAccessUser(forged, "https://meetspike.example/api/pair/start", {})).ok, false);
  });

  it("passes a valid user token and rejects a forged one with a generic 403", async () => {
    const team = await makeAccessTeam();
    const ok = await requireAccessUser(
      new Headers({ "cf-access-jwt-assertion": await team.userToken() }),
      "https://meetspike.example/api/pair/start",
      ACCESS_ENV,
      { fetcher: team.fetcher },
    );
    assert.equal(ok.ok, true);
    const bad = await requireAccessUser(
      new Headers({ "cf-access-jwt-assertion": "header.payload.signature" }),
      "https://meetspike.example/api/pair/start",
      ACCESS_ENV,
      { fetcher: team.fetcher },
    );
    assert.equal(bad.ok, false);
    assert.equal(!bad.ok && bad.status, 403);
    assert.doesNotMatch(!bad.ok ? bad.error : "", /malformed|signature|kid/);
  });
});

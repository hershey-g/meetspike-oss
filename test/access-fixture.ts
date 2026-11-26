/**
 * A stand-in Cloudflare Access team for tests: a locally generated RSA key,
 * its JWKS, and signed tokens. Nothing here talks to Cloudflare.
 */
export const TEAM = "https://meetspike-test.cloudflareaccess.com";
export const AUD = "aud-tag-fixture-0123456789abcdef";
export const ACCESS_ENV = { ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: AUD };

function b64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

function b64urlJson(value: unknown): string {
  return b64url(new TextEncoder().encode(JSON.stringify(value)));
}

export type AccessTeam = {
  kid: string;
  jwks: { keys: Array<Record<string, unknown>> };
  sign(payload: Record<string, unknown>, header?: Record<string, unknown>): Promise<string>;
  /** A user token that verifies: right iss and aud, five minutes left. */
  userToken(over?: Record<string, unknown>): Promise<string>;
  fetcher: (input: string) => Promise<Response>;
  calls: string[];
};

export async function makeAccessTeam(kid = "kid-1"): Promise<AccessTeam> {
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const pub = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  const jwks = { keys: [{ kty: "RSA", alg: "RS256", use: "sig", kid, n: pub.n, e: pub.e }] };
  const calls: string[] = [];
  async function sign(payload: Record<string, unknown>, header: Record<string, unknown> = { alg: "RS256", kid, typ: "JWT" }) {
    const input = `${b64urlJson(header)}.${b64urlJson(payload)}`;
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(input));
    return `${input}.${b64url(new Uint8Array(sig))}`;
  }
  return {
    kid,
    jwks,
    sign,
    calls,
    userToken(over = {}) {
      const now = Math.floor(Date.now() / 1000);
      return sign({ iss: TEAM, aud: [AUD], email: "owner@example.com", sub: "user-1", type: "app", iat: now, nbf: now, exp: now + 300, ...over });
    },
    async fetcher(input: string) {
      calls.push(input);
      if (input === `${TEAM}/cdn-cgi/access/certs`) {
        return new Response(JSON.stringify(jwks), { headers: { "content-type": "application/json" } });
      }
      return new Response("not found", { status: 404 });
    },
  };
}

/** Points global fetch at the team's JWKS for code that does not take a fetcher. */
export function useGlobalFetch(team: AccessTeam): () => void {
  const original = globalThis.fetch;
  globalThis.fetch = ((input: RequestInfo | URL) => team.fetcher(String(input instanceof Request ? input.url : input))) as typeof fetch;
  return () => {
    globalThis.fetch = original;
  };
}

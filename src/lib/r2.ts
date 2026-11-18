import type { Env } from "../env.ts";

export async function putRawJson(env: Env, key: string, body: string): Promise<void> {
  await env.RAW.put(key, body, {
    httpMetadata: { contentType: "application/json" },
  });
}

export async function getRawJson(env: Env, key: string): Promise<string | null> {
  const obj = await env.RAW.get(key);
  return obj ? obj.text() : null;
}

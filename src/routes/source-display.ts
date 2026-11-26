import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { Env } from "../env.ts";
import { SOURCE_OURA, SOURCE_WHOOP } from "../types.ts";
import { loadSourceDisplay, setSourceDisplay } from "../lib/source-display.ts";

// The existing Cloudflare Access policy for /api/* authenticates browser
// sessions and native clients using Access service tokens.
export const sourceDisplay = new Hono<{ Bindings: Env }>();

sourceDisplay.use("*", async (c, next) => {
  c.header("Cache-Control", "private, no-store");
  await next();
});

sourceDisplay.get("/", async (c) => c.json(await loadSourceDisplay(c.env)));

sourceDisplay.patch("/", bodyLimit({ maxSize: 256 }), async (c) => {
  if (c.req.header("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
    return c.json({ error: "Use application/json." }, 415);
  }
  const body: unknown = await c.req.json().catch(() => null);
  if (typeof body !== "object" || body === null || Array.isArray(body) || Object.keys(body).length !== 1) {
    return c.json({ error: "Send one source and a boolean." }, 400);
  }
  const [[source, enabled]] = Object.entries(body);
  if ((source !== SOURCE_OURA && source !== SOURCE_WHOOP) || typeof enabled !== "boolean") {
    return c.json({ error: "Set oura or whoop to true or false." }, 400);
  }
  return c.json(await setSourceDisplay(c.env, source, enabled));
});

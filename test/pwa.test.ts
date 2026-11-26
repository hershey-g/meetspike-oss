import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";

// Static checks on public/: the app installs as "Meetspike", and a refresh
// always revalidates app code instead of serving a cached copy.
const pub = new URL("../public/", import.meta.url);
const read = (name: string) => readFileSync(new URL(name, pub), "utf8");

/** Parses public/_headers into path → { header: value }. */
function headerRules(): Map<string, Record<string, string>> {
  const rules = new Map<string, Record<string, string>>();
  let current: Record<string, string> | null = null;
  for (const line of read("_headers").split("\n")) {
    if (!line.trim() || line.trim().startsWith("#")) continue;
    if (!/^\s/.test(line)) {
      current = {};
      rules.set(line.trim(), current);
    } else if (current) {
      const i = line.indexOf(":");
      current[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
    }
  }
  return rules;
}

describe("PWA manifest and icons", () => {
  const manifest = JSON.parse(read("manifest.webmanifest"));

  it("is installable as Meetspike, standalone, dark", () => {
    assert.equal(manifest.name, "Meetspike");
    assert.equal(manifest.short_name, "Meetspike");
    assert.equal(manifest.start_url, "/");
    assert.equal(manifest.display, "standalone");
    assert.equal(manifest.background_color, "#15191e");
    assert.equal(manifest.theme_color, "#15191e");
    assert.match(read("app.css"), /--bg:\s*#15191e/);
  });

  it("lists 192, 512 and maskable 512 PNGs that exist", () => {
    const icons = manifest.icons as { src: string; sizes: string; purpose: string }[];
    const want = ["192x192:any", "512x512:any", "512x512:maskable"];
    for (const w of want) assert.ok(icons.some((i) => `${i.sizes}:${i.purpose}` === w), `missing ${w}`);
    for (const i of icons) {
      assert.match(i.src, /\?v=\d+$/, "icons carry a version so they can be cached long");
      assert.ok(existsSync(new URL(`.${i.src.split("?")[0]}`, pub)), `${i.src} exists`);
    }
    assert.ok(existsSync(new URL("icons/apple-touch-icon.png", pub)));
    assert.ok(existsSync(new URL("favicon.ico", pub)));
  });

  for (const page of ["index.html", "setup.html"]) {
    it(`${page} links the manifest, icons and app meta tags`, () => {
      const html = read(page);
      assert.match(html, /<link rel="manifest" href="\/manifest\.webmanifest" crossorigin="use-credentials"/);
      assert.match(html, /rel="apple-touch-icon" href="\/icons\/apple-touch-icon\.png\?v=\d+"/);
      assert.match(html, /rel="icon" href="\/favicon\.ico\?v=\d+"/);
      assert.match(html, /name="theme-color" content="#15191e"/);
      assert.match(html, /name="apple-mobile-web-app-capable" content="yes"/);
      assert.match(html, /name="apple-mobile-web-app-title" content="Meetspike"/);
      assert.doesNotMatch(html, /dashboard\.css/, "dashboard.css no longer exists");
    });
  }

  for (const page of ["index.html", "setup.html"]) {
    it(`${page} is laid out for the notch / Dynamic Island`, () => {
      const html = read(page);
      assert.match(html, /name="viewport" content="[^"]*viewport-fit=cover/);
      assert.match(html, /name="apple-mobile-web-app-status-bar-style" content="black-translucent"/);
    });
  }
});

describe("service worker", () => {
  const swSrc = read("sw.js");

  it("only the main app registers it, from the root scope, bypassing the HTTP cache", () => {
    const pwa = read("pwa.js");
    assert.match(pwa, /register\("\/sw\.js", \{ scope: "\/", updateViaCache: "none" \}\)/);
    assert.match(read("app.js"), /from "\.\/pwa\.js"/);
    for (const f of ["setup.js", "setup.html"]) assert.doesNotMatch(read(f), /serviceWorker/);
  });

  it("activates new versions at once and drops old caches", () => {
    assert.match(swSrc, /skipWaiting\(\)/);
    assert.match(swSrc, /clients\.claim\(\)/);
    assert.match(swSrc, /const CACHE = `\$\{PREFIX\}\$\{VERSION\}`/);
    assert.match(swSrc, /caches\.delete\(key\)/);
  });

  it("never intercepts the API, OAuth, webhooks or setup", () => {
    const m = /const PASS_THROUGH = (\/.*\/);/.exec(swSrc);
    assert.ok(m, "PASS_THROUGH regex present");
    const re = new Function(`return ${m[1]}`)() as RegExp;
    for (const p of ["/api/view", "/api", "/auth/oura/callback", "/hooks/oura", "/setup", "/setup.js", "/setup.html"]) assert.ok(re.test(p), p);
    for (const p of ["/", "/app.js", "/app.css", "/apis-are-fun"]) assert.equal(re.test(p), false, p);
  });

  it("serves pages and app code network-first", () => {
    assert.match(swSrc, /req\.mode === "navigate"\) \{\s*\/\/[^\n]*\n\s*event\.respondWith\(networkFirst\(/);
    assert.match(swSrc, /SHELL\.includes\(url\.pathname\)\) \{\s*event\.respondWith\(networkFirst\(/);
    for (const f of ["/app.js", "/app.css", "/pwa.js", "/install-gate.js", "/range-presets.js"]) assert.ok(swSrc.includes(`"${f}"`), f);
  });
});

describe("cache headers", () => {
  const rules = headerRules();

  it("app code, pages and the manifest revalidate on every load", () => {
    const paths = ["/", "/index.html", "/setup", "/setup.html", "/setup.js", "/setup.css", "/app.js", "/app.css", "/range-presets.js", "/pwa.js", "/install-gate.js", "/ptr.js", "/ptr-logic.js", "/sw.js", "/manifest.webmanifest"];
    for (const p of paths) {
      const cc = rules.get(p)?.["cache-control"];
      assert.equal(cc, "no-cache", `${p} must be no-cache, got ${cc}`);
    }
  });

  it("nothing uses stale-while-revalidate, and there is no catch-all rule", () => {
    for (const [p, h] of rules) assert.doesNotMatch(h["cache-control"] ?? "", /stale-while-revalidate/, p);
    assert.equal(rules.has("/*"), false);
  });

  it("icons are long-cached", () => {
    assert.match(rules.get("/icons/*")?.["cache-control"] ?? "", /max-age=31536000/);
  });
});

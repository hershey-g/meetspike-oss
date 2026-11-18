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

  it("does not register a service worker", () => {
    for (const f of ["app.js", "setup.js", "index.html", "setup.html"]) {
      assert.doesNotMatch(read(f), /serviceWorker/);
    }
  });
});

describe("cache headers", () => {
  const rules = headerRules();

  it("app code, pages and the manifest revalidate on every load", () => {
    const paths = ["/", "/index.html", "/setup", "/setup.html", "/setup.js", "/setup.css", "/app.js", "/app.css", "/range-presets.js", "/manifest.webmanifest"];
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

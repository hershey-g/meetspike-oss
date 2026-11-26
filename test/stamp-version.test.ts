import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { readVersion, stampSource, versionFor } from "../scripts/stamp-version.mjs";

const root = new URL("../", import.meta.url);
const read = (p: string) => readFileSync(new URL(p, root), "utf8");

describe("deploy version stamp", () => {
  const now = new Date("2026-11-18T15:30:05.123Z");

  it("builds <sha7>-<utc time> from a commit, local-<time> without one", () => {
    assert.equal(versionFor({ sha: "1A2B3C4D5E6F7a8b9c0d\n", now }), "1a2b3c4-20261118T153005Z");
    assert.equal(versionFor({ sha: "", now }), "local-20261118T153005Z");
    assert.equal(versionFor({ sha: "not-a-sha", now }), "local-20261118T153005Z");
  });

  it("rewrites exactly the VERSION line of the committed sw.js", () => {
    const src = read("public/sw.js");
    assert.equal(readVersion(src), "dev", "the committed worker is unstamped");
    const out = stampSource(src, "1a2b3c4-20261118T153005Z");
    assert.equal(readVersion(out), "1a2b3c4-20261118T153005Z");
    assert.notEqual(out, src, "a new version changes the bytes, which is what triggers the update");
    assert.equal(out.split("\n").length, src.split("\n").length);
    assert.equal(stampSource(out, "dev"), src, "stamping is reversible");
  });

  it("refuses unsafe versions and sources without exactly one VERSION line", () => {
    const src = read("public/sw.js");
    assert.throws(() => stampSource(src, 'x"; alert(1); "'), /unsafe/);
    assert.throws(() => stampSource("const X = 1;", "abc"), /exactly one/);
    assert.throws(() => stampSource(`${src}\nconst VERSION = "dev";`, "abc"), /exactly one/);
  });

  it.skip("every deploy path stamps: GitHub Actions and the npm deploy scripts", () => {
    const wf = read(".github/workflows/deploy.yml");
    const stampAt = wf.indexOf("node scripts/stamp-version.mjs");
    const deployAt = wf.indexOf("wrangler deploy -c wrangler.production.jsonc");
    assert.ok(stampAt > 0 && deployAt > stampAt, "deploy.yml stamps before wrangler deploy");
    const scripts = JSON.parse(read("package.json")).scripts;
    assert.match(scripts.deploy, /stamp-version\.mjs -- wrangler deploy/);
    assert.match(scripts["deploy:production"], /stamp-version\.mjs -- wrangler deploy/);
  });
});

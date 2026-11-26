#!/usr/bin/env node
/**
 * Stamps the deploy version into public/sw.js, so every deploy gives the
 * service worker a new byte, the browser installs it, and open or installed
 * copies of Meetspike move to the new code without a reinstall.
 *
 *   node scripts/stamp-version.mjs
 *       Stamp in place and leave it (CI: the checkout is thrown away).
 *   node scripts/stamp-version.mjs -- wrangler deploy [args]
 *       Stamp, run the command, then put sw.js back as it was, so a local
 *       deploy does not leave the working tree dirty. Exits with the
 *       command's exit code.
 *
 * Version: first 7 characters of the commit (GITHUB_SHA in Actions, else
 * `git rev-parse HEAD`) plus the UTC time, e.g. 1a2b3c4-20261118T153000Z.
 * The time part means redeploying the same commit still rolls clients over.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const VERSION_LINE = /^const VERSION = "[^"\n]*";$/m;
const SAFE = /^[A-Za-z0-9._-]{1,64}$/;

/** `<sha7>-<yyyymmddThhmmssZ>`, or `local-<time>` when there is no commit. */
export function versionFor({ sha, now = new Date() } = {}) {
  const t = now.toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  const short = (sha ?? "").trim().toLowerCase().slice(0, 7);
  return /^[0-9a-f]{7}$/.test(short) ? `${short}-${t}` : `local-${t}`;
}

/** Returns sw.js source with VERSION set. Throws if the line is missing or the version is unsafe. */
export function stampSource(src, version) {
  if (!SAFE.test(version)) throw new Error(`Refusing to stamp unsafe version ${JSON.stringify(version)}`);
  const matches = src.match(new RegExp(VERSION_LINE.source, "gm")) ?? [];
  if (matches.length !== 1) throw new Error(`Expected exactly one 'const VERSION = "...";' line in sw.js, found ${matches.length}`);
  return src.replace(VERSION_LINE, `const VERSION = "${version}";`);
}

/** Reads the stamped version back out of sw.js source (null if absent). */
export function readVersion(src) {
  return /^const VERSION = "([^"\n]*)";$/m.exec(src)?.[1] ?? null;
}

function currentSha() {
  if (process.env.GITHUB_SHA) return process.env.GITHUB_SHA;
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return "";
  }
}

function main(argv) {
  const swPath = fileURLToPath(new URL("../public/sw.js", import.meta.url));
  const original = readFileSync(swPath, "utf8");
  const version = versionFor({ sha: currentSha() });
  writeFileSync(swPath, stampSource(original, version));
  console.log(`Stamped public/sw.js with version ${version}`);

  const sep = argv.indexOf("--");
  const cmd = sep === -1 ? [] : argv.slice(sep + 1);
  if (!cmd.length) return 0;
  try {
    const r = spawnSync(cmd[0], cmd.slice(1), { stdio: "inherit", shell: process.platform === "win32" });
    if (r.error) throw r.error;
    return r.status ?? 1;
  } finally {
    writeFileSync(swPath, original);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = main(process.argv.slice(2));
}

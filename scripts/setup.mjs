#!/usr/bin/env node
/**
 * npm run setup — create the Cloudflare pieces Meetspike needs and write their
 * ids into wrangler.production.jsonc, so nobody edits ids by hand.
 *
 * Safe to run again: anything that already exists under the expected name is
 * reused. Nothing is ever deleted. No secret is written anywhere.
 *
 *   npm run setup                       # WHOOP, the default for a new install
 *   npm run setup -- --wearable oura
 *   npm run setup -- --name meetspike   # use your own name instead of the template's
 *   npm run setup -- --dry-run          # show what would happen, change nothing
 */
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  PRODUCTION_FILE,
  TEMPLATE_FILE,
  chooseWearable,
  configWearable,
  fillConfig,
  findD1,
  findKv,
  isAlreadyExists,
  isGitIgnored,
  listHasName,
  parseArgs,
  parseCreatedId,
  parseJsonc,
  planSteps,
  renameWorker,
  resourceNames,
} from "./setup-lib.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const say = (line = "") => console.log(line);

function fail(message) {
  console.error(`\n✗ ${message}`);
  process.exit(1);
}

function wrangler(args, { inherit = false } = {}) {
  const res = spawnSync("npx", ["--no-install", "wrangler", ...args], {
    cwd: root,
    encoding: "utf8",
    stdio: inherit ? "inherit" : ["ignore", "pipe", "pipe"],
    env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
  });
  return { ok: res.status === 0, stdout: res.stdout ?? "", stderr: res.stderr ?? "", status: res.status };
}

function must(result, what) {
  if (!result.ok) fail(`${what} failed.\n${result.stderr || result.stdout}`);
  return result;
}

/** Create unless the list already shows it; a "already exists" answer also counts as there. */
function ensure(label, name, { exists, create }) {
  if (exists()) {
    say(`  ✓ ${label} "${name}" already exists — reusing it`);
    return false;
  }
  const res = create();
  if (res.ok) {
    say(`  + ${label} "${name}" created`);
    return true;
  }
  if (isAlreadyExists(res.stderr + res.stdout)) {
    say(`  ✓ ${label} "${name}" already exists — reusing it`);
    return false;
  }
  return fail(`could not create ${label} "${name}".\n${res.stderr || res.stdout}`);
}

let opts;
try {
  opts = parseArgs(process.argv.slice(2));
} catch (err) {
  fail(err.message);
}

if (opts.help) {
  say(readFileSync(fileURLToPath(import.meta.url), "utf8").split("*/")[0].replace(/^#!.*\n\/\*\*\n?/, "").replace(/^ \* ?/gm, ""));
  process.exit(0);
}

const templatePath = join(root, TEMPLATE_FILE);
const productionPath = join(root, PRODUCTION_FILE);
if (!existsSync(templatePath)) fail(`${TEMPLATE_FILE} is missing. Run this from the project folder.`);

const existingText = existsSync(productionPath) ? readFileSync(productionPath, "utf8") : null;
const templateText = renameWorker(readFileSync(templatePath, "utf8"), opts.name);
const baseText = existingText ?? templateText;
const names = resourceNames(parseJsonc(baseText));

say(`Meetspike setup for the Worker "${names.worker}"`);
say(existingText ? `Found ${PRODUCTION_FILE} — updating it in place.` : `No ${PRODUCTION_FILE} yet — it will be created from ${TEMPLATE_FILE}.`);
say();
for (const step of planSteps(names, opts)) say(`  • ${step}`);
say();

if (opts.dryRun) {
  say("Dry run: nothing was created and no file was written.");
  process.exit(0);
}

if (!isGitIgnored(readFileSync(join(root, ".gitignore"), "utf8"), PRODUCTION_FILE)) {
  fail(`${PRODUCTION_FILE} is not in .gitignore. Add it first so account ids never reach git.`);
}

if (!wrangler(["whoami"]).ok) {
  fail("You are not signed in to Cloudflare. Run:  npx wrangler login   and then run this again.");
}

say("Creating what is missing:");

// D1
let d1Id = findD1(must(wrangler(["d1", "list", "--json"]), "Listing D1 databases").stdout, names.d1);
let createdDatabase = false;
if (d1Id) say(`  ✓ D1 database "${names.d1}" already exists — reusing it`);
else {
  const created = must(wrangler(["d1", "create", names.d1]), `Creating D1 database "${names.d1}"`);
  d1Id = findD1(wrangler(["d1", "list", "--json"]).stdout, names.d1) ?? parseCreatedId(created.stdout);
  if (!d1Id) fail(`created D1 database "${names.d1}" but could not read its id.`);
  createdDatabase = true;
  say(`  + D1 database "${names.d1}" created`);
}

// KV
let kvId = findKv(must(wrangler(["kv", "namespace", "list"]), "Listing KV namespaces").stdout, names.kv, names.worker);
if (kvId) say(`  ✓ KV namespace "${names.kv}" already exists — reusing it`);
else {
  const created = must(wrangler(["kv", "namespace", "create", names.kv]), `Creating KV namespace "${names.kv}"`);
  kvId = findKv(wrangler(["kv", "namespace", "list"]).stdout, names.kv, names.worker) ?? parseCreatedId(created.stdout);
  if (!kvId) fail(`created KV namespace "${names.kv}" but could not read its id.`);
  say(`  + KV namespace "${names.kv}" created`);
}

// R2
ensure("R2 bucket", names.r2, {
  exists: () => listHasName(wrangler(["r2", "bucket", "list"]).stdout, names.r2),
  create: () => wrangler(["r2", "bucket", "create", names.r2]),
});

// Queues
const queueList = wrangler(["queues", "list"]).stdout;
for (const queue of names.queues) {
  ensure("Queue", queue, {
    exists: () => listHasName(queueList, queue),
    create: () => wrangler(["queues", "create", queue]),
  });
}

// Config
const wearable = chooseWearable({ flag: opts.wearable, existingConfigText: existingText, createdDatabase });
const { text, warnings } = fillConfig(baseText, { d1Id, kvId, wearable });
writeFileSync(productionPath, text);
say();
say(`Wrote ${PRODUCTION_FILE} (ids only — no secrets, and git ignores this file).`);
for (const w of warnings) say(`  ! ${w}`);
const active = configWearable(text);
say(
  active
    ? `Wearable: ${active}.`
    : "Wearable: not set in the config. An install that already has Oura keys keeps using Oura; otherwise WHOOP. Pass --wearable to choose.",
);

// Migrations
if (!opts.skipMigrations) {
  say();
  say("Applying database migrations:");
  must(wrangler(["d1", "migrations", "apply", names.d1, "--remote", "-c", PRODUCTION_FILE], { inherit: true }), "Applying migrations");
}

say();
say("Done. Next:");
say("  1. npm run deploy:production");
say("  2. Open the address it prints and add /setup — that page walks you through the rest.");

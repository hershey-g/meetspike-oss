import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
// @ts-expect-error — plain JS module shared with the setup script.
import * as lib from "../scripts/setup-lib.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const template = readFileSync(`${root}wrangler.jsonc`, "utf8");
// Made-up ids in the right shape. Not real resources.
const D1_ID = "11111111-2222-3333-4444-555555555555";
const KV_ID = "aaaaaaaabbbbbbbbccccccccdddddddd";

describe("setup — reading the config", () => {
  it("parses JSONC with comments, trailing commas and // inside strings", () => {
    const parsed = lib.parseJsonc(`{
      // a comment
      "url": "https://example.com/a//b", /* block */
      "list": [1, 2,],
    }`);
    assert.deepEqual(parsed, { url: "https://example.com/a//b", list: [1, 2] });
  });

  it("finds every resource name the template asks for", () => {
    assert.deepEqual(lib.resourceNames(lib.parseJsonc(template)), {
      worker: "meetspike",
      d1: "meetspike-db",
      kv: "meetspike-tokens",
      r2: "meetspike-raw",
      queues: ["meetspike-ingest", "meetspike-ingest-dlq"],
    });
  });

  it("renames every resource with --name, and leaves the template alone without it", () => {
    const renamed = lib.resourceNames(lib.parseJsonc(lib.renameWorker(template, "stressboard")));
    assert.deepEqual(renamed, {
      worker: "stressboard",
      d1: "stressboard-db",
      kv: "stressboard-tokens",
      r2: "stressboard-raw",
      queues: ["stressboard-ingest", "stressboard-ingest-dlq"],
    });
    assert.equal(lib.renameWorker(template, null), template);
    assert.equal(lib.renameWorker(template, "meetspike"), template);
  });

  it("keeps the tracked template free of real ids and of a WEARABLE value", () => {
    const cfg = lib.parseJsonc(template);
    assert.equal(cfg.d1_databases[0].database_id, lib.D1_PLACEHOLDER);
    assert.equal(cfg.kv_namespaces[0].id, lib.KV_PLACEHOLDER);
    assert.equal(lib.configWearable(template), null);
    assert.equal(cfg.routes, undefined);
    assert.equal(template, readFileSync(`${root}wrangler.jsonc.example`, "utf8"));
  });
});

describe("setup — options", () => {
  it("parses flags in both spellings", () => {
    assert.deepEqual(lib.parseArgs([]), { dryRun: false, help: false, wearable: null, name: null, skipMigrations: false });
    assert.equal(lib.parseArgs(["--dry-run"]).dryRun, true);
    assert.equal(lib.parseArgs(["--wearable", "oura"]).wearable, "oura");
    assert.equal(lib.parseArgs(["--wearable=WHOOP"]).wearable, "whoop");
    assert.equal(lib.parseArgs(["--name=stressboard", "--skip-migrations"]).name, "stressboard");
  });

  it("rejects what it does not understand", () => {
    assert.throws(() => lib.parseArgs(["--wearable", "fitbit"]), /--wearable must be one of: whoop, oura/);
    assert.throws(() => lib.parseArgs(["--name", "Has Spaces"]), /lower-case/);
    assert.throws(() => lib.parseArgs(["--delete"]), /unknown option/);
  });
});

describe("setup — reuse what exists (idempotent names)", () => {
  it("finds a D1 database by exact name, through wrangler's banner", () => {
    const out = `
 ⛅️ wrangler 4.x
[
  { "uuid": "${D1_ID}", "name": "meetspike-db", "version": "production" },
  { "uuid": "99999999-0000-0000-0000-000000000000", "name": "meetspike-db-old" }
]`;
    assert.equal(lib.findD1(out, "meetspike-db"), D1_ID);
    assert.equal(lib.findD1(out, "meetspike"), null, "a prefix is not a match");
    assert.equal(lib.findD1("[]", "meetspike-db"), null);
    assert.equal(lib.findD1("not json", "meetspike-db"), null);
  });

  it("finds a KV namespace by title, including the older worker-prefixed title", () => {
    const list = JSON.stringify([
      { id: "ffffffffffffffffffffffffffffffff", title: "someone-elses-tokens" },
      { id: KV_ID, title: "meetspike-tokens" },
    ]);
    assert.equal(lib.findKv(list, "meetspike-tokens", "meetspike"), KV_ID);
    const legacy = JSON.stringify([{ id: KV_ID, title: "meetspike-meetspike-tokens" }]);
    assert.equal(lib.findKv(legacy, "meetspike-tokens", "meetspike"), KV_ID);
    assert.equal(lib.findKv(list, "stressboard-tokens", "stressboard"), null);
  });

  it("matches whole names in text listings, so ingest is not confused with ingest-dlq", () => {
    const queues = `
┌──────────┬──────────────────────────┬───────────┐
│ id       │ name                     │ producers │
├──────────┼──────────────────────────┼───────────┤
│ 0a1b     │ meetspike-ingest-dlq │ 0         │
└──────────┴──────────────────────────┴───────────┘`;
    assert.equal(lib.listHasName(queues, "meetspike-ingest-dlq"), true);
    assert.equal(lib.listHasName(queues, "meetspike-ingest"), false);
    const buckets = "name:           meetspike-raw\ncreation_date:  2026-01-01T00:00:00.000Z\n";
    assert.equal(lib.listHasName(buckets, "meetspike-raw"), true);
    assert.equal(lib.listHasName(buckets, "meetspike"), false);
    assert.equal(lib.listHasName(JSON.stringify([{ name: "meetspike-raw" }]), "meetspike-raw"), true);
    assert.equal(lib.listHasName("", "meetspike-raw"), false);
  });

  it("treats “already exists” from a create as success, and other errors as errors", () => {
    assert.equal(lib.isAlreadyExists("The bucket you tried to create already exists, and you own it. [code: 10004]"), true);
    assert.equal(lib.isAlreadyExists("Queue name is already taken"), true);
    assert.equal(lib.isAlreadyExists("Authentication error [code: 10000]"), false);
    assert.equal(lib.isAlreadyExists(""), false);
  });

  it("reads a new id out of wrangler's create output", () => {
    assert.equal(lib.parseCreatedId(`"database_id": "${D1_ID}"`), D1_ID);
    assert.equal(lib.parseCreatedId(`database_id = "${D1_ID}"`), D1_ID);
    assert.equal(lib.parseCreatedId(`{ "binding": "TOKENS", "id": "${KV_ID}" }`), KV_ID);
    assert.equal(lib.parseCreatedId("nothing here"), null);
  });
});

describe("setup — writing the production config", () => {
  it("fills both ids and the wearable, and keeps the comments", () => {
    const { text, warnings } = lib.fillConfig(template, { d1Id: D1_ID, kvId: KV_ID, wearable: "whoop" });
    const cfg = lib.parseJsonc(text);
    assert.equal(cfg.d1_databases[0].database_id, D1_ID);
    assert.equal(cfg.kv_namespaces[0].id, KV_ID);
    assert.equal(cfg.vars.WEARABLE, "whoop");
    assert.equal(cfg.vars.OURA_SANDBOX, "true");
    assert.deepEqual(warnings, []);
    assert.doesNotMatch(text, /REPLACE_/);
    assert.match(text, /\/\/ Template\./);
    assert.equal(cfg.name, "meetspike");
  });

  it("is a no-op on a second run", () => {
    const first = lib.fillConfig(template, { d1Id: D1_ID, kvId: KV_ID, wearable: "whoop" }).text;
    const second = lib.fillConfig(first, { d1Id: D1_ID, kvId: KV_ID, wearable: null });
    assert.equal(second.text, first);
    assert.deepEqual(second.warnings, []);
  });

  it("never overwrites an id that is already there — it warns instead", () => {
    const first = lib.fillConfig(template, { d1Id: D1_ID, kvId: KV_ID }).text;
    const other = lib.fillConfig(first, { d1Id: "00000000-0000-0000-0000-000000000000", kvId: KV_ID });
    assert.equal(other.text, first);
    assert.equal(other.warnings.length, 1);
    assert.match(other.warnings[0], /Left as it is/);
  });

  it("refuses to write a config that still has no id", () => {
    assert.throws(() => lib.fillConfig(template, { d1Id: "", kvId: KV_ID }), /could not fill/);
  });

  it("sets, replaces and inserts WEARABLE without touching other vars", () => {
    const set = lib.setWearable(template, "oura");
    assert.equal(lib.configWearable(set), "oura");
    assert.equal(lib.parseJsonc(set).vars.OURA_SANDBOX, "true");
    assert.equal(lib.configWearable(lib.setWearable(set, "whoop")), "whoop");
    assert.deepEqual(lib.parseJsonc(lib.setWearable('{ "vars": {} }', "whoop")).vars, { WEARABLE: "whoop" });
    assert.throws(() => lib.setWearable(template, "fitbit"), /unknown wearable/);
  });

  it("defaults a new install to WHOOP but never flips an existing one", () => {
    // Brand-new: we just created the database.
    assert.equal(lib.chooseWearable({ flag: null, existingConfigText: null, createdDatabase: true }), "whoop");
    // Resources were already there (an install being set up again on a new machine): write nothing.
    assert.equal(lib.chooseWearable({ flag: null, existingConfigText: null, createdDatabase: false }), null);
    // A production config already exists: keep what it says.
    assert.equal(lib.chooseWearable({ flag: null, existingConfigText: "{}", createdDatabase: false }), null);
    // An explicit choice always wins.
    assert.equal(lib.chooseWearable({ flag: "oura", existingConfigText: "{}", createdDatabase: false }), "oura");
    assert.equal(lib.chooseWearable({ flag: "oura", existingConfigText: null, createdDatabase: true }), "oura");
  });
});

describe("setup — safety", () => {
  it("has wrangler.production.jsonc in .gitignore", () => {
    const gitignore = readFileSync(`${root}.gitignore`, "utf8");
    assert.equal(lib.isGitIgnored(gitignore, lib.PRODUCTION_FILE), true);
    assert.equal(lib.isGitIgnored("node_modules/\n", lib.PRODUCTION_FILE), false);
  });

  it("plans only creates and reuses — nothing destructive", () => {
    const steps = lib.planSteps(lib.resourceNames(lib.parseJsonc(template)));
    assert.equal(steps.length, 7);
    assert.ok(steps.every((s: string) => !/delete|remove|drop/i.test(s)));
    assert.equal(lib.planSteps(lib.resourceNames(lib.parseJsonc(template)), { skipMigrations: true }).length, 6);
    const script = readFileSync(`${root}scripts/setup.mjs`, "utf8");
    assert.doesNotMatch(script, /"delete"|wrangler delete|secret put|"secret"/);
  });

  it("--dry-run prints the plan, runs nothing and writes no file", () => {
    const before = existsSync(`${root}wrangler.production.jsonc`);
    const out = execFileSync(process.execPath, [`${root}scripts/setup.mjs`, "--dry-run", "--wearable", "oura"], { encoding: "utf8" });
    assert.match(out, /Meetspike setup for the Worker "meetspike"/);
    assert.match(out, /D1 database "meetspike-db": reuse if it exists, otherwise create/);
    assert.match(out, /Dry run: nothing was created and no file was written\./);
    assert.equal(existsSync(`${root}wrangler.production.jsonc`), before);
  });
});

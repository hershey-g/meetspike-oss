/**
 * Pure helpers for `npm run setup`. No file or network access in here, so the
 * tests can exercise the parsing and the "reuse, never delete" name logic
 * without a Cloudflare account.
 */

export const TEMPLATE_FILE = "wrangler.jsonc";
export const PRODUCTION_FILE = "wrangler.production.jsonc";
export const D1_PLACEHOLDER = "REPLACE_D1_DATABASE_ID";
export const KV_PLACEHOLDER = "REPLACE_KV_NAMESPACE_ID";
export const WEARABLES = ["whoop", "oura"];
export const DEFAULT_WEARABLE = "whoop";

/** Remove // and block comments and trailing commas, leaving strings alone. */
export function stripJsonc(text) {
  let out = "";
  let i = 0;
  let inString = false;
  while (i < text.length) {
    const ch = text[i];
    const next = text[i + 1];
    if (inString) {
      out += ch;
      if (ch === "\\") {
        out += next ?? "";
        i += 2;
        continue;
      }
      if (ch === '"') inString = false;
      i += 1;
      continue;
    }
    if (ch === '"') {
      inString = true;
      out += ch;
      i += 1;
      continue;
    }
    if (ch === "/" && next === "/") {
      while (i < text.length && text[i] !== "\n") i += 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end === -1 ? text.length : end + 2;
      continue;
    }
    out += ch;
    i += 1;
  }
  return out.replace(/,(\s*[}\]])/g, "$1");
}

export function parseJsonc(text) {
  return JSON.parse(stripJsonc(text));
}

export function parseArgs(argv) {
  const opts = { dryRun: false, help: false, wearable: null, name: null, skipMigrations: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const value = () => {
      const eq = arg.indexOf("=");
      if (eq !== -1) return arg.slice(eq + 1);
      i += 1;
      return argv[i];
    };
    if (arg === "--dry-run" || arg === "-n") opts.dryRun = true;
    else if (arg === "--help" || arg === "-h") opts.help = true;
    else if (arg === "--skip-migrations") opts.skipMigrations = true;
    else if (arg === "--wearable" || arg.startsWith("--wearable=")) {
      const v = String(value() ?? "").trim().toLowerCase();
      if (!WEARABLES.includes(v)) throw new Error(`--wearable must be one of: ${WEARABLES.join(", ")}`);
      opts.wearable = v;
    } else if (arg === "--name" || arg.startsWith("--name=")) {
      const v = String(value() ?? "").trim();
      if (!/^[a-z0-9][a-z0-9-]{0,50}$/.test(v)) {
        throw new Error("--name must be lower-case letters, numbers and dashes (for example: stressboard)");
      }
      opts.name = v;
    } else throw new Error(`unknown option: ${arg}`);
  }
  return opts;
}

/** Give every resource a new prefix: `--name stressboard` turns meetspike-db into stressboard-db. */
export function renameWorker(templateText, newName) {
  const current = parseJsonc(templateText).name;
  if (!newName || newName === current) return templateText;
  return templateText.split(current).join(newName);
}

/** The resource names a config asks for. The KV namespace has no name in the config, so it follows the Worker. */
export function resourceNames(config) {
  const d1 = config.d1_databases?.[0];
  const kv = config.kv_namespaces?.[0];
  const r2 = config.r2_buckets?.[0];
  if (!config.name || !d1?.database_name || !kv || !r2?.bucket_name) {
    throw new Error("config is missing name, d1_databases, kv_namespaces or r2_buckets");
  }
  const queues = new Set();
  for (const p of config.queues?.producers ?? []) if (p.queue) queues.add(p.queue);
  for (const c of config.queues?.consumers ?? []) {
    if (c.queue) queues.add(c.queue);
    if (c.dead_letter_queue) queues.add(c.dead_letter_queue);
  }
  return {
    worker: config.name,
    d1: d1.database_name,
    kv: `${config.name}-tokens`,
    r2: r2.bucket_name,
    queues: [...queues],
  };
}

/** First JSON array or object in a command's output (wrangler prints banners around it). */
export function extractJson(stdout) {
  const text = String(stdout ?? "");
  const candidates = [text.indexOf("["), text.indexOf("{")].filter((n) => n !== -1).sort((a, b) => a - b);
  for (const start of candidates) {
    const close = text[start] === "[" ? "]" : "}";
    for (let end = text.lastIndexOf(close); end > start; end = text.lastIndexOf(close, end - 1)) {
      try {
        return JSON.parse(text.slice(start, end + 1));
      } catch {
        /* try a shorter slice */
      }
    }
  }
  return null;
}

/** `wrangler d1 list --json` → id of the database with exactly this name, or null. */
export function findD1(stdout, name) {
  const list = extractJson(stdout);
  if (!Array.isArray(list)) return null;
  const hit = list.find((d) => d?.name === name);
  return hit?.uuid ?? hit?.database_id ?? hit?.id ?? null;
}

/**
 * `wrangler kv namespace list` → id of the namespace, or null.
 * Older wrangler prefixed the title with the Worker name, so both spellings count as "already there".
 */
export function findKv(stdout, title, worker) {
  const list = extractJson(stdout);
  if (!Array.isArray(list)) return null;
  const wanted = new Set([title, `${worker}-${title}`]);
  const hit = list.find((n) => wanted.has(n?.title));
  return hit?.id ?? null;
}

/** True when `name` appears in list output as a whole name (not as part of a longer one). */
export function listHasName(stdout, name) {
  const json = extractJson(stdout);
  if (Array.isArray(json)) {
    const names = json.map((x) => x?.name ?? x?.queue_name ?? x?.bucket_name ?? x?.title);
    if (names.some((n) => typeof n === "string")) return names.includes(name);
  }
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|[^A-Za-z0-9_-])${escaped}($|[^A-Za-z0-9_-])`, "m").test(String(stdout ?? ""));
}

/** A create that failed because the thing is already there is a success for a re-run. */
export function isAlreadyExists(output) {
  return /already exists|already taken|already been taken|already in use|is taken|\b(10004|10014|11009|7502)\b/i.test(
    String(output ?? ""),
  );
}

/** Id printed by `wrangler d1 create` / `wrangler kv namespace create`, as a fallback to listing again. */
export function parseCreatedId(stdout) {
  const m =
    /"?database_id"?\s*[:=]\s*"([0-9a-f-]{32,36})"/i.exec(String(stdout ?? "")) ??
    /"?id"?\s*[:=]\s*"([0-9a-f]{32})"/i.exec(String(stdout ?? ""));
  return m ? m[1] : null;
}

export function looksLikeId(value) {
  return typeof value === "string" && /^[0-9a-f-]{32,36}$/i.test(value);
}

/** The WEARABLE value in a config's `vars`, or null. */
export function configWearable(configText) {
  const v = parseJsonc(configText).vars?.WEARABLE;
  return typeof v === "string" && v.trim() ? v.trim().toLowerCase() : null;
}

/** Set or replace `vars.WEARABLE`, keeping every comment and every other line as it was. */
export function setWearable(configText, wearable) {
  if (!WEARABLES.includes(wearable)) throw new Error(`unknown wearable: ${wearable}`);
  if (/"WEARABLE"\s*:\s*"[^"]*"/.test(configText)) {
    return configText.replace(/"WEARABLE"\s*:\s*"[^"]*"/, `"WEARABLE": "${wearable}"`);
  }
  const m = /"vars"\s*:\s*\{/.exec(configText);
  if (!m) throw new Error('config has no "vars" block to put WEARABLE in');
  const at = m.index + m[0].length;
  const rest = configText.slice(at);
  const empty = /^\s*\}/.test(rest);
  return `${configText.slice(0, at)}\n    "WEARABLE": "${wearable}"${empty ? "\n  " : ","}${rest}`;
}

/**
 * Put the real ids into a config. `baseText` is the existing production file
 * on a re-run, otherwise the tracked template. Placeholders are filled; ids
 * that are already there are left alone and reported if they disagree with
 * what the account has.
 */
export function fillConfig(baseText, { d1Id, kvId, wearable = null }) {
  const warnings = [];
  let text = baseText;
  const before = parseJsonc(baseText);
  const haveD1 = before.d1_databases?.[0]?.database_id;
  const haveKv = before.kv_namespaces?.[0]?.id;
  if (haveD1 === D1_PLACEHOLDER) text = text.split(D1_PLACEHOLDER).join(d1Id);
  else if (haveD1 !== d1Id) warnings.push(`database_id is ${haveD1}, but the account's database is ${d1Id}. Left as it is.`);
  if (haveKv === KV_PLACEHOLDER) text = text.split(KV_PLACEHOLDER).join(kvId);
  else if (haveKv !== kvId) warnings.push(`kv namespace id is ${haveKv}, but the account's namespace is ${kvId}. Left as it is.`);
  if (wearable) text = setWearable(text, wearable);
  const after = parseJsonc(text);
  if (!looksLikeId(after.d1_databases?.[0]?.database_id) || !looksLikeId(after.kv_namespaces?.[0]?.id)) {
    throw new Error("could not fill the database or KV id into the config");
  }
  return { text, warnings };
}

/**
 * Which WEARABLE to write, if any.
 * - `--wearable` always wins.
 * - A production config that already exists keeps whatever it says.
 * - A brand-new install (we created the database just now) gets the default.
 * - Resources that were already there with no config on this machine is an
 *   existing install being set up again: write nothing, so it keeps behaving
 *   as it does today.
 */
export function chooseWearable({ flag, existingConfigText, createdDatabase }) {
  if (flag) return flag;
  if (existingConfigText != null) return null;
  return createdDatabase ? DEFAULT_WEARABLE : null;
}

/** True when `file` is covered by a line in .gitignore (exact name or a simple leading-slash form). */
export function isGitIgnored(gitignoreText, file) {
  return String(gitignoreText ?? "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .some((l) => l === file || l === `/${file}`);
}

/** What a run would do, in order, for --dry-run and for the opening summary. */
export function planSteps(names, { skipMigrations = false } = {}) {
  const steps = [
    `D1 database "${names.d1}": reuse if it exists, otherwise create`,
    `KV namespace "${names.kv}": reuse if it exists, otherwise create`,
    `R2 bucket "${names.r2}": reuse if it exists, otherwise create`,
    ...names.queues.map((q) => `Queue "${q}": reuse if it exists, otherwise create`),
    `Write the ids into ${PRODUCTION_FILE} (not tracked by git)`,
  ];
  if (!skipMigrations) steps.push(`Apply database migrations to "${names.d1}"`);
  return steps;
}

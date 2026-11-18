# Meetspike

Which meetings cost you — and which people keep showing up when they do.

Meetspike is a small app you run yourself, on your own Cloudflare account. It joins your **Google Calendar** with your wearable — a **WHOOP** band or an **Oura ring** — and shows, day by day, what your meetings did to your recovery, sleep and strain. It is built for a phone first and installs on your home screen like an app. Your data stays in your account; nobody else can see it, including the people who wrote this.

How it fits together, for developers: [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md).

---

## For AI agents

If you are a coding agent (Claude Code, Codex, Cursor, …) asked to set this up, this file is everything you need. Do this, in order:

1. **Ask the human for these things first.** You cannot create them yourself.
   - A **Cloudflare account on the Workers Paid plan**, and a way to sign in to it from this machine (`npx wrangler login` in their browser, or a `CLOUDFLARE_API_TOKEN` in the environment). If the account is on the Free plan, stop and say so — Queues and Workflows need Paid.
   - **Which wearable: `whoop` or `oura`.** One is active at a time. See [Choosing WHOOP or Oura](#choosing-whoop-or-oura).
   - A **wearable developer app** (Oura *or* WHOOP) — they create it and give you its Client ID and Client Secret. See [step 6](#6-create-the-wearable-developer-app).
   - A **Google OAuth client** (type *Web application*) — Client ID and Client Secret. See [step 7](#7-create-the-google-oauth-client).
2. Run [steps 1–5](#set-it-up-step-by-step) (install, sign in, create resources, deploy). That gives you the app's address, which the human needs for the redirect URLs in steps 6 and 7.
3. Tell the human the exact redirect URLs ([step 6](#6-create-the-wearable-developer-app), [step 7](#7-create-the-google-oauth-client)) and wait for the keys.
4. Store the keys with `wrangler secret put` ([step 8](#8-store-the-keys-as-secrets)). Pipe values in from stdin; never write them to a file in this repo and never echo them back. Also generate and store `AI_KEY_SECRET` yourself (`openssl rand -base64 32 | npx wrangler secret put AI_KEY_SECRET -c wrangler.production.jsonc`) so "Ask your data" can be turned on; the human pastes their own Claude API key into the app later, never into the terminal.
5. The human must click through the two sign-in pages themselves ([step 9](#9-connect-the-accounts)). Then run the first import ([step 10](#10-bring-in-your-data)).
6. Recommend [step 11](#11-lock-the-door-with-cloudflare-access-recommended) (Cloudflare Access). Until it is done, anyone with the address can open the dashboard.
7. Tell the human how to [install the app on their phone](#install-it-on-your-phone) and, if they want it, how to [turn on Ask your data](#ask-your-data-optional).

Rules:

- **Never commit secrets.** Not `.dev.vars`, not `wrangler.production.jsonc`, not a Client Secret, not an API token. `wrangler.jsonc` in git keeps its `REPLACE_…` placeholders forever.
- Only create or change the resources named in this file (all prefixed with the Worker name, `meetspike-` by default). Do not touch, rename or delete anything else in the account, and never run `wrangler delete`.
- Do not create DNS records or add `routes` to the config. The app deploys to `workers.dev`.
- If something about the existing account is unclear (a resource with the same name that you did not create, for example), stop and ask.
- Check your work with `npm run typecheck` and `npm test` if you changed any code.

---

## What you need

- A **Cloudflare account** on the [Workers Paid plan](https://developers.cloudflare.com/workers/platform/pricing/) (about $5 a month). Queues and Workflows need it.
- A **WHOOP** band with an active membership, or an **Oura ring** with an active **Oura Membership**. See [Choosing WHOOP or Oura](#choosing-whoop-or-oura).
- A **Google account** whose primary calendar holds your meetings.
- [Node.js](https://nodejs.org) 22 or newer and `git` (not needed for the one-button route).
- Optional, for "Ask your data": a [Claude API key](https://console.anthropic.com/) from Anthropic. You pay Anthropic directly for what you ask.
- About 15 minutes.

## Two ways to set it up

**One button.** If this repository is public on GitHub, Cloudflare can copy and deploy it for you. If you forked it, use your fork's path instead of `hershey-g/meetspike-oss`:

```
https://deploy.workers.cloudflare.com/?url=https://github.com/hershey-g/meetspike-oss
```

Sign in, accept the suggested names, leave the key fields empty, and press **Create and deploy**. Cloudflare creates the Worker, database, storage and queues and applies the database migrations. Then open `https://<your-app-address>/setup` and continue from [step 6](#6-create-the-wearable-developer-app) below — the setup page walks through the same steps.

**Step by step**, below. This is the route to give an agent.

## Set it up, step by step

Throughout, `https://<your-app-address>` means the address Cloudflare gives your Worker, for example `https://meetspike.<your-subdomain>.workers.dev`.

### 1. Get the code and install

```bash
git clone https://github.com/hershey-g/meetspike-oss.git meetspike
cd meetspike
npm ci
```

### 2. Sign in to Cloudflare

```bash
npx wrangler login
npx wrangler whoami
```

`login` opens a browser. On a machine without one, create an API token instead (Cloudflare dashboard → My Profile → API Tokens) with edit rights on **Workers Scripts, D1, Workers R2 Storage, Workers KV Storage, Queues** and export it as `CLOUDFLARE_API_TOKEN` together with `CLOUDFLARE_ACCOUNT_ID`. Do not use a Global API key.

### 3. Create the Cloudflare resources

The app needs:

| Resource | Default name | Binding |
| --- | --- | --- |
| D1 database | `meetspike-db` | `DB` |
| R2 bucket | `meetspike-raw` | `RAW` |
| KV namespace | `meetspike-tokens` | `TOKENS` |
| Queue | `meetspike-ingest` | `INGEST_Q` |
| Dead-letter queue | `meetspike-ingest-dlq` | — |
| Workflow | `meetspike-backfill` | `BACKFILL` |
| Workflow (nightly, 11:00 UTC) | `meetspike-reconcile` | `RECONCILE` |

**The easy way** — one command creates all of it and applies the database migrations:

```bash
npm run setup -- --wearable whoop    # or: --wearable oura   (default: whoop)
```

It writes the real ids into `wrangler.production.jsonc` (git ignores that file) and sets `WEARABLE` there. It is safe to run again: anything that already exists under the expected name is reused, and nothing is ever deleted. Other flags: `--dry-run` shows what it would do and changes nothing; `--name stressboard` uses your own prefix instead of `meetspike`; `--skip-migrations` leaves the database alone. If you use this, skip to [step 5](#5-deploy).

**By hand** — the same thing, command by command:

```bash
cp wrangler.jsonc wrangler.production.jsonc

npx wrangler d1 create meetspike-db                 # prints a database_id
npx wrangler kv namespace create meetspike-tokens   # prints an id
npx wrangler r2 bucket create meetspike-raw
npx wrangler queues create meetspike-ingest
npx wrangler queues create meetspike-ingest-dlq
```

Then edit `wrangler.production.jsonc` (never `wrangler.jsonc`):

- replace `REPLACE_D1_DATABASE_ID` with the D1 `database_id`;
- replace `REPLACE_KV_NAMESPACE_ID` with the KV `id`;
- under `"vars"`, add `"WEARABLE": "oura"` or `"WEARABLE": "whoop"`.

The two Workflows are not created separately; `wrangler deploy` creates them from the config. `wrangler.jsonc.example` is a spare copy of the template.

### 4. Apply the database migrations

`npm run setup` already did this. By hand:

```bash
npx wrangler d1 migrations apply meetspike-db --remote -c wrangler.production.jsonc
```

Run the same command again after you pull a release that adds a file to `migrations/`.

### 5. Deploy

```bash
npm run deploy:production
```

It prints the app's address. Open `https://<your-app-address>/setup` — the setup page shows the exact redirect URLs, which keys are still missing (never their values), and has buttons for the remaining steps. Everything below can be done from that page or from a terminal.

**The app has no sign-in of its own.** Until you finish [step 11](#11-lock-the-door-with-cloudflare-access-recommended), anyone who knows the address can open it. Do step 11 before you import real data if that matters to you.

### 6. Create the wearable developer app

Create one — whichever wearable you chose. Both are free.

**Oura**

1. Go to <https://cloud.ouraring.com/oauth/applications> and create an application.
2. Redirect URI, exactly: `https://<your-app-address>/auth/oura/callback`
3. Copy the **Client ID** and **Client Secret**.

Scopes the app asks for: `email personal daily heartrate workout session tag`.

**WHOOP**

1. Go to <https://developer-dashboard.whoop.com/apps/create> and create an app.
2. Redirect URL, exactly: `https://<your-app-address>/api/whoop/callback`
3. Scopes: `read:recovery read:cycles read:sleep read:workout read:profile read:body_measurement offline`
4. Copy the **Client ID** and **Client Secret**.

### 7. Create the Google OAuth client

1. In the [Google Cloud console](https://console.cloud.google.com/), create (or pick) a project and enable the **Google Calendar API**.
2. Configure the OAuth consent screen. While it is in *Testing*, add your own Google address as a test user.
3. Credentials → **Create credentials** → **OAuth client ID** → type **Web application**.
4. Authorized redirect URI, exactly: `https://<your-app-address>/auth/google/callback`
5. Copy the **Client ID** and **Client Secret**.

Meetspike asks for one scope, `calendar.readonly`. It can read your calendar and nothing else.

### 8. Store the keys as secrets

Each command asks you to paste the value. Add `-c wrangler.production.jsonc` to every command, as shown.

```bash
# Google — always
npx wrangler secret put GOOGLE_CLIENT_ID     -c wrangler.production.jsonc
npx wrangler secret put GOOGLE_CLIENT_SECRET -c wrangler.production.jsonc

# WHOOP
npx wrangler secret put WHOOP_CLIENT_ID      -c wrangler.production.jsonc
npx wrangler secret put WHOOP_CLIENT_SECRET  -c wrangler.production.jsonc

# or Oura
npx wrangler secret put OURA_CLIENT_ID       -c wrangler.production.jsonc
npx wrangler secret put OURA_CLIENT_SECRET   -c wrangler.production.jsonc

# Ask your data (optional) — a random value, nobody needs to know it
openssl rand -base64 32 | npx wrangler secret put AI_KEY_SECRET -c wrangler.production.jsonc
```

You can also add them in the Cloudflare dashboard: Workers & Pages → your Worker → Settings → Variables and Secrets → Add → type **Secret**.

Every setting the code reads:

| Name | Needed | What it is |
| --- | --- | --- |
| `WEARABLE` | yes | `oura` or `whoop`. Normally a plain value under `"vars"` in `wrangler.production.jsonc`. |
| `GOOGLE_CLIENT_ID` | yes | Google OAuth client ID. |
| `GOOGLE_CLIENT_SECRET` | yes | Google OAuth client secret. |
| `OURA_CLIENT_ID` | Oura | Oura application client ID. |
| `OURA_CLIENT_SECRET` | Oura | Oura application client secret. Also the key that verifies Oura webhooks. |
| `WHOOP_CLIENT_ID` | WHOOP | WHOOP app client ID. |
| `WHOOP_CLIENT_SECRET` | WHOOP | WHOOP app client secret. |
| `OURA_SANDBOX` | Oura | Plain value under `"vars"`. The template ships `"true"`, which reads Oura's sample data. Set it to `"false"` for your own data. |
| `GOOGLE_REDIRECT_URI` | no | Override. Defaults to `<your-app-address>/auth/google/callback`. |
| `OURA_REDIRECT_URI` | no | Override. Defaults to `<your-app-address>/auth/oura/callback`. |
| `WHOOP_REDIRECT_URI` | no | Override. Defaults to `<your-app-address>/api/whoop/callback`. |
| `AI_KEY_SECRET` | for Ask | 32+ random characters (`openssl rand -base64 32`). Encrypts your Claude API key at rest. Without it, everything else works and Ask says what is missing. Changing it later makes a saved Claude key unreadable; paste the key again. |
| `DISPLAY_TITLE` | no | Your own title for the dashboard. Default: Meetspike. |
| `INGEST_ADMIN_SECRET` | no | Only for the optional Plaud ingest — see [PLAUD.md](./PLAUD.md). |

Bindings the code also reads, all created in [step 3](#3-create-the-cloudflare-resources): `DB` (D1), `RAW` (R2), `TOKENS` (KV), `INGEST_Q` (Queue), `BACKFILL` and `RECONCILE` (Workflows), `ASSETS` (the static app in `public/`). Your Claude API key is not a Worker secret: you paste it into the app (More → AI key, or the Ask screen) and it is stored encrypted in KV.

You normally do not need the redirect overrides. Without them each redirect is built from the address the sign-in started on, so the app works on its `workers.dev` address and on any custom domain at the same time. Setting one pins every sign-in to that single address.

About `WEARABLE`: set it in one place only. Cloudflare refuses a deploy where the same name is both a secret and a config value. If it is not set at all, an install that has Oura keys and no WHOOP keys uses Oura, and anything else uses WHOOP.

**Oura users:** open `wrangler.production.jsonc`, change `"OURA_SANDBOX": "true"` to `"false"`, and run `npm run deploy:production` again. Otherwise you will see Oura's sample data instead of your own.

### 9. Connect the accounts

A person has to do this in a browser — these are sign-in pages. Either press the **Connect** buttons on `https://<your-app-address>/setup`, or open:

- Oura: `https://<your-app-address>/auth/oura/start`
- WHOOP: `https://<your-app-address>/auth/whoop/start`
- Google: `https://<your-app-address>/auth/google/start`

Approve each one. You are sent back to the app, and the tokens are stored in your KV namespace (`whoop:tokens` or `oura:tokens`, and `google:tokens`).

### 10. Bring in your data

On the setup page, press **Import my last 30 days**. Or from a terminal:

```bash
APP=https://<your-app-address>

# wearable: the last 30 days
curl -X POST "$APP/api/backfill" -H 'content-type: application/json' -d '{"mode":"production"}'

# calendar: the last 30 days
curl -X POST "$APP/api/calendar/sync" -H 'content-type: application/json' \
  -d "{\"mode\":\"live\",\"startDay\":\"$(date -d '-30 days' +%F)\"}"
```

The wearable import runs in the background as a Workflow and takes a minute or two. Both calls accept `"startDay"` and `"endDay"` (`YYYY-MM-DD`) for a different range; without them the wearable import covers 30 days and the calendar sync 14. (On macOS use `date -v-30d +%F`.) After this, the app refreshes the last 7 days by itself every night at 11:00 UTC.

Want to look around before connecting anything? Sample data works with no keys at all:

```bash
curl -X POST "$APP/api/backfill"      -H 'content-type: application/json' -d '{"mode":"fixtures"}'
curl -X POST "$APP/api/calendar/sync" -H 'content-type: application/json' -d '{"mode":"fixtures"}'
```

Then open `https://<your-app-address>/`. `GET /api/health` shows what is connected and which wearable is active.

(Once Cloudflare Access is on, `curl` from a terminal is blocked like everyone else — use the setup page, or an Access service token.)

### 11. Lock the door with Cloudflare Access (recommended)

Cloudflare Access puts a sign-in in front of the app. It is free for personal use. In [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → Access → Applications → Add an application → Self-hosted:

1. **One application for the whole app.** Domain: `<your-app-address>` with an empty path. Policy: **Allow**, include your own email address.
2. **One application for each path that must stay open**, each with the policy **Bypass → Everyone**. Other services call these addresses and cannot sign in. The most specific path wins, so these override the first application.

   | Path | Why it must bypass |
   | --- | --- |
   | `/auth/google/callback` | Google sends you back here after sign-in. |
   | `/auth/oura/callback` | Oura sends you back here. |
   | `/api/whoop/callback` | WHOOP sends you back here. |
   | `/hooks/*` | Oura webhooks. The request signature is the check. |
   | `/api/plaud/*` | Only if you use the [Plaud ingest](./PLAUD.md). The admin secret is the check. |
   | `/manifest.webmanifest`, `/icons/*`, `/favicon.ico` | Optional, recommended: lets phones install the app. These hold the app's name and icon, no data. |

   You only need the callback of the wearable you use. `/api/whoop/callback` sits under the protected `/` and `/api/*`, so it needs its own Bypass application with that exact path.

Check it: in a private window, `https://<your-app-address>/api/health` should ask you to sign in, and `https://<your-app-address>/hooks/oura` should answer without one.

### 12. Deploy on merge with GitHub Actions (optional)

Two workflows ship in `.github/workflows/`:

- `tests.yml` runs the type check and the tests on every pull request. It needs no secrets.
- `deploy.yml` runs them again on every push to `main`, then deploys.

`deploy.yml` needs three repository secrets (GitHub → Settings → Secrets and variables → Actions):

| Secret | What it is |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | A token limited to what this app uses: Workers Scripts, D1, R2, KV, Queues. Not a Global API key. |
| `CLOUDFLARE_ACCOUNT_ID` | The account the Worker lives in. |
| `WRANGLER_PRODUCTION_CONFIG` | The whole text of your `wrangler.production.jsonc`. |

The config is written to disk for that run only and is never committed. The workflow does not apply database migrations; when a release adds one, run the command in [step 4](#4-apply-the-database-migrations) yourself. If you do not want automatic deploys, delete `deploy.yml` or leave the secrets unset (the deploy job then fails without changing anything).

## What you see

A phone-first app with four tabs and an **Ask** button.

- **Today.** Three rings (recovery, sleep and strain on WHOOP; readiness, sleep and meeting hours on Oura), the day's meetings on a timeline, what a day like this usually costs you the next morning, and today's numbers against your usual (median of the last 28 days). Step a day with `‹` `›`, or tap the date to pick one.
- **Dates.** Pick any two dates (up to 92 days) on a calendar, or a quick pick: Today, Yesterday, Last 7 days, Last 30 days, This month, Last month. It compares next-morning recovery after heavy days (4+ hours or 5+ meetings) with lighter days, charts both, and lists the days that cost you and the people on them.
- **People.** Everyone you met in the last 28 days, with how you woke up the morning after. Tap one for 60 days of meetings with them.
- **More.** Sync calendar, connections, your Claude key, the setup guide and a privacy note.
- **Ask your data.** Chat about your meetings and recovery (see below).

With an **Oura ring**, each meeting also carries Elevated / Worth watching / Restored from your heart rate inside the meeting, with a graph when you tap it, and there is a "Meetings that spiked" list. **WHOOP** does not share heart rate during the day, so on WHOOP the app works from daily recovery, sleep and strain and says so; it never invents a per-meeting reading.

Work on day **D** is joined to your sleep and recovery on the morning of **D+1**: the night after the work. "After hours" means a meeting that started at 18:00 or later. [METRICS.md](./METRICS.md) defines every number.

## Choosing WHOOP or Oura

One setting, `WEARABLE`, picks the wearable: `whoop` or `oura`.

| | WHOOP | Oura |
| --- | --- | --- |
| Daily recovery / readiness, sleep, HRV, resting HR | yes | yes |
| Daily strain | yes | no (meeting hours instead) |
| Heart rate inside each meeting | no — WHOOP's API has no intraday heart rate | yes |
| Sample data with no account | `"mode": "fixtures"` | `"fixtures"`, or Oura's sandbox with `OURA_SANDBOX=true` |
| Developer app | [developer-dashboard.whoop.com](https://developer-dashboard.whoop.com/apps/create) | [cloud.ouraring.com/oauth/applications](https://cloud.ouraring.com/oauth/applications) |
| Callback path | `/api/whoop/callback` | `/auth/oura/callback` |

- `npm run setup` writes `"WEARABLE": "whoop"` (or `oura` with `--wearable oura`) into `wrangler.production.jsonc`.
- If `WEARABLE` is not set, an install with Oura keys and no WHOOP keys uses Oura; anything else uses WHOOP.
- To switch, change it in one place only — under `"vars"` in `wrangler.production.jsonc` and deploy again, or as a secret (`npx wrangler secret put WEARABLE`), or in `.dev.vars` locally. Cloudflare refuses a deploy where the same name is both a secret and a plain value.
- Both wearables' data can sit in the same database; the setting only chooses which one the app shows. WHOOP needs `migrations/0008_daily_strain.sql`, which step 4 applies.

## Install it on your phone

Meetspike is an installable web app (a PWA) with its own name and icon.

- **iPhone / iPad:** open the app's address in Safari → Share → **Add to Home Screen**.
- **Android:** open it in Chrome → menu → **Install app** (or **Add to Home screen**).
- **Desktop Chrome / Edge:** the install icon in the address bar.

It opens full-screen, without browser bars. If Cloudflare Access is on, sign in once in the browser first, and add the optional bypass for `/manifest.webmanifest`, `/icons/*` and `/favicon.ico` in [step 11](#11-lock-the-door-with-cloudflare-access-recommended) so the phone can fetch the icon.

There is no offline mode and no service worker on purpose: every launch and every refresh loads the newest version you deployed. `public/_headers` tells the browser to revalidate the app's code each time (`Cache-Control: no-cache`), and the screen cache in the page is refetched on every full load. Icons are long-cached; they come from one SVG design in `scripts/build-icons.mjs` (`npm run icons` regenerates the committed PNGs).

## Ask your data (optional)

Ask questions in plain words — "which meetings cost me the most sleep this month?" — and Claude answers from your own numbers. It uses **your own Claude API key**, so you pay Anthropic directly and nothing goes through anyone else.

1. Make sure the Worker has `AI_KEY_SECRET` ([step 8](#8-store-the-keys-as-secrets)).
2. In the app, open **Ask** (or **More → AI key**) and paste your key (`sk-ant-…`). The Worker checks it with Anthropic once, then stores it encrypted (AES-GCM) in KV. Only its last four characters ever reach the browser. **Remove** deletes it.
3. Ask. Questions use the selected date range, or the last 60 days.

What is sent to Anthropic with each question: one line per day in the range — date, your morning scores (recovery or readiness, sleep, HRV, resting heart rate, strain on WHOOP), next-morning scores, meeting count and hours — and under it each meeting's local start time, title, kind, length and up to six attendee names (the part of the email before `@` when there is no name). Plus your question and the last few turns of the chat. **Not** sent: email addresses, calendar descriptions, locations, raw wearable data, heart-rate samples, Plaud transcripts or audio. The model is set in `src/routes/ask.ts` (`ASK_MODEL`). Chat history stays in the browser tab.

## Limits

- **WHOOP gives daily data only.** WHOOP's API does not share minute-by-minute heart rate, so with WHOOP there is no in-meeting heart rate, no per-meeting Elevated/Restored reading, and no “often spikes you” badge for a person. You get recovery, strain and sleep per day next to your meeting load.
- **Oura needs an active Oura Membership.** Without one, Oura's API refuses data requests (a `403`), and Meetspike has nothing to show.
- **One wearable at a time**, chosen by `WEARABLE`. Both wearables' data can sit in the same database; the setting chooses which one the dashboard shows.
- **One person per install.** There are no user accounts. Access control is Cloudflare Access in front of the whole app.
- **Days are counted in `America/New_York`** unless your Oura profile reports a different timezone (Oura installs use the profile's). It is not yet a setting: the zone is fixed in `src/lib/time.ts` (`IANA_FALLBACK`), `public/app.js` (`TZ`) and a few default arguments. Meetings elsewhere still appear, but day boundaries and "after hours" use that zone. See [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md#time-zone) for what changing it involves.
- **Primary Google calendar only**, read-only.
- People are identified by attendee **email**. Private events and events without attendees have nobody to show.
- Heart-rate coverage can be missing (ring off, charging). Meetspike says so instead of guessing.
- Oura webhooks are implemented (`/hooks/oura`) but nothing registers a subscription for you; the nightly refresh does the work.
- Optional: phone calls recorded with a Plaud device can appear beside calendar meetings. See [PLAUD.md](./PLAUD.md). The app never holds a Plaud token and never stores transcripts or audio.

## How it is built

| Piece | Role |
| --- | --- |
| Worker (Hono) | The API, the OAuth flows and the static phone app in `public/` |
| R2 | Append-only archive of the raw wearable and calendar JSON, including Oura heart-rate samples |
| D1 | The queryable projection: daily scores, events, attendees |
| KV | OAuth tokens (`oura:tokens`, `whoop:tokens`, `google:tokens`), the encrypted Claude key (`ai:anthropic`), short-lived sign-in state |
| Queue + Workflows | Oura webhook ingest, the 30-day backfill, and the nightly 7-day reconcile |
| Anthropic API | Only for Ask, only with your key |

More detail, including a diagram: [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md).

### API

All under the same address, all JSON.

- `GET /api/view?date=` or `?start=&end=` — everything one screen needs in one request (briefing, your usual, heavy-day comparison, costliest days and people, per-day series, connection status, Oura meeting hits)
- `GET /api/ask/status`, `PUT /api/ask/key` `{ "key": "sk-ant-…" }`, `DELETE /api/ask/key`, `POST /api/ask` `{ "question", "start?", "end?", "history?" }` — Ask your data
- `GET /api/health` — what is connected; includes `wearable`
- `GET /api/setup/status` — what the setup page shows (which keys exist, never their values)
- `POST /api/backfill` — `{ "mode": "fixtures" | "production" }`; Oura also takes `"sandbox"`. Optional `startDay`, `endDay`.
- `POST /api/calendar/sync` — `{ "mode": "fixtures" | "live" }`
- `POST /api/reconcile` — run the nightly refresh now
- `GET /api/insights/hits?days=28` — meetings ranked by in-meeting heart rate (`?start=&end=` also accepted)
- `GET /api/briefing/day?date=YYYY-MM-DD`, `GET /api/briefing/week?date=`, `GET /api/briefing/range?start=&end=`
- `GET /api/people/:email/meetings?days=60`, `GET /api/meetings/by-attendee?email=`
- `GET /api/meetings/stressed`, `GET /api/meetings/sleep-impact`, `GET /api/metrics/daily?start=&end=`, `GET /api/sleep`
- `GET /auth/{whoop,oura,google}/start` → provider → `/api/whoop/callback`, `/auth/oura/callback`, `/auth/google/callback`
- `GET|POST /hooks/oura` — Oura webhook challenge and events (HMAC-checked)
- `POST /api/plaud/ingest` — optional, see [PLAUD.md](./PLAUD.md)

Date ranges are inclusive local days, at most 92. A bad range is a `400` with the reason in `error`.

### Local development

```bash
npm ci
cp .dev.vars.example .dev.vars     # git ignores .dev.vars; put local keys there
npx wrangler d1 migrations apply meetspike-db --local
npm run dev                        # http://localhost:8787
npm run typecheck
npm test
```

Under `wrangler dev` the redirect URLs are `http://localhost:8787/auth/oura/callback` and so on; register those on your developer apps if you want to sign in locally.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](./CONTRIBUTING.md). [AGENTS.md](./AGENTS.md) has the short rules for coding agents working on the code.

## Security

To report a vulnerability, follow [SECURITY.md](./SECURITY.md). Please do not open a public issue that contains tokens, calendar contents or heart-rate data.

## License

MIT — see [LICENSE](./LICENSE).

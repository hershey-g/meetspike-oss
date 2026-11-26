# Meetspike

Which meetings cost you, and which people keep showing up when they do.

Meetspike is a small app you run yourself, on your own Cloudflare account. It joins your **Google Calendar** with your wearable, **WHOOP** or an **Oura ring**, and shows, day by day, what your meetings did to you. Your data stays in your account. Nobody else can see it, including the people who wrote this.

- **On an iPhone?** Start with the [iPhone walkthrough](docs/IPHONE-ONBOARDING.md), from install to your first heart rate.
- **What changed, and when:** [CHANGELOG.md](CHANGELOG.md).

What you see depends on the wearable, because the two share different things:

- **WHOOP** shares daily recovery, strain, sleep, and workouts through its developer API. Each day shows recovery and strain next to your meeting load, and days are ranked by the night that followed. WHOOP's API has no live heart rate and no heart rate recordings, so for WHOOP only, meeting heart rate comes from the strap over Bluetooth (see below).
- **Oura** includes heart rate through the day in its own API, so Meetspike reads meeting heart rate straight from Oura once the ring syncs with the Oura app. No extra app or Bluetooth setup. Meetspike shows a heart-rate strip for each meeting and says, in words, what happened.

## How WHOOP works

Meetspike reads WHOOP through WHOOP's official developer API (v2), with your permission:

1. **Connect once.** You sign in to WHOOP from the setup page (OAuth). Meetspike keeps the tokens in your own Cloudflare account and renews them on its own.
2. **Scores arrive when WHOOP scores them.** WHOOP sends a signed webhook to `/hooks/whoop` when a sleep, recovery or workout is scored or changed. Meetspike checks the signature and pulls the new numbers right away.
3. **A 15-minute check as backup.** Every 15 minutes Meetspike also re-reads yesterday and today, so nothing is missed if a webhook is late. This is also how the day's strain stays current, because WHOOP has no webhook for strain. Pulling down to refresh in the app runs the same check.
4. **A nightly check** re-reads the last 7 days to catch late edits.

**Heart rate during meetings (WHOOP only).** WHOOP's official API does not provide live heart rate or heart rate recordings, only daily summaries (recovery, sleep, strain, average and max heart rate for the day). WHOOP's app does have a minute-by-minute graph and Stress Monitor, but WHOOP keeps those to its own app, and WHOOP's terms do not allow using its private app endpoints. This build does not include any WHOOP private-API code, so meeting heart rate comes from Bluetooth. One setting is shared: Bluetooth heart rate needs `WHOOP_WEB_HR` set to `enabled` on the Worker, because the same flag turns on heart-rate storage. That flag alone, with no WHOOP login saved, uses only Bluetooth.

So meeting heart rate comes straight from the strap instead. Turn on **HR Broadcast** in the WHOOP app and the strap acts as a standard Bluetooth heart rate sensor. [Meetspike HR for Mac](mac/MeetspikeHR/README.md) and [Meetspike HR for iPhone](ios/README.md) listen around events from Apple Calendar. They send live readings about every five seconds and replay recorded data for meeting history. On iPhone, turn on the broadcast in WHOOP, then connect in the Meetspike app before locking the phone. Bluetooth supplies heart rate only.

**Setting up heart rate on your Mac.** Your strap stays connected to the WHOOP app on your iPhone. The Mac just listens to the strap's HR Broadcast, so there is nothing to pair. The first time you open MeetspikeHR, a setup guide walks you through this and shows live status for each step. It comes back at each launch until the first heart rate arrives, and you can reopen it from Settings.

1. **Wear the strap.**
2. **Turn on HR Broadcast** in the WHOOP app on your phone: **Menu → Device Settings → HR Broadcast**. It can turn itself off after a WHOOP firmware update, so check it again after updates.
3. **Keep the WHOOP app on your phone connected.** That's fine.
4. **Close other apps that read WHOOP heart rate**, such as Peloton and Zwift. The strap sends heart rate to one listener at a time.
5. **Do not put the strap in pairing mode, and do not add the WHOOP in the Mac's Bluetooth settings.** Pairing mode can pull the strap away from the WHOOP app on your phone, and HR Broadcast does not need pairing. If your WHOOP is listed in **System Settings → Bluetooth**, choose **Forget This Device**.
6. **Allow full Calendar access** from the Meetspike HR menu. Choose **Go live now** if you want to test outside a meeting.
7. **Allow Bluetooth when macOS asks.** If you said no, turn on MeetspikeHR in **System Settings → Privacy & Security → Bluetooth**.

The menu bar shows **♥ 72** while heart rate is coming in, and an outline heart with a dash when there is no current reading. If it says **No WHOOP broadcast found — check HR Broadcast**, check steps 1 and 2 and keep the strap near the Mac. If it says **Bluetooth not allowed**, use the button in the menu to open System Settings. More help is in [`mac/MeetspikeHR/README.md`](mac/MeetspikeHR/README.md#troubleshooting).

This workaround is only for WHOOP. Oura's API already includes heart rate, so with an Oura ring you can use Meetspike without either native app or HR Broadcast.

## What you need

- A **Cloudflare account** on the Workers Paid plan (about $5 a month). This is where the app runs.
- A **WHOOP** or **Oura** account, with the band or ring you already wear.
- A **Google account** whose calendar holds your meetings.
- Optional: an **iPhone** (iOS 17 or later) with the Meetspike app, for live heart rate on your phone. See [docs/IPHONE-ONBOARDING.md](docs/IPHONE-ONBOARDING.md).
- About **15 minutes**.

You do not need to know how to code.

## Set it up

There are two ways. Both end at the same place: a setup page inside your own copy of the app that walks you through the rest.

### The quick way: one button

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/hershey-g/meetspike-oss)

1. Click the button and sign in to Cloudflare.
2. It asks a few questions. You can accept every suggested name. Where it asks for keys (WHOOP, Oura, Google), **leave them empty for now**. You will add them in a minute.
3. Press **Create and deploy**. Cloudflare makes your own copy of the app, its database and its storage.
4. When it finishes, open the address it shows you and add `/setup` to the end, for example `https://your-app.your-name.workers.dev/setup`.
5. Follow the setup page. It takes you through steps 1–8 below.

What the button can and cannot do, plainly:

- It **does** create the app, the database, the storage and the queue, and it prepares the database.
- It **cannot** create your WHOOP, Oura or Google developer apps. Those belong to your accounts with those companies, so only you can make them. The setup page shows exactly where to click and what to paste.
- It only works for a **public** copy of this repository. If the button gives an error, use the guided way below. It does the same thing.

### The guided way: four commands

Use this if the button is not available, or if you would rather see each step. You need [Node.js](https://nodejs.org) (version 20 or newer) installed.

1. Download this project and open a terminal in its folder.
2. Run these, one at a time:

   ```bash
   npm install
   npx wrangler login
   npm run setup
   npm run deploy:production
   ```

   - `npx wrangler login` opens your browser so you can sign in to Cloudflare.
   - `npm run setup` creates the database, the storage and the queues, and writes their ids into a file called `wrangler.production.jsonc`. You never type an id yourself. It is safe to run again: anything that already exists is reused, and nothing is ever deleted.
   - `npm run deploy:production` puts the app online and prints its address.

3. Open that address with `/setup` on the end and follow the page.

Use Oura instead of WHOOP? Run `npm run setup -- --wearable oura`. Want to see what setup would do without changing anything? `npm run setup -- --dry-run`. Want your own name instead of `hg-biometrics`? `npm run setup -- --name meetspike`.

### What the setup page walks you through

1. **Choose the wearable to set up.** Repeat the wearable steps to connect both WHOOP and Oura.
2. **Create a developer app** with WHOOP ([developer-dashboard.whoop.com](https://developer-dashboard.whoop.com/apps/create)) or Oura ([cloud.ouraring.com/oauth/applications](https://cloud.ouraring.com/oauth/applications)). It is free. The page shows the exact **redirect URL** to paste, with a copy button.
3. **Give the two keys to your app.** The developer app shows a Client ID and a Client Secret. You paste them into Cloudflare (Workers & Pages → your app → Settings → Variables and Secrets → Add → type **Secret**). The setup page cannot store them for you (a Cloudflare app is not able to set its own secrets), so it shows you the names to use and ticks each one off once it is saved.
4. **Connect** your wearable with one button.
5. **Connect Google Calendar** the same way: create a Google sign-in key, paste two values, press Connect. Meetspike can only read your calendar. Connect more than one Google account if you have them, then pick which calendars count as meetings. Every account counts as you, and a meeting on two calendars counts once.
6. **Bring in your data.** The setup button imports recent data for the selected wearable. Connected wearables refresh throughout the day.
7. **Lock the door.** Until you do this, anyone who has the address can open your dashboard. The page shows how to put a sign-in in front of it with Cloudflare Access.
8. **Connect your iPhone** (optional). Press **Show setup code**, then scan it in the iPhone app. Set a few Worker settings first: `WHOOP_WEB_HR`, `INGEST_ADMIN_SECRET`, `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD`, and an Access service token for the phone. The walkthrough lists them. Walkthrough: [docs/IPHONE-ONBOARDING.md](docs/IPHONE-ONBOARDING.md).

If you prefer a terminal for step 3, these do the same thing (each one asks you to paste the value):

```bash
npx wrangler secret put WHOOP_CLIENT_ID
npx wrangler secret put WHOOP_CLIENT_SECRET
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
# Oura:
npx wrangler secret put OURA_CLIENT_ID
npx wrangler secret put OURA_CLIENT_SECRET
```

Add `-c wrangler.production.jsonc` to each if you used `npm run setup`.

### Choosing the primary wearable

Set `WEARABLE` to `whoop` or `oura` to choose the primary score for meeting-load comparisons, charts, and people views. Meetspike imports both connected sources and shows WHOOP Recovery and Oura Readiness with their own usual scores.

- **New installs use WHOOP.** `npm run setup` writes `"WEARABLE": "whoop"` into `wrangler.production.jsonc` (or `oura` with `--wearable oura`).
- **If `WEARABLE` is not set at all,** an install that already has Oura keys and no WHOOP keys keeps using Oura. Nothing switches on its own when you update.
- To change it, use any one of these:
  - in `wrangler.production.jsonc`, under `"vars"`: `"WEARABLE": "oura"`, then deploy again;
  - as a secret: `npx wrangler secret put WEARABLE`, then type `whoop` or `oura`;
  - in the Cloudflare dashboard: Settings → Variables and Secrets → Add → type **Secret**, name `WEARABLE`;
  - for local development, in `.dev.vars`: `WEARABLE=whoop`.

  Use one place, not two: Cloudflare refuses a deploy where the same name is both a secret and a config value.

Meeting heart rate prefers WHOOP when its stored Bluetooth readings cover the meeting. A complete Oura reading takes priority over partial WHOOP data. When neither covers the whole meeting, the chart uses the available readings, including Oura points in gaps left by WHOOP. Each meeting shows its source. More lists the connection, last day with data, and saved history range for each wearable.

### Importing wearable history

**Schema approval required.** Apply `migrations/0013_dual_wearables.sql` on the intended environment before running the import or enabling the updated ingest code. Production schema changes require Hershey’s approval.

Run the following on an approved staging or local installation with each intended wearable already connected. Keep the existing Cloudflare Access gate in front of the API and supply its regular credentials when required. Use the existing `INGEST_ADMIN_SECRET` through the environment. Oura full history requires `OURA_SANDBOX=false` because Oura’s sandbox contains synthetic data.

```bash
curl --fail-with-body --request POST --json '{"source":"oura"}' \
  --header "x-admin-secret: ${INGEST_ADMIN_SECRET}" \
  "${MEETSPIKE_STAGE_URL}/api/history/backfill"

curl --fail-with-body --request POST --json '{"source":"whoop"}' \
  --header "x-admin-secret: ${INGEST_ADMIN_SECRET}" \
  "${MEETSPIKE_STAGE_URL}/api/history/backfill"
```

Save the `workflowId` and `totalWindows` from each response. Check the import status and completed windows, then use the same ID if a job is interrupted.

```bash
curl --fail-with-body --header "x-admin-secret: ${INGEST_ADMIN_SECRET}" \
  "${MEETSPIKE_STAGE_URL}/api/history/backfill/${WORKFLOW_ID}"

curl --fail-with-body --request POST --header "x-admin-secret: ${INGEST_ADMIN_SECRET}" \
  "${MEETSPIKE_STAGE_URL}/api/history/backfill/${WORKFLOW_ID}/resume"
```

The default search starts January 1, 2010, before either wearable had device history, and ends today in UTC. Optional `startDay` and `endDay` are inclusive. Oura imports Readiness, daily sleep, sleep episodes with HRV, and heart rate. Daily collections use 30-day windows and heart rate uses seven-day windows. WHOOP imports recovery (including HRV and resting heart rate), sleep, cycles, and workouts in 30-day windows. Archived Oura heart-rate documents stay in R2. The jobs paginate, pace requests, wait on provider rate limits, and record successful windows in D1. Resume reuses those checkpoints while the Workflow instance is retained. A fresh run can safely replay the same range if the instance expires.

WHOOP’s developer API does not return continuous heart rate. Bluetooth ingest provides WHOOP meeting heart rate. Oura coverage depends on the samples the ring recorded and synced. [Oura API](https://cloud.ouraring.com/v2/docs), [WHOOP developer API support](https://developer.whoop.com/docs/developing/support/).

### WHOOP webhooks

Apply migration `0011_whoop_webhooks.sql` before enabling this endpoint. In the
[WHOOP Developer Dashboard](https://developer-dashboard.whoop.com/), add
`https://<meetspike host>/hooks/whoop` to the app's Webhooks section and select
model version **v2**. If your dashboard supplies a separate webhook signing
secret, set it with `wrangler secret put WHOOP_WEBHOOK_SECRET` using your
production config. Otherwise the endpoint uses `WHOOP_CLIENT_SECRET`.

If the host is behind Cloudflare Access, have an operator configure an Access
Bypass for `/hooks/whoop` so WHOOP can reach the signed endpoint. The 15-minute
cron remains as a backup. Deletion events appear in `sync_log`; existing rows
stay in place until deletion support is added.

## What you see

The web app is phone-first with four tabs and an Ask button. The iPhone app has the same screens (Today, Dates, People, Ask) plus a **Live** tab for live heart rate, and a **Menu**. See [the iPhone walkthrough](docs/IPHONE-ONBOARDING.md).

- **Today.** Three rings (recovery, sleep, strain on WHOOP; readiness, sleep and meeting hours on Oura), the day's meetings on a timeline, what a day like this usually costs you the next morning, and today's numbers against your usual (median of the last 28 days). Step a day with `‹` `›`, or tap the date to pick one.
- **Dates.** Pick any two dates on a calendar, or a quick pick: Today, Yesterday, Last 7 days, Last 30 days, This month, Last month. The page compares next-morning recovery after heavy days (4+ hours or 5+ meetings) with lighter days, charts both, and lists the days that cost you and the people on them.
- **People.** Everyone you met, with how you woke up the morning after, for the past 7 days, 28 days, 90 days or year. Tap one for 60 days of meetings with them. The iPhone app also has a **Companies** view, which groups people by their email domain.
- **More.** Sync calendar, connections, your AI key, the setup guide and a privacy note.
- **Ask your data.** Chat about your meetings and recovery with your own Claude API key (see below).
- **Meeting choices.** Mark a meeting **I didn't join** or **Don't link this meeting**, or set its **Meeting times**. Left-out meetings stay in the list, dimmed, and are not counted in averages. Your calendar is never changed.

With heart-rate coverage, meetings also carry Elevated / Worth watching / Restored from heart rate inside the meeting, with a graph when you tap one, and a "Meetings that spiked" list.

Plaud recordings whose title is `Phone Call:…` or contains `[meetspike]` show beside calendar events, labelled as phone calls.

### Ask your data (optional)

Chat uses your own Claude API key, so you pay Anthropic directly. The key is stored encrypted in KV under a key derived from one Worker secret, and only its last four characters ever reach the browser:

```bash
npx wrangler secret put AI_KEY_SECRET   # 32+ random characters, e.g. from: openssl rand -base64 32
```

Then open Ask in the app and paste the key. Each question sends Anthropic the days it needs: dates, meeting titles and times, attendee names and your scores. No email addresses, transcripts or audio. Without `AI_KEY_SECRET` the rest of the app works and Ask explains what is missing.

### Install it like an app

Meetspike is an installable web app. On iPhone, open it in Safari → Share → **Add to Home Screen**. On Android or desktop Chrome, menu → **Install app**. It opens full-screen with its own icon. (The native iPhone app is separate: see [docs/IPHONE-ONBOARDING.md](docs/IPHONE-ONBOARDING.md).) There is no offline mode and no service worker: every launch and every refresh loads the newest version (`public/_headers` makes the browser revalidate the app's code each time). The icons are generated from one SVG by `npm run icons` (`scripts/build-icons.mjs`); the PNGs are committed.

## Why day D → next morning

Work happens on local day **D**. The night after that work is your wearable’s morning **D+1**. Meetspike keeps that join. After-hours means the meeting started at 18:00 or later in `America/New_York`.

## Architecture (plain)

| Piece | Role |
| --- | --- |
| R2 | Append-only archive of wearable and Calendar JSON |
| D1 | Projection: daily scores, events, attendee emails |
| KV | OAuth tokens (`whoop:tokens`, `oura:tokens`, `google:tokens:<email>` per Google account) |
| Queue + workflows | Ingest and a nightly 7-day reconcile |
| `/` | Same-origin UI (this repo’s `public/`); `/setup` is the first-run page |

Oura heart rate stays in R2. List endpoints load the day’s archive once, then slice each meeting. Optional WHOOP heart-rate ingest saves matching per-meeting samples in D1.

## For developers

```bash
npm install
cp .dev.vars.example .dev.vars
npm test
npm run typecheck
npm run dev
```

`wrangler.jsonc` is a template: its ids are placeholders and stay that way. Real ids live in `wrangler.production.jsonc`, which `npm run setup` writes and git ignores. Never commit that file, `.dev.vars`, or any key.

Resource names in the template are prefixed `hg-biometrics-` so this app stays isolated from anything else in the account. Setup never binds, reads, renames or deletes another Worker's resources, and never touches DNS. Deploys go to `workers.dev` only. A custom host (example: `https://meetspike.example.com`) can point at the same Worker as a custom domain from the Cloudflare dashboard; do not add routes to the config. The app works on several hosts at once (OAuth redirects follow the host you signed in on), which makes moving hosts painless: see [docs/DOMAIN-MOVE.md](./docs/DOMAIN-MOVE.md) for a worked example.

Redirect URLs. Register these exactly, with your own address in front:

```
https://<your-worker>.<your-subdomain>.workers.dev/api/whoop/callback
https://<your-worker>.<your-subdomain>.workers.dev/auth/oura/callback
https://<your-worker>.<your-subdomain>.workers.dev/auth/google/callback
```

They are worked out from the app's own address. Set `WHOOP_REDIRECT_URI`, `OURA_REDIRECT_URI` or `GOOGLE_REDIRECT_URI` only to override one.

Scopes in code. WHOOP: `read:recovery read:cycles read:sleep read:workout read:profile read:body_measurement offline`. Oura: `email personal daily heartrate workout session tag` (do not request `spo2Daily` until a projector exists). Google: `calendar.readonly` only.

WHOOP specifics:

- Official WHOOP developer API v2 only (`/v2/recovery`, `/v2/cycle`, `/v2/activity/sleep`, `/v2/activity/workout`).
- WHOOP allows 100 requests a minute and 10,000 a day. The client paces itself to both, reads WHOOP's `X-RateLimit-*` headers, and hands a 429 back to the workflow to retry later. A 30-day import is about ten requests.
- WHOOP refresh tokens are single-use; each refresh stores the new one.
- Recovery (score, HRV, resting heart rate) and sleep land on the morning the sleep ended. Cycle strain and average/max heart rate land on that same day. Rows are tagged `source = 'whoop'` in the same tables Oura uses, plus `daily_strain`.

### Access

Most-specific application wins.

- Allow your email on `/`, `/setup`, `/api/*`, `/auth/whoop/start`, `/auth/oura/start`, `/auth/google/start`
- Bypass everyone on `/api/whoop/callback`, `/auth/oura/callback` and `/auth/google/callback`
- Bypass everyone on `/hooks/*` (HMAC is the auth)
- Optional, for installing the app on a phone: bypass everyone on `/manifest.webmanifest`, `/icons/*` and `/favicon.ico` (no data in them)

In a private window, `GET /api/health` should be blocked. `GET /hooks/oura` should answer the challenge.

iPhone pairing (setup step 8) also checks the Access sign-in inside the Worker, so a request that reaches the Worker without Access (a preview URL, `workers.dev`) cannot make a setup code. Set two Worker variables, then deploy:

- `ACCESS_TEAM_DOMAIN`: `https://<team-name>.cloudflareaccess.com` (Zero Trust → Settings → Custom Pages shows the team domain)
- `ACCESS_AUD`: the Application Audience (AUD) tag of the Access application that covers `/api/*` (Zero Trust → Access → Applications → the app → Overview). Comma-separate several if more than one app covers `/api/*`.

Without them, `POST /api/pair/start` answers 503. Only a person who signed in can make a code; service tokens cannot. Pairing codes live in D1, so apply migration `0016_pair_codes.sql` before deploying this release (`npx wrangler d1 migrations apply <db name> --remote -c wrangler.production.jsonc`).

### First data

1. `POST /api/backfill { "mode": "fixtures" }`: sample data for the active wearable
2. `POST /api/calendar/sync { "mode": "fixtures" }`
3. Sign in at `/auth/whoop/start` (or `/auth/oura/start`) and `/auth/google/start`
4. WHOOP: `POST /api/backfill { "mode": "production" }`. WHOOP has no sandbox.
5. Oura: sandbox first, then `OURA_SANDBOX=false` and a production backfill. Do not register Oura webhooks yet.

### Deploying from GitHub

Two workflows are in `.github/workflows/`:

- `tests.yml` runs the type check and the tests on every pull request.
- `deploy.yml` runs them again on every push to `main`, then deploys.

`deploy.yml` needs three repository secrets (Settings → Secrets and variables → Actions):

| Secret | What it is |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | A token limited to this Worker and its D1, R2, KV, Queues and Workflows. Not a Super Admin token. |
| `CLOUDFLARE_ACCOUNT_ID` | The account the Worker lives in. |
| `WRANGLER_PRODUCTION_CONFIG` | The whole text of your `wrangler.production.jsonc`. |

The config is written to disk for that run only and is never committed. The workflow does not apply database migrations; when a release adds one, run `npx wrangler d1 migrations apply <database name> --remote -c wrangler.production.jsonc` yourself.

## API (thin)

- `GET /api/view?date=` or `?start=&end=`: everything one screen needs in one request: the day or range briefing, your usual over the last 28 days, the heavy-day comparison, the costliest days and people, a per-day series, connection status, and (Oura) ranked meeting hits
- `GET /api/ask/status`, `PUT /api/ask/key` `{ "key": "sk-ant-…" }`, `DELETE /api/ask/key`, `POST /api/ask` `{ "question", "start?", "end?", "history?" }`: Ask your data
- `POST /api/ask/stream`: same body as `/api/ask`, answered as server-sent events: `step` `{ id, label, status }` (calendar, body, think, write; real counts), `text` `{ delta }`, then `done` `{ truncated, model, start, end, refused? }` or `error` `{ error, needsKey? }`. Closing the request stops the Anthropic call. No question, no key or a bad range still come back as plain JSON errors.
- `GET /api/insights/hits?days=28`: meetings ranked by in-meeting heart-rate; `?start=&end=` scopes the feed and its baseline to that range instead
- `GET /api/briefing/day?date=YYYY-MM-DD`: day strip + meeting cards (local day in `America/New_York`). `?start=D&end=D` is the same day; a multi-day `start`/`end` returns the range aggregate
- `GET /api/briefing/range?start=YYYY-MM-DD&end=YYYY-MM-DD`: totals plus per-day and per-meeting results over an inclusive range (`?date=` is a one-day range)
- `GET /api/briefing/week?date=YYYY-MM-DD`: Monday–Sunday week in review for the week containing `date`
- `GET /api/companies`, `GET /api/companies/search`, `GET /api/companies/:domain/meetings`: people grouped by email domain (`PUT /api/companies/:domain/name` renames one)
- `GET /api/calendars`: Google accounts, their calendars and which ones count; `PUT /api/calendars/selection`; `DELETE /api/calendars/accounts/:email` disconnects one account
- `GET /api/people/:email/meetings?days=60`: history with that attendee (`?start=&end=` also accepted)
- `GET /api/meetings/by-attendee?email=`: same, via query string
- Date ranges are inclusive local days, with no span limit. End before start, or a date that is not a real `YYYY-MM-DD`, is a `400` with the reason in `error`. A lone `start`, `end`, or `date` is a one-day range. `/api/meetings/stressed` and `/api/meetings/sleep-impact` take `start`/`end` (or the older `from`/`to`) under the same rules.
- `GET /api/health`: includes `wearable` (which one is active, and what it can report)
- `GET /api/setup/status`: what the setup page shows: redirect URLs, which keys exist (never their values), what is connected
- `GET /auth/whoop/start` → WHOOP → `GET /api/whoop/callback`
- `POST /api/backfill`: `{ "mode": "fixtures" | "production" }` for WHOOP; Oura also takes `"sandbox"`
- Every briefing response carries `wearable`. When `wearable.hasIntradayHr` is false, `hr` and each meeting’s `hrStress` are null and the day slice carries `strain`.
- `POST /api/plaud/ingest`: Olive-only, admin secret, matching Plaud windows (see [PLAUD.md](./PLAUD.md))

### WHOOP heart-rate ingest

- Meetspike HR sends small timestamped batches to `POST /api/whoop-web/live` using the same ingest secret and Access service-token headers as replay. The live Durable Object keeps a rolling nine-hour chart buffer. The Worker also stores the samples durably in D1. The Today view can follow a meeting through its two ten-minute pads via `GET /api/meetings/:id/live-hr` using the existing browser Access session. The 30-minute replay keeps building the saved meeting rows.
- When releasing live HR on an existing install, copy the `LIVE_HR` binding and `live-hr-v1` Durable Object class migration from `wrangler.jsonc` into the production config used by GitHub Actions or Wrangler. Raw heart-rate storage requires migration `0012_whoop_web_hr_raw.sql` before the updated Worker is deployed. Confirm that the read route is covered by the same Access policy as the other meeting endpoints and that the Mac service token covers the live POST route.
- Send version 1 to `POST /api/whoop-web/ingest` using the ingest admin secret, with WHOOP active and `WHOOP_WEB_HR` enabled. Use `source: "ble"` for the Mac and iPhone apps. A body without `source` is stored as `"codebox"` for compatibility; this build has no job that sends it. The value becomes `sync_log.trigger`, with `sync_log.source` set to `whoop_web`.
- Each ingest request can carry up to 92,160 `[unix_ms, bpm]` points and 200 `{startMs, endMs}` spans. Raw readings are upserted per installation owner, source, and timestamp. A successful ingest returns `rawStored: true`. The Mac sends pending samples in batches of up to 4,000 with empty spans.
- Ingest projects meeting rows from the stored samples, including both ten-minute pads. It keeps older cached samples from the same window and prefers BLE when raw sources share an exact timestamp. A partly covered meeting shows “Heart rate from 9:45 AM” (or “until …”) in the meeting list and detail (`hrStress.partial`).
- To fill late or moved meetings, send `{"day":"YYYY-MM-DD"}` to `POST /api/whoop-web/rebuild` with the ingest admin secret and the existing Access policy. The Worker uses the configured time zone and rebuilds meetings that start on that local day. It reads D1 only.
- Reminder: `GET /api/whoop-web/reminder` (ingest secret) returns the calendar meeting starting within two minutes or in progress, plus `live` (true when the owner's phone or Mac heart rate arrived in the last minute, null if that check failed). `POST /api/whoop-web/reminder` `{ title?, repeat? }` answers `pushover: "live"` and sends nothing while heart rate is coming in; otherwise it sends a Pushover push when the optional `PUSHOVER_TOKEN` and `PUSHOVER_USER` Worker secrets are set (otherwise it answers `pushover: "not_configured"`). The Mac app calls these when a Zoom or calendar meeting is starting and no Bluetooth reading has arrived for 60 seconds, at most once per meeting plus one repeat after 5 minutes. The Mac sends the same Access service-token headers here, so confirm the service token also covers `GET` and `POST /api/whoop-web/reminder`; a blocked lookup fails silently and no reminder fires.
- Reminder push (Apple push, iPhone build 11): `POST /api/whoop-web/reminder/owner` takes an optional `push: { token, environment }` (64 to 200 hex characters, `production` or `development`) next to `active` and `covered`, and replies `push: true` only when Apple accepted the device. A bad `push` is a 400. Without `push` (builds 9 and 10), when `active` is false, or when APNs is not set up or rejects the token, the reply is `push: false` and the phone keeps its local reminders. When `push` is true, the every-minute cron (`* * * * *`) checks the meetings the phone covers: two minutes before the start and again one minute in it sends a push only if no heart rate arrived in the last 60 seconds from any device, and nine minutes after the end it sends "you can turn off HR Broadcast" only if heart rate is still arriving. Each decision is final and kept for a day in KV (`push:done:*`). Pushes never carry a meeting title or a heart rate. Optional Worker secrets: `APNS_KEY_P8` (the .p8 key, PKCS8 PEM), `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_TOPIC` (default `com.hersheyg.meetspike.hr`). The deploy workflow passes both cron schedules with `--triggers`, because the production config is a secret.
- Stored samples and the meeting detail chart retain the original cadence. Meeting scores use one mean per occupied minute. Baselines count overlapping minutes once, and use the meeting's padding when fewer than 30 distinct minutes are available from other meetings.

## Limits

- No per-minute Oura stress series in this repo.
- Person identity is attendee **email**. The UI shows Google `displayName` when the event stored one. Private or title-only events have neither.
- Heart-rate coverage can be missing. Meetspike will not invent it.
- WHOOP live heart rate uses HR Broadcast and the MeetspikeHR app. Stored Bluetooth readings and synced Oura ring readings can cover meetings without a live stream.
- No Plaud token in this Worker. Transcripts and audio URLs are not stored.

## Public name

The Worker on Cloudflare stays `hg-biometrics` (isolation). The product is Meetspike.

Never commit `.dev.vars`, real Access emails, or anyone else's name or email. Tests and screenshots use made-up people. See [SECURITY.md](./SECURITY.md).

## License

MIT. See [LICENSE](./LICENSE), [SECURITY.md](./SECURITY.md).

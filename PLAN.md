# Revised plan — Oura + Calendar join

Platform: Cloudflare (Workers, D1, R2, KV, Queues, Workflows). Not Vercel.

## Decisions vs the original spec

- Sequential, one repo. No parallel git worktrees. No Vue scaffold.
- WHOOP dropped.
- Product is nights × work. **Google Calendar is in scope for this phase** (source two after Oura projector). CRM overlay is still later.
- Webhooks implemented but not registered until backfill + reconcile are green (P1.5).
- Heart-rate time series archived to R2 only. No `hr_samples` in D1.
- `raw_object` is source-generic and versioned by `content_hash`. Oura revisions append; the index is not overwritten.
- `source_day` kept beside computed `day`. IANA zone on `user_profile` + `sleep_periods`. Tombstones via `deleted_at`.
- Access: allow on `/`, `/api/*`, `/auth/oura/start`, `/auth/google/start`. **Bypass** `/auth/oura/callback`, `/auth/google/callback`, and `/hooks/*`.
- HMAC: `x-oura-signature` over `timestamp + raw body`, key = OAuth client secret, 5-minute replay window. GET challenge on the same path.
- Workflow `schedules` on reconcile (`0 11 * * *`). Reconcile also does a full-window Calendar sync (and re-reads each account's calendar list) when a Google account is connected (Google failure does not fail the Oura run).
- Calendar only: `triggers.crons` `*/15 * * * *` → `scheduled` handler → incremental Google sync of every chosen calendar in every connected account (`nextSyncToken` per calendar in D1 `google_calendar`, full-window fallback on 410). The app also syncs on load and on its Refresh button.
- Reminder push: the second cron `* * * * *` runs only `runPushTick` (`src/sources/whoop-web/push.ts`), an Apple push when no heart rate is arriving. The `*/15` jobs do not run on it. The deploy workflow passes both with `--triggers`.
- 403 from Oura = membership lapsed, not a refreshable 401.

## Metric dictionary

| Column | Meaning |
| --- | --- |
| `daily_sleep.score` | Oura sleep score 0–100. Stage minutes are merged from the long-sleep period. |
| `daily_readiness.score` | Oura readiness. Not comparable to WHOOP Recovery. |
| `daily_activity.score` | Oura activity score. Not strain. |
| `daily_stress` | Oura day-grain stress (`stress_high` / `recovery_high` seconds + `day_summary`). Already projected. |
| `day` | Oura calendar day. Instants stored UTC. |
| `calendar_event.day` | Local work day D (IANA zone). Join to Oura morning D+1. |
| heartrate | R2 only. In-meeting stress reads these samples; they are not inserted into D1. |

Skipped until a projector exists: `daily_spo2`, `vo2_max`, `daily_cardiovascular_age`, `daily_resilience`. Do not request `spo2Daily`.

## Ship order

See [CLAUDE.md](./CLAUDE.md). Schema freezes after `0001_init.sql` is applied remote. Calendar is `0003_calendar.sql` + `0004_calendar_local.sql` (do not edit 0003 if it has already been applied — 0004 adds `start_local` / `end_local`).

## Calendar join

Work on local day D → Oura sleep/readiness on day D+1 (Oura morning date). After-hours = start ≥ 18:00 local. Early start = start < 08:00 local. Kinds: client, internal, deep_work, admin, personal.

APIs (Access-protected like other `/api/*`):

- `GET /api/meetings/stressed` — upcoming/recent meetings ranked by same-day `daily_stress` and/or next-morning readiness hit
- `GET /api/meetings/sleep-impact` — late nights, early starts, heavy days vs next-morning sleep/readiness
- `GET /api/briefing/day?date=` — calendar load + prior-night Oura + flags + `summary`
- `GET /api/briefing/week?date=` — Monday–Sunday week in review (HR zone counts, no invented data)
- `POST /api/plaud/ingest` — admin-secret upsert of Phone Call: / [meetspike] Plaud windows only
- `GET /api/metrics/daily?start=&end=` — read-only daily_sleep / readiness / activity / stress series
- `GET /api/insights/hits?days=28` — meetings ranked by in-meeting ring heart-rate vs the wearer’s usual
- `POST /api/calendar/sync` — `{ "mode": "fixtures" }` or live primary-calendar pull
- `GET /` — insight-first dashboard (Workers assets from `public/`)

# Metric dictionary

Oura documents do not all live at the same grain. Daily scores and period physiology are different resources.

## Daily sleep

Oura `daily_sleep` is score + contributors (each contributor is itself a 0–100 subscore). Duration, stages, HRV, and rHR come from `sleep` (period) with `type = long_sleep`. The projector merges the long-sleep period onto the daily row. Naps do not overwrite nightly physiology.

## Readiness / activity / stress

Keep Oura names. Do not chart them against another vendor's "recovery" or "strain" on one axis without a disclaimer.

`daily_stress` **is projected** (`stress_high_s`, `recovery_high_s`, `day_summary`) under the existing `daily` scope. It is **day grain**, not meeting grain.

## Day

`day` is Oura's calendar day in the user's local zone (`America/New_York` from `personal_info`). `source_day` is the value Oura sent. Instants are UTC. `tz_offset_min` is the offset observed on that row.

## Heart rate

`heartrate` uses `start_datetime` / `end_datetime`. Chunks are 7 days. Samples are written to R2 and not projected to D1.

The dashboard **does** read those R2 objects for meeting windows. `raw_object` rows with `endpoint = heartrate` and a `day` (fixture bundles `hr-YYYY-MM-DD`, or page bundles `hr-YYYY-MM-DD-pN` from live list) are loaded, parsed as `{ bpm, timestamp, source }` samples, and filtered to `[startUtc, endUtc]`. Production list no longer flattens each sample into its own raw object — a page is one archive doc with `day` stamped from the first timestamp. Ingest also infers `day` from a sample timestamp when the doc has none.

There is no per-minute Oura daytime-stress series in this repo. In-meeting “stress” is an honest **heart-rate proxy**: minutes / share of samples at or above that day’s **awake mean + 8 bpm**, plus mean in-meeting bpm vs the day’s awake mean. Resting HR is shown for context (daytime HR is usually already above resting + 15). If no samples overlap the window, the UI says **No ring HR in this window** and does not invent a score.

## Calendar × Oura join (honesty)

| Rule | Meaning |
| --- | --- |
| Work day D | Local calendar date of `start_utc` in `America/New_York` (DST-aware). Queries use that local midnight range, not the denormalized `day` column or UTC `T00:00Z`/`T23:59Z` bounds. |
| Week | Monday–Sunday containing the selected day, same local zone. |
| Plaud phone / tagged | Same `calendar_event` row + in-window HR join. `source_type` is `plaud_phone`, `plaud_tagged`, or `plaud_both`. Not every Plaud file. |
| Oura morning D+1 | `daily_sleep` / `daily_readiness` where `day = D+1`. That is the night after the work day. |
| Prior night of briefing D | Oura `day = D` (woke that morning, before the work day). |
| After-hours | Event start ≥ 18:00 local. |
| Early start | Event start < 08:00 local (sleep-impact heuristic; not in the original PLAN kinds list). |
| Same-day stress | `daily_stress` where `day = D`. This is **not** HR during the meeting window. |
| Intra-meeting HR | R2 heartrate samples overlapping the meeting window. Dashboard proxy only — not Oura daytime stress. Missing coverage is reported, not invented. |
| Stress proxy | If `daily_stress` has no row, invert same-day readiness score + `hrv_balance` contributor. Flag `stress_proxy`. Not an Oura stress document. |

Meeting JSON includes `signals.stressSource`: `daily_stress` | `readiness_proxy` | `none`. Titles are returned; tokens and emails are not.

`GET /api/metrics/daily` is a read-only join of those daily tables. `GET /api/insights/hits` ranks meetings by the in-meeting heart-rate proxy first; next-morning sleep/readiness vs the wearer’s median is secondary. `GET /api/people/:email/meetings` lists prior meetings that share an attendee email and returns `name` when Google stored a display name. Day-only recovery hits use plain titles (`Quiet calendar — still a hard recovery day` / `No calendar meeting that day`) — never “thin night”. UI copy says “beats per minute” / “highest”, not “mean”.

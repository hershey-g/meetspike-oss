# Plaud ingest (optional)

If you record phone calls with a [Plaud](https://www.plaud.ai/) device, those calls can appear on the dashboard beside your calendar meetings, with the same heart-rate reading. This is optional; skip this file if you do not use Plaud.

Meetspike never holds a Plaud token and never calls Plaud. You run your own small script or scheduled job that reads your recording list (for example through Plaud's official MCP server or export), keeps the titles that match, and POSTs only the time windows to this Worker.

## What to sync

| Title | `source_type` | `sync_reason` |
| --- | --- | --- |
| `/^Phone Call:/i` | `plaud_phone` | `phone_title` |
| contains `[meetspike]` (any case) | `plaud_tagged` | `tag` |
| both | `plaud_both` | `phone_title,tag` |

Do **not** POST every recording. Non-matching titles are rejected with `reason: "no_match"`.

## Auth

```
wrangler secret put INGEST_ADMIN_SECRET
```

Header (preferred):

```
x-admin-secret: <INGEST_ADMIN_SECRET>
```

`Authorization: Bearer <INGEST_ADMIN_SECRET>` is also accepted.

Cloudflare Access: **Bypass Everyone on `/api/plaud/*`**. The admin secret is the authz (same idea as HMAC on `/hooks/*`). If you leave Access on `/api/*` instead, your job must also send an Access service token.

## `POST /api/plaud/ingest`

JSON body — one recording or a batch (max 200 per request):

```json
{
  "recordings": [
    {
      "plaud_file_id": "of_00000000000000000000000000000001",
      "title": "Phone Call: Schedule delay for Thursday meeting",
      "start_at": "2026-09-16T18:18:50.000Z",
      "end_at": "2026-09-16T18:19:56.000Z",
      "duration_ms": 66000,
      "has_transcript": true
    }
  ]
}
```

A single object with those fields is also accepted.

| Field | Required | Notes |
| --- | --- | --- |
| `plaud_file_id` | yes | Plaud `id`. Unique. Idempotent upsert key. |
| `title` | yes | Store as shown (whitespace collapsed). |
| `start_at` | yes | Prefer UTC ISO (`…Z`). Naive `YYYY-MM-DDTHH:mm:ss` is read as `America/New_York`. |
| `end_at` | one of end / duration | UTC ISO or naive local. |
| `duration_ms` | one of end / duration | Milliseconds. Plaud reports `duration` in ms — you may send it as `duration`. |
| `has_transcript` | no | Boolean only. |

**Never send** transcripts, notes, `presigned_url`, audio URLs, or tokens. If they appear, they are dropped and not written to D1.

### Response

```json
{
  "ok": true,
  "written": 1,
  "skipped": 0,
  "rejected": 0,
  "truncated": false,
  "results": [
    { "plaud_file_id": "of_…", "status": "written", "source_type": "plaud_phone" }
  ]
}
```

`skipped` means the same `plaud_file_id` + window + title is already stored. Safe to re-POST.

## Backfill after deploy

1. Make sure the database migrations are applied (README, step 4).
2. Set `INGEST_ADMIN_SECRET` (a long random string you make up) and deploy.
3. List your Plaud recordings.
4. Keep rows whose `name` matches the table above.
5. Map `id` → `plaud_file_id`, `name` → `title`, `start_at` + `duration` → window. Convert `start_at` to UTC if you can.
6. `POST` batches of ≤200. Repeat until history is loaded. Re-runs are idempotent.

## Keeping it current

Run the same job on a schedule (nightly is enough) with the same filter, POSTing only new or changed matches. The heart-rate reading is the same in-window ring reading used for calendar meetings (Elevated / Worth watching / Restored).

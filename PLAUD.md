# Plaud ingest (Olive)

Meetspike never holds a Plaud token. Olive’s bot cron uses **user-plaud MCP**, keeps matching titles, and POSTs scrubbed windows to this Worker.

Folder/`meetspike` tag sync is a later phase. Do not call unofficial Plaud APIs.

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

Cloudflare Access: **Bypass Everyone on `/api/plaud/*`**. The admin secret is the authz (same idea as HMAC on `/hooks/*`). If Access stays on `/api/*`, the cron must also send an Access service token.

## `POST /api/plaud/ingest`

JSON body — one recording or a batch (max 200 per request):

```json
{
  "recordings": [
    {
      "plaud_file_id": "of_8aa402f855b24e97a7dc74bc555d447a",
      "title": "Phone Call: Schedule Delay for Meeting with Chaim",
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
| `duration_ms` | one of end / duration | Milliseconds. Plaud MCP `duration` is ms — you may send it as `duration`. |
| `has_transcript` | no | Boolean only. |
| `speakers` | no | Speaker names, `["Jane Doe"]` or `[{ "name": "Jane Doe", "email": "jane@acme.com" }]`. Used only to name a calendar attendee of an overlapping meeting when it maps cleanly (same email, or the name spells the email, e.g. jane.doe@ ↔ Jane Doe). Generic labels like `Speaker 1` are ignored. No transcript text is sent or stored. |

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

1. Apply migration `0007` (and `0006` if not yet) on `hg-biometrics-db` local then remote.
2. Put `INGEST_ADMIN_SECRET`. Deploy **`hg-biometrics` only**.
3. Via user-plaud MCP `list_files`, page/scan recordings.
4. Keep rows whose `name` matches the table above.
5. Map `id` → `plaud_file_id`, `name` → `title`, `start_at` + `duration` → window. Convert `start_at` to UTC if you can.
6. `POST` batches of ≤200. Repeat until history is loaded. Re-runs are idempotent.

## Nightly cron

Same filter, POST only new or changed matches. HR join is the existing in-window ring proxy (Elevated / Worth watching / Restored). No parallel HR pipeline.

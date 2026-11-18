# Notes for coding agents

**Setting Meetspike up for someone?** Follow [README.md](./README.md) from the top. Its "For AI agents" section says what to do, in order, and what to ask the human for.

**Changing the code?** The short rules:

- Never commit secrets: no `.dev.vars`, no `wrangler.production.jsonc`, no client secrets, no API tokens. `wrangler.jsonc` keeps its `REPLACE_…` placeholders.
- `npm run typecheck` and `npm test` must pass before you call something done.
- Do not edit a migration that may already be applied. Add a new numbered file in `migrations/`.
- Wearable data is revised after it is published. Writes to D1 are upserts; keep them that way.
- Oura heart-rate samples live in R2 only. Do not insert them into D1.
- An Oura `403` means the membership lapsed. It is not a `401` to refresh and retry.
- Oura webhooks (`/hooks/oura`): HMAC-SHA256 of timestamp + raw body, keyed by the OAuth client secret, 5-minute replay window. Acknowledge fast; enqueue the work.
- Test data and fixtures are synthetic: `example.com` / `*.example` addresses and invented names only.
- Do not run `wrangler delete`, add `routes` to the config, or touch Cloudflare resources this app did not create.
- A refresh must always load the newest deploy: keep `Cache-Control: no-cache` for app code in `public/_headers`, and do not add a caching service worker.
- "Ask your data" sends Anthropic only what `src/lib/ask-context.ts` builds (no email addresses, transcripts or raw data). Keep it that way, and update the README and docs/ARCHITECTURE.md if it changes.

[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) explains how the pieces fit. [METRICS.md](./METRICS.md) defines the numbers. [PLAUD.md](./PLAUD.md) covers the optional Plaud ingest.

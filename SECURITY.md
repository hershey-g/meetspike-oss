# Security

## Report a problem

Report it privately: on GitHub, open this repository's **Security** tab and choose **Report a vulnerability** (a private security advisory). Do not open a public issue for a vulnerability, and never post tokens, calendar contents, or heart-rate archives anywhere public.

## Operators

- Put Cloudflare Access in front of `/`, `/api/*`, and `/auth/*/start`. OAuth callbacks and `/hooks/*` must bypass Access (HMAC is the webhook auth).
- Never commit `.dev.vars`, `.env`, OAuth client secrets, Access service tokens, or wrangler state.
- `wrangler.jsonc` ships placeholders (`REPLACE_D1_DATABASE_ID`, `REPLACE_KV_NAMESPACE_ID`) and stays that way. `npm run setup` writes real IDs into `wrangler.production.jsonc`, which is gitignored. Never commit that file, `.dev.vars` or OAuth secrets.
- `/setup` and `/api/setup/status` report which secrets exist, never their values. Put them behind Access with the rest of `/` and `/api/*`. The WHOOP callback (`/api/whoop/callback`) must bypass Access like the other OAuth callbacks.
- A fresh install has no Access in front of it until you add it. Do step 7 of the setup page (README step 11) before you import real data.
- Heart-rate and calendar archives live in your R2 bucket. Treat that bucket as private.
- If you use the Plaud ingest, `/api/plaud/*` bypasses Access and `INGEST_ADMIN_SECRET` is its only check. Make it long and random.

## This repo

Fixtures use `you@example.com` and `*.example` addresses only. No real calendar titles, phones, or account emails belong in git.

If a secret ever lands in git, rotate it at the provider; removing the commit is not enough.

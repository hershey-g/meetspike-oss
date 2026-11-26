# Security

## Report a problem

Email the maintainer privately. Do not open a public issue that includes tokens, calendar contents, or heart-rate archives.

## Operators

- Put Cloudflare Access in front of `/`, `/api/*`, and `/auth/*/start`. OAuth callbacks and `/hooks/*` must bypass Access (HMAC is the webhook auth).
- Never commit `.dev.vars`, `.env`, OAuth client secrets, Access service tokens, or wrangler state.
- `wrangler.jsonc` ships placeholders (`REPLACE_D1_DATABASE_ID`, `REPLACE_KV_NAMESPACE_ID`) and stays that way. `npm run setup` writes real IDs into `wrangler.production.jsonc`, which is gitignored. Never commit that file, `.dev.vars` or OAuth secrets.
- `/setup` and `/api/setup/status` report which secrets exist, never their values. Put them behind Access with the rest of `/` and `/api/*`. The WHOOP callback (`/api/whoop/callback`) must bypass Access like the other OAuth callbacks.
- A fresh install has no Access in front of it until you add it. Do step 7 of the setup page before you import real data.
- iPhone pairing (setup step 8): `POST /api/pair/start` stays behind Access and also verifies the `Cf-Access-Jwt-Assertion` token itself (RS256 signature against the team keys, issuer, `ACCESS_AUD`, expiry), needs a signed-in person rather than a service token, and refuses to run without `ACCESS_TEAM_DOMAIN` and `ACCESS_AUD` (except `wrangler dev` on http://localhost). The QR holds only the Worker address and a one-time code, never a secret. The phone trades the code at `POST /hooks/pair` (covered by the existing `/hooks/*` bypass) for `INGEST_ADMIN_SECRET`, plus `PHONE_ACCESS_CLIENT_ID` / `PHONE_ACCESS_CLIENT_SECRET` if you set them. Codes live in D1 (`pair_codes`, migration 0016) as a SHA-256 hash, expire after 10 minutes, and are deleted on the first attempt by one atomic `DELETE ... RETURNING`, so a code pays out once. Making a new code deletes older ones. Exchanges are rate limited per address (in KV, approximate).
- Heart-rate and calendar archives live in your R2 bucket. Treat that bucket as private.
- Do not register Oura webhooks until reconcile has run clean once.

## This repo

Fixtures use `you@example.com` and `*.example` addresses only. No real calendar titles, phones, or account emails belong in git.

Older commits on `main` may still contain Cloudflare D1/KV *resource IDs* (not credentials). The current tree uses placeholders. Do not rewrite published history. Rotate OAuth secrets if they ever landed in git — none are in this tree.

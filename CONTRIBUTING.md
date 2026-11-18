# Contributing

Thanks for helping. Meetspike is small on purpose; small, focused changes are the easiest to review.

## Before you open a pull request

```bash
npm ci
npm run typecheck
npm test
```

Both must pass. The same checks run on every pull request.

## Ground rules

- **No secrets and no real data.** No keys, tokens, account ids, real email addresses, real calendar titles or real heart-rate exports — in code, tests, fixtures, screenshots or issue text. Use `example.com` / `*.example` addresses and invented names.
- **Add a test** for behaviour you add or change. Tests live in `test/` and run with Node's built-in test runner.
- **Schema changes are new migrations.** Add the next numbered file in `migrations/`; do not edit one that already exists.
- **Say what the data can support.** If a number is missing, the UI says so. Do not invent or interpolate readings.
- Keep `wrangler.jsonc` a template with `REPLACE_…` placeholders.

## Reporting bugs

Open an issue with what you did, what you expected and what happened. Remove personal details first. For anything security-related, follow [SECURITY.md](./SECURITY.md) instead of opening a public issue.

## License

By contributing you agree that your contribution is licensed under the [MIT License](./LICENSE).

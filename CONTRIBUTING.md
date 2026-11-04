# Contributing

Use a separate Supabase development project. Never run fixture scripts, database resets or migrations against the deployed Treasure Heist database. Preserve the existing 12-second signal, 35-second planning and 8-second reveal timers unless a separately reviewed rules change explicitly permits otherwise.

1. Fork or clone this repository and follow README.md.
2. Make a focused branch and keep changes small.
3. Run `npm ci`, `npm test` and a configured `npm run build`.
4. For backend changes, test SQL and concurrent gameplay against an isolated development project. Include exact pass/fail results and test provenance in the PR. Do not upload tokens, player identifiers or private fixture data.
5. Describe the change, validation, limitations and migration impact in a pull request.

Security-sensitive changes must preserve member-only room access, hidden actions, request UUID idempotency, transactional resolution and server-authoritative scoring. Never add permissive RLS policies to private tables or use a service-role key in the browser. Use environment variables; `.env` and generated test sessions are ignored.

Report suspected vulnerabilities privately to the repository owner rather than posting working credentials or exploit details in a public issue. Do not run abuse tests on the public game.

The repository is prepared with the MIT license, subject to the owner's publication approval. Third-party dependencies retain their own licenses. Do not claim independent-device or human testing when only automated clients were used.

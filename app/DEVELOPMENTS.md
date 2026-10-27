# DEVELOPMENTS.md — Offline demo mode

> Technical plan and progress log. Status table and log are **append/update only**:
> never delete a past log entry. Rules for agents: [`AGENTS.md`](AGENTS.md).

## Goal

Publish the web app on Vercel today (Devpost demo URL, LinkedIn) **without a
running server**, while the app looks fully populated and every flow (sign-up,
onboarding, taste check, reveal, home brief, feed, story dialog, Fact Check
badges and results) works naturally. Later (before jury review) the server is
deployed, `API_BASE_URL` is set and the same URL becomes the live app with
**no errors** when switching.

Approach: run the real server locally with a fresh Tavily key, let it produce
real data (stories, summaries, latest developments, digests, fact checks,
research), export the API responses into a bundled snapshot, and answer the
app's API calls from that snapshot inside the browser.

## Decisions (approved)

| # | Decision |
|---|---|
| D1 | Offline = in-app `OfflineBackend` (`http.Client`) with server-identical JSON. No offline branches in `AppState`. |
| D2 | Stories: bundled read-only snapshot (`assets/offline/snapshot.json`). User data + fresh server stories: Hive CE (IndexedDB). |
| D3 | Offline personal ranking by tags: micro match > macro match > recency; taste-check likes boost their tags. Interest sentence saved, ignored in ranking. |
| D4 | Mode fixed per session. Online first; probe `/api/taxonomy` (4 s). Empty `API_BASE_URL` = offline, no network. |
| D5 | Online session: failed reads (network/timeout/5xx) fall back to local silently; 4xx pass through; failed writes dropped silently. |
| D6 | Online sessions refresh the local DB: newest ~1,500 stories, last 30 days; bundled snapshot never deleted. |
| D7 | `off.` session tokens; an online session clears them silently (sign-in screen, no "session expired"). |
| D8 | Hidden offline: WAI chat, Ask, Fact Check/Research start without saved result, add site, add "+" follow, live web search. Interest sentence stays visible. |
| D9 | 10 harvest profiles: 7 single-category + 3 mixed. "Latest developments" for an offline user = the closest profile's card. |
| D10 | Daily digest: 7 categories + general, saved from the server. |
| D11 | Harvest uses only the new Tavily key (scratchpad env, `TAVILY_API_KEYS`, reserve 0), cap 990/1000. `.env` key untouched (jury). |
| D12 | Story dates are kept as fetched (no shifting). |
| D13 | Diagnostics: mode logged to the browser console; `?debug=1` shows a small mode badge. |
| D14 | (added 2026-10-26, option A) Live-session writes always go to the server with a 90 s first-byte timeout. A failure shows the app's usual error; it is never stored locally or sent again (user ids belong to the server; replays could double comments or flip toggled likes). |

## Harvest profiles (D9)

| Username | Categories | Subtopics (examples) |
|---|---|---|
| `demo_tech` | Tech | software, startups, security, policy |
| `demo_ai` | AI | llm_agents, models_research, ai_tools, anthropic, benchmarks |
| `demo_hardware` | Hardware | semiconductors, gpus, tsmc, storage_memory |
| `demo_auto` | Automotive | ev_charging, autonomous, solid_state_battery |
| `demo_gaming` | Gaming | releases, hardware_consoles, pc_gaming, steam_deck |
| `demo_finance` | Finance | markets, macro, crypto, fintech |
| `demo_science` | Science | space, jwst, energy, biotech |
| `demo_builder` | AI + Tech + Hardware | llm_agents, ai_chips, software, gpus |
| `demo_investor` | Finance + Tech + Automotive | markets, startups, industry |
| `demo_explorer` | Science + Gaming + Automotive | space, releases, autonomous |

Each profile gets an interest sentence. The single-category profiles also get
one "+" follow and one watched site.

## Snapshot format (`assets/offline/snapshot.json`)

```jsonc
{
  "version": 1, "generated_at": "…", "server_commit": "…",
  "taxonomy": [ /* GET /api/taxonomy */ ],
  "articles": { "<id>": { /* GET /api/articles/{id}: list fields + clean_text */ } },
  "fact_checks": { "<id>": [ /* recorded SSE events of the cached deep-inspect */ ] },
  "research": { "<id>": { /* GET …/deep-inspect/research */ } },
  "comments": { "<id>": [ … ] },
  "digests": { "_all": { … }, "<Macro>": { … } },
  "latest": { "<profile username>": { "macros": [], "micros": [], "card": { … } } },
  "sites": { "<profile username>": { "sites": [ … ], "stories": { … } } },
  "tavily_calls": [ /* GET /api/tavily/calls, newest first */ ],
  "ingestion_status": { … }
}
```

Embeddings are not exported. Measured size: ~4–5 KB per story, ~12 KB per fact
check → ~8 MB raw / ~2.5 MB gzip for ~1,500 stories.

---

## Plan

### Phase 0: Preparation
- **T0.1** Create `seed.env` in the session scratchpad (new key, `TAVILY_API_KEYS`, `TAVILY_CREDIT_RESERVE=0`). Record the baseline `/usage` of both keys.
  *Done when:* new key 0/1000; `.env` key unchanged (1031 reported).
- **T0.2** Start Postgres (Docker), API (`uvicorn`) and `worker.py` with `seed.env` loaded first. Run a 1-query smoke harvest.
  *Done when:* the new row in `tavily_calls.key_id` = sha1(new key)[:10]; the `.env` key usage did not change.

### Phase 1: Harvest (server, no code changes)
- **T1.1** Seed rounds with `ingest_tavily.py --seed --seed-range month|week|day` (73 templates each, ~110 credits/round). Measure after each round.
- **T1.2** Create the 10 profiles through the API (login, preferences, follows, sites); let interest fetches finish.
- **T1.3** Wait for the worker to enrich everything (summary, tags, briefing). *Done when:* the count of stories without a summary is ~0.
- **T1.4** Daily digests: 7 categories + general (`GET /api/intelligence/daily-digest`).
- **T1.5** Latest developments for each profile (`GET /api/users/{id}/latest-developments`; uses no Tavily).
- **T1.6** Fact Check 40 stories. Selection: enriched, newest 10 days, ≥5 per category where available, prefer stories with `also_published`/multiple origins.
- **T1.7** Research with the remaining budget. Measure the first call, then decide how many. Stop at 990.
  *Phase done when:* usage ≤ 1000, `.env` key unchanged; the per-phase credit report is in the log.

### Phase 2: Export
- **T2.1** `tool/export_snapshot.dart`: reads the running API (same JSON the app parses) and writes `assets/offline/snapshot.json`. Fact checks are recorded by replaying the cached `POST …/deep-inspect` stream (the server returns `is_cached: true` and spends no credits).
- **T2.2** Validate: every exported object parses with the app's models (test), sizes reported.

### Phase 3: Offline data layer (`lib/offline/`)
- **T3.1** Dependencies: `hive_ce`, `hive_ce_flutter`. In-memory fallback when IndexedDB is unavailable.
- **T3.2** `snapshot_store.dart`: loads the asset once, indexes by id/macro/micro/date.
- **T3.3** `local_db.dart`: Hive boxes for users, sessions, preferences, follows, interactions, comments, fresh server stories (+ retention D6).
- **T3.4** `ranking.dart`: tag ranking (D3) + taste-like boosts; closest profile for latest developments (D9).
- **T3.5** `offline_backend.dart`: `http.BaseClient` routing every `ApiService` endpoint:
  auth (`off.` tokens), me, taxonomy, articles list/detail, search (local text + tags), personalized feed, preferences GET/PUT, follows, sites, interactions, comments, daily digest, latest developments, deep-inspect (SSE replay), research GET, tavily calls, ingestion status, telemetry. Online-only endpoints return a server-like 503 (never reached because the UI hides them).
- **T3.6** `backend_client.dart`: mode decision (D4), online client with silent read fallback (D5), writes fresh stories to the local DB (D6), `off.` token handling (D7).
- **T3.7** Wire into `main.dart`/`AppState` construction only (`ApiService(client: …)`); expose `isLive`.

### Phase 4: UI gating
- **T4.1** Hide the controls listed in D8 when `!isLive` (`web_shell.dart` nav, `web_chat_page.dart`, `article_dialog.dart` ask/fact check/research, `web_sites_page.dart` + `interest_form.dart` add site/follow, `web_discover_page.dart` live results).
- **T4.2** `?debug=1` mode badge + console log (D13).

### Phase 5: Verification
- **T5.1** Unit tests: OfflineBackend parses with `ApiService` for every endpoint; ranking; retention; fallback rules (network error vs 4xx); `off.` token clearing.
- **T5.2** `flutter analyze` + `flutter test` green.
- **T5.3** Manual Chrome runs: (a) empty `API_BASE_URL`, (b) live local server, (c) server stopped mid-session. Full flow: sign-up → onboarding → taste check → reveal → home → feed → story → fact check result.

### Phase 6: Deploy (Vercel)
- **T6.1** Offline build (`--dart-define=API_BASE_URL=`), check size.
- **T6.2** User runs `npx vercel login` once; deploy `build/web` with cache headers; share the URL.
- **T6.3** Tell the user which files to commit (agent does not run git).

### Phase 7: Later (before jury review)
- Deploy the server with this same database (`pg_dump`) so ids match, set `CORS_ORIGINS`, set `API_BASE_URL` on Vercel and redeploy. Run the T5.3 (b) checks against production.

---

## Status

| Task | Status | Notes |
|---|---|---|
| T0.1 | ✅ | harvest key id `97bfaced5b`, reserved `.env` key id `68698d0e57` |
| T0.2 | ✅ | smoke query: 1 credit, 18 new stories; `/usage` lags, so the local call log is also counted |
| T1.1 | ✅ | month + week + day rounds (~226 cr), 1,256 stories |
| T1.2 | ✅ | 10 profiles; 7 follows; 5 of 7 sites ready (~81 cr) |
| T1.3 | ✅ | 1,256 stories, all with a summary |
| T1.4 | ✅ | 7 category digests (~12 cr each) |
| T1.5 | ✅ | 10 cards, refreshed after the day round (8 changed) |
| T1.6 | ✅ | 39 of 40 (guard stopped at 708), ~10.5 cr each |
| T1.7 | ✅ | 3 reports (26 + 25 + 65 cr); key reached Tavily's limit |
| T2.1 | ✅ | 772 stories, 43 Fact Checks, 7 research, 8 digests, 10 cards; 2.7 MB (0.9 MB gzip) |
| T2.2 | ✅ | snapshot test green; 119/119; offline release build OK |
| T3.1–T3.7 | ✅ | `lib/offline/` (4 files), AppState wiring; 21 new tests, 115/115 green |
| T4.1–T4.2 | ✅ | `isLive` gating in 7 UI files + `?debug=1` badge; 116/116 green |
| T5.1–T5.3 | 🔶 | T5.1 done; T5.3 (a) offline run checked by the user; (b), (c) pending |
| T6.1–T6.3 | ✅ | https://weownfeed.vercel.app (offline); committed as `5583204` |

## Log

<!-- Append entries; newest last. Format:
### YYYY-MM-DD — T<id>: <title>
- **What:** files / commands
- **Result:** numbers (credits, counts, sizes), test output
- **Conditions:** what had to hold for it to count as done; any deviation from the plan
-->

### 2026-10-26: Planning
- **What:** code analysis of `app/` and `server/`; `AGENTS.md` and this file created.
- **Result:** harvest key 0/1000; `.env` key reports 1031/1000 on the plan (the user confirmed that the hackathon credit covers the rest; it is reserved for the jury). Local DB: 95 stories (52 AI). 73 query templates. Average exported story ~4–5 KB.
- **Conditions:** no code changes, no git operations.

### 2026-10-26 — T0.1: Harvest key isolation
- **What:** `seed.env` in the session scratchpad (`TAVILY_API_KEYS`/`TAVILY_API_KEY` = harvest key, `TAVILY_CREDIT_RESERVE=0`, `API_INGEST_URL=http://127.0.0.1:8000/api/internal/ingest`). Helper scripts `usage.sh` (Tavily `/usage` for both keys) and `credits.py` (credits per key from `tavily_calls`). Nothing written to the repo or to `server/.env`.
- **Result:** with `seed.env` loaded, `tavily_service.configured_keys()` returns only `97bfaced5b` (harvest). The `.env` key is `68698d0e57`. Baseline: harvest 0/1000, reserved 1031/1000 on the plan.
- **Conditions:** `load_dotenv()` never overrides variables already in the environment, so the processes started with `seed.env` cannot see the `.env` key. When the harvest key runs out, rotation has no other key to fall back to.

### 2026-10-26 — T0.2: Server stack + smoke harvest
- **What:** Postgres container `weownfeed-postgres-1` (Docker Desktop); `uvicorn main:app --host 127.0.0.1 --port 8000` and `worker.py` started with `seed.env` (logs in scratchpad `api.log`, `worker.log`). One query through `ingest_tavily._harvest_query("AI chips", week, 20 results)`.
- **Result:** `tavily_calls` id 65: key `97bfaced5b`, search, 1 credit, 20 results; stories 95 → 113; the worker started enriching. Reserved key: no new calls, `/usage` still 1031.
- **Conditions:** Tavily `/usage` still showed 0 for the harvest key ~30 s after the call (it lags). The credit cap check therefore uses max(`/usage`, local log sum).

### 2026-10-26 — T1.1 (round 1/3): Seed, `time_range=month`
- **What:** `ingest_tavily.py --seed --seed-range month` with `seed.env` (log: scratchpad `seed_month.log`).
- **Result:** 73 queries, 540 fetched, 311 new stories (total 422). Harvest key: 74 search + 13 extract calls ≈ **76 credits** (local log). Every template produced new stories. Reserved key: 0 calls.
- **Conditions:** cost per round is ~1 credit/query (Extract fallback is rare), below the 110 estimate. Tavily `/usage` still reports 0 for the harvest key, so the cap uses the local log + margin. The worker enriches at ~4 stories in parallel (~40 s each).

### 2026-10-26 — T1.1 (round 2/3): Seed, `time_range=week`
- **What:** `ingest_tavily.py --seed --seed-range week` (log: scratchpad `seed_week.log`).
- **Result:** 73 queries, 539 fetched, 503 new stories → **782 stories** in the DB (609 waiting for enrichment). Harvest key total: 147 search + 21 extract calls ≈ **150 credits**. Reserved key: 0 calls.
- **Conditions:** the `day` round is deferred to the end of Phase 1 so the demo opens with the freshest stories. Tavily `/usage` still reports 0 for the harvest key ~10 min after the calls.

### 2026-10-26 — T1.2: Harvest profiles
- **What:** scratchpad `make_profiles.py` (login creates the account → `PUT preferences` with interest sentence → `POST follows` → `POST sites`), then `fix_sites.py`. Ids/tokens saved in scratchpad `profiles.json` (needed by the export). Worker restarted with `NANO_CONCURRENCY=8` (process env only; `.env` keeps 4). Restart is safe: the worker claims rows with `FOR UPDATE SKIP LOCKED`.
- **Result:** 10 profiles (`demo_tech` … `demo_explorer`), all `200`. Follows: Microsoft, OpenAI, Intel, Tesla, Nintendo, Federal Reserve, SpaceX. Sites ready: anthropic.com/news (5), nvidianews.nvidia.com/news (5), ea.com/news (4), nasa.gov/news (4), stripe.com/blog (3). Interest fetches: 47 demand queries. Stories: 975. Harvest key total ≈ **231 credits**; reserved key 0 calls.
- **Conditions / deviation:** the server's site map only selects `/news/`, `/press/`, `/blog/` paths and needs a slug-like last segment. blog.cloudflare.com, chipsandcheese.com, electrek.co, blog.playstation.com, vercel.com/blog and insideevs.com/news returned `no_articles` and were removed again (no empty sites in the demo). `demo_tech` and `demo_auto` have no site, so no more credits were spent on trial and error.

### 2026-10-26 — T3.1–T3.7: Offline data layer
- **What:** `hive_ce ^2.22.0` + `hive_ce_flutter ^2.3.4`; `assets/offline/` registered in `pubspec.yaml` (placeholder `snapshot.json` until T2.1).
  - `lib/offline/local_store.dart`: JSON documents in Hive boxes (`offline_users`, `offline_sessions`, `offline_comments`, `fresh_articles`, `live_users`). Memory fallback when IndexedDB is unavailable; memory is read first, so failed disk writes still count.
  - `lib/offline/snapshot.dart`: `OfflineSnapshot.load()` decodes the asset once; a missing or broken asset → empty snapshot (the app still opens).
  - `lib/offline/ranking.dart`: tag score = 12 × subtopic hits + 15 × follow hits + 8 × category hit + liked-tag boost (≤ 3 × 3 per tag) + freshness (0–10 over 10 days). Fewer than 30 matches → newest other stories follow. `closestProfile`: shared categories × 10 + shared subtopics × 2 + first category 3 − extra categories × 4.
  - `lib/offline/offline_backend.dart`: `http.BaseClient` serving every `ApiService` endpoint with the server's shapes and rules: login creates the account (`off.` token), preferences (category canonicalisation, ≤ 12 subtopics, interest sentence keep/clear/set, same `interest_summary` text), follows (≤ 3), interactions (toggle; like adds the category + first 2 subtopics, ≤ 15; dislike removes them; dislike/skip hide the story), comments, cached Fact Check SSE (`status` → `final` with `is_cached: true` → `[DONE]`), research, daily digest (category → `_all`), latest developments (closest profile; 409 without picks), Tavily calls, ingestion status, telemetry. Chat/WAI/synthesize/site follows → 503. `addFresh` keeps the newest 1,500 / 30 days, pruning at most once a minute.
  - `lib/offline/backend_client.dart`: mode decided once (empty `API_BASE_URL` → offline with no network; else probe `/api/taxonomy` in 4 s). Live: GET network error / timeout (25 s; AI paths exempt) / 5xx → offline answer; 4xx and writes pass through; `off.` token → 401 without calling the server; stories (`/api/articles`, `/api/feed`, latest developments) and users (`/auth/me`, login, preferences) are saved for later offline sessions. Console: `[WOF] backend: live|offline (…)`.
  - `AppState`: optional `backend` (default `BackendClient.instance`), `isLive`, `init()` awaits the mode first. No other `AppState` logic changed.
- **Result:** `flutter analyze` clean. `flutter test`: **115 / 115** (21 new in `test/offline_backend_test.dart`, run through the real `ApiService`).
- **Conditions / deviations:** the tests caught that `ApiService` parses DELETE answers as JSON: offline follow delete now returns the server's `{"status": "removed", "id": …}`. Writes that fail in a live session are not retried offline (D5 said "dropped silently"): their user ids belong to the server, and the existing UI already handles their errors. In an offline session the Sites page shows no sites (offline accounts follow none; adding is hidden in Phase 4).

### 2026-10-26 — D14 + T4.1–T4.2: Write timeout, UI gating, debug badge
- **What:**
  - D14 (user chose option A): `BackendClient` gets a `writeTimeout` (90 s, first byte) on live writes; `AGENTS.md` §3 now describes the real write behaviour (it said "dropped without a message").
  - `web_shell.dart`: offline sessions hide the **WAI Assistant** and **Site Watch** menu items (`_SideNav._onlineOnly`); `_pageBody` sends those indices to Home when not live. `?debug=1` shows `_ModeBadge` (live + base URL / offline demo).
  - `web_feed_page.dart`: "Send to WAI" button, ↑ key and its shortcut hint only when live (`_ActionBar.onWai` is nullable).
  - `web_home_page.dart`: Latest developments "Ask" only when live. `web_discover_page.dart`: "Dig deeper with WAI" only when live (Discover has no live-web section; offline search already answers `semantic: true`, `explore: []`).
  - `article_dialog.dart`: Fact Check button only when live or a saved result exists; "Ask WAI" button and the "Ask about this story" box only when live; the Research card (now with its own top margin) only when live or a saved report exists. The checks sit inside the existing `ListenableBuilder`s so a report that loads later still appears.
  - `interest_form.dart`: offline onboarding skips steps 2 ("+" follows) and 3 (sites) via `_shownSteps` / `_stepBy`; the profile form hides both sections. `web_onboarding_page.dart`: step overlines are numbered over the shown steps (`1 / 3` offline, `1 / 5` live).
- **Result:** `flutter analyze` clean. `flutter test`: **116 / 116** (new: a hung live write fails with `ApiException` and nothing is stored locally).
- **Conditions / deviations:** Site Watch is hidden as a whole page offline, not just its add box: offline accounts follow no sites, so the page would be empty. The interest sentence step stays (D8). Visual check in Chrome is part of T5.3.

### 2026-10-26 — T1.4–T1.7, T1.1 round 3, T2.1–T2.2 (first pass)
- **What:** all calls through the local API started with the harvest key only; helper scripts in the session scratchpad (`harvest.py`, `fc_pick.py`).
  - T1.4: `GET /api/intelligence/daily-digest?macro=…` for the 7 categories, 54–81 s and ~12 credits each. No separate "general" digest: without a category the server picks Gaming, so the export reuses the AI digest as `_all`.
  - T1.5: `GET /api/users/{id}/latest-developments` for the 10 profiles: 8 stories each, Nebius only (no Tavily). Asked again after enrichment ends.
  - T1.6: picked primary stories with a summary, last 10 days, not yet checked, most outlet copies first, 5 per category then by copies (all 40 have copies). `POST /api/articles/{id}/deep-inspect` (SSE) with the profiles' tokens in turn (server limit 20 / user / hour). 39 done (the credit guard at 700 stopped before the 40th): 22 Verified, 3 Partially verified, 1 Contradicted, 13 Unverified (single source). ~10.5 credits each.
  - T1.1 round 3: `ingest_tavily.py --seed --seed-range day` with `TAVILY_CREDIT_RESERVE=150`: 71 queries, 320 new stories, ~76 credits.
  - T1.7: `POST /api/articles/{id}/deep-inspect/research` (mini): Anthropic IPO (26 cr), AI-found vulnerability (25), Samsung/TSMC/Nvidia (65). The next 4 failed with Tavily's "exceeds your plan's set usage limit": the key's real usage reached 1,000 while the server's local log showed ~859 (Tavily bills some calls above the local estimates). Total research reports in the DB: 7 (4 from before today).
  - T2.1: `tool/export_snapshot.dart --profiles=<file> [--api=…] [--digests]`: list → details (8 at a time) → saved Fact Check from the cached deep-inspect stream (only for stories with `fact_check_verdict`, so it never starts a new check) → research → comments → digests (only with `--digests`, else kept from the current file) → profile cards → Tavily calls, ingestion status, telemetry. Tokens are never written out. Trial run: 630 stories, 1.9 MB (0.6 MB gzip), 22 s.
  - T2.2: `test/snapshot_asset_test.dart` parses every part with the app models and checks that every story on a digest or card is in the snapshot.
- **Result:** reserved `.env` key: 0 new calls, `/usage` unchanged at 1031. Harvest key: spent to Tavily's limit. `flutter analyze` clean, snapshot test green.
- **Conditions / deviations:**
  - The server saves a failed Research as `status: completed` with the report "Research failed: …" (`routers/intelligence.py`, research handler, via the mock fallback in `tavily_service.tavily_research`). Those 4 entries were removed from the harvest DB (`fact_check_cache - 'research'`), and the export skips such reports. The server bug itself is not fixed (server code is outside this plan).
  - The Finance digest picked a promotional cluster ("Global Payments"); it is kept as the server produced it.
  - Tavily `/usage` lagged all day (still 230 at the end), so the local log was the only live measure and undercounted. For future runs: keep a wider margin than 10 credits.

### 2026-10-26 — T1.3, T1.5, T2.1–T2.2: Final harvest data and export
- **What:** enrichment finished (1,256 stories, 0 without a summary; 768 primary stories, the rest are merged copies). Profile cards asked twice: the first call starts the server's background refresh, the second (2 min later) reads it; 8 of 10 headlines changed. Final export: `dart run tool/export_snapshot.dart --digests --profiles=<scratchpad>/profiles.json`.
- **Result:** `assets/offline/snapshot.json`: 768 listed + 4 card stories, 43 saved Fact Checks, 7 research reports, 8 digests (`_all` = AI), 10 profile cards, Tavily calls, ingestion status, telemetry. 2.7 MB (0.9 MB gzip). `flutter analyze` clean, `flutter test` **119 / 119**, `flutter build web --release --dart-define=API_BASE_URL=` OK (`build/web` 46 MB, mostly CanvasKit).
- **Conditions / deviations:** the first final run failed `snapshot_asset_test`: 4 digest stories had been merged into other stories after the digests were made, so the list (primary stories only) left them out. The export now also fetches the detail of every story a digest or card points to. No comments exist on the harvest stories (none were written), so the offline comment lists start empty.

### 2026-10-26 — T5.3 (a), T6.1–T6.2: Offline run and Vercel deploy
- **What:** release build served locally (`python -m http.server` in `build/web`) and checked by the user. The UI stuttered in a Firefox-based browser (Zen) and ran smoothly in Edge; offline backend timing with the real snapshot (Dart VM): personal feed page 1 ~0.1 s, other calls 0.01–0.07 s. Deploy with the Vercel CLI, no git: `vercel link --yes --project weownfeed --scope we-own-vision` and `vercel deploy --prod` inside `build/web`.
- **Result:** https://weownfeed.vercel.app (team WeOwnVision, project `weownfeed`, not connected to a repository). `/`, `main.dart.js` and `snapshot.json` answer 200 publicly. Build output checked for keys before the upload (none).
- **Conditions / deviations:**
  - `vercel link` tried to connect the GitHub repo on its own and failed (no access); the project stays unconnected. It also wrote `.env.local` (a Vercel OIDC token) and a `.gitignore` into `build/web`; `.env.local` was deleted before the upload. Both live only in the ignored build folder, so a rebuild removes the link: run `vercel link` again before the next deploy.
  - The prebuilt upload has no `vercel.json`, so the no-cache headers of T6.2 are not applied (Vercel's default for static files is `max-age=0, must-revalidate`).
  - Firefox-based browsers render this Flutter build noticeably slower; not addressed.

### 2026-10-26 — T6.3: Commit
- **What:** the user committed and pushed from the repo root (`WeOwnFeed-public`, origin `WeOwnVision/WeOwnFeed`): `5583204 Offline demo mode`, 40 files (app offline mode, snapshot, export tool, tests, docs; server story copies / "Also published").
- **Result:** local `main` equals `origin/main` (`5583204`), working tree clean; `app/assets/offline/snapshot.json` and `app/lib/offline/` are tracked.
- **Conditions / deviations:** this log entry and the status row change come after the commit and are not committed yet.

### 2026-10-26 — Server fix: failed Research is no longer saved as a report
- **What:** `server/tavily_service.py` `tavily_research`: a Tavily error (and a missing client) now returns `{"status": "failed", "error": …, "report": "", "sources": []}` instead of `{"report": "Research failed: …"}`. With no report, `POST /api/articles/{id}/deep-inspect/research` takes its existing `failed` branch: nothing is saved, the app shows "Research could not finish" and the user can start it again. New test `test_failed_research_is_not_a_report` in `server/tests/test_tavily_integration.py`.
- **Result:** server tests **124 / 124** (`pytest tests --ignore=tests/live`). No credits spent.
- **Conditions / deviations:** `POST /api/tavily/research` (ingestion secret only) now also returns the failed shape. The running local API keeps the old code until it restarts. Not committed yet.

### 2026-10-27 — App icons: WOF logo instead of the Flutter defaults
- **What:** `web/favicon.png` (64 px) and `web/icons/Icon-{192,512}.png`, `Icon-maskable-{192,512}.png` made from `Images/WOF_LOGO_SQUARE.jpg` (Pillow in a scratchpad venv, not a project dependency): the favicon and normal icons are cropped around the logo, the maskable icons use the whole image so the logo stays inside the safe zone. Offline build and Vercel deploy as in T6.2.
- **Result:** https://weownfeed.vercel.app serves the new favicon and icons (checked against the local files).
- **Conditions / deviations:** browsers cache favicons; an open tab may show the old icon until a hard reload.

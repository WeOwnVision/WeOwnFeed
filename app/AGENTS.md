# AGENTS.md — WeOwnFeed app

> Guide for developers and coding agents working in `app/`.
> **Stack**: Flutter 3.35.3 / Dart 3.9.2, web first (desktop layout under `lib/web/`), mobile layout under `lib/screens/`.
> **Backend**: `../server/` (FastAPI). See `../server/AGENTS.md` for the API side.
> **Work in progress**: the offline demo mode. Plan and status live in [`DEVELOPMENTS.md`](DEVELOPMENTS.md); read it before starting a task.

---

## 1. Layout

```text
app/
├── lib/
│   ├── main.dart              # Entry: web → WebGate, mobile → HomePage
│   ├── services/
│   │   ├── api_service.dart   # The only HTTP client (takes an injectable http.Client)
│   │   ├── local_cache.dart   # Legacy localStorage feed cache
│   │   └── text_fragment.dart
│   ├── state/app_state.dart   # All session, feed, onboarding, brief, fact check, research state
│   ├── models/api_models.dart # JSON models (fromJson/toJson) shared by every layer
│   ├── offline/               # (planned) offline backend, snapshot store, local DB, ranking
│   ├── web/                   # Web pages, shell, dialogs, widgets
│   └── data/seed_articles.dart# Made-up placeholders; never shown as news
├── assets/offline/            # (planned) snapshot.json exported from the server
├── tool/                      # (planned) export_snapshot.dart
├── bin/                       # Dart scripts that use ApiService against a running server
├── test/
└── vercel.json                # Vercel build (clones Flutter, builds web)
```

## 2. Data flow

`UI → AppState → ApiService → http.Client → server`

- `AppState` talks to the server only through `ApiService`. It checks
  `hasServerUser` in many places, so a user without a real-looking id never
  gets onboarding, a personal feed or the brief.
- **Offline design rule:** offline mode replaces the `http.Client` given to
  `ApiService` with `OfflineBackend`, which answers the same endpoints with the
  same JSON shapes from local data. `AppState` and pages stay unaware of the
  mode. Do not add offline branches inside `AppState` methods. Only UI gating
  (hiding online-only controls) reads the mode flag.

## 3. Modes

| Build | Behaviour |
|---|---|
| `--dart-define=API_BASE_URL=` (empty) | Offline only. No network calls to an API. |
| `API_BASE_URL=https://…` | Probe `GET /api/taxonomy` (4 s) at startup: success → online session, failure → offline session. |
| No define (local dev) | Defaults to `http://127.0.0.1:8000`, probe as above. |

- The mode is **fixed for the whole session**. It never mixes server and local
  user ids in one session.
- In an online session, a read that fails with a network error, timeout or 5xx
  is answered from local data without any message. 4xx responses are real
  answers and pass through. Writes always go to the server (90 s timeout for
  the first byte); a failed write shows the app's usual error message and is
  neither stored locally nor sent again (D14 in `DEVELOPMENTS.md`).
- Offline sessions use tokens with the `off.` prefix. If an online session
  finds an `off.` token, it clears it and shows the sign-in screen with no
  error.
- Online sessions write fetched stories into the local DB. Retention keeps the
  newest ~1,500 stories and the last 30 days. The bundled snapshot is the base
  layer and is never deleted.

## 4. Online-only controls (hidden in offline sessions)

WAI chat (nav item + page), "Ask about this story", starting a Fact Check on a
story without a saved result, starting Research without a saved result, adding
a site, adding a "+" follow, the live web results in Discover. The interest
sentence field stays visible: it is saved and has no effect on offline ranking.

## 5. Rules for agents

- **No git operations** (commit, push, branch, stash, reset…). Tell the user
  what to commit instead.
- **Tavily keys:** never write a key into the repo or into `../server/.env`.
  The harvest key lives only in the session scratchpad env file and is passed
  to server processes as `TAVILY_API_KEYS`. The `.env` key is reserved for the
  jury demo and must not be spent.
- Harvest credit cap: stop at **990 / 1000** on the harvest key. Check
  `GET https://api.tavily.com/usage` after every phase.
- Read a file before editing it; match the surrounding style (English comments,
  doc comments on public members, small private helpers).
- After each task: `flutter analyze` clean, `flutter test` green, then add an
  entry to the log in `DEVELOPMENTS.md` (append only, never rewrite old
  entries).

## 6. Commands

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d chrome                                   # local server at 127.0.0.1:8000
flutter run -d chrome --dart-define=API_BASE_URL=       # offline only
flutter build web --release --dart-define=API_BASE_URL= # offline demo build
dart run tool/export_snapshot.dart                      # (planned) server → assets/offline/snapshot.json
```

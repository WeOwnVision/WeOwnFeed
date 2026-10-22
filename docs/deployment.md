# Deploying WeOwnFeed

WeOwnFeed has two parts that deploy separately:

| Part | Folder | Where | What it is |
|---|---|---|---|
| Web app | `app/` | Vercel (or any static host) | Flutter web build: static HTML/JS files |
| Server | `server/` | Any cloud VM with Docker | API, enrichment worker, ingestion, PostgreSQL |

```text
browser ──HTTPS──► https://<app>.vercel.app          (static files)
   │
   └──HTTPS──► https://api.<your-domain>  ──► Caddy ──► api container :8000
                                                          │
                                       worker, ingest ────┼──► postgres (pgvector)
                                                          │
                                       Nebius Token Factory, Tavily (outbound)
```

The browser calls the API directly, so the API needs **HTTPS** (a page served
over HTTPS cannot call an `http://` API) and must list the app's address in
`CORS_ORIGINS`.

Deploy the server first: the app's build needs the API address.

---

## 1. Server on a cloud VM

Any provider works (Nebius, AWS, GCP, Hetzner, DigitalOcean…). Suggested size:
2 vCPU, 4 GB RAM, 20 GB disk, Ubuntu 24.04. The models run on Nebius, so the
VM needs no GPU.

### 1.1 Point a domain at the VM

Create a DNS `A` record such as `api.example.com` → the VM's public IP. Open
ports **80** and **443** in the VM's firewall (Caddy needs 80 to get the
certificate). Keep 8000 and 5432 closed; `docker-compose.yml` binds them to
`127.0.0.1` only.

### 1.2 Install Docker and get the code

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker
git clone https://github.com/WeOwnVision/WeOwnFeed.git
cd WeOwnFeed/server
```

### 1.3 Configure

```bash
cp .env.example .env
nano .env
```

Set at least:

| Variable | Value |
|---|---|
| `AI_API_KEY` | Nebius Token Factory key |
| `TAVILY_API_KEY` (or `TAVILY_API_KEYS`) | Tavily key(s) |
| `INGESTION_SECRET` | long random string: `python3 -c "import secrets; print(secrets.token_urlsafe(36))"` |
| `POSTGRES_PASSWORD` | long random string (docker compose builds `DATABASE_URL` from it) |
| `CORS_ORIGINS` | the web app's address, e.g. `https://weownfeed.vercel.app` (add a custom domain too if you use one) |
| `FORWARDED_ALLOW_IPS` | `*` — safe here because port 8000 only accepts connections from this machine (Caddy) |

Keep `TAVILY_CREDIT_RESERVE` so automatic ingestion leaves credits for live
verification during the demo.

### 1.4 Start the stack

```bash
docker compose up -d --build
docker compose ps                      # api should become "healthy"
docker compose logs -f api worker      # Ctrl+C to stop following
```

On a new database, fill it once (runs every query template; spends Tavily credits):

```bash
docker compose exec ingest python ingest_tavily.py --seed
```

Optional: `docker compose --profile watcher up -d` also starts the RSS-less site
watcher.

### 1.5 HTTPS with Caddy

Caddy gets and renews a Let's Encrypt certificate by itself.

```bash
sudo apt install -y caddy
sudo tee /etc/caddy/Caddyfile >/dev/null <<'EOF'
api.example.com {
    reverse_proxy 127.0.0.1:8000
}
EOF
sudo systemctl reload caddy
curl https://api.example.com/api/taxonomy     # should return JSON
```

The API documentation is then at `https://api.example.com/docs`.

### 1.6 Updating

```bash
cd WeOwnFeed && git pull
cd server && docker compose up -d --build
```

Database migrations run automatically when the API starts.

### 1.7 Moving from the old username-only login

Accounts created before passwords existed have no password yet: the first
sign-in with that username sets one, so anyone who types the name first owns
the account. To start clean instead, delete them once (their likes, comments
and follows go with them):

```bash
docker compose exec api python purge_passwordless_users.py         # shows the count
docker compose exec api python purge_passwordless_users.py --yes   # deletes
```

### 1.8 Backups

From `server/`:

```bash
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip > backup-$(date +%F).sql.gz
```

---

## 2. Web app on Vercel

`app/vercel.json` tells Vercel how to build: it downloads Flutter 3.35.3,
runs `flutter build web` and serves `build/web`.

1. In Vercel: **Add New → Project**, import the GitHub repository.
2. **Root Directory**: `app`. Leave the framework preset as "Other"; the build
   and output settings come from `vercel.json`.
3. **Environment Variables**: `API_BASE_URL` = `https://api.example.com` (no
   trailing slash). It is compiled into the app at build time, so redeploy
   after changing it.
4. Deploy. The first build takes a few minutes (Flutter download); later builds
   reuse the cache.
5. Add the final app address (e.g. `https://weownfeed.vercel.app`) to the
   server's `CORS_ORIGINS` and restart the API: `docker compose up -d api`.

### Without the Vercel build

If the Vercel build ever fails, build locally and upload the result:

```bash
cd app
flutter build web --release --dart-define=API_BASE_URL=https://api.example.com
npx vercel deploy build/web --prod
```

Any static host (Netlify, Cloudflare Pages, GitHub Pages, nginx) can serve
`build/web` the same way.

---

## 3. Checklist before sharing the link

- [ ] `https://api.example.com/docs` opens and `/api/taxonomy` returns JSON.
- [ ] The web app signs up a new account, finishes onboarding and shows stories.
- [ ] Browser console has no CORS errors (if it does, check `CORS_ORIGINS`).
- [ ] `docker compose logs worker` shows articles being enriched.
- [ ] The Tavily terminal in the app shows calls (`/api/tavily/calls`).
- [ ] `.env` exists only on the server; `git status` shows no secrets.
- [ ] Remaining Tavily credits are above the reserve (`GET /api/ingestion/status`).

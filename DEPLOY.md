# Deploying Ụgwọ to Production

**Ụgwọ** ships as a self-contained multi-stage container (`Dockerfile`) bundling:
1. **Gleam 1.19 `erlang-shipment`** on **Erlang/OTP 27** (`entrypoint.sh run`)
2. **Zig 0.13 `ReleaseSafe`** `ugwo-kernel` binary (`i128` minor-unit ledger + SQLite WAL)
3. **Elm 0.19.1 `--optimize`** compiled UI bundle (`priv/static/ugwo.js`)

Because **Ụgwọ** persists state in **SQLite WAL** (`UGWO_DB_PATH=/data/ugwo.db`), run a single primary writer instance attached to a persistent volume (`/data`).

---

## Option 1: Fly.io (Recommended for Pan-African Edge + SQLite WAL)

`fly.toml` is preconfigured for the Johannesburg (`jnb`) region with a persistent `ugwo_wal_data` volume and `/healthz` readiness probe:

```bash
cd ugwo
fly auth login
fly launch --copy-config --no-deploy
fly volumes create ugwo_wal_data --region jnb --size 3
fly deploy
```

Attach a custom domain (for example `ugwo.live` or `pay.flowmation.live`):

```bash
fly certs add ugwo.live
```

---

## Option 2: Ubuntu / Debian VPS alongside FlowMation (Docker Compose + Caddy)

```bash
cd ugwo
docker compose up -d --build
curl -fsS http://127.0.0.1:3000/healthz
```

Example Caddy reverse-proxy block for automatic HTTPS:

```caddyfile
ugwo.live {
    reverse_proxy 127.0.0.1:3000
}
```

---

## Option 3: Render or Railway (via GitHub)

1. Push `/home/user/ugwo` to a GitHub repository.
2. **On Render:** Select **New → Blueprint**, connect the repository, and Render will provision the web service plus the `5 GB` `/data` persistent disk from `render.yaml`.
3. **On Railway:** Create a project from the GitHub repository (`railway.json`), mount a Volume at `/data`, and set `UGWO_DB_PATH=/data/ugwo.db`.

---

## Runtime Environment Variables

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `PORT` | `3000` | HTTP listener port bound on `0.0.0.0` |
| `UGWO_DB_PATH` | `/data/ugwo.db` | Persistent SQLite WAL ledger file path |
| `UGWO_KERNEL_BIN` | `/app/priv/bin/ugwo-kernel` | Path to compiled Zig `ReleaseSafe` binary |
| `UGWO_STATIC_DIR` | `/app/priv/static` | Directory serving `index.html`, `styles.css`, and `ugwo.js` |

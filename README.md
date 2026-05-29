# RMO Gateway

nginx TLS reverse proxy that fronts the **web** demo host and the **ratchet**
backend as a single HTTPS origin.

```
                    ┌──────────── gateway (nginx) ────────────┐
  browser ──HTTPS──▶│ :443  TLS termination                   │
                    │   /api/  /skillbox/  /dist/  ──▶ ratchet :3000
                    │   /health  /ready          ──▶ ratchet :3000
                    │   everything else          ──▶ web     :3100
                    │ :80   → 301 redirect to :443            │
                    └──────────────────────────────────────────┘
```

Routing the API straight to ratchet (instead of through web's built-in
self-proxy) is exactly the production posture web's docs describe: "matches
how a real embedding host would deploy ratchet behind their own reverse proxy."
Because the browser sees one origin, there are no CORS round-trips.

## Quick start

```bash
cd gateway
cp .env.example .env          # optional — sane defaults work as-is
./scripts/gen-certs.sh        # self-signed cert for local HTTPS
docker compose up -d

# Start the apps the gateway proxies to (in the repo root):
cd .. && ./start.sh           # ratchet :3000 + web :3100

# Open https://localhost/  (accept the self-signed cert warning)
```

Stop with `docker compose down`.

## What goes where

| Path                                  | Upstream      |
| ------------------------------------- | ------------- |
| `/api/chat`                           | ratchet (SSE, unbuffered) |
| `/api/`, `/skillbox/`, `/dist/`       | ratchet       |
| `/health`, `/ready`                   | ratchet       |
| everything else (`/`, static assets)  | web           |

`/api/chat` is configured for Server-Sent Events: response buffering is off and
read/send timeouts are raised to 1h so the token stream isn't batched or cut.
`client_max_body_size` is 50m to allow photo/PDF attachment uploads.

## Configuration

All knobs live in `.env` (see `.env.example`):

| Var                | Default                       | Purpose                          |
| ------------------ | ----------------------------- | -------------------------------- |
| `SERVER_NAME`      | `localhost`                   | TLS SNI / redirect host          |
| `HTTP_PORT`        | `80`                          | published plain-HTTP port        |
| `HTTPS_PORT`       | `443`                         | published HTTPS port             |
| `WEB_UPSTREAM`     | `host.docker.internal:3100`   | web host address                 |
| `RATCHET_UPSTREAM` | `host.docker.internal:3000`   | ratchet backend address          |

If ports 80/443 are taken or need root, set `HTTP_PORT=8080` /
`HTTPS_PORT=8443` and browse `https://localhost:8443/`.

The nginx config is an envsubst **template** (`nginx/templates/default.conf.template`),
rendered at container start from the env vars above. Shared proxy directives
live in `nginx/snippets/proxy-common.conf`.

## TLS certificates

`./scripts/gen-certs.sh` writes a self-signed cert + key to `certs/`
(`fullchain.pem`, `privkey.pem`) with a SAN covering `localhost`, `127.0.0.1`,
and `$SERVER_NAME`. Regenerate with `FORCE=1 ./scripts/gen-certs.sh`.

For production, drop a real cert/key (e.g. from Let's Encrypt) into `certs/`
under those same two filenames and restart the container. The HTTP server block
already serves `/.well-known/acme-challenge/` from `/var/www/certbot` if you
wire up certbot. `certs/` is gitignored.

## Verifying

```bash
docker compose ps                              # gateway should be healthy
curl -k https://localhost/health               # → ratchet's {"status":"ok"}
curl -kI http://localhost/                     # → 301 to https://
docker compose logs -f gateway                 # tail access/error logs
```

After editing the template or snippets, reload without downtime:

```bash
docker compose exec gateway nginx -t           # validate config
docker compose restart gateway                 # re-render template + reload
```
# gateway

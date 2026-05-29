# RMO Gateway

nginx TLS reverse proxy that fronts the **web** demo host and the **ratchet**
backend as a single HTTPS origin.

```
                    ┌──────────── gateway (nginx) ────────────┐
  browser ──HTTPS──▶│ :8443 TLS termination                   │
                    │   /api/  /skillbox/  /dist/  ──▶ ratchet :3000
                    │   /health  /ready          ──▶ ratchet :3000
                    │   everything else          ──▶ web     :3100
                    │ :8080 → 301 redirect to :8443           │
                    └──────────────────────────────────────────┘
```

Routing the API straight to ratchet (instead of through web's built-in
self-proxy) is exactly the production posture web's docs describe: "matches
how a real embedding host would deploy ratchet behind their own reverse proxy."
Because the browser sees one origin, there are no CORS round-trips.

## Quick start (native nginx — default)

Runs nginx directly on the host. No Docker. Needs `nginx` + `envsubst` on PATH
(`brew install nginx gettext`).

```bash
# From the repo root — starts ratchet, web, AND the gateway:
./start.sh
# Open https://localhost:8443/  (accept the self-signed cert warning)
./stop.sh

# Or run just the gateway against already-running apps:
cd gateway && ./scripts/run-native.sh
```

`run-native.sh` renders `nginx/templates/default.conf.template` into
`gateway/.run/` with absolute host paths, generates a self-signed cert on first
run, validates the config, then starts (or reloads) nginx. The master PID is in
`gateway/.run/nginx.pid`; logs are in `gateway/.run/logs/`.

Default ports are **8080/8443** so nginx starts without `sudo`. For standard
80/443, set `HTTP_PORT=80 HTTPS_PORT=443` and run as root.

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

`run-native.sh` (and `start.sh`) read these env vars:

| Var                | Default            | Purpose                          |
| ------------------ | ------------------ | -------------------------------- |
| `SERVER_NAME`      | `localhost`        | TLS SNI / redirect host          |
| `HTTP_PORT`        | `8080`             | plain-HTTP listen port           |
| `HTTPS_PORT`       | `8443`             | HTTPS listen port                |
| `WEB_UPSTREAM`     | `127.0.0.1:3100`   | web host address                 |
| `RATCHET_UPSTREAM` | `127.0.0.1:3000`   | ratchet backend address          |

The nginx config is an envsubst **template** (`nginx/templates/default.conf.template`)
shared by both the native and Docker paths. Shared proxy directives live in
`nginx/snippets/proxy-common.conf`.

## TLS certificates

`./scripts/gen-certs.sh` writes a self-signed cert + key to `certs/`
(`fullchain.pem`, `privkey.pem`) with a SAN covering `localhost`, `127.0.0.1`,
and `$SERVER_NAME`. `run-native.sh` calls it automatically on first run.
Regenerate with `FORCE=1 ./scripts/gen-certs.sh`.

For production, drop a real cert/key (e.g. from Let's Encrypt) into `certs/`
under those same two filenames. The HTTP server block already serves
`/.well-known/acme-challenge/` from `/var/www/certbot` if you wire up certbot.
`certs/` is gitignored.

## Running under Docker (optional)

The same template also drives a container, for hosts that prefer Docker over a
system nginx:

```bash
cd gateway
cp .env.example .env          # set HTTP_PORT/HTTPS_PORT, upstreams
docker compose up -d          # publishes :80/:443 by default
```

In the container nginx always listens on 80/443; `docker-compose.yml` maps the
host `HTTP_PORT`/`HTTPS_PORT` onto them and points the upstreams at
`host.docker.internal`.

## Verifying

```bash
curl -k https://localhost:8443/health          # → ratchet's {"status":"ok"}
curl -kI http://localhost:8080/                # → 301 to https://…:8443/
tail -f gateway/.run/logs/error.log            # native logs
```

After editing the template or snippets, re-render + reload without downtime:

```bash
cd gateway && ./scripts/run-native.sh          # validates, then -s reload
```

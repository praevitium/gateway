# Gateway: TLS Reverse Proxy

## What It Does

nginx that fronts **web** (`:3100`) and **ratchet** (`:3000`) as a single HTTPS
origin. Terminates TLS, redirects HTTP → HTTPS, and routes by path: ratchet owns
`/api/`, `/skillbox/`, `/dist/`, `/health`, `/ready`; web owns everything else.

This is the production-shaped deployment the web subproject anticipates —
ratchet sits behind the host's reverse proxy, and the single origin removes
CORS round-trips.

## How It Runs

**Native nginx is the default** (this machine has no Docker; `brew install nginx`).
`../start.sh` calls `scripts/run-native.sh`, which renders the template into
`.run/`, generates a cert on first run, validates, and starts/reloads nginx on
**8080/8443** (non-root ports). Docker is an optional alternative — the SAME
template drives both.

## Layout

```
gateway/
├── docker-compose.yml                    // optional container path (nginx:alpine)
├── .env.example                          // SERVER_NAME, *_UPSTREAM, ports
├── nginx/
│   ├── templates/default.conf.template   // shared, envsubst-rendered (native + docker)
│   └── snippets/proxy-common.conf        // shared proxy_set_header block
├── scripts/
│   ├── run-native.sh                     // render + start/reload host nginx
│   └── gen-certs.sh                       // self-signed cert → certs/
├── certs/                                // TLS material (gitignored)
├── .run/                                 // rendered config + pid + logs (gitignored)
└── README.md
```

## Key Decisions

- **Native nginx, not Docker, is the primary path.** The project was first
  scaffolded around docker-compose, but the host has no Docker. `run-native.sh`
  renders the template to a self-contained `.run/nginx.conf` (own pid/log/temp
  paths) so nothing touches the system nginx config. docker-compose.yml stays as
  an optional deployment artifact driven by the same template.
- **One template, two runtimes.** `default.conf.template` is parameterized over
  `HTTP_LISTEN`/`HTTPS_LISTEN`/`CERT_DIR`/`SNIPPET_DIR`/`REDIRECT_HTTPS_PORT` so
  the native script (host paths, 8080/8443) and the container (`/etc/nginx/...`,
  80/443) both render it. nginx's own `$host`/`$scheme` survive envsubst because
  no matching env var exists.
- **Non-root ports by default.** 8080/8443 so `start.sh` brings the gateway up
  without sudo. The HTTP→HTTPS redirect carries the explicit `:8443` suffix
  (`REDIRECT_HTTPS_PORT`) since the standard-port assumption doesn't hold; it's
  empty when HTTPS_PORT=443.
- **API goes straight to ratchet, not through web's self-proxy.** web/server.mjs
  can proxy `/api/`, `/skillbox/`, `/dist/` itself, but the gateway routes those
  to ratchet directly — one less hop and the intended production seam.
- **`/api/chat` is a dedicated SSE location.** `proxy_buffering off` +
  `proxy_read_timeout 1h` so the streamed token response isn't batched or
  severed. This is the one path that breaks under default nginx buffering.
- **Self-signed certs for dev, drop-in real certs for prod.** `certs/` holds
  `fullchain.pem` + `privkey.pem`; gen-certs.sh creates a SAN cert for local
  use. Production swaps in a real cert under the same names. HSTS is left
  commented out so a dev cert doesn't pin browsers to HTTPS.

## What Not To Do

- **Don't buffer `/api/chat`.** Any change that re-enables proxy buffering on
  that location breaks streaming.
- **Don't commit `certs/`, `.env`, or `.run/`.** All gitignored; local/secret
  or machine-generated material.
- **Don't hardcode ports/hosts/paths in the template.** They're env-substituted
  so the same file serves native + docker — keep new knobs that way.
- **Don't duplicate proxy headers per-location.** Add shared directives to
  `snippets/proxy-common.conf`.
- **Don't edit `.run/nginx.conf` or `.run/server.conf`.** They're regenerated on
  every `run-native.sh`; edit the template/snippets instead.

# Central Routing

[![Nginx](https://img.shields.io/badge/Nginx-Alpine-009639?style=flat-square&logo=nginx&logoColor=white)](https://nginx.org/)
[![Docker](https://img.shields.io/badge/Docker-Containerized-2496ED?style=flat-square&logo=docker&logoColor=white)](https://www.docker.com/)
[![Docker Compose](https://img.shields.io/badge/Docker_Compose-v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Linux](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)](https://kernel.org/)
[![TLS Ready](https://img.shields.io/badge/TLS-Let's_Encrypt_ready-F4B400?style=flat-square&logo=letsencrypt&logoColor=white)](https://letsencrypt.org/)
[![License](https://img.shields.io/github/license/mach1el/routing?style=flat-square)](LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/mach1el/routing?style=flat-square)](https://github.com/mach1el/routing/commits/master)
[![Repository Size](https://img.shields.io/github/repo-size/mach1el/routing?style=flat-square)](https://github.com/mach1el/routing)
[![Open Issues](https://img.shields.io/github/issues/mach1el/routing?style=flat-square)](https://github.com/mach1el/routing/issues)

Central Nginx ingress for services on this host. Nginx is the only container
that publishes public HTTP/HTTPS ports; application containers are reached over
the shared `routing` Docker network.

## Current routes

| Host | Path | Upstream |
|---|---|---|
| `stvoid.duckdns.org` / `void-occult.localhost` | `/` | `voidocc-frontend:80` |
| `stvoid.duckdns.org` / `void-occult.localhost` | `/api/*` | `voidocc-backend:8000` |
| `stvoid.duckdns.org` / `void-occult.localhost` | `/health` | `voidocc-backend:8000` |
| any configured host | `/_routing/health` | Nginx health response |

Signal Bot is intentionally absent from the HTTP route table and does not need
the shared network. It uses outbound Telegram long-polling and does not run an
HTTP server. Add a route only after the bot gains a real health, metrics, or
webhook listener.

## Start locally

Start the router first so Docker creates the shared network, then start each
application stack:

```bash
cp .env.example .env
docker compose up -d

docker compose -f ../void-occult/docker-compose.yml up -d --build
docker compose -f ../signal-bot/docker-compose.yml up -d --build
```

Open <https://stvoid.duckdns.org> from the internet or
<http://void-occult.localhost> on the host. The `.localhost` suffix resolves
locally in modern browsers without editing `/etc/hosts`.

Verify routing:

```bash
curl -fsS http://void-occult.localhost/_routing/health
curl -fsS http://void-occult.localhost/health
```

## Configuration

Copy `.env.example` to `.env` and change:

- `ROUTING_HTTP_PORT`: published host port, default `80`.
- `ROUTING_HTTPS_PORT`: published TLS port, default `443`.
- `ROUTING_NETWORK`: shared Docker network name. Use the same value in every
  application stack.
- `ROUTING_CERT_DIR`: host directory containing `fullchain.pem` and
  `privkey.pem`.
- `VOID_OCCULT_HOST`: public Nginx `server_name`.
- `VOID_OCCULT_LOCAL_HOST`: HTTP-only hostname for local development.

After changing a host or an Nginx template, recreate the production router:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml \
  up -d --force-recreate
```

## VPS HTTPS setup

The setup script updates the DuckDNS address, installs a five-minute IP update
job, obtains a Let's Encrypt certificate through DuckDNS DNS-01, and starts the
production routing stack:

```bash
sudo bash letencrypt-setup.sh \
  --domain stvoid \
  --token YOUR_DUCKDNS_TOKEN \
  --email you@example.com
```

Run it from this repository on an Ubuntu/Debian VPS with Docker Compose v2
already installed. It synchronizes `VOID_OCCULT_HOST` and `ROUTING_CERT_DIR` in
the ignored `.env` file and mounts the certificate from
`/etc/ssl/duckdns/<subdomain>`. If that directory already contains
`fullchain.pem` and `privkey.pem`, the existing certificate is reused without a
new issuance. The DuckDNS token is written only to a root-owned updater script
under `/usr/local/bin`; it is not stored in this repository. Avoid committing
or pasting a real token into `.env`, logs, or other scripts.

acme.sh installs its own daily renewal job. Renewed files are copied to the
configured certificate directory and the routing container is reloaded
automatically. To run the same renewal check manually:

```bash
sudo scripts/renew-certificates.sh
```

When the certificate already exists, connect it to Docker Nginx without
contacting Let's Encrypt again:

```bash
sudo bash letencrypt-setup.sh \
  --domain stvoid \
  --reuse-existing
```

The rerun reuses the existing certificate and changes its renewal reload hook
to the routing container.

The production override publishes port 443, redirects the public HTTP hostname
to HTTPS, and keeps `void-occult.localhost` available over HTTP. To issue one
certificate for both the DuckDNS hostname and its subdomains, add `--wildcard`.

## Production notes

Allow inbound TCP ports 80 and 443. Certificate issuance and renewal use
DuckDNS DNS-01, so they do not depend on inbound port 80.

Do not add public routes to databases, internal debug endpoints, or Signal Bot
unless those services implement authentication and an explicit HTTP contract.

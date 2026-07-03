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
| `apexvoid.net` / `void-occult.localhost` | `/` | `voidocc-frontend:80` |
| `apexvoid.net` / `void-occult.localhost` | `/api/*` | `voidocc-backend:8000` |
| `apexvoid.net` / `void-occult.localhost` | `/health` | `voidocc-backend:8000` |
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

Open <https://apexvoid.net> from the internet or
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
- `VOID_OCCULT_HOST`: public Nginx `server_name`.
- `VOID_OCCULT_LOCAL_HOST`: HTTP-only hostname for local development.
- `VOID_OCCULT_CERT_NAME`: Let's Encrypt certificate directory name, normally
  identical to the public hostname.

After changing a host or an Nginx template, recreate the production router:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml \
  up -d --force-recreate
```

## HTTPS bootstrap

Start the HTTP configuration first, then request the certificate:

```bash
docker compose up -d
docker compose run --rm certbot certonly \
  --webroot --webroot-path /var/www/certbot \
  --domain apexvoid.net \
  --agree-tos --register-unsafely-without-email

docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

The production override publishes port 443, redirects the public HTTP hostname
to HTTPS, and keeps `void-occult.localhost` available over HTTP.

Run `scripts/renew-certificates.sh` daily from cron. If initial issuance was
blocked by a temporary DNS failure, the script retries it before enabling TLS.
Afterward Certbot only renews when the certificate is near expiry, and Nginx
reloads the renewed certificate.

## Production notes

Point public DNS at the host and allow inbound TCP ports 80 and 443. Port 80
must remain reachable for HTTP-01 certificate renewal.

Do not add public routes to databases, internal debug endpoints, or Signal Bot
unless those services implement authentication and an explicit HTTP contract.

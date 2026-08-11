# Central Routing

[![Nginx](https://img.shields.io/badge/Nginx-Alpine-009639?style=flat-square&logo=nginx&logoColor=white)](https://nginx.org/)
[![Docker](https://img.shields.io/badge/Docker-Containerized-2496ED?style=flat-square&logo=docker&logoColor=white)](https://www.docker.com/)
[![Docker Compose](https://img.shields.io/badge/Docker_Compose-v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Linux](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)](https://kernel.org/)
[![TLS Ready](https://img.shields.io/badge/TLS-Let's_Encrypt_ready-F4B400?style=flat-square&logo=letsencrypt&logoColor=white)](https://letsencrypt.org/)
[![License](https://img.shields.io/github/license/st-mich43l/routing?style=flat-square)](LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/st-mich43l/routing?style=flat-square)](https://github.com/st-mich43l/routing/commits/master)
[![Repository Size](https://img.shields.io/github/repo-size/st-mich43l/routing?style=flat-square)](https://github.com/st-mich43l/routing)
[![Open Issues](https://img.shields.io/github/issues/st-mich43l/routing?style=flat-square)](https://github.com/st-mich43l/routing/issues)

Central Nginx ingress for services on this host. Nginx is the only container
that publishes public HTTP/HTTPS ports; application containers are reached over
the shared `routing` Docker network.

## Current routes

| Host | Path | Upstream |
|---|---|---|
| `apexvoid.net` / `fate.apexvoid.net` / `void-occult.localhost` | `/` | `apexvoid-occult-frontend:80` |
| `apexvoid.net` / `fate.apexvoid.net` / `void-occult.localhost` | `/api/*` | `apexvoid-occult-backend:8000` |
| `apexvoid.net` / `fate.apexvoid.net` / `void-occult.localhost` | `/health` | `apexvoid-occult-backend:8000` |
| `trading.apexvoid.net` | `/` | `apexvoid-trading-frontend:80` |
| `ledger.apexvoid.net` | `/` | `apexvoid-ledger-frontend:80` |
| `ledger.apexvoid.net` | `/api/*` | `apexvoid-ledger-backend:4000` |
| any configured host | `/_routing/health` | Nginx health response |

The trading bot (`apexvoid-trading-bot`) is intentionally absent from the HTTP
route table and does not need the shared network. It uses outbound Telegram
long-polling and does not run an HTTP server. Add a route only after the bot
gains a real health, metrics, or webhook listener.

## Start locally

All deployable files live under `deployment-template/` — this is exactly what
CI ships to the VPS. Run compose commands from inside that directory.

Start the router first so Docker creates the shared network, then start each
application stack:

```bash
cd deployment-template
cp .env.example .env
docker compose up -d

docker compose -f ../../apexvoid-occult/docker-compose.yml up -d --build
docker compose -f ../../apexvoid-trading/docker-compose.yml up -d --build
docker compose -f ../../apexvoid-trading-bot/docker-compose.yml up -d --build
```

`apexvoid-ledger` has no local-dev compose file of its own (its
`deployment-template/docker-compose.yml.j2` is rendered by Ansible on
deploy, not run directly) — see that repo's README for local dev.

Open <https://apexvoid.net> from the internet or
<http://void-occult.localhost> on the host. The `.localhost` suffix resolves
locally in modern browsers without editing `/etc/hosts`.

Verify routing:

```bash
curl -fsS http://void-occult.localhost/_routing/health
curl -fsS http://void-occult.localhost/health
```

## Configuration

> [!IMPORTANT]
> In production, `.env` is **machine-managed** — [`ansible-library`](https://github.com/st-mich43l/ansible-library)
> renders it fresh on every deploy from `inventory/group_vars/all/vars.yml`'s
> `projects.routing.env_vars`, so it can never silently drift from what's
> declared there (which is exactly what caused `ledger.apexvoid.net` to be
> missing from `renew-certificates.sh`'s domain list after it was added here
> but not there). **Change a domain or port in `ansible-library`, not by
> hand-editing `.env` on the host** — the next deploy overwrites it.

For local dev only, copy `.env.example` to `.env` and change:

- `ROUTING_HTTP_PORT`: published host port, default `80`.
- `ROUTING_HTTPS_PORT`: published TLS port, default `443`.
- `ROUTING_NETWORK`: shared Docker network name. Use the same value in every
  application stack.
- `VOID_OCCULT_HOST`: public Nginx `server_name`.
- `VOID_OCCULT_LOCAL_HOST`: HTTP-only hostname for local development.
- `FATE_HOST`: public hostname for the Purple Star and I Ching service.
- `TRADING_HOST`: public hostname for the trading knowledge base.
- `LEDGER_HOST`: public hostname for the personal loan dashboard.
- `VOID_OCCULT_CERT_NAME`: Let's Encrypt certificate directory name, normally
  identical to the public hostname.
- `CERTBOT_ADDITIONAL_DOMAINS`: space-separated names added to the shared TLS
  certificate.

After changing a host or an Nginx template, recreate the production router:

```bash
cd deployment-template
docker compose -f docker-compose.yml -f docker-compose.prod.yml \
  up -d --force-recreate
```

## HTTPS bootstrap

Start the HTTP configuration first, then request the certificate:

```bash
cd deployment-template
docker compose up -d
docker compose run --rm certbot certonly \
  --webroot --webroot-path /var/www/certbot \
  --domain apexvoid.net \
  --domain fate.apexvoid.net \
  --domain trading.apexvoid.net \
  --domain ledger.apexvoid.net \
  --agree-tos --register-unsafely-without-email

docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

The production override publishes port 443, redirects the public HTTP hostname
to HTTPS, and keeps `void-occult.localhost` available over HTTP.

Run `deployment-template/scripts/renew-certificates.sh` daily from cron. If initial issuance was
blocked by a temporary DNS failure, the script retries it before enabling TLS.
Afterward Certbot only renews when the certificate is near expiry, and Nginx
reloads the renewed certificate.

## Deployment (CI)

Pushes to `master` that touch `deployment-template/**` trigger
[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml), which calls the
shared reusable workflow in
[`st-mich43l/action-library`](https://github.com/st-mich43l/action-library). CI
`rsync`s `deployment-template/` to `/home/apexvoid/deployment/routing` on the VPS and runs
`docker compose ... up -d`. The rsync excludes `.env` and `certbot/`, so
host-only config and TLS keys are never overwritten or deleted.

Configure once in the repo (**Settings → Secrets and variables → Actions**):

| Kind | Name | Sensitive | Value |
|------|------|-----------|-------|
| Variable | `DEPLOY_HOST` | no | VPS IP or DNS name |
| Variable | `DEPLOY_USER` | no | SSH deploy user |
| Variable | `DEPLOY_PORT` | no | SSH port (optional, defaults to 22) |
| Secret | `DEPLOY_SSH_KEY` | **yes** | Private key of the deploy user |

The deploy user must be in the `docker` group and have its public key in the
VPS `~/.ssh/authorized_keys`.

## Production notes

Point public DNS at the host and allow inbound TCP ports 80 and 443. Port 80
must remain reachable for HTTP-01 certificate renewal.

Do not add public routes to databases, internal debug endpoints, or the trading
bot unless those services implement authentication and an explicit HTTP contract.

#!/bin/sh
set -eu

ROUTING_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROUTING_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

DOMAIN=${VOID_OCCULT_HOST:-stvoid.duckdns.org}
CERT_NAME=${VOID_OCCULT_CERT_NAME:-$DOMAIN}

if [ ! -s "certbot/conf/live/$CERT_NAME/fullchain.pem" ]; then
  docker compose \
    -f docker-compose.yml \
    run --rm certbot certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --domain "$DOMAIN" \
    --cert-name "$CERT_NAME" \
    --agree-tos \
    --register-unsafely-without-email \
    --non-interactive
fi

docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  up -d

docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  run --rm certbot renew --quiet

docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  exec -T nginx nginx -s reload

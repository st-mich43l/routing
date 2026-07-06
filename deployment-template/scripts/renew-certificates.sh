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

DOMAIN=${VOID_OCCULT_HOST:-apexvoid.net}
CERT_NAME=${VOID_OCCULT_CERT_NAME:-$DOMAIN}
ADDITIONAL_DOMAINS=${CERTBOT_ADDITIONAL_DOMAINS:-fate.apexvoid.net trading.apexvoid.net}
CERT_PATH="certbot/conf/live/$CERT_NAME/fullchain.pem"

set -- --domain "$DOMAIN"
for domain in $ADDITIONAL_DOMAINS; do
  set -- "$@" --domain "$domain"
done

issue_certificate=false
if [ ! -s "$CERT_PATH" ]; then
  issue_certificate=true
else
  for domain in "$DOMAIN" $ADDITIONAL_DOMAINS; do
    if ! openssl x509 -in "$CERT_PATH" -noout -checkhost "$domain" >/dev/null 2>&1; then
      issue_certificate=true
      break
    fi
  done
fi

if [ "$issue_certificate" = true ]; then
  expand_arg=
  if [ -s "$CERT_PATH" ]; then
    expand_arg=--expand
  fi

  docker compose \
    -f docker-compose.yml \
    run --rm certbot certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    "$@" \
    --cert-name "$CERT_NAME" \
    $expand_arg \
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

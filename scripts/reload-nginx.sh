#!/bin/sh
set -eu

ROUTING_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if ! docker compose \
  -f "$ROUTING_DIR/docker-compose.yml" \
  -f "$ROUTING_DIR/docker-compose.prod.yml" \
  ps --status running --services | grep -qx nginx; then
  echo "Routing Nginx is not running; certificate files were updated without a reload."
  exit 0
fi

docker compose \
  -f "$ROUTING_DIR/docker-compose.yml" \
  -f "$ROUTING_DIR/docker-compose.prod.yml" \
  exec -T nginx nginx -s reload

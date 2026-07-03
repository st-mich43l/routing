#!/bin/sh
set -eu

ACME_HOME=${ACME_HOME:-/root/.acme.sh}

if [ ! -x "$ACME_HOME/acme.sh" ]; then
  echo "acme.sh was not found at $ACME_HOME/acme.sh" >&2
  echo "Run letencrypt-setup.sh first." >&2
  exit 1
fi

"$ACME_HOME/acme.sh" --cron --home "$ACME_HOME"

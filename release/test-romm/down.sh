#!/bin/sh
# down.sh — tear down the disposable test RomM completely (containers + data).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPOSE="docker compose"; docker compose version >/dev/null 2>&1 || COMPOSE=docker-compose
ROMM_TEST_SECRET=x $COMPOSE -f "$HERE/compose.yml" down -v --remove-orphans
rm -rf "$HERE/volumes"
echo "test-romm down (library/ fixtures kept)"

#!/usr/bin/env bash
# Runs sitespeed.io and sends per-iteration metrics to InfluxDB (plugin in plugins/influxdb).
# Used as the entrypoint of the sitespeed service (docker-compose.yml) and by Jenkins.
#
#   SITESPEED_URLS          URL file in urls/ (e.g. blazedemo.txt) or space-separated URLs
#   SITESPEED_ITERATIONS    page loads per URL (default 3)
#   SITESPEED_BROWSER       chrome | firefox (default chrome)
#   SITESPEED_CONNECTIVITY  native, cable, 4g, 3g, ... (default native = no throttling)
#   RUN_ID, APPLICATION, TEST_TITLE, INFLUXDB_URL, INFLUXDB_DB
# Extra arguments are passed to sitespeed.io unchanged.
set -euo pipefail

SITESPEED_DIR=${SITESPEED_DIR:-/sitespeed}
RESULTS_DIR=${RESULTS_DIR:-/results}
URLS=${SITESPEED_URLS:-blazedemo.txt}

sanitize() { tr -c 'A-Za-z0-9._-' '_' <<<"$1" | sed 's/_$//'; }

if [[ "$URLS" == http* ]]; then
  read -ra targets <<<"$URLS"
  default_app=$(sed -E 's#^https?://([^/:]+).*#\1#' <<<"${targets[0]}")
else
  targets=("$SITESPEED_DIR/urls/$URLS")
  default_app=$(basename "$URLS" .txt)
fi

export RUN_ID=$(sanitize "${RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}")
export APPLICATION=$(sanitize "${APPLICATION:-$default_app}")
export TEST_TITLE="${TEST_TITLE:-$APPLICATION frontend test} ($RUN_ID)"
export INFLUXDB_URL=${INFLUXDB_URL:-http://influxdb:8086}
export INFLUXDB_DB=${INFLUXDB_DB:-jmeter}

OUT="$RESULTS_DIR/sitespeed/$RUN_ID"
echo "run-sitespeed: run $RUN_ID, application $APPLICATION, results in $OUT"

exec /start.sh "${targets[@]}" \
  --outputFolder "$OUT" \
  -n "${SITESPEED_ITERATIONS:-3}" \
  -b "${SITESPEED_BROWSER:-chrome}" \
  --browsertime.connectivity.profile "${SITESPEED_CONNECTIVITY:-native}" \
  --plugins.add "$SITESPEED_DIR/plugins/influxdb/index.js" \
  "$@"

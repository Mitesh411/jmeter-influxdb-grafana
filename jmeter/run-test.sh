#!/usr/bin/env bash
# Runs one JMeter test plan headless and records the run in InfluxDB ("test_runs").
#
# Settings come from environment variables (see .env / docker-compose.yml / Jenkinsfile):
#   TEST_PLAN       plan file in $TEST_PLAN_DIR (default blazedemo.jmx)
#   RUN_ID          run identifier, tagged on every metric (default: UTC timestamp)
#   APPLICATION     application tag (default: plan file name without .jmx)
#   TEST_TITLE      free text shown in Grafana annotations
#   THREADS, RAMPUP, DURATION, TARGET_HOST, TARGET_PORT, TARGET_PROTOCOL   passed to the plan when set
#   MAX_ERROR_PCT   fail the run (exit 2) when the error % is above this value
#   INFLUXDB_URL, INFLUXDB_DB
# Extra arguments are passed to jmeter unchanged, e.g. -Jfoo=bar.
set -uo pipefail

TEST_PLAN_DIR=${TEST_PLAN_DIR:-/tests}
RESULTS_DIR=${RESULTS_DIR:-/results}
TEST_PLAN=${TEST_PLAN:-blazedemo.jmx}
INFLUXDB_URL=${INFLUXDB_URL:-http://influxdb:8086}
INFLUXDB_DB=${INFLUXDB_DB:-jmeter}

# Only characters that are safe in tags, file names and URLs.
sanitize() { tr -c 'A-Za-z0-9._-' '_' <<<"$1" | sed 's/_$//'; }
RUN_ID=$(sanitize "${RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}")
APPLICATION=$(sanitize "${APPLICATION:-$(basename "$TEST_PLAN" .jmx)}")
TEST_TITLE=${TEST_TITLE:-"$APPLICATION load test"}

RUN_DIR="$RESULTS_DIR/jmeter/$RUN_ID"
mkdir -p "$RUN_DIR"

# Line protocol string field escaping. test_runs numbers are written as floats (no "i"),
# matching the sitespeed.io plugin, because InfluxDB rejects mixed field types.
field() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }
influx_write() {
  curl -sS -o /dev/null --max-time 5 -XPOST "$INFLUXDB_URL/write?db=$INFLUXDB_DB&precision=ms" --data-binary "$1" \
    || echo "run-test: could not write run metadata to InfluxDB" >&2
}

START_MS=$(date +%s%3N)
SERIES="test_runs,tool=jmeter,application=$APPLICATION,runId=$RUN_ID"
# Expected end, so dashboard links have a sensible range while the test is still running.
EXPECTED_END_MS=$(( START_MS + (${RAMPUP:-0} + ${DURATION:-600} + 60) * 1000 ))
influx_write "$SERIES status=\"running\",title=$(field "$TEST_TITLE"),testPlan=$(field "$TEST_PLAN"),threads=${THREADS:-0},report=\"jmeter/$RUN_ID/html-report/index.html\",endTime=${EXPECTED_END_MS} $START_MS"

args=(
  -n -f
  -t "$TEST_PLAN_DIR/$TEST_PLAN"
  -l "$RUN_DIR/results.jtl"
  -j "$RUN_DIR/jmeter.log"
  -e -o "$RUN_DIR/html-report"
  -Jjmeter.reportgenerator.temp_dir=/tmp/jmeter-report
  "-Jinfluxdb.url=$INFLUXDB_URL/write?db=$INFLUXDB_DB"
  "-JrunId=$RUN_ID"
  "-Japplication=$APPLICATION"
  "-JtestTitle=$TEST_TITLE ($RUN_ID)"
)
# Unset values fall back to the defaults inside the test plan.
[[ -n "${THREADS:-}" ]] && args+=("-Jthreads=$THREADS")
[[ -n "${RAMPUP:-}" ]] && args+=("-Jrampup=$RAMPUP")
[[ -n "${DURATION:-}" ]] && args+=("-Jduration=$DURATION")
[[ -n "${TARGET_HOST:-}" ]] && args+=("-Jhost=$TARGET_HOST")
[[ -n "${TARGET_PORT:-}" ]] && args+=("-Jport=$TARGET_PORT")
[[ -n "${TARGET_PROTOCOL:-}" ]] && args+=("-Jprotocol=$TARGET_PROTOCOL")

echo "run-test: run $RUN_ID, plan $TEST_PLAN, application $APPLICATION, results in $RUN_DIR"
jmeter "${args[@]}" "$@"
JMETER_EXIT=$?

# Totals from the HTML report's statistics.json: "Total" : { ... "sampleCount" : N, "errorCount" : N, "errorPct" : X, ... }
STATS="$RUN_DIR/html-report/statistics.json"
total() { tr -d '\n ' <"$STATS" | sed -n "s/.*\"Total\":{[^}]*\"$1\":\([0-9.eE+-]*\).*/\1/p"; }
SAMPLES=0 ERROR_PCT=0
if [[ -f "$STATS" ]]; then
  SAMPLES=$(total sampleCount); ERROR_PCT=$(total errorPct)
fi

if (( JMETER_EXIT != 0 )) || [[ ! -f "$STATS" ]]; then
  STATUS=error; EXIT=1
elif [[ -n "${MAX_ERROR_PCT:-}" ]] && awk "BEGIN { exit !(${ERROR_PCT:-0} > $MAX_ERROR_PCT) }"; then
  STATUS=failed; EXIT=2
else
  STATUS=passed; EXIT=0
fi

END_MS=$(date +%s%3N)
# Same series and timestamp as the start point, so InfluxDB updates that point.
influx_write "$SERIES status=\"$STATUS\",samples=${SAMPLES:-0},errorPct=${ERROR_PCT:-0},durationSec=$(( (END_MS - START_MS) / 1000 )),endTime=$(( END_MS + 30000 )) $START_MS"

echo "run-test: $STATUS (samples=${SAMPLES:-0}, errors=${ERROR_PCT:-0}%${MAX_ERROR_PCT:+, threshold=$MAX_ERROR_PCT%})"
exit $EXIT

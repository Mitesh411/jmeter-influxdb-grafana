#!/usr/bin/env bash
# Starts a JMeter or sitespeed.io test container from inside the Jenkins container.
#
# The container runs on the host's Docker engine (sibling, not nested), so bind mounts need
# host paths. They are read from Jenkins' own mounts of the project (/project) and the
# results folder (/results). Test containers get only those folders, not the Docker socket.
#
# Usage: run-test-container.sh jmeter|sitespeed
# Settings are read from the environment (Jenkins job parameters + docker-compose.yml).
set -euo pipefail

tool=${1:?usage: run-test-container.sh jmeter|sitespeed}
self=$(hostname)
host_path() {
  docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$1\"}}{{.Source}}{{end}}{{end}}" "$self"
}
PROJECT=$(host_path /project)
RESULTS=$(host_path /results)
if [[ -z "$PROJECT" || -z "$RESULTS" ]]; then
  echo "Cannot find the host paths of /project and /results. Is Jenkins started from docker-compose.yml?" >&2
  exit 1
fi

common=(
  --rm --network "$PERF_NETWORK"
  -v "$RESULTS:/results"
  -e RUN_ID -e APPLICATION -e TEST_TITLE -e INFLUXDB_URL -e INFLUXDB_DB
)

case "$tool" in
  jmeter)
    # Build the image on first use (same build as `docker compose build jmeter`).
    docker image inspect "$JMETER_IMAGE" >/dev/null 2>&1 || docker build -t "$JMETER_IMAGE" /project/jmeter
    exec docker run "${common[@]}" \
      -v "$PROJECT/jmeter/test-plans:/tests:ro" \
      -e TEST_PLAN -e THREADS -e RAMPUP -e DURATION \
      -e TARGET_HOST -e TARGET_PORT -e TARGET_PROTOCOL -e MAX_ERROR_PCT \
      "$JMETER_IMAGE"
    ;;
  sitespeed)
    exec docker run "${common[@]}" --shm-size=1g \
      -v "$PROJECT/sitespeed:/sitespeed:ro" \
      -e SITESPEED_URLS -e SITESPEED_ITERATIONS -e SITESPEED_BROWSER -e SITESPEED_CONNECTIVITY \
      --entrypoint bash "$SITESPEED_IMAGE" /sitespeed/run-sitespeed.sh
    ;;
  *)
    echo "Unknown tool: $tool" >&2
    exit 1
    ;;
esac

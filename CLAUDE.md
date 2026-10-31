# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker Compose stack for live JMeter monitoring: JMeter's built-in Backend Listener (`InfluxdbBackendListenerClient`) pushes metrics every 5 s to InfluxDB 1.x, and Grafana reads them with InfluxQL. There is no application code. The "source" is `docker-compose.yml`, a JMeter `.jmx` test plan, Grafana provisioning YAML and a dashboard JSON. `README.md` is the user-facing setup guide. Keep it in sync when behavior changes.

## Commands

```bash
docker compose up -d                      # InfluxDB + Grafana (jmeter is in the "test" profile, so it is NOT started here)
docker compose run --rm jmeter            # build (first time) and run the test plan headless
DURATION=20 THREADS=2 docker compose run --rm jmeter   # quick smoke run; vars come from .env
TEST_PLAN=other.jmx docker compose run --rm jmeter     # run another plan from jmeter/test-plans/
docker compose build jmeter               # rebuild the JMeter image after Dockerfile changes
docker compose config -q                  # validate compose file
docker compose down -v                    # stop and wipe InfluxDB/Grafana volumes
```

On PowerShell, set overrides with `$env:DURATION=20; docker compose run --rm jmeter`.

There are no unit tests. To verify a change, run a short test and check the data:

```bash
# Raw data in InfluxDB (auth disabled; port bound to 127.0.0.1)
curl -s -G http://localhost:8086/query --data-urlencode db=jmeter --data-urlencode 'q=SHOW FIELD KEYS'
# Grafana datasource health and a dashboard query through Grafana (admin/admin)
curl -s http://admin:admin@localhost:3000/api/datasources/uid/influxdb-jmeter/health
curl -s -X POST http://admin:admin@localhost:3000/api/ds/query -H 'Content-Type: application/json' -d '{"from":"now-1h","to":"now","queries":[{"refId":"A","datasource":{"uid":"influxdb-jmeter"},"rawQuery":true,"resultFormat":"table","intervalMs":5000,"query":"<InfluxQL>"}]}'
```

When testing InfluxQL by hand, use curl as shown above, not `influx -execute` from PowerShell. PowerShell's quoting breaks double-quoted field names like `"pct95.0"`.

## How the pieces connect

- **Parameters flow from `.env` into `docker-compose.yml` (the `jmeter` service's `command`), then to JMeter `-J` properties, then to `${__P(name,default)}` in the `.jmx`.** Property names are `threads`, `rampup`, `duration`, `influxdb.url`, `application`, `testTitle`, `host`, `protocol`. The `.jmx` defaults point at `localhost:8086`, so a plan opened in a local JMeter GUI still reaches the Dockerized InfluxDB. To add a tunable, change all three places.
- **The InfluxDB version must stay 1.x.** The core listener writes to `/write?db=jmeter`. `influxdb:latest` is InfluxDB 3 and will break this. The `INFLUXDB_DB` env var creates the database only on first init, when the volume is empty.
- **Grafana provisioning:**
  - The datasource has the fixed uid `influxdb-jmeter`, with InfluxQL, `dbName: jmeter` and `timeInterval: 5s`.
  - Dashboards load from `grafana/dashboards/`, mounted at `/var/lib/grafana/dashboards`. Grafana polls this folder every 30 s, so a new or changed dashboard JSON appears without a restart.
- **The dashboard JSON does not hard-code the datasource.** Every panel and target uses `{"type":"influxdb","uid":"${DS}"}`, backed by the `DS` datasource template variable, so the file can also be imported by hand into any Grafana. Keep that pattern when adding panels.
- **Read-only test plan mount.** `jmeter/test-plans` is mounted read-only at `/tests`. Anything JMeter writes must go to `/results` (bind-mounted to `./results`, gitignored). This is why `-Jjmeter.reportgenerator.temp_dir=/tmp/jmeter-report` is set. Without it, HTML report generation fails.

## InfluxDB schema written by JMeter 5.6.3 (verified against live data)

Dashboard queries depend on these details:

- **Measurement `jmeter`:** tags `application`, `transaction`, `statut` (sic: `ok`/`ko`/`all`). Error rows add the tags `responseCode` and `responseMessage`.
- **Totals: `transaction='all'` with `statut='all'`.** Fields are `count`, `countError`, `hit`, `avg`, `min`, `max`, `pct90.0`, `pct95.0`, `pct99.0`, `rb`, `sb`.
- **Per-sampler rows** (`transaction=<sampler name>`) have **no `countError`**. Get per-transaction error counts from `sum("count")` with `statut='ko'`. Those rows exist only once something has failed.
- **Thread counts:** `transaction='internal'` has the fields `minAT`, `maxAT`, `meanAT`, `startedT`, `endedT`.
- **Counts vs. latency fields:** `count` is per 5 s interval. `avg`, `min`, `max` and `pctX` come from JMeter's sliding window of recent samples, not per interval. Dashboard percentiles are therefore approximations, `mean()` of the reported values.
- **Measurement `events`:** field `text` ("<testTitle> started/ended") and tag `title=ApacheJMeter`. The dashboard uses it for annotations.
- **Rates** are computed as `sum("count") / ($__interval_ms / 1000)` with `GROUP BY time($__interval)`, and panels set `"interval": "5s"` so buckets are never smaller than the send interval.

## Conventions

- Pin image versions (`influxdb:1.12.2`, `grafana/grafana:13.1.1`, JMeter 5.6.3 with a SHA-512 check in `jmeter/Dockerfile`). When bumping JMeter, update both `JMETER_VERSION` and `JMETER_SHA512` (from `https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-<ver>.tgz.sha512`) and the image tag in `docker-compose.yml`.
- Host ports are bound to `127.0.0.1`. This is a local-only setup with InfluxDB auth disabled.
- The example plan targets the public site `https://blazedemo.com`. Keep default load low (5 users with 1–3 s think time). Response assertions are substring checks on page text.

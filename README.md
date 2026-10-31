# JMeter → InfluxDB → Grafana

A Docker setup for watching JMeter load tests live in Grafana. JMeter's built-in **Backend Listener** pushes metrics into **InfluxDB 1.x** every 5 seconds, and Grafana charts them.

```
┌──────────┐  HTTP line protocol   ┌────────────┐   InfluxQL   ┌──────────┐
│  JMeter  │ ────────────────────▶ │  InfluxDB  │ ◀─────────── │ Grafana  │ ◀── you (browser)
│ (docker) │  /write?db=jmeter     │   :8086    │              │  :3000   │
└──────────┘                       └────────────┘              └──────────┘
      │
      └── load ──▶ https://blazedemo.com  (public demo site for load-testing practice)
```

| Component | Version | Why this version |
|-----------|---------|------------------|
| Apache JMeter | 5.6.3 (Java 21) | Latest JMeter release |
| InfluxDB | 1.12.2 | JMeter's built-in listener writes to the 1.x `/write?db=` API. **Don't use `influxdb:latest`**: that tag is InfluxDB 3. |
| Grafana | 13.1.1 | Current Grafana release line |

### Why InfluxDB 1.x, and not `influxdb:latest`?

JMeter's built-in InfluxDB Backend Listener was designed for InfluxDB 1.x, and everything in this setup follows that model:

- JMeter writes metrics to `http://influxdb:8086/write?db=jmeter`. That's a plain database name, with no organization, bucket or token.
- The `INFLUXDB_DB=jmeter` setting creates that database automatically on first start. This variable exists only in the 1.x image.
- The Grafana dashboard queries use **InfluxQL**, which is native to 1.x. So does community dashboard 5496.

The InfluxDB docs warn that the `influxdb:latest` tag now points to **InfluxDB 3**. With `latest`, this compose setup would break:

- `INFLUXDB_DB` is ignored, so the `jmeter` database is never created and the health check never passes.
- InfluxDB 3 expects token-based authentication, which this setup doesn't configure.
- The command-line tool and setup steps are different, so the `influx -execute "CREATE DATABASE jmeter"` commands in this README would no longer apply.
- Even if it worked today, `latest` can move to a new major version without warning. Pinning `1.12.2` keeps the stack reproducible.

**Can a newer InfluxDB work?** Yes, with extra setup. JMeter 5.6.3 can write to InfluxDB 2.x through the Backend Listener's `influxdbToken` parameter and a URL that includes `bucket` and `org`. InfluxDB 2.x and 3 also offer 1.x-compatible endpoints. Either route means creating tokens and an organization and bucket (or database), then reconfiguring the Grafana data source. That's extra work with little benefit for a local monitoring setup. This repo has been tested only with InfluxDB 1.x.

## What's in the repo

```
.
├── docker-compose.yml                  # influxdb + grafana (+ jmeter, run on demand)
├── .env                                # ports/credentials/test settings (local defaults)
├── jmeter/
│   ├── Dockerfile                      # JMeter 5.6.3, checksum-verified download
│   └── test-plans/blazedemo.jmx        # example plan with an InfluxDB Backend Listener
├── grafana/
│   ├── provisioning/datasources/       # auto-connects Grafana to InfluxDB
│   ├── provisioning/dashboards/        # auto-loads dashboards from grafana/dashboards
│   └── dashboards/jmeter-dashboard.json
└── results/                            # created at runtime: results.jtl, jmeter.log, html-report/
```

---

## Getting started from scratch

### 0. Prerequisites

- Docker Desktop (Windows/macOS) or Docker Engine with the Compose plugin (Linux). Check with:
  ```bash
  docker --version
  docker compose version
  ```
- Ports **3000** (Grafana) and **8086** (InfluxDB) free on your machine. Both are bound to `127.0.0.1` only.
- Internet access, because the test sends requests to `https://blazedemo.com`.

### 1. Start the stack (one command)

From the project folder:

```bash
docker compose up -d
```

This starts InfluxDB and Grafana. Grafana waits until InfluxDB is healthy. Check that both are running:

```bash
docker compose ps
```

Both containers should show `Up`, and `influxdb` should show `(healthy)`.

### 2. Create the InfluxDB database for JMeter

The database `jmeter` is **created automatically** on first start (`INFLUXDB_DB=jmeter` in `docker-compose.yml`). To check it, or to create it by hand:

```bash
# list databases (you should see "jmeter")
docker compose exec influxdb influx -execute "SHOW DATABASES"

# create it manually (safe to run again; does nothing if it already exists)
docker compose exec influxdb influx -execute "CREATE DATABASE jmeter"
```

### 3. Open Grafana and connect it to InfluxDB

1. Open **http://localhost:3000**.
2. Log in as **admin / admin**. You can skip the prompt to change the password, or change it there.

The InfluxDB data source is **already connected** through provisioning (`grafana/provisioning/datasources/influxdb.yml`). To check it, go to **Connections → Data sources → InfluxDB-JMeter → Save & test**. You should see *"datasource is working"*.

<details>
<summary>Prefer to connect it manually? (or to connect another Grafana)</summary>

1. **Connections → Data sources → Add data source → InfluxDB**
2. Fill in:
   | Field | Value |
   |-------|-------|
   | Query language | **InfluxQL** |
   | URL | `http://influxdb:8086` (from inside Docker) or `http://localhost:8086` (Grafana running on your host) |
   | Database | `jmeter` |
   | User / Password | leave empty (auth is disabled in this local setup) |
   | HTTP Method | `GET` |
   | Min time interval | `5s` |
3. Click **Save & test**.

</details>

### 4. Import the Grafana dashboard

The dashboard **JMeter Load Test (InfluxDB)** is loaded automatically into the **JMeter** folder (**Dashboards → JMeter**).

To import it by hand, for example into another Grafana:

1. **Dashboards → New → Import**
2. **Upload dashboard JSON file**, then select `grafana/dashboards/jmeter-dashboard.json`
3. Click **Import**. The dashboard has a *Data source* dropdown at the top, so it works with any InfluxDB (InfluxQL) data source.

**Alternative: community dashboard.** On the Import screen, enter ID **`5496`** ("Apache JMeter Dashboard using Core InfluxdbBackendListenerClient"), click **Load**, pick the InfluxDB data source, and click **Import**. It reads the same `jmeter` measurement.

### 5. Run the example JMeter test

```bash
docker compose run --rm jmeter
```

The first run builds the JMeter image, which takes about a minute. By default the test runs **5 users** for **120 s** with a 10 s ramp-up. Each user goes through the BlazeDemo flight-booking flow:

| Step | Request | Check |
|------|---------|-------|
| 01 Home page | `GET /` | "Welcome to the Simple Travel Agency!" |
| 02 Find flights | `POST /reserve.php` | "Flights from Paris to Buenos Aires" |
| 03 Choose flight | `POST /purchase.php` | "Your flight from TLV to SFO has been reserved." |
| 04 Purchase flight | `POST /confirmation.php` | "Thank you for your purchase today!" |

Each user waits 1–3 s between requests. Leave the user count low. BlazeDemo is a shared public site.

Override settings for a single run:

```bash
# bash / zsh
THREADS=10 DURATION=300 docker compose run --rm jmeter
```
```powershell
# PowerShell
$env:THREADS=10; $env:DURATION=300; docker compose run --rm jmeter
```

Available settings (defaults are in `.env`): `THREADS`, `RAMPUP`, `DURATION` (seconds), `APPLICATION` (the tag used to filter in Grafana), `TEST_TITLE` (the annotation text), and `TEST_PLAN` (a file in `jmeter/test-plans/`).

### 6. Watch the results

Open the dashboard in Grafana while the test runs. It refreshes every 5 s and shows:

- Total requests, failed requests, error rate, average and 95th-percentile response time, and peak users
- Throughput (requests/s and errors/s) and active users over time
- Average and 95th-percentile response time per transaction, and throughput per transaction
- Network traffic sent and received
- A per-transaction summary table and an errors-by-response-code table
- Purple markers at test **start** and **end**

Use the **Application** and **Transaction** dropdowns at the top to filter.

When the run finishes, JMeter also writes:
- `results/results.jtl`: raw sample results
- `results/jmeter.log`: the JMeter log
- `results/html-report/index.html`: JMeter's static HTML report, which you can open in a browser

---

## How the Backend Listener is configured

In `jmeter/test-plans/blazedemo.jmx` → **InfluxDB Backend Listener**:

| Parameter | Value |
|-----------|-------|
| Implementation | `org.apache.jmeter.visualizers.backend.influxdb.InfluxdbBackendListenerClient` |
| influxdbMetricsSender | `org.apache.jmeter.visualizers.backend.influxdb.HttpMetricsSender` |
| influxdbUrl | `${__P(influxdb.url,http://localhost:8086/write?db=jmeter)}` |
| application | `${__P(application,blazedemo)}` |
| measurement | `jmeter` |
| summaryOnly | `false` (send metrics for each transaction, not just the total) |
| samplersRegex | `.*` |
| percentiles | `90;95;99` |
| testTitle | `${__P(testTitle,BlazeDemo load test)}` |

In Docker, `-Jinfluxdb.url=http://influxdb:8086/write?db=jmeter` is passed by `docker-compose.yml`. When you run the plan from a **JMeter GUI on your own machine**, the default `http://localhost:8086/...` reaches the same InfluxDB through the published port.

**Adding the listener to your own test plan:** right-click the Test Plan, then **Add → Listener → Backend Listener**. Choose the `InfluxdbBackendListenerClient` implementation and set the parameters above. Save the `.jmx` in `jmeter/test-plans/` and run it with `TEST_PLAN=your-plan.jmx docker compose run --rm jmeter`.

### What ends up in InfluxDB

- Measurement `jmeter` with tags `application`, `transaction`, and `statut` (`ok` / `ko` / `all`):
  - `transaction=all` holds the totals across all transactions. Its fields are `count`, `countError`, `hit`, `avg`, `min`, `max`, `pct90.0`, `pct95.0`, `pct99.0`, `rb`, and `sb`.
  - `transaction=internal` holds thread counts: `minAT`, `maxAT`, `meanAT`, `startedT`, and `endedT`.
  - Errors are written with extra `responseCode` and `responseMessage` tags.
- Measurement `events` holds the test start and end annotations (field `text`).

Try it yourself:

```bash
docker compose exec influxdb influx -database jmeter -execute "SHOW MEASUREMENTS"
docker compose exec influxdb influx -database jmeter -execute "SELECT * FROM jmeter WHERE transaction='all' ORDER BY time DESC LIMIT 5"
```

---

## Day-to-day commands

| What | Command |
|------|---------|
| Start InfluxDB + Grafana | `docker compose up -d` |
| Run the test | `docker compose run --rm jmeter` |
| Follow the logs | `docker compose logs -f influxdb grafana` |
| Stop (keep data) | `docker compose down` |
| Stop and **delete all data** | `docker compose down -v` |
| Clear test data only | `docker compose exec influxdb influx -execute "DROP DATABASE jmeter; CREATE DATABASE jmeter"` |
| Rebuild the JMeter image | `docker compose build jmeter` |

## Troubleshooting

- **Dashboard is empty.** Check that the time range (top right) covers the test run and that the **Application** dropdown has a value. If the dropdown is empty, no data has arrived yet. Look in `results/jmeter.log` for `InfluxdbBackendListenerClient` or HTTP errors.
- **The dashboard doesn't appear right after `up -d`.** Grafana scans the dashboards folder every 30 s. Wait a moment, then reload the page.
- **`port is already allocated`.** Another process is using 3000 or 8086. Stop it, or change the left-hand port in `docker-compose.yml` (for example `"127.0.0.1:3001:3000"`).
- **The test shows many errors.** BlazeDemo may be slow or down. Open https://blazedemo.com in a browser, and lower `THREADS`.
- **Grafana password.** It is read from `.env` (`GRAFANA_ADMIN_PASSWORD`) only when Grafana first creates its data volume. To reset it, run `docker compose down -v` and start again.

## Security notes

This setup is for **local use**. InfluxDB authentication is off, Grafana uses `admin/admin`, and both ports are bound to `127.0.0.1`. Before you expose it anywhere, set `INFLUXDB_HTTP_AUTH_ENABLED=true` with admin and write users (see the InfluxDB Docker docs below), add the credentials to the data source, and change the Grafana password.

## References

- JMeter downloads: https://jmeter.apache.org/download_jmeter.cgi
- JMeter real-time results and Backend Listener: https://jmeter.apache.org/usermanual/realtime-results.html
- InfluxDB v1 in Docker: https://docs.influxdata.com/influxdb/v1/introduction/install/docker/
- Grafana dashboard 5496: https://grafana.com/grafana/dashboards/5496

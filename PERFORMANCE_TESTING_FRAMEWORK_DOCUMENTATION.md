# Performance Testing Framework: Architecture & Engineering Documentation

## 1. Executive Summary & Brief Overview

The **Performance Testing Framework** (`serputko/performance-testing-framework`) is an end-to-end continuous performance testing, metric ingestion, and analytical visualization platform. It unifies backend protocol-level load testing (JMeter) and client-side synthetic frontend performance testing (Sitespeed.io, WebPageTest) under unified orchestration (Jenkins), central time-series telemetry (InfluxDB, Graphite, Telegraf), and analytical monitoring (Grafana).

```
                            [ Test Operator ]
                                    │
                               starts jobs
                                    ▼
                             [   Jenkins   ]
                                    │
           ┌────────────────────────┴────────────────────────┐
           │ runs                                            │ runs
           ▼                                                 ▼
   [ Backend Job ]                                    [ Frontend Job ]
  (BackendJob.xml)                                   (FrontendJob.xml)
           │                                                 │
     starts runner                                   runs tests ┌───────┐
           ▼                                                    ▼       ▼
    [ JMeter Runner ] ── executes ──▶ [ Test Scenarios ]   [Sitespeed] [WPT]
           │                                                    │       │
      sends metrics                                       sends metrics │
           ▼                                                    │       │
    [( InfluxDB )] ◀────────────────────────────────────────────┘       │
           ▲   ▲                                                        │
           │   └────────────── proxies requests ──────────────┐         │
     visualizes                                               │         │
        metrics                                               │         │
           │                                        [ Timeshift Proxy ] │
   [ Load Monitoring ]                             ([app.js] / [handlers.js])
  (LoadTestMonitoring.json)                                   ▲         │
           ▲                                                  │ queries │
        renders                                               │ datasource
           │                                                  │         │
      [ Grafana ] ────── loads dashboard ─────▶ [ Test Comparison ] ◀───┘
                                                (compare_tests.js)
```

### Core Workflow at a Glance
1. **Triggering**: A test operator triggers parameterized jobs in **Jenkins**.
2. **Backend Execution**: Jenkins executes `BackendJob.xml`, which spins up the **JMeter runner** to execute compiled `.jmx` **Test scenarios**. Real-time sample data and thread metrics stream directly into **InfluxDB** via HTTP Line Protocol (`InfluxdbBackendListenerClient`).
3. **Frontend Execution**: Jenkins executes `FrontendJob.xml`, triggering **Sitespeed.io** (in-browser browser metrics, Core Web Vitals) and **WebPageTest (WPT)** private instances for deep waterfall analysis.
4. **Infrastructure Telemetry**: **Telegraf** agents collect host/system metrics (CPU, memory, disk, network) across target environments and forward them to **InfluxDB** and/or **Graphite**.
5. **Real-Time Visualization**: **Grafana** consumes InfluxDB time-series data to render live dashboard metrics (`LoadTestMonitoring.json`).
6. **Cross-Test Comparison**: Grafana loads scripted dashboards (`compare_tests.js`), routing queries through a custom **Timeshift proxy** (`app.js`, `handlers.js`) to align baseline and candidate runs across arbitrary historical time windows.

---

## 2. Detailed Component Breakdown, Couplings, and Blast Radius

### Group 1: Test Execution Subsystem

#### 2.1 Test Operator (`node_user`)
- **Description**: The human engineer, automated pipeline, or webhook initiating performance experiments.
- **Coupling**:
  - Outgoing coupling to **Jenkins** via HTTP/HTTPS web UI or REST API (`POST /job/<job_name>/buildWithParameters`).
- **Impact & Blast Radius**: High governance impact. Misconfigured job parameters (e.g., target host, thread count, ramp-up time) can cause unintended denial-of-service against non-production or production targets.

#### 2.2 Jenkins Master / Controller (`node_jenkins`)
- **Description**: The central continuous integration and orchestration engine coordinating backend and frontend test pipelines.
- **Coupling**:
  - Triggers **Backend Job** (`BackendJob.xml`) and **Frontend Job** (`FrontendJob.xml`).
  - Manages agent nodes, credentials, execution workspaces, artifacts (`.jtl`, HTML reports), and pipeline schedules.
- **Impact & Blast Radius**: Single Point of Failure (SPOF) for pipeline automation. If Jenkins fails or agent nodes disconnect, no automated load or frontend runs can be initiated or reported to CI gates.

#### 2.3 Backend Job (`node_backend_job` / `BackendJob.xml`)
- **Description**: The Jenkins job definition configuring backend load tests (parameter injection: target hostname, virtual users, duration, ramp-up, test plan selection).
- **Coupling**:
  - Tight coupling with Jenkins execution plugins, workspace filesystem, and Docker/CLI environments.
  - Spawns the **JMeter Runner**.
- **Impact & Blast Radius**: Job misconfigurations (e.g., missing heap options, incorrect environment variables) immediately fail backend executions before any load is generated.

#### 2.4 JMeter Runner (`node_jmeter`)
- **Description**: The JVM-based load engine executing distributed or standalone JMeter CLI executions.
- **Coupling**:
  - Reads **Test scenarios** (`.jmx` XML scripts).
  - Outgoing TCP/HTTP to Target Application Under Test (AUT).
  - Outgoing HTTP Line Protocol (`/write?db=jmeter`) to **InfluxDB** via the built-in `InfluxdbBackendListenerClient`.
- **Impact & Blast Radius**: Highly sensitive to CPU/Memory starvation. If JMeter runs out of heap (`java.lang.OutOfMemoryError`), virtual user threads stall or crash, skewing latency calculations and leading to false performance conclusions. If JMeter's connection to InfluxDB breaks, telemetry is lost even if load generation continues.

#### 2.5 Test Scenarios (`node_scenarios`)
- **Description**: Apache JMeter `.jmx` test script definitions encompassing thread groups, HTTP samplers, transaction controllers, think-time timers, extractors, and assertions.
- **Coupling**:
  - Tightly coupled to JMeter’s plugin ecosystem (e.g., JMeter Standard / Custom Plugins, JSON Path extractors) and the AUT API specification.
- **Impact & Blast Radius**: Broken assertions or outdated endpoints invalidate the entire test run, generating false negative error spikes (`statut=ko`) in InfluxDB.

---

### Group 2: Frontend Testing Subsystem

#### 2.6 Frontend Job (`node_frontend_job` / `FrontendJob.xml`)
- **Description**: The Jenkins orchestration job dedicated to synthetic client-side performance measurements.
- **Coupling**:
  - Triggers **Sitespeed.io** container runners and dispatches test runs to the **WebPageTest (WPT)** server.
- **Impact & Blast Radius**: Isolated from backend load generation. If this job fails, client-side real-user metrics (First Contentful Paint, Largest Contentful Paint, Speed Index) are missing, but backend throughput testing remains unaffected.

#### 2.7 Sitespeed.io (`node_sitespeed`)
- **Description**: Containerized browser automation tool (wrapping Browsertime, Chrome/Firefox drivers, Lighthouse) measuring real browser page load performance.
- **Coupling**:
  - Consumes target URLs; outputs JSON metrics, video recordings, and HAR files.
  - Forwards aggregated performance timing metrics into **InfluxDB** / **Graphite**.
- **Impact & Blast Radius**: High CPU/GPU footprint on Jenkins runners due to headless browser instances. Resource contention can cause artificial frontend latency inflation if co-hosted with JMeter.

#### 2.8 WebPageTest Server (`node_wpt` / `wptserver`)
- **Description**: On-premise or containerized instance of WebPageTest server and test agents conducting multi-step browser waterfalls, connection throttling (3G/4G/Cable), and CPU emulation.
- **Coupling**:
  - Receives test dispatch requests from `FrontendJob.xml`; agents record waterfalls and send results back to WPT server.
- **Impact & Blast Radius**: Agent availability bottlenecks. If WPT test agents are busy or stalled, frontend test stages block or time out.

---

### Group 3: Metrics & Storage Subsystem

#### 2.9 InfluxDB (`node_influx`)
- **Description**: Time-series database storing real-time JMeter metrics (`jmeter` measurement: response times, throughput, active threads, percentiles, error codes) and frontend metrics.
- **Coupling**:
  - Receives continuous asynchronous writes from **JMeter Runner** (`/write?db=jmeter`).
  - Receives system metrics from **Telegraf**.
  - Queried directly by **Grafana** (`LoadTestMonitoring.json`).
  - Queried indirectly by **Timeshift Proxy** for historical test comparison.
- **Impact & Blast Radius**: **Critical Single Point of Failure for Observability**. If InfluxDB crashes or its write buffer fills up:
  - JMeter metric sender threads block or drop sample packets.
  - Live Grafana dashboards fail to render (`502 Bad Gateway` or timeouts).
  - Historical test data cannot be audited.

#### 2.10 Telegraf Agent (`node_telegraf`)
- **Description**: Plugin-driven server agent collecting host and container metrics (CPU, RAM, Network I/O, Disk usage) from the AUT and test infrastructure.
- **Coupling**:
  - Probes target server OS metrics and flushes data to **InfluxDB** and/or **Graphite**.
- **Impact & Blast Radius**: Low impact on load execution, but critical for diagnosing root causes (distinguishing whether high response times are due to database CPU saturation vs. application thread pool exhaustion).

#### 2.11 Graphite (`node_graphite`)
- **Description**: Alternative time-series metric storage utilizing the Carbon/Whisper format, frequently used by Sitespeed.io and legacy performance plugins.
- **Coupling**:
  - Receives metrics from **Telegraf** or frontend tools; optionally queried by Grafana.
- **Impact & Blast Radius**: Low coupling with backend JMeter runs; failure affects only specific legacy frontend panels.

#### 2.12 Timeshift Proxy (`node_proxy_app` / `app.js`)
- **Description**: Node.js reverse proxy intercepting Grafana InfluxQL queries, calculating historical time offsets, and shifting test time boundaries for direct comparison.
- **Coupling**:
  - Upstream: **Grafana** (configured as a custom HTTP InfluxDB datasource).
  - Modules: Imports query rewriting logic from `handlers.js`.
  - Downstream: **InfluxDB** (forwards modified queries).
- **Impact & Blast Radius**: Directly impacts the **Test Comparison** dashboard (`compare_tests.js`). If `app.js` crashes, baseline vs. candidate comparison fails while direct live monitoring (`LoadTestMonitoring.json`) continues to function.

#### 2.13 Query Rewriting Handlers (`node_proxy_handlers` / `handlers.js`)
- **Description**: Core regex/string manipulation algorithms that parse incoming InfluxQL queries, extract `WHERE time >= ... AND time <= ...` clauses, and apply time shifts (e.g., `-7d`, `-1d`, or fixed epoch timestamps).
- **Coupling**:
  - Tightly coupled to `app.js` and specific InfluxQL syntax flavors.
- **Impact & Blast Radius**: If query parsing fails (e.g., upon encountering new Grafana query syntax or macro transformations), queries return HTTP 400 or malformed data, corrupting comparison charts.

---

### Group 4: Dashboards & Visualization Subsystem

#### 2.14 Grafana (`node_grafana`)
- **Description**: Multi-tenant analytical visualization dashboard engine.
- **Coupling**:
  - Connects to **InfluxDB** (direct native datasource).
  - Connects to **Timeshift Proxy** (proxy datasource).
  - Hosts **Load Monitoring** and **Test Comparison** dashboards.
- **Impact & Blast Radius**: Operator-facing observability interface. Grafana failures prevent visual assessment during test execution, but do not stop ongoing load generation in JMeter or data ingestion into InfluxDB.

#### 2.15 Load Monitoring Dashboard (`node_monitoring` / `LoadTestMonitoring.json`)
- **Description**: Production-grade Grafana dashboard displaying live telemetry: Active Threads, Throughput (req/sec), Error Rate (%), Percentiles (p90, p95, p99), and Latency Breakdown by Transaction.
- **Coupling**:
  - Direct dependency on the InfluxDB schema written by JMeter (measurement `jmeter`, tags: `application`, `transaction`, `statut`).
- **Impact & Blast Radius**: If the tag schema changes (e.g., renaming `statut` or missing `transaction`), panels show `No Data`, blinding operators to system stress.

#### 2.16 Test Comparison Dashboard (`node_comparison` / `compare_tests.js`)
- **Description**: Scripted/dynamic Grafana dashboard generator querying via the Timeshift Proxy to overlay metric curves of two different test runs on the same visual timeline.
- **Coupling**:
  - Depends on Grafana’s scripted dashboard API and the **Timeshift Proxy** (`app.js`).
- **Impact & Blast Radius**: Affects retrospective regression analysis and release sign-off gating.

---

## 3. Coupling Matrix & Critical Path Dependency Analysis

| Source Component | Target Component | Protocol / Channel | Coupling Type | Criticality |
| :--- | :--- | :--- | :--- | :--- |
| **Test Operator** | Jenkins | HTTPS / Web UI | Loose (Asynchronous) | Medium |
| **Jenkins** | Backend Job (`.xml`) | Jenkins Internal Engine | Tight (Configuration) | High |
| **Backend Job** | JMeter Runner | Process Exec / Docker Run | Tight (Runtime dependency) | High |
| **JMeter Runner** | Test Scenarios (`.jmx`)| File / XML Parsing | Tight (Script dependency) | High |
| **JMeter Runner** | Application Under Test | HTTP/HTTPS/gRPC | Tight (Network/Throughput) | Critical |
| **JMeter Runner** | InfluxDB | HTTP REST Line Protocol | Moderate (Async batch buffer)| High |
| **Jenkins** | Frontend Job (`.xml`) | Jenkins Internal Engine | Tight (Configuration) | Medium |
| **Frontend Job** | Sitespeed.io / WPT | Docker CLI / REST API | Moderate (Job lifecycle) | Medium |
| **Sitespeed.io** | Target AUT | HTTP/HTTPS (Browser) | Loose (Black-box browser) | Medium |
| **Telegraf** | Target AUT / Hosts | System Probes (Proc/Sockets)| Loose (Read-only polling) | Low |
| **Telegraf** | InfluxDB / Graphite | TCP / Line Protocol | Loose (Buffer dropped on fail) | Medium |
| **Grafana** | InfluxDB | InfluxQL / HTTP | Moderate (Query engine) | High |
| **Grafana** | Timeshift Proxy | HTTP / InfluxQL compatible | Moderate (Proxy endpoint) | Medium |
| **Timeshift Proxy**| `handlers.js` | Node.js CommonJS Import | Tight (In-process call) | High |
| **Timeshift Proxy**| InfluxDB | HTTP Reverse Proxy | Tight (Direct forwarding) | High |
| **Grafana** | `compare_tests.js`| Grafana Scripted Dashboard | Tight (Grafana JS runtime) | Medium |

---

## 4. Roadblocks, Failure Modes & Chaos Engineering Analysis

When running heavy load, testing systems undergo severe stress. The following section models failure scenarios, their cascading blast radii, and recovery playbooks.

```
                    ┌───────────────────────────────┐
                    │     CHAOS INGESTION MATRIX    │
                    └───────────────┬───────────────┘
                                    │
       ┌────────────────────────────┼────────────────────────────┐
       ▼                            ▼                            ▼
[ InfluxDB OOM / Disk Full ]  [ JMeter Heap Exhaustion ]   [ Network Drops & Latency ]
 • JMeter buffers fill up      • Virtual threads freeze     • Artificially high latency
 • Drops metric batches        • GC pauses halt traffic     • TCP reset storms
 • Grafana panels show N/A     • Unreliable test results    • Metric corruption
       │                            │                            │
       └────────────────────────────┼────────────────────────────┘
                                    ▼
                    ┌───────────────────────────────┐
                    │    SYSTEM & DATA ROADBLOCKS   │
                    │  • Timeshift Proxy Crash      │
                    │  • Metric Cardinatlity Boom   │
                    │  • Clock Skew / NTP Drift     │
                    └───────────────────────────────┘
```

### 4.1 InfluxDB Saturation (Disk I/O, Memory Exhaustion & High Cardinality)
- **Failure Phenomenon**: Under tests with 1,000+ distinct dynamic sampler URLs or rapid 1-second metric flush intervals, InfluxDB's Time-Structured Merge (TSM) engine experiences memory exhaustion (OOM kill) or write-ahead-log (WAL) disk saturation.
- **Cascading Blast Radius**:
  - `InfluxdbBackendListenerClient`'s HTTP write queue backs up in JMeter memory.
  - JMeter worker threads may block waiting for buffer availability if queue limits are unbounded.
  - Grafana dashboard queries time out with 504 errors.
- **Chaos Experiment**:
  - Introduce 100% disk I/O wait on InfluxDB using `fio` or throttle disk write IOPS to 50 using `cgroups`.
  - Simulate network partition between JMeter and InfluxDB using `iptables -A INPUT -p tcp --dport 8086 -j DROP`.
- **Mitigation & Recovery**:
  - Enable sample filtering via `samplersRegex` to exclude health checks and static assets.
  - Set `summaryOnly=true` during ultra-high stress tests.
  - Configure Retention Policies (RPs) and Downsampling Continuous Queries in InfluxDB.

### 4.2 JMeter Runner Heap Exhaustion & JVM Garbage Collection Pauses
- **Failure Phenomenon**: Improper JVM memory allocation (`-Xms1g -Xmx1g` on high-concurrency 5,000+ thread tests) induces Stop-The-World (STW) garbage collection pauses.
- **Cascading Blast Radius**:
  - JMeter fails to generate configured transactions per second (TPS).
  - Measured response times reflect JMeter’s internal JVM freeze rather than AUT latency, completely invalidating test accuracy.
- **Chaos Experiment**:
  - Restrict container memory to 512MB while pushing 2,000 threads.
  - Trigger JVM pause injection using `jcmd <pid> GC.run` continuously.
- **Mitigation & Recovery**:
  - Implement a strict distributed load generation topology (Master-Worker / JMeter Kubernetes Operator).
  - Standardize JVM garbage collection to ZGC or Shenandoah (`-XX:+UseZGC`) to eliminate STW pauses over 1ms.

### 4.3 Timeshift Proxy Bottleneck or Termination (`app.js` / `handlers.js`)
- **Failure Phenomenon**: If the Node.js event loop blocks due to excessive regex processing in `handlers.js` on large multi-megabyte InfluxQL payloads, or unhandled exceptions terminate the single-threaded Node process.
- **Cascading Blast Radius**:
  - The `compare_tests.js` dashboard fails completely with HTTP 502/504 errors.
  - Test comparisons cannot be generated during post-test triage.
- **Chaos Experiment**:
  - Kill the `node app.js` process during test comparison rendering.
  - Inject 500ms delay into proxy query forwarding using `tc qdisc add dev eth0 root netem delay 500ms`.
- **Mitigation & Recovery**:
  - Run the Timeshift proxy under process managers like PM2 with automatic clustering and auto-restart policies.
  - Migrate timeshifting logic natively into modern Grafana query transformations.

### 4.4 Clock Skew & NTP Drift Across Distributed Runners
- **Failure Phenomenon**: In distributed runner setups or between Jenkins, JMeter, and InfluxDB, clock skew exceeding a few seconds leads to mismatched timestamps in time-series metrics.
- **Cascading Blast Radius**:
  - JMeter samples appear in the "future" or "past" relative to server telemetry collected by Telegraf.
  - Correlation between client-side errors and server-side CPU spikes is ruined.
- **Chaos Experiment**:
  - Adjust local system clock by 30 seconds (`date -s "+30 seconds"`) on the JMeter runner during an active test.
- **Mitigation & Recovery**:
  - Enforce chrony/NTP synchronization on all runner hosts and database containers with alerts if offset exceeds 10ms.

---

## 5. Architectural Improvements & Modernization Roadmap

| Dimension | Legacy Architecture (As Diagrammed) | Recommended Modern Architecture | Key Business & Engineering Benefits |
| :--- | :--- | :--- | :--- |
| **Load Engine Orchestration** | Static Jenkins VM / Local Docker Runner | **Kubernetes-native Distributed JMeter Operator** (or K6 / Locust) | Dynamic autoscaling of load generators, self-healing runner pods, zero infrastructure waste when idle. |
| **Time-Series Storage** | InfluxDB 1.x (Standalone) / Graphite | **VictoriaMetrics** or **InfluxDB 3.x / TimescaleDB** | 10x higher write throughput, superior compression, active clustering, and native OpenTelemetry ingestion. |
| **Historical Comparison** | Node.js Timeshift Proxy (`app.js`) + Scripted Dashboard (`compare_tests.js`) | **Native Grafana Transformations** or **Built-in Time-Shift Overlays** | Eliminates custom proxy maintenance, removes SPOF, and leverages official Grafana multi-query features. |
| **Pipeline Governance** | Jenkins XML Jobs (`BackendJob.xml`) | **Jenkins Declarative Pipeline (`Jenkinsfile`) or GitHub Actions / GitLab CI** | Infrastructure-as-code, versioned test pipelines, pull-request automated performance checks. |
| **Quality Gates** | Manual Grafana Inspection | **Automated SLA/SLO Gating via Keptn / Lighthouse CI / Datadog Monitors** | Automatic pass/fail build decisions in CI pipelines based on p95 latency and error budgets. |
| **Trace Correlation** | Isolated Metrics (JMeter + Telegraf) | **Distributed Tracing (OpenTelemetry + Jaeger / Tempo)** | Ability to click from a slow JMeter 95th-percentile transaction directly into the exact backend microservice trace. |

---

## 6. Implementation Checklist & Operational Playbook

### Running a Reliable Performance Verification
1. **Infrastructure Pre-Flight Check**:
   - Verify InfluxDB storage space: `df -h /var/lib/influxdb`.
   - Ensure NTP synchronization across all test generators: `chronyc tracking`.
2. **Execution Gating**:
   - Start with a low-concurrency smoke test (5 threads, 60s) to validate end-to-end telemetry pipeline (JMeter ➔ InfluxDB ➔ Grafana).
   - Verify `jmeter` database exists: `SHOW DATABASES` in InfluxDB.
3. **During Execution**:
   - Monitor JMeter runner CPU/Memory to ensure utilization stays below 75% to prevent client-side measurement distortions.
   - Monitor InfluxDB HTTP error response rates (`httpd_client_errors` / `httpd_server_errors`).
4. **Post-Execution & Comparison**:
   - Archive raw `.jtl` artifacts to cold object storage (S3/GCS).
   - Launch `compare_tests.js` dashboard via the Timeshift proxy to verify that response times remain within acceptable variance thresholds (e.g., ±5% of previous baseline).

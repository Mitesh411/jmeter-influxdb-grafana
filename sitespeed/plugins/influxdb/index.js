// sitespeed.io plugin: writes frontend metrics to InfluxDB 1.x, tagged with the run id.
//
// sitespeed.io 42 only ships a Graphite plugin. This one writes to the same InfluxDB
// database as JMeter, so Grafana can show and compare backend and frontend runs together.
//
//   measurement "sitespeed"   one point per page per iteration, written as soon as the
//                             iteration finishes (browsertime + pagexray + coach metrics)
//   measurement "test_runs"   one point per run (start, then updated at the end)
//
// Configured with environment variables (set by run-sitespeed.sh):
//   INFLUXDB_URL, INFLUXDB_DB, RUN_ID, APPLICATION, TEST_TITLE
//
// The plugin does not extend @sitespeed.io/plugin because that package is not resolvable
// from a mounted folder; sitespeed.io only needs these methods.

const influxUrl = process.env.INFLUXDB_URL || 'http://influxdb:8086';
const influxDb = process.env.INFLUXDB_DB || 'jmeter';
const runId = process.env.RUN_ID || 'adhoc';
const application = process.env.APPLICATION || 'frontend';
const title = process.env.TEST_TITLE || `${application} frontend test`;

// Line protocol escaping (InfluxDB 1.x).
const tag = v =>
  String(v ?? '').replaceAll(/[\n\r]+/g, ' ').trim().replaceAll(/([ ,=\\])/g, '\\$1') || 'none';
const str = v => '"' + String(v ?? '').replaceAll(/(["\\])/g, '\\$1') + '"';

function fieldSet(fields) {
  return Object.entries(fields)
    .filter(([, v]) => v !== undefined && v !== null && v !== '' && !Number.isNaN(v))
    .map(([k, v]) => `${k}=${typeof v === 'string' ? str(v) : Number(v)}`)
    .join(',');
}

export default class InfluxDBPlugin {
  constructor(options, context) {
    this.options = options;
    this.context = context;
    this.log = context.getLogger('sitespeedio.plugin.influxdb');
    this.alias = {};
    this.timestamps = {}; // "url|iteration" -> navigation start (ms), shared by all metrics of one iteration
    this.pending = [];
    this.errors = 0;
    this.pages = 0;
  }

  getName() {
    return 'influxdb';
  }

  async open() {
    this.startMs = Date.now();
    this.runSeries = `test_runs,tool=sitespeed,application=${tag(application)},runId=${tag(runId)}`;
    const iterations = this.options.browsertime?.iterations ?? 3;
    await this.write(
      `${this.runSeries} ${fieldSet({
        status: 'running',
        title,
        iterations,
        report: `sitespeed/${runId}/index.html`,
        // Expected end so dashboard links have a range while the run is going.
        endTime: this.startMs + 30 * 60 * 1000
      })} ${this.startMs}`
    );
  }

  processMessage(message) {
    switch (message.type) {
      case 'browsertime.browser': {
        this.browser = message.data?.browser?.name;
        return;
      }
      case 'browsertime.alias': {
        this.alias[message.url] = message.data;
        return;
      }
      case 'browsertime.run': {
        return this.writePage(message, this.browsertimeFields(message.data));
      }
      case 'pagexray.run': {
        return this.writePage(message, this.pagexrayFields(message.data));
      }
      case 'coach.run': {
        const advice = message.data?.advice ?? {};
        return this.writePage(message, {
          coachScore: advice.score,
          coachPerformance: advice.performance?.score,
          coachPrivacy: advice.privacy?.score,
          coachBestPractice: advice.bestpractice?.score
        });
      }
      case 'browsertime.pageSummary': {
        this.pages++;
        return;
      }
      case 'error': {
        this.errors++;
        return;
      }
    }
  }

  browsertimeFields(d) {
    const vitals = d.googleWebVitals ?? {};
    const visual = d.visualMetrics ?? {};
    const pageTimings = d.timings?.pageTimings ?? {};
    const errors = d.errors?.length ?? 0;
    this.errors += errors;
    return {
      ttfb: vitals.ttfb,
      firstContentfulPaint: vitals.firstContentfulPaint,
      largestContentfulPaint: vitals.largestContentfulPaint,
      cumulativeLayoutShift: vitals.cumulativeLayoutShift,
      totalBlockingTime: vitals.totalBlockingTime,
      firstPaint: d.timings?.firstPaint,
      domContentLoaded: pageTimings.domContentLoadedTime,
      pageLoadTime: pageTimings.pageLoadTime,
      backEndTime: pageTimings.backEndTime,
      frontEndTime: pageTimings.frontEndTime,
      fullyLoaded: d.fullyLoaded,
      speedIndex: visual.SpeedIndex,
      firstVisualChange: visual.FirstVisualChange,
      lastVisualChange: visual.LastVisualChange,
      visualComplete85: visual.VisualComplete85,
      visualComplete95: visual.VisualComplete95,
      visualComplete99: visual.VisualComplete99,
      longTasks: d.cpu?.longTasks?.tasks,
      longTasksDuration: d.cpu?.longTasks?.totalDuration,
      domElements: d.pageinfo?.domElements,
      cpuBenchmark: d.browser?.cpuBenchmark,
      mainDocumentStatus: d.mainDocument?.status,
      errors,
      errorMessages: errors ? d.errors.join('\n').slice(0, 2000) : undefined
    };
  }

  pagexrayFields(d) {
    const types = d.contentTypes ?? {};
    return {
      transferSize: d.transferSize,
      contentSize: d.contentSize,
      requests: d.requests,
      domains: d.totalDomains,
      thirdPartyRequests: d.thirdParty?.requests,
      thirdPartyTransferSize: d.thirdParty?.transferSize,
      htmlTransferSize: types.html?.transferSize,
      cssTransferSize: types.css?.transferSize,
      javascriptTransferSize: types.javascript?.transferSize,
      imageTransferSize: types.image?.transferSize,
      fontTransferSize: types.font?.transferSize
    };
  }

  writePage(message, fields) {
    const key = `${message.url}|${message.iteration}`;
    if (message.type === 'browsertime.run') {
      this.timestamps[key] = message.data?.pageinfo?.navigationStartTime ?? Date.now();
    }
    const time = this.timestamps[key] ?? Date.now();
    const url = new URL(message.url);
    const page = this.alias[message.url] ?? url.host + url.pathname;
    const report =
      `sitespeed/${runId}/` + this.context.resultUrls.relativeSummaryPageUrl(message.url, this.alias[message.url]) + 'index.html';
    const series =
      `sitespeed,application=${tag(application)},runId=${tag(runId)},page=${tag(page)}` +
      `,browser=${tag(this.browser ?? this.options.browser)},connectivity=${tag(this.options.browsertime?.connectivity?.profile ?? 'native')}`;
    const fs = fieldSet({ ...fields, iteration: message.iteration, url: message.url, report });
    const p = this.write(`${series} ${fs} ${time}`);
    this.pending.push(p);
    return p;
  }

  async close() {
    await Promise.allSettled(this.pending);
    const endMs = Date.now();
    await this.write(
      `${this.runSeries} ${fieldSet({
        status: this.errors > 0 || this.pages === 0 ? 'failed' : 'passed',
        pages: this.pages,
        errors: this.errors,
        durationSec: Math.round((endMs - this.startMs) / 1000),
        endTime: endMs + 30_000
      })} ${this.startMs}`
    );
  }

  async write(body) {
    try {
      const response = await fetch(`${influxUrl}/write?db=${encodeURIComponent(influxDb)}&precision=ms`, {
        method: 'POST',
        body,
        signal: AbortSignal.timeout(5000)
      });
      if (!response.ok) {
        this.log.error('InfluxDB write failed (%s): %s', response.status, await response.text());
      }
    } catch (error) {
      this.log.error('InfluxDB write failed: %s', error.message);
    }
  }
}

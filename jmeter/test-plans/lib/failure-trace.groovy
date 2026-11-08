// Failure trace writer, run by a JSR223 Listener in each test plan.
//
// For every failed sample it writes one point to the InfluxDB measurement "failures"
// with the full request and response (headers, body, assertion messages, timings,
// redirects, W3C trace id). The Grafana "Request trace" dashboard reads these points.
//
// JMeter properties used (all optional):
//   influxdb.url             same write URL the Backend Listener uses
//   application, runId       tags that tie the trace to a test run
//   failureTrace.max         max traces per test run (default 500), protects InfluxDB during error storms
//   failureTrace.bodyChars   max characters kept per request/response body (default 10000)

import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import java.util.concurrent.atomic.AtomicInteger
import org.apache.jmeter.protocol.http.sampler.HTTPSampleResult
import org.apache.jmeter.samplers.SampleResult
import org.apache.jmeter.threads.JMeterContextService

SampleResult r = sampleResult
if (r == null || r.isSuccessful()) {
    return
}

int maxTraces = (props.getProperty('failureTrace.max') ?: '500') as int
int bodyChars = (props.getProperty('failureTrace.bodyChars') ?: '10000') as int
String writeUrl = props.getProperty('influxdb.url') ?: 'http://localhost:8086/write?db=jmeter'
String application = props.getProperty('application') ?: 'unknown'
String runId = props.getProperty('runId') ?: 'adhoc'

// One counter per test run, shared by all threads.
String counterKey = 'failureTrace.count.' + JMeterContextService.getTestStartTime()
props.putIfAbsent(counterKey, new AtomicInteger())
int n = ((AtomicInteger) props.get(counterKey)).incrementAndGet()
if (n > maxTraces) {
    if (n == maxTraces + 1) {
        log.warn("failure-trace: reached ${maxTraces} traces for run ${runId}; further failures are counted by the Backend Listener only")
    }
    return
}

def truncate = { String s ->
    if (s == null) return ''
    s.length() > bodyChars ? s.substring(0, bodyChars) + "\n... [truncated, ${s.length()} chars total]" : s
}
// Line protocol escaping (InfluxDB 1.x).
def tag = { String s ->
    s = (s ?: '').replaceAll('[\\r\\n]+', ' ').trim()
    s ? s.replace('\\', '\\\\').replace(',', '\\,').replace(' ', '\\ ').replace('=', '\\=') : 'none'
}
def str = { String s -> '"' + (s ?: '').replace('\\', '\\\\').replace('"', '\\"') + '"' }

def methodOf = { SampleResult s -> s instanceof HTTPSampleResult ? s.getHTTPMethod() : '' }
String method = methodOf(r)
String requestHeaders = r.getRequestHeaders() ?: ''
def tp = (requestHeaders =~ /(?im)^traceparent:\s*[0-9a-f]{2}-([0-9a-f]{32})-/)
String traceId = tp.find() ? tp.group(1) : ''

String failureMessage = r.getAssertionResults()
        .findAll { it.isFailure() || it.isError() }
        .collect { "${it.getName()}: ${it.getFailureMessage() ?: '(no message)'}" }
        .join('\n')
if (!failureMessage) {
    failureMessage = "${r.getResponseCode()} ${r.getResponseMessage() ?: ''}".trim()
}
String redirects = r.getSubResults().collect { sub ->
    "${sub.getResponseCode()} ${methodOf(sub)} ${sub.getUrlAsString()} (${sub.getTime()} ms)"
}.join('\n')

String sampleId = "${runId}-${n}"
String line = 'failures' +
        ',application=' + tag(application) +
        ',runId=' + tag(runId) +
        ',transaction=' + tag(r.getSampleLabel()) +
        ',responseCode=' + tag(r.getResponseCode()) +
        ' sampleId=' + str(sampleId) +
        ',method=' + str(method) +
        ',url=' + str(r.getUrlAsString()) +
        ',responseMessage=' + str(r.getResponseMessage()) +
        ',failureMessage=' + str(truncate(failureMessage)) +
        ',requestHeaders=' + str(truncate(requestHeaders)) +
        ',requestData=' + str(truncate(r.getSamplerData())) +
        ',responseHeaders=' + str(truncate(r.getResponseHeaders())) +
        ',responseBody=' + str(truncate(r.getResponseDataAsString())) +
        ',redirects=' + str(redirects) +
        ',threadName=' + str(r.getThreadName()) +
        ',traceId=' + str(traceId) +
        ',elapsed=' + r.getTime() + 'i' +
        ',latency=' + r.getLatency() + 'i' +
        ',connect=' + r.getConnectTime() + 'i' +
        ',receivedBytes=' + r.getBytesAsLong() + 'i' +
        ',sentBytes=' + r.getSentBytes() + 'i' +
        // ns timestamp; the counter in the low digits keeps two failures in the same ms apart
        ' ' + (r.getTimeStamp() * 1_000_000L + n)

props.putIfAbsent('failureTrace.httpClient', HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build())
HttpClient client = (HttpClient) props.get('failureTrace.httpClient')
try {
    HttpResponse<String> resp = client.send(
            HttpRequest.newBuilder(URI.create(writeUrl))
                    .timeout(Duration.ofSeconds(3))
                    .POST(HttpRequest.BodyPublishers.ofString(line))
                    .build(),
            HttpResponse.BodyHandlers.ofString())
    if (resp.statusCode() >= 300) {
        log.warn("failure-trace: InfluxDB returned ${resp.statusCode()}: ${resp.body()}")
    }
} catch (Exception e) {
    log.warn("failure-trace: could not write trace ${sampleId}: ${e}")
}

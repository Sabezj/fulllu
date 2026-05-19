import { writeFile } from 'fs/promises';
import { performance } from 'perf_hooks';

const baseUrl = (process.env.BASE_URL || 'http://127.0.0.1:3000').replace(/\/+$/, '');
const concurrency = Math.max(1, Number(process.env.CONCURRENCY || 5));
const requestsPerWorker = Math.max(1, Number(process.env.REQUESTS_PER_WORKER || 10));
const scenario = process.env.SCENARIO || 'knowledge-search';
const authTokenFromEnv = `${process.env.AUTH_TOKEN || ''}`.trim();
const outputPath = process.env.OUTPUT_PATH || '';

function percentile(values, p) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return Number(sorted[index].toFixed(2));
}

async function fetchJson(path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, options);
  const text = await response.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { response, body };
}

async function resolveAuthHeaders() {
  let token = authTokenFromEnv;
  if (!token) {
    const tokenResponse = await fetchJson('/api/auth/token');
    if (!tokenResponse.response.ok || !tokenResponse.body?.token) {
      throw new Error('Unable to obtain auth token. Provide AUTH_TOKEN or enable /api/auth/token for the test environment.');
    }
    token = tokenResponse.body.token;
  }

  const csrfResponse = await fetchJson('/api/csrf-token');
  if (!csrfResponse.response.ok || !csrfResponse.body?.csrfToken) {
    throw new Error('Unable to obtain CSRF token.');
  }

  return {
    Authorization: `Bearer ${token}`,
    'X-CSRF-Token': csrfResponse.body.csrfToken,
    'Content-Type': 'application/json'
  };
}

function scenarioPayload(index) {
  if (scenario === 'action-plan') {
    return {
      endpoint: '/api/action-plan',
      body: {
        objective: 'Помочь подростку понять безопасный следующий шаг',
        context: `Сценарий ${index}: меня травят в школьном чате и я не знаю, что делать дальше`,
        knowledge_query: 'кибербуллинг в школьном чате безопасные шаги',
        knowledge_limit: 5
      }
    };
  }

  return {
    endpoint: '/api/knowledge/search',
    body: {
      query: `Сценарий ${index}: что делать подростку при кибербуллинге`,
      limit: 5
    }
  };
}

async function runWorker(workerIndex, headers) {
  const durations = [];
  const statuses = [];

  for (let requestIndex = 0; requestIndex < requestsPerWorker; requestIndex += 1) {
    const payload = scenarioPayload(`${workerIndex + 1}-${requestIndex + 1}`);
    const startedAt = performance.now();
    const result = await fetchJson(payload.endpoint, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload.body)
    });
    const durationMs = Number((performance.now() - startedAt).toFixed(2));
    durations.push(durationMs);
    statuses.push(result.response.status);
  }

  return { durations, statuses };
}

async function main() {
  const headers = await resolveAuthHeaders();
  const startedAt = performance.now();
  const workerResults = await Promise.all(
    Array.from({ length: concurrency }, (_, index) => runWorker(index, headers))
  );
  const wallClockMs = Number((performance.now() - startedAt).toFixed(2));

  const durations = workerResults.flatMap(item => item.durations);
  const statuses = workerResults.flatMap(item => item.statuses);
  const okCount = statuses.filter(status => status >= 200 && status < 300).length;
  const totalRequests = statuses.length;
  const result = {
    base_url: baseUrl,
    scenario,
    concurrency,
    requests_per_worker: requestsPerWorker,
    total_requests: totalRequests,
    ok_requests: okCount,
    error_requests: totalRequests - okCount,
    wall_clock_ms: wallClockMs,
    throughput_rps: Number((totalRequests / Math.max(wallClockMs / 1000, 0.001)).toFixed(2)),
    p50_ms: percentile(durations, 50),
    p95_ms: percentile(durations, 95),
    p99_ms: percentile(durations, 99),
    max_ms: durations.length ? Number(Math.max(...durations).toFixed(2)) : 0,
    status_codes: statuses.reduce((acc, status) => {
      acc[status] = (acc[status] || 0) + 1;
      return acc;
    }, {})
  };

  const output = JSON.stringify(result, null, 2);
  if (outputPath) {
    await writeFile(outputPath, output, 'utf8');
  }
  console.log(output);
}

main().catch(error => {
  console.error(error.message || error);
  process.exitCode = 1;
});

import { afterAll, beforeAll, describe, expect, jest, test } from '@jest/globals';
import { mkdir, writeFile } from 'fs/promises';
import path from 'path';
import { performance } from 'perf_hooks';

process.env.NODE_ENV = 'test';
process.env.PORT = '0';
process.env.USE_PY_SEARCH = 'false';
process.env.MOCK_OPENAI = 'true';

const mockChatCreate = jest.fn().mockResolvedValue({
  choices: [
    {
      message: {
        content: JSON.stringify({
          summary: 'План действий сформирован.',
          steps: [
            {
              id: 'step_1',
              action: 'Уточнить ключевые факты.',
              rationale: 'Это необходимо для безопасного ответа.',
              evidence_ids: [101],
              status: 'todo'
            },
            {
              id: 'step_2',
              action: 'Сформировать следующий безопасный шаг.',
              rationale: 'Пользователю нужен конкретный и реалистичный план.',
              evidence_ids: [102],
              status: 'todo'
            }
          ]
        })
      }
    }
  ]
});

const mockEmbedCreate = jest.fn().mockResolvedValue({
  data: [
    { embedding: new Array(1536).fill(0.001) }
  ]
});

await jest.unstable_mockModule('openai', () => ({
  OpenAI: class {
    chat = { completions: { create: mockChatCreate } };
    embeddings = { create: mockEmbedCreate };
  }
}));

function buildKnowledgeRows() {
  return [
    {
      chunk_id: 101,
      document_id: 'doc_general',
      document_title: 'LawVoice General Prompt',
      chunk_text: 'Пользователь должен сначала уточнить ключевые факты, затем получить безопасные варианты действий.',
      relevance: 0.92
    },
    {
      chunk_id: 102,
      document_id: 'doc_safety',
      document_title: 'LawVoice Safety Profile',
      chunk_text: 'При угрозе жизни, шантаже и публикации интимных материалов нужно рекомендовать взрослого и 112.',
      relevance: 0.88
    },
    {
      chunk_id: 103,
      document_id: 'doc_school',
      document_title: 'LawVoice Mentor Profile',
      chunk_text: 'Школьные конфликты требуют спокойного разбора фактов, ролей участников и ближайшего безопасного шага.',
      relevance: 0.74
    }
  ];
}

await jest.unstable_mockModule('pg', () => {
  const query = jest.fn(async (sql) => {
    const text = typeof sql === 'string' ? sql : String(sql?.text || sql || '');

    if (text.includes('SELECT 1 AS ok')) {
      return { rows: [{ ok: 1 }] };
    }
    if (text.includes('SELECT COUNT(*) AS count FROM products')) {
      return { rows: [{ count: '128' }] };
    }
    if (text.includes('SELECT COUNT(*) AS count FROM knowledge_documents')) {
      return { rows: [{ count: '6' }] };
    }
    if (text.includes('FROM knowledge_chunks kc') && text.includes('JOIN knowledge_documents kd')) {
      return { rows: buildKnowledgeRows() };
    }
    if (text.includes('SELECT * FROM analytics')) {
      return { rows: [] };
    }
    return { rows: [] };
  });

  const Pool = class {
    constructor() {
      this.query = query;
      this.connect = jest.fn().mockResolvedValue();
      this.end = jest.fn().mockResolvedValue();
      this.on = jest.fn();
    }
  };

  return { default: { Pool }, Pool };
});

await jest.unstable_mockModule('pgvector/pg', () => ({
  toSql: value => value
}));

await jest.unstable_mockModule('redis', () => ({
  createClient: () => ({
    connect: jest.fn().mockResolvedValue(),
    on: jest.fn()
  })
}));

import request from 'supertest';
import jwt from 'jsonwebtoken';

const { app, server, pool } = await import('../server.js');

function percentile(values, p) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

async function runBenchmark(label, totalRequests, concurrency, execute) {
  const durations = [];
  let cursor = 0;

  const worker = async () => {
    while (true) {
      const index = cursor;
      cursor += 1;
      if (index >= totalRequests) return;
      const start = performance.now();
      const res = await execute();
      const end = performance.now();
      if (res.status >= 400) {
        throw new Error(`${label} failed with status ${res.status}`);
      }
      durations.push(end - start);
    }
  };

  for (let i = 0; i < Math.min(10, totalRequests); i += 1) {
    await execute();
  }

  const wallStart = performance.now();
  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  const wallMs = performance.now() - wallStart;

  const avg = durations.reduce((sum, value) => sum + value, 0) / durations.length;
  return {
    route: label,
    requests: totalRequests,
    concurrency,
    throughput_rps: Number((totalRequests / (wallMs / 1000)).toFixed(2)),
    p50_ms: Number(percentile(durations, 50).toFixed(2)),
    p95_ms: Number(percentile(durations, 95).toFixed(2)),
    p99_ms: Number(percentile(durations, 99).toFixed(2)),
    avg_ms: Number(avg.toFixed(2)),
    max_ms: Number(Math.max(...durations).toFixed(2))
  };
}

describe('LawVoice backend synthetic benchmark', () => {
  const benchmarkOutput = path.join(process.cwd(), 'docs', 'defense', 'lawvoice_backend_benchmark.json');
  const token = jwt.sign({ id: 1 }, process.env.JWT_SECRET || 'devsecret', { expiresIn: '1h' });
  let csrfToken = '';
  let csrfCookie = '';

  beforeAll(async () => {
    const csrf = await request(app).get('/api/csrf-token');
    csrfToken = csrf.body.csrfToken;
    csrfCookie = (csrf.headers['set-cookie'] || [])
      .map(value => value.split(';')[0])
      .join('; ');
  });

  afterAll(async () => {
    await mkdir(path.dirname(benchmarkOutput), { recursive: true });
    await pool.end();
    server.close();
  });

  test('collects route-level latency metrics', async () => {
    const results = [];

    results.push(await runBenchmark('GET /api/profiles', 20, 2, async () => request(app).get('/api/profiles')));

    results.push(
      await runBenchmark('POST /api/classify-intent (lawvoice rule path)', 10, 2, async () =>
        request(app)
          .post('/api/classify-intent')
          .set('Cookie', csrfCookie)
          .set('Authorization', `Bearer ${token}`)
          .set('X-CSRF-Token', csrfToken)
          .send({ transcript: 'Меня задержали, что мне делать?', mode: 'lawvoice' })
      )
    );

    results.push(
      await runBenchmark('POST /api/knowledge/search', 10, 2, async () =>
        request(app)
          .post('/api/knowledge/search')
          .set('Cookie', csrfCookie)
          .set('Authorization', `Bearer ${token}`)
          .set('X-CSRF-Token', csrfToken)
          .send({ query: 'кибербуллинг школа возврат товара', limit: 3 })
      )
    );

    results.push(
      await runBenchmark('POST /api/action-plan', 10, 2, async () =>
        request(app)
          .post('/api/action-plan')
          .set('Cookie', csrfCookie)
          .set('Authorization', `Bearer ${token}`)
          .set('X-CSRF-Token', csrfToken)
          .send({
            objective: 'Сформировать безопасный план действий для подростка',
            context: 'Пользователь жалуется на конфликт в школе и просит понятный следующий шаг.',
            constraints: ['Не выдавать категоричную юридическую квалификацию'],
            knowledge_query: 'права ученика конфликт в школе безопасный следующий шаг'
          })
      )
    );

    const payload = {
      benchmark_type: 'synthetic_in_process_mocked_dependencies',
      environment: {
        runtime: 'node + supertest + mocked openai/postgres/redis',
        note: 'Measures backend route overhead and control flow, not external provider latency.'
      },
      results
    };

    await writeFile(benchmarkOutput, JSON.stringify(payload, null, 2), 'utf-8');

    expect(results).toHaveLength(4);
    expect(results.every(item => item.p95_ms > 0)).toBe(true);
  });
});

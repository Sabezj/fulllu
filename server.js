import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import cookieParser from 'cookie-parser';
import csrf from 'csurf';
import { fileURLToPath } from 'url';
import { basename, dirname, join, resolve } from 'path';
import { mkdir, open, readFile, readdir, stat, writeFile } from 'fs/promises';
import dotenv from 'dotenv';
import pg from 'pg';
import { toSql } from 'pgvector/pg';
import NodeCache from 'node-cache';
import { createClient } from 'redis';
import http from 'http';
import https from 'https';
import net from 'net';
import { readFileSync } from 'fs';
import pino from 'pino';
import axios from 'axios'; // HTTP client for OpenAI API
import axiosRetry from 'axios-retry'; // Retry logic for OpenAI requests
import config from './config.js';
import { OpenAI } from 'openai';
import crypto from 'crypto';
import jwt from 'jsonwebtoken';
import { classifyIntent } from './services/intents.js';
import { registerClient as registerAgentConsoleClient, log as agentConsoleLog } from './services/agentConsole.js';
import {
  METRICS_CONTENT_TYPE,
  buildTextLogMeta,
  createRequestContext,
  durationSince,
  metricsRequestAllowed,
  recordActionPlan,
  recordHttpRequest,
  recordIntentRequest,
  recordKnowledgeSearch,
  recordLlmRequest,
  recordSessionRecording,
  recordUpstreamRequest,
  renderPrometheusMetrics,
  setComponentHealth,
  setKnowledgeFootprint
} from './services/observability.js';
import {
  buildGroundedActionPlan,
  normalizeKnowledgeDocumentPayload,
  splitTextIntoChunks,
  estimateTokens
} from './services/knowledgePlanner.js';


// Load environment variables
dotenv.config();
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const LOGS_DIR = join(__dirname, 'logs');
const MONITORING_LOGS_DIR = join(LOGS_DIR, 'monitoring');
const SESSION_LOGS_DIR = join(LOGS_DIR, 'sessions');
const MONITORING_RUNTIME_DIR = join(__dirname, 'ops', 'monitoring', 'runtime');
const LOG_FILE = join(__dirname, 'logs', 'app.log');
// Configure pino logger (logs to file in production)
const transport = process.env.NODE_ENV === 'production'
  ? pino.transport({ target: 'pino/file', options: { destination: LOG_FILE, mkdir: true } })
  : undefined;
const logger = pino({ level: process.env.LOG_LEVEL || 'info' }, transport);
const app = express();
if (process.env.NODE_ENV === 'production') {
  // Trust first reverse proxy (nginx) so rate limiting and IP logging work correctly.
  app.set('trust proxy', 1);
}

function resolveRouteLabel(req) {
  const routePath = typeof req.route?.path === 'string' ? req.route.path : '';
  const baseUrl = typeof req.baseUrl === 'string' ? req.baseUrl : '';
  if (routePath) {
    return `${baseUrl}${routePath}` || routePath;
  }
  return req.path || 'unmatched';
}

function shouldLogRequest(req) {
  if (!req.path) return false;
  if (req.path === '/metrics') return false;
  if (req.path.startsWith('/api/health')) return false;
  if (req.path.startsWith('/api/ready')) return false;
  if (req.path.startsWith('/api/csrf-token')) return false;
  return req.path.startsWith('/api/');
}
// SSE endpoint for Agent Console (must be after app is defined)
app.get('/agent-console/events', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  // Optional heartbeat to keep proxies from closing idle connections
  const heartbeat = setInterval(() => {
    try { res.write(':\n\n'); } catch {}
  }, 25000);
  req.on('close', () => clearInterval(heartbeat));
  registerAgentConsoleClient(res);
});


// ---- Legacy commerce catalog / Python Search Proxy (guarded) --------
const COMMERCE_CATALOG_ENABLED = config.get('commerce.catalogEnabled');
const USE_PY_SEARCH = COMMERCE_CATALOG_ENABLED && process.env.USE_PY_SEARCH === 'true';
const SEARCH_API = process.env.SEARCH_API || 'http://127.0.0.1:5051';

if (USE_PY_SEARCH) {
  async function forwardSearch(req, res, path) {
    try {
      const url = new URL(path, SEARCH_API);
      for (const [k, v] of Object.entries(req.query || {})) {
        if (Array.isArray(v)) v.forEach(val => url.searchParams.append(k, val));
        else if (v !== undefined && v !== null) url.searchParams.append(k, String(v));
      }
      const r = await fetch(url, { headers: { 'accept': 'application/json' } });
      const text = await r.text();
      const ct = r.headers.get('content-type') || 'application/json';
      res.status(r.status).type(ct).send(text);
    } catch (err) {
      console.error('Search proxy error:', err?.message || err);
      res.status(502).json({ error: 'Search backend unavailable' });
    }
  }

  // Place these BEFORE any local handlers for the same routes
  app.get('/api/products/search', requireAdminAccess, (req, res) => forwardSearch(req, res, '/v1/products/search'));
  app.get('/api/products', requireAdminAccess, (req, res) => forwardSearch(req, res, '/v1/products'));
  app.get('/api/products/categories', requireAdminAccess, (req, res) => forwardSearch(req, res, '/v1/products/categories'));
}
// ---------------------------------------------------------------------
app.use('/agent-console', express.static(join(__dirname, 'public')));
const PORT = config.get('server.port');
const profilesDir = join(__dirname, 'profiles');
// Initialize PostgreSQL connection pool
const { Pool } = pg;
const pool = new Pool({
  connectionString: config.get('database.url'), // use convict config
});
let vectorExtensionAvailable = false;

function canReachTcpEndpoint(host, port, timeoutMs = 1000) {
  return new Promise(resolve => {
    const socket = net.createConnection({ host, port });
    let settled = false;

    const finish = reachable => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(reachable);
    };

    socket.setTimeout(timeoutMs);
    socket.once('connect', () => finish(true));
    socket.once('timeout', () => finish(false));
    socket.once('error', () => finish(false));
  });
}
// Attempt to reconnect when the PostgreSQL pool encounters an error
async function reconnectDB(err) {
  logger.error('PostgreSQL pool error', err);
  try {
    await pool.connect();
    logger.info('PostgreSQL pool reconnected');
  } catch (reconnectErr) {
    logger.error('PostgreSQL reconnection failed', reconnectErr);
  }
}
pool.on('error', reconnectDB);
// Initialize database tables at startup
async function initDB() {
  try {
    await pool.query('CREATE EXTENSION IF NOT EXISTS vector');
    vectorExtensionAvailable = true;
    logger.info('pgvector extension is available');
  } catch (err) {
    vectorExtensionAvailable = false;
    logger.warn({ err }, 'pgvector extension is unavailable; semantic vector search disabled');
  }

  try {
    await pool.query('CREATE EXTENSION IF NOT EXISTS pg_trgm');
  } catch (err) {
    logger.warn({ err }, 'pg_trgm extension is unavailable; trigram search may be degraded');
  }

  await pool.query(`
  CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    phone TEXT,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (phone, name)
  )`);
  if (COMMERCE_CATALOG_ENABLED) {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS products (
        id SERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        thickness_mm NUMERIC,
        coating TEXT,
        price_rub_m2 NUMERIC,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (name, thickness_mm, coating)
      )`);
    if (vectorExtensionAvailable) {
      await pool.query(`
        CREATE TABLE IF NOT EXISTS product_embeddings (
          product_id INTEGER PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
          embedding VECTOR(1536)
        )`);
      await pool.query(
        'CREATE INDEX IF NOT EXISTS product_embeddings_idx ON product_embeddings USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)'
      );
    } else {
      await pool.query(`
        CREATE TABLE IF NOT EXISTS product_embeddings (
          product_id INTEGER PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
          embedding JSONB
        )`);
    }
    await pool.query(`
      CREATE TABLE IF NOT EXISTS orders (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES users(id),
        product_id INTEGER REFERENCES products(id),
        qty INTEGER,
        total NUMERIC,
        delivery_address TEXT,
        contact_name TEXT,
        contact_phone TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )`);
  }
  await pool.query(`
    CREATE TABLE IF NOT EXISTS analytics (
      id SERIAL PRIMARY KEY,
      session_id TEXT,
      duration_ms INTEGER,
      tokens INTEGER,
      queries INTEGER,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )`);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS agent_profiles (
      id SERIAL PRIMARY KEY,
      name TEXT UNIQUE NOT NULL,
      instructions TEXT,
      voice TEXT,
      mood TEXT,
      rules TEXT,
      created_at TIMESTAMP DEFAULT NOW()
    )`);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS knowledge_documents (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      source_name TEXT,
      mime_type TEXT,
      content TEXT NOT NULL,
      metadata JSONB DEFAULT '{}'::jsonb,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )`);
  if (vectorExtensionAvailable) {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS knowledge_chunks (
        id SERIAL PRIMARY KEY,
        document_id TEXT NOT NULL REFERENCES knowledge_documents(id) ON DELETE CASCADE,
        chunk_index INTEGER NOT NULL,
        chunk_text TEXT NOT NULL,
        embedding VECTOR(1536),
        token_estimate INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (document_id, chunk_index)
      )`);
    await pool.query(
      'CREATE INDEX IF NOT EXISTS knowledge_chunks_embedding_idx ON knowledge_chunks USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)'
    );
  } else {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS knowledge_chunks (
        id SERIAL PRIMARY KEY,
        document_id TEXT NOT NULL REFERENCES knowledge_documents(id) ON DELETE CASCADE,
        chunk_index INTEGER NOT NULL,
        chunk_text TEXT NOT NULL,
        embedding JSONB,
        token_estimate INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (document_id, chunk_index)
      )`);
  }
  await pool.query(
    'CREATE INDEX IF NOT EXISTS knowledge_chunks_document_idx ON knowledge_chunks (document_id)'
  );
  await pool.query(
    "CREATE INDEX IF NOT EXISTS knowledge_chunks_fts_idx ON knowledge_chunks USING GIN (to_tsvector('russian', chunk_text))"
  );
  if (COMMERCE_CATALOG_ENABLED) {
    const data = await readFile(join(__dirname, 'profnastil_price.json'), 'utf-8');
    const products = JSON.parse(data);
    for (const p of products) {
      // No id in JSON, so insert without id (SERIAL generates it), ON CONFLICT on unique fields.
      await pool.query(
        `INSERT INTO products (name, thickness_mm, coating, price_rub_m2)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (name, thickness_mm, coating) DO NOTHING`,
        [p['Наименование продукции'], p['Толщина металла (мм)'], p['Покрытие'], p['Цена м² (руб)']]
      );
    }
  }
}
try {
  await initDB();
} catch (err) {
  logger.error({ err }, 'DB init error');
  process.exit(1);
}
// Simple in-memory cache for product search results
const searchCache = new NodeCache({ stdTTL: 300 });
const redisUrl = process.env.REDIS_URL || 'redis://localhost:6379';
const redis = createClient({
  url: redisUrl,
  retryStrategy: retries => Math.min(retries * 100, 3000),
  socket: {
    reconnectStrategy: retries => Math.min(retries * 100, 3000),
    connectTimeout: 1000
  }
});
redis.on('error', err => {
  logger.error({ err }, 'Redis error');
});
try {
  const redisEndpoint = new URL(redisUrl);
  const redisHost = redisEndpoint.hostname || '127.0.0.1';
  const redisPort = Number(redisEndpoint.port || 6379);
  if (await canReachTcpEndpoint(redisHost, redisPort)) {
    await redis.connect();
  } else {
    logger.warn({ redisHost, redisPort }, 'Redis unreachable at startup; continuing without Redis-backed features');
  }
} catch (err) {
  logger.warn({ err }, 'Redis unavailable at startup; continuing without Redis-backed features');
}
// Enable automatic retries for OpenAI API calls with exponential backoff
axiosRetry(axios, {
  retries: 3,
  retryDelay: axiosRetry.exponentialDelay
});
// Initialize OpenAI client using configured API key
const openai = new OpenAI({ apiKey: config.get('openai.apiKey') });
const ADMIN_SESSION_COOKIE = 'lawvoice_admin_session';
const ADMIN_SESSION_TTL_MS = Math.max(
  60 * 60 * 1000,
  (Number(process.env.ADMIN_SESSION_TTL_HOURS || 12) || 12) * 60 * 60 * 1000
);
const AUTH_SIGNING_SECRET =
  `${process.env.ADMIN_SESSION_SECRET || process.env.JWT_SECRET || config.get('admin.apiKey') || ''}`.trim() || 'devsecret';
// JWT auth helpers
function decodeBearerToken(req) {
  const auth = req.headers['authorization'];
  if (!auth) return null;
  const token = auth.split(' ')[1];
  if (!token) return null;
  try {
    return jwt.verify(token, process.env.JWT_SECRET || 'devsecret');
  } catch {
    return null;
  }
}
function hasValidAdminApiKey(req) {
  const apiKey = req.headers['x-api-key'];
  const configuredAdminApiKey = config.get('admin.apiKey');
  return Boolean(configuredAdminApiKey) && apiKey === configuredAdminApiKey;
}
function decodeAdminSession(req) {
  const token = req.cookies?.[ADMIN_SESSION_COOKIE];
  if (!token) return null;
  try {
    const decoded = jwt.verify(token, AUTH_SIGNING_SECRET);
    if (decoded?.role !== 'admin') return null;
    return decoded;
  } catch {
    return null;
  }
}
function applyRequestIdentity(req) {
  if (hasValidAdminApiKey(req)) {
    req.user = { id: 'admin-api-key', role: 'admin', auth_source: 'api_key' };
    return;
  }
  const adminSession = decodeAdminSession(req);
  if (adminSession) {
    req.user = { ...adminSession, auth_source: 'admin_session' };
    return;
  }
  const bearerUser = decodeBearerToken(req);
  if (bearerUser) {
    req.user = bearerUser;
    return;
  }
  req.user = null;
}
function requireAuth(req, res, next) {
  if (config.get('auth.devNoAuth')) {
    req.user = req.user || { id: 'dev-user', role: 'admin', auth_source: 'dev_no_auth' };
    return next();
  }
  if (!req.user) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  return next();
}
function requireAdminAccess(req, res, next) {
  if (config.get('auth.devNoAuth')) {
    req.user = req.user || { id: 'dev-admin', role: 'admin', auth_source: 'dev_no_auth' };
    return next();
  }
  if (req.user?.role === 'admin') {
    return next();
  }
  return res.status(401).json({ error: 'Unauthorized' });
}
function shouldUseSecureCookies(req) {
  const explicit = `${process.env.COOKIE_SECURE || ''}`.trim().toLowerCase();
  if (explicit === 'true') return true;
  if (explicit === 'false') return false;
  return req?.secure === true || `${req?.headers?.['x-forwarded-proto'] || ''}`.trim().toLowerCase() === 'https';
}
function issueAdminSession(req, res) {
  const expiresInSec = Math.max(3600, Math.floor(ADMIN_SESSION_TTL_MS / 1000));
  const token = jwt.sign(
    {
      id: 'admin',
      role: 'admin',
      scope: ['admin'],
      display_name: 'Administrator'
    },
    AUTH_SIGNING_SECRET,
    { expiresIn: expiresInSec }
  );
  res.cookie(ADMIN_SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: 'lax',
    secure: shouldUseSecureCookies(req),
    maxAge: ADMIN_SESSION_TTL_MS,
    path: '/'
  });
}
function clearAdminSession(res) {
  res.clearCookie(ADMIN_SESSION_COOKIE, {
    httpOnly: true,
    sameSite: 'lax',
    path: '/'
  });
}
function buildAuthState(req) {
  const isAdmin = req.user?.role === 'admin';
  const productionMode = config.get('env') === 'production';
  const defaultGrafanaUrl = productionMode ? '/grafana/' : 'http://127.0.0.1:3001';
  const defaultPrometheusUrl = productionMode ? '/proteus/' : 'http://127.0.0.1:9090';
  const defaultProteusUrl = productionMode ? '/proteus/' : '';
  return {
    role: isAdmin ? 'admin' : 'user',
    isAdmin,
    canManage: isAdmin,
    observability: isAdmin
      ? {
          grafanaUrl: `${process.env.GRAFANA_ROOT_URL || defaultGrafanaUrl}`.trim(),
          prometheusUrl: `${process.env.PROMETHEUS_ROOT_URL || defaultPrometheusUrl}`.trim(),
          proteusUrl: `${process.env.PROTEUS_ROOT_URL || defaultProteusUrl}`.trim(),
          metricsUrl: '/metrics',
          logsUrl: '/api/admin/logs',
          logSourcesUrl: '/api/admin/log-sources'
        }
      : null
  };
}

const LOG_SOURCE_DEFINITIONS = [
  {
    id: 'app',
    label: 'LawVoice app',
    description: 'Логи Node.js приложения и stdout/stderr из scripts/start_all.ps1.',
    env: ['APP_LOG_FILE', 'LAWVOICE_LOG_FILE'],
    paths: [
      LOG_FILE,
      join(LOGS_DIR, 'app.out.log'),
      join(LOGS_DIR, 'app.err.log')
    ],
    patterns: [
      { dir: LOGS_DIR, regex: /^app(?:\.\d{8}_\d{6})?\.(?:out|err)\.log$/i }
    ]
  },
  {
    id: 'grafana',
    label: 'Grafana',
    description: 'Логи Grafana из native monitoring runtime или настроенного GRAFANA_LOG_FILE.',
    env: ['GRAFANA_LOG_FILE', 'GRAFANA_LOG_PATH'],
    paths: [
      join(MONITORING_RUNTIME_DIR, 'grafana', 'logs', 'grafana.log'),
      join(LOGS_DIR, 'grafana.log')
    ],
    patterns: [
      { dir: MONITORING_LOGS_DIR, regex: /^grafana(?:\.\d{8}_\d{6})?\.(?:out|err)\.log$/i },
      { dir: join(MONITORING_RUNTIME_DIR, 'grafana', 'logs'), regex: /\.log$/i }
    ]
  },
  {
    id: 'prometheus',
    label: 'Prometheus',
    description: 'Логи Prometheus, который собирает метрики для Grafana.',
    env: ['PROMETHEUS_LOG_FILE', 'PROMETHEUS_LOG_PATH'],
    paths: [
      join(LOGS_DIR, 'prometheus.log')
    ],
    patterns: [
      { dir: MONITORING_LOGS_DIR, regex: /^prometheus(?:\.\d{8}_\d{6})?\.(?:out|err)\.log$/i }
    ]
  },
  {
    id: 'proteus',
    label: 'Proteus',
    description: 'Отдельный источник Proteus; укажите PROTEUS_LOG_FILE или PROTEUS_LOG_PATH, если сервис пишет логи вне ./logs.',
    env: ['PROTEUS_LOG_FILE', 'PROTEUS_LOG_PATH'],
    paths: [
      join(LOGS_DIR, 'proteus.log'),
      join(LOGS_DIR, 'proteus.out.log'),
      join(LOGS_DIR, 'proteus.err.log')
    ],
    patterns: [
      { dir: LOGS_DIR, regex: /^proteus(?:\.\d{8}_\d{6})?(?:\.(?:out|err))?\.log$/i },
      { dir: MONITORING_LOGS_DIR, regex: /^proteus(?:\.\d{8}_\d{6})?(?:\.(?:out|err))?\.log$/i }
    ]
  }
];

const LOG_SOURCE_ALIASES = new Map([
  ['default', 'app'],
  ['application', 'app'],
  ['lawvoice', 'app'],
  ['grafana-logs', 'grafana'],
  ['prom', 'prometheus'],
  ['prometheus-logs', 'prometheus'],
  ['proteus-logs', 'proteus']
]);

function normalizeLogSourceId(rawSource) {
  const requested = `${rawSource || 'app'}`.trim().toLowerCase();
  return LOG_SOURCE_ALIASES.get(requested) || requested;
}

function getLogSourceDefinition(rawSource) {
  const sourceId = normalizeLogSourceId(rawSource);
  return LOG_SOURCE_DEFINITIONS.find(source => source.id === sourceId) || null;
}

function sanitizeSessionRecordingId(value = '') {
  return `${value || ''}`.trim().replace(/[^a-zA-Z0-9_.-]/g, '-').slice(0, 96);
}

function clampText(value = '', maxLength = 20000) {
  const text = `${value ?? ''}`;
  return text.length > maxLength ? `${text.slice(0, maxLength)}…` : text;
}

function normalizeSessionRecording(payload = {}) {
  const now = new Date();
  const startedAt = Number.isFinite(Date.parse(payload.startedAt)) ? new Date(payload.startedAt) : now;
  const endedAt = Number.isFinite(Date.parse(payload.endedAt)) ? new Date(payload.endedAt) : now;
  const rawSessionId = sanitizeSessionRecordingId(payload.sessionId || payload.openaiSessionId || crypto.randomUUID());
  const fileId = `${startedAt.toISOString().replace(/[:.]/g, '-')}_${rawSessionId || crypto.randomUUID()}`;
  const transcript = Array.isArray(payload.transcript)
    ? payload.transcript.slice(0, 300).map(item => ({
        role: `${item?.role || item?.type || 'unknown'}`.slice(0, 32),
        text: clampText(item?.text || item?.message || '', 12000),
        at: Number.isFinite(Date.parse(item?.at)) ? new Date(item.at).toISOString() : now.toISOString()
      })).filter(item => item.text)
    : [];
  const events = Array.isArray(payload.events)
    ? payload.events.slice(-500).map(item => ({
        type: `${item?.type || item?.action || 'event'}`.slice(0, 64),
        message: clampText(item?.message || item?.text || '', 6000),
        at: Number.isFinite(Date.parse(item?.at)) ? new Date(item.at).toISOString() : now.toISOString(),
        meta: item?.meta && typeof item.meta === 'object' ? item.meta : undefined
      }))
    : [];
  const userTurns = transcript.filter(item => item.role === 'user').length;
  const assistantTurns = transcript.filter(item => item.role === 'assistant').length;
  const firstUserText = transcript.find(item => item.role === 'user')?.text || '';
  const summary = typeof payload.summary === 'object' && payload.summary
    ? payload.summary
    : {
        title: firstUserText ? clampText(firstUserText, 120) : 'Диалог без распознанной пользовательской реплики',
        short: `Диалог: ${userTurns} реплик пользователя, ${assistantTurns} ответов ассистента.`,
        outcome: payload.endReason || 'session_ended'
      };
  return {
    id: fileId,
    app: 'lawvoice',
    version: 1,
    createdAt: now.toISOString(),
    startedAt: startedAt.toISOString(),
    endedAt: endedAt.toISOString(),
    durationMs: Math.max(0, Number(payload.durationMs || 0)),
    endReason: `${payload.endReason || 'session_ended'}`.slice(0, 80),
    session: {
      localId: sanitizeSessionRecordingId(payload.localSessionId || ''),
      openaiId: sanitizeSessionRecordingId(payload.openaiSessionId || payload.sessionId || ''),
      model: clampText(payload.model || '', 120),
      voice: clampText(payload.voice || '', 120),
      profile: clampText(payload.profile || '', 160),
      mode: clampText(payload.mode || '', 80)
    },
    metrics: {
      tokens: Number(payload.metrics?.tokens || payload.tokens || 0),
      queries: Number(payload.metrics?.queries || payload.queries || userTurns),
      estimatedCostUsd: Number(payload.metrics?.estimatedCostUsd || 0),
      risk: clampText(payload.metrics?.risk || '', 40),
      anxiety: clampText(payload.metrics?.anxiety || '', 40)
    },
    summary,
    transcript,
    events
  };
}

function sessionRecordingListItem(recording, fileName, fileStat) {
  return {
    id: recording.id || fileName.replace(/\.json$/i, ''),
    file: fileName,
    title: recording.summary?.title || 'Без названия',
    short: recording.summary?.short || '',
    startedAt: recording.startedAt,
    endedAt: recording.endedAt,
    durationMs: recording.durationMs || 0,
    userTurns: Array.isArray(recording.transcript) ? recording.transcript.filter(item => item.role === 'user').length : 0,
    assistantTurns: Array.isArray(recording.transcript) ? recording.transcript.filter(item => item.role === 'assistant').length : 0,
    model: recording.session?.model || '',
    profile: recording.session?.profile || '',
    risk: recording.metrics?.risk || '',
    anxiety: recording.metrics?.anxiety || '',
    tokens: Number(recording.metrics?.tokens || 0),
    queries: Number(recording.metrics?.queries || 0),
    estimatedCostUsd: Number(recording.metrics?.estimatedCostUsd || 0),
    endReason: recording.endReason || '',
    size: fileStat.size,
    updatedAt: fileStat.mtime.toISOString()
  };
}

async function ensureSessionLogsDir() {
  await mkdir(SESSION_LOGS_DIR, { recursive: true });
}

function getSessionRecordingPath(rawId) {
  const id = sanitizeSessionRecordingId(rawId);
  if (!id) {
    const err = new Error('Invalid session recording id');
    err.statusCode = 400;
    throw err;
  }
  const filePath = resolve(SESSION_LOGS_DIR, `${id}.json`);
  const root = resolve(SESSION_LOGS_DIR);
  if (!filePath.startsWith(`${root}\\`) && !filePath.startsWith(`${root}/`)) {
    const err = new Error('Invalid session recording path');
    err.statusCode = 400;
    throw err;
  }
  return filePath;
}

async function saveSessionRecording(payload) {
  const recording = normalizeSessionRecording(payload);
  await ensureSessionLogsDir();
  const filePath = getSessionRecordingPath(recording.id);
  await writeFile(filePath, JSON.stringify(recording, null, 2), 'utf8');
  return recording;
}

async function listSessionRecordings(limit = 50) {
  await ensureSessionLogsDir();
  const maxItems = Math.max(1, Math.min(Number(limit) || 50, 200));
  const files = await readdir(SESSION_LOGS_DIR);
  const items = [];

  for (const fileName of files.filter(name => /\.json$/i.test(name))) {
    try {
      const filePath = getSessionRecordingPath(fileName.replace(/\.json$/i, ''));
      const [raw, fileStat] = await Promise.all([
        readFile(filePath, 'utf8'),
        stat(filePath)
      ]);
      const recording = JSON.parse(raw);
      items.push(sessionRecordingListItem(recording, fileName, fileStat));
    } catch (err) {
      logger.warn({ err, fileName }, 'Skipping invalid session recording file');
    }
  }

  return items
    .sort((a, b) => new Date(b.endedAt || b.updatedAt).getTime() - new Date(a.endedAt || a.updatedAt).getTime())
    .slice(0, maxItems);
}

async function readSessionRecording(rawId) {
  await ensureSessionLogsDir();
  const filePath = getSessionRecordingPath(rawId);
  const raw = await readFile(filePath, 'utf8');
  return JSON.parse(raw);
}

function parseConfiguredLogPaths(envNames = []) {
  const values = [];
  for (const envName of envNames) {
    const raw = `${process.env[envName] || ''}`.trim();
    if (!raw) continue;
    values.push(...raw.split(/[;,]/).map(item => item.trim()).filter(Boolean));
  }
  return values;
}

async function tryStat(filePath) {
  try {
    return await stat(filePath);
  } catch {
    return null;
  }
}

function toLogFileDescriptor(filePath, fileStat) {
  return {
    path: filePath,
    name: basename(filePath),
    size: fileStat.size,
    updatedAt: fileStat.mtime.toISOString(),
    mtimeMs: fileStat.mtimeMs
  };
}

async function collectLogFilesFromPath(rawPath) {
  const resolvedPath = resolve(__dirname, rawPath);
  const fileStat = await tryStat(resolvedPath);
  if (!fileStat) return [];

  if (fileStat.isFile()) {
    return [toLogFileDescriptor(resolvedPath, fileStat)];
  }

  if (!fileStat.isDirectory()) {
    return [];
  }

  return collectLogFilesFromPattern({ dir: resolvedPath, regex: /\.log$/i });
}

async function collectLogFilesFromPattern(pattern) {
  const dir = resolve(__dirname, pattern.dir);
  const dirStat = await tryStat(dir);
  if (!dirStat?.isDirectory()) return [];

  let entries = [];
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }

  const files = [];
  for (const entry of entries) {
    if (!entry.isFile() || !pattern.regex.test(entry.name)) continue;
    const filePath = join(dir, entry.name);
    const fileStat = await tryStat(filePath);
    if (fileStat?.isFile()) {
      files.push(toLogFileDescriptor(filePath, fileStat));
    }
  }
  return files;
}

async function collectLogFilesForSource(sourceDefinition) {
  const seen = new Set();
  const files = [];

  const addFiles = (items) => {
    for (const item of items) {
      const key = item.path.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      files.push(item);
    }
  };

  for (const configuredPath of parseConfiguredLogPaths(sourceDefinition.env)) {
    addFiles(await collectLogFilesFromPath(configuredPath));
  }

  for (const filePath of sourceDefinition.paths || []) {
    addFiles(await collectLogFilesFromPath(filePath));
  }

  for (const pattern of sourceDefinition.patterns || []) {
    addFiles(await collectLogFilesFromPattern(pattern));
  }

  return files.sort((a, b) => b.mtimeMs - a.mtimeMs);
}

async function buildLogSourcesPayload() {
  const sources = [];
  for (const sourceDefinition of LOG_SOURCE_DEFINITIONS) {
    const files = await collectLogFilesForSource(sourceDefinition);
    sources.push({
      id: sourceDefinition.id,
      label: sourceDefinition.label,
      description: sourceDefinition.description,
      available: files.length > 0,
      files: files.slice(0, 8).map(({ mtimeMs, ...file }) => file)
    });
  }
  return sources;
}

async function tailLogFile(filePath, lineLimit) {
  const fileStat = await stat(filePath);
  if (!fileStat.isFile()) {
    throw new Error('Log source is not a file');
  }

  const configuredMaxBytes = Number(process.env.ADMIN_LOG_TAIL_BYTES || 1024 * 1024);
  const maxBytes = Math.max(64 * 1024, Math.min(configuredMaxBytes || 1024 * 1024, 4 * 1024 * 1024));
  const bytesToRead = Math.min(fileStat.size, maxBytes);
  if (bytesToRead <= 0) {
    return {
      text: '',
      lines: [],
      size: fileStat.size,
      updatedAt: fileStat.mtime.toISOString(),
      truncated: false
    };
  }

  const handle = await open(filePath, 'r');
  try {
    const buffer = Buffer.alloc(bytesToRead);
    await handle.read(buffer, 0, bytesToRead, fileStat.size - bytesToRead);
    const text = buffer.toString('utf8').replace(/\0/g, '');
    const allLines = text.split(/\r?\n/).filter(line => line.length > 0);
    const lines = allLines.slice(-lineLimit);
    return {
      text: lines.join('\n'),
      lines,
      size: fileStat.size,
      updatedAt: fileStat.mtime.toISOString(),
      truncated: fileStat.size > bytesToRead || allLines.length > lineLimit
    };
  } finally {
    await handle.close();
  }
}

async function readLogSourceTail(rawSource, lineLimit) {
  const sourceDefinition = getLogSourceDefinition(rawSource);
  if (!sourceDefinition) {
    const err = new Error('Unknown log source');
    err.statusCode = 404;
    throw err;
  }

  const files = await collectLogFilesForSource(sourceDefinition);
  if (!files.length) {
    return {
      source: {
        id: sourceDefinition.id,
        label: sourceDefinition.label,
        description: sourceDefinition.description
      },
      available: false,
      files: [],
      selectedFile: null,
      text: '',
      lines: [],
      truncated: false,
      message: 'Файлы логов для этого источника не найдены.'
    };
  }

  const selectedFile = files[0];
  const tail = await tailLogFile(selectedFile.path, lineLimit);
  return {
    source: {
      id: sourceDefinition.id,
      label: sourceDefinition.label,
      description: sourceDefinition.description
    },
    available: true,
    files: files.slice(0, 8).map(({ mtimeMs, ...file }) => file),
    selectedFile: (({ mtimeMs, ...file }) => file)(selectedFile),
    ...tail
  };
}
async function getEmbeddings(texts) {
  const batchSize = 50;
  const out = [];
  for (let i = 0; i < texts.length; i += batchSize) {
    const batch = texts.slice(i, i + batchSize);
    const startedAtMs = Date.now();
    try {
      const resp = await openai.embeddings.create({
        model: 'text-embedding-3-small',
        input: batch
      });
      recordLlmRequest({
        operation: 'embedding',
        model: 'text-embedding-3-small',
        status: 'ok',
        durationMs: durationSince(startedAtMs)
      });
      out.push(...resp.data.map(e => e.embedding));
    } catch (err) {
      recordLlmRequest({
        operation: 'embedding',
        model: 'text-embedding-3-small',
        status: 'error',
        durationMs: durationSince(startedAtMs)
      });
      logger.error({ err, batch_size: batch.length }, 'Embedding batch failed');
      throw err; // Rethrow to handle in caller
    }
  }
  return out;
}

function buildExcerpt(text, max = 320) {
  const normalized = String(text || '').replace(/\s+/g, ' ').trim();
  if (normalized.length <= max) return normalized;
  return `${normalized.slice(0, max - 1)}…`;
}

function normalizeKnowledgeHitRows(rows = []) {
  return rows
    .map(row => {
      const chunkId = Number(row.chunk_id);
      if (!Number.isInteger(chunkId)) return null;
      return {
        chunk_id: chunkId,
        document_id: row.document_id || null,
        document_title: row.document_title || row.title || 'Документ',
        relevance: Number.isFinite(Number(row.relevance)) ? Number(row.relevance) : null,
        excerpt: buildExcerpt(row.chunk_text || row.excerpt || '')
      };
    })
    .filter(Boolean);
}

async function searchKnowledgeChunks(queryText, limit = 6, context = {}) {
  const query = typeof queryText === 'string' ? queryText.trim() : '';
  const source = context.source || 'unknown';
  const searchLogger = context.logger || logger;
  const startedAtMs = Date.now();
  if (!query) {
    recordKnowledgeSearch({
      source,
      backend: 'none',
      status: 'empty_query',
      durationMs: durationSince(startedAtMs),
      hitCount: 0
    });
    return { hits: [], backend: 'none' };
  }
  const parsedLimit = Math.max(1, Math.min(parseInt(limit, 10) || 6, 20));
  let usedFallback = false;

  if (vectorExtensionAvailable) {
    try {
      const embedding = (await getEmbeddings([query]))[0];
      const { rows } = await pool.query(
        `SELECT kc.id AS chunk_id,
                kc.document_id,
                kd.title AS document_title,
                kc.chunk_text,
                1 - (kc.embedding <=> $1) AS relevance
           FROM knowledge_chunks kc
           JOIN knowledge_documents kd ON kd.id = kc.document_id
          ORDER BY kc.embedding <=> $1
          LIMIT $2`,
        [toSql(embedding), parsedLimit]
      );
      const hits = normalizeKnowledgeHitRows(rows);
      if (hits.length > 0) {
        recordKnowledgeSearch({
          source,
          backend: 'semantic',
          status: 'ok',
          durationMs: durationSince(startedAtMs),
          hitCount: hits.length
        });
        return { hits, backend: 'semantic' };
      }
      usedFallback = true;
    } catch (err) {
      usedFallback = true;
      searchLogger.warn({ err, source }, 'Knowledge semantic search failed, falling back to FTS');
    }
  }

  try {
    const { rows } = await pool.query(
      `SELECT kc.id AS chunk_id,
              kc.document_id,
              kd.title AS document_title,
              kc.chunk_text,
              ts_rank(
                to_tsvector('russian', kc.chunk_text),
                plainto_tsquery('russian', $1)
              ) AS relevance
         FROM knowledge_chunks kc
         JOIN knowledge_documents kd ON kd.id = kc.document_id
        WHERE to_tsvector('russian', kc.chunk_text) @@ plainto_tsquery('russian', $1)
        ORDER BY relevance DESC
        LIMIT $2`,
      [query, parsedLimit]
    );
    const hits = normalizeKnowledgeHitRows(rows);
    recordKnowledgeSearch({
      source,
      backend: usedFallback ? 'fts_fallback' : 'fts',
      status: hits.length > 0 ? 'ok' : 'empty',
      durationMs: durationSince(startedAtMs),
      hitCount: hits.length
    });
    return { hits, backend: usedFallback ? 'fts_fallback' : 'fts' };
  } catch (err) {
    recordKnowledgeSearch({
      source,
      backend: usedFallback ? 'fts_fallback' : 'fts',
      status: 'error',
      durationMs: durationSince(startedAtMs),
      hitCount: 0
    });
    searchLogger.error({ err, source }, 'Knowledge fallback search failed');
    return { hits: [], backend: usedFallback ? 'fts_fallback' : 'fts' };
  }
}

const synonymMap = { 'оцинкованный': ['Zn'], 'оцинковка': ['Zn'] };

function expandTerms(query) {
  const words = query.toLowerCase().split(/\s+/);
  const expanded = new Set(words);
  for (const w of words) {
    const syns = synonymMap[w];
    if (syns) syns.forEach(s => expanded.add(s));
  }
  return Array.from(expanded);
}

function parsePositiveUsd(rawValue) {
  if (rawValue === undefined || rawValue === null || `${rawValue}`.trim() === '') {
    return null;
  }
  const parsed = Number(rawValue);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return null;
  }
  return Math.round(parsed * 100) / 100;
}

const SESSION_COST_LIMIT_USD = parsePositiveUsd(process.env.SESSION_COST_LIMIT_USD);
if (process.env.SESSION_COST_LIMIT_USD && SESSION_COST_LIMIT_USD === null) {
  logger.warn('Invalid SESSION_COST_LIMIT_USD value detected; per-session cost cap is disabled.');
}

let lastOperationalMetricsRefreshAt = 0;
let operationalMetricsRefreshPromise = null;

async function refreshOperationalMetrics(force = false) {
  const refreshIntervalMs = 10000;
  const startedAtMs = Date.now();
  if (!force && lastOperationalMetricsRefreshAt && (startedAtMs - lastOperationalMetricsRefreshAt) < refreshIntervalMs) {
    return;
  }
  if (operationalMetricsRefreshPromise) {
    return operationalMetricsRefreshPromise;
  }

  operationalMetricsRefreshPromise = (async () => {
    let documents = 0;
    let chunks = 0;
    try {
      const { rows } = await pool.query(
        `SELECT
            (SELECT COUNT(*)::INTEGER FROM knowledge_documents) AS documents,
            (SELECT COUNT(*)::INTEGER FROM knowledge_chunks) AS chunks`
      );
      documents = Number(rows?.[0]?.documents || 0);
      chunks = Number(rows?.[0]?.chunks || 0);
      setComponentHealth('db', true);
    } catch (err) {
      setComponentHealth('db', false);
      logger.warn({ err }, 'Failed to refresh operational metrics from the database');
    }

    setKnowledgeFootprint({
      documents,
      chunks,
      pgvectorEnabled: vectorExtensionAvailable
    });
    setComponentHealth('openai_configured', Boolean(config.get('openai.apiKey')));
    lastOperationalMetricsRefreshAt = Date.now();
  })();

  try {
    await operationalMetricsRefreshPromise;
  } finally {
    operationalMetricsRefreshPromise = null;
  }
}
// Validate required environment variables
const requiredEnvVars = ['OPENAI_API_KEY', 'MODEL_NAME', 'VOICE_ID', 'DATABASE_URL'];
const missingEnvVars = requiredEnvVars.filter(varName => !process.env[varName]);
if (missingEnvVars.length > 0) {
  logger.error('❌ Missing required environment variables:');
  missingEnvVars.forEach(varName => {
    logger.error(` - ${varName}`);
  });
  logger.error('\n📋 Please copy .env.example to .env and configure all required variables');
  process.exit(1);
}
// Security middleware
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", "'unsafe-eval'", "https://cdn.jsdelivr.net"], // Added 'unsafe-eval'
      styleSrc: ["'self'", "https://fonts.googleapis.com"],
      fontSrc: ["'self'", "https://fonts.gstatic.com"],
      connectSrc: ["'self'", "https://api.openai.com", "wss://api.openai.com", "https://cdn.jsdelivr.net"],
      mediaSrc: ["'self'", "blob:"],
    },
  },
}));
// Root cause: CORS origin was hardcoded to localhost, causing CORS errors in production
// Fixed by reading from environment variable with fallback to localhost for dev
const ALLOWED_ORIGINS = process.env.ALLOWED_ORIGINS 
  ? process.env.ALLOWED_ORIGINS.split(',').map(o => o.trim())
  : ['http://localhost', 'http://localhost:3000'];

app.use(cors({ 
  origin: (origin, callback) => {
    // Allow requests with no origin (mobile apps, curl, etc.)
    if (!origin) return callback(null, true);
    
    if (ALLOWED_ORIGINS.includes(origin)) {
      callback(null, true);
    } else {
      callback(new Error(`Origin ${origin} not allowed by CORS`));
    }
  },
  credentials: true 
}));
app.use(express.json({ limit: '5mb' }));
app.use(cookieParser());
app.use((req, res, next) => {
  applyRequestIdentity(req);
  next();
});
app.use(express.static('public'));
app.use((req, res, next) => {
  const requestContext = createRequestContext(req);
  req.requestId = requestContext.requestId;
  req.log = logger.child({
    request_id: requestContext.requestId,
    method: req.method,
    path: req.path
  });
  res.setHeader('X-Request-Id', requestContext.requestId);

  if (shouldLogRequest(req)) {
    req.log.info({ event: 'request_received' }, 'HTTP request received');
  }

  res.on('finish', () => {
    const durationMs = durationSince(requestContext.startedAtMs);
    const route = resolveRouteLabel(req);
    const isObservable = req.path.startsWith('/api/') || req.path === '/metrics';
    if (isObservable) {
      recordHttpRequest({
        method: req.method,
        route,
        statusCode: res.statusCode,
        durationMs
      });
    }
    if (shouldLogRequest(req)) {
      req.log.info(
        {
          event: 'request_completed',
          route,
          status_code: res.statusCode,
          duration_ms: durationMs,
          user_id: req.user?.id || null
        },
        'HTTP request completed'
      );
    }
  });

  next();
});
// CSRF — включаем только для HTML-страниц.
const csrfProtection = csrf({ cookie: true });
app.use((req, res, next) => {
  if (req.path.startsWith('/api/')) {
    return next();
  }
  return csrfProtection(req, res, next);
});
// Global rate limiter. Nginx auth_request can call this endpoint once per
// protected asset request, so do not count it as user traffic.
app.use(rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  skip: req => req.path === '/api/auth/admin/check'
}));
// Helper to create per-user/IP rate limiters
const createLimiter = (maxAnon, maxAuth) =>
  rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: (req, res) => (req.user ? maxAuth : maxAnon), // auth users vs anonymous
    keyGenerator: (req, res) => `${req.ip}:${req.user?.id || 'anon'}`,
    message: 'Too many requests from this IP, please try again later.',
    standardHeaders: true,
    legacyHeaders: false,
  });
// Stricter rate limiter for session creation
const sessionLimiter = createLimiter(10, 40); // fewer requests allowed
// More permissive limiter for product search
const searchLimiter = createLimiter(50, 200);
app.use('/api/session', sessionLimiter);
app.use('/api/realtime/sdp', sessionLimiter);
app.use('/api/products/search', searchLimiter);
// Health check endpoint with DB and OpenAI checks
app.get('/api/health', async (req, res) => {
  const health = {
    status: 'ok',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    config: {
      model: config.get('openai.model'),
      voice: config.get('openai.voice'),
      port: PORT
    },
    details: {}
  };
  let degraded = false;
  // --- Database connectivity check and uptime ---
  try {
    // Simple query to verify the connection
    await pool.query('SELECT 1');
    // Query database uptime in seconds
    const { rows } = await pool.query(
      "SELECT EXTRACT(EPOCH FROM (NOW() - pg_postmaster_start_time())) AS uptime"
    );
    health.details.db = {
      status: 'ok',
      uptime: Number(rows[0].uptime)
    };
    setComponentHealth('db', true);
  } catch (error) {
    degraded = true;
    health.details.db = {
      status: 'error',
      error: error.message
    };
    setComponentHealth('db', false);
  }
  // --- Ensure embeddings are present ---
  try {
    if (!COMMERCE_CATALOG_ENABLED) {
      health.details.embeddings = {
        status: 'disabled',
        reason: 'commerce_catalog_disabled'
      };
    } else {
      const { rows } = await pool.query('SELECT COUNT(*) AS count FROM product_embeddings');
      const count = Number(rows[0].count);
      health.details.embeddings = {
        status: count > 0 ? 'ok' : 'empty',
        count
      };
      if (count === 0) {
        degraded = true;
      }
    }
  } catch (error) {
    degraded = true;
    health.details.embeddings = {
      status: 'error',
      error: error.message
    };
  }
  // --- Knowledge base check ---
  try {
    const { rows } = await pool.query('SELECT COUNT(*) AS count FROM knowledge_documents');
    health.details.knowledge = {
      status: 'ok',
      documents: Number(rows[0].count)
    };
    setKnowledgeFootprint({
      documents: Number(rows[0].count),
      chunks: 0,
      pgvectorEnabled: vectorExtensionAvailable
    });
  } catch (error) {
    degraded = true;
    health.details.knowledge = {
      status: 'error',
      error: error.message
    };
  }
  // --- OpenAI API availability check ---
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000); // 5s timeout
    const response = await fetch('https://api.openai.com/v1/models', {
      headers: {
        Authorization: `Bearer ${process.env.OPENAI_API_KEY}`
      },
      signal: controller.signal
    });
    clearTimeout(timeout);
    if (!response.ok) {
      throw new Error(`OpenAI API responded with status ${response.status}`);
    }
    health.details.openai = { status: 'ok' };
    setComponentHealth('openai_upstream', true);
  } catch (error) {
    degraded = true;
    health.details.openai = {
      status: 'error',
      error: error.message
    };
    setComponentHealth('openai_upstream', false);
  }
  if (degraded) {
    health.status = 'degraded';
  }
  res.json(health);
});
app.get('/api/ready', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    await refreshOperationalMetrics();
    res.json({
      status: 'ready',
      timestamp: new Date().toISOString(),
      vector_search: vectorExtensionAvailable ? 'enabled' : 'disabled'
    });
  } catch (error) {
    res.status(503).json({
      status: 'not_ready',
      error: error.message
    });
  }
});
app.get('/metrics', async (req, res) => {
  if (req.user?.role !== 'admin' && !metricsRequestAllowed(req)) {
    return res.status(403).json({ error: 'Forbidden' });
  }

  try {
    await refreshOperationalMetrics();
  } catch (error) {
    logger.warn({ err: error }, 'Proceeding with cached metrics after refresh failure');
  }

  res.setHeader('Content-Type', METRICS_CONTENT_TYPE);
  res.send(renderPrometheusMetrics());
});
// CSRF token endpoint
app.get('/api/csrf-token', csrfProtection, (req, res) => {
  res.json({ csrfToken: req.csrfToken() });
});
app.get('/admin', (req, res) => {
  res.sendFile(join(__dirname, 'public', 'admin.html'));
});
app.get('/api/auth/me', (req, res) => {
  res.json(buildAuthState(req));
});
app.get('/api/auth/admin/check', requireAdminAccess, (req, res) => {
  res.status(204).end();
});
app.post('/api/auth/admin/login', (req, res) => {
  const apiKey = typeof req.body?.apiKey === 'string' ? req.body.apiKey.trim() : '';
  const configuredAdminApiKey = `${config.get('admin.apiKey') || ''}`.trim();
  if (!configuredAdminApiKey) {
    return res.status(503).json({ error: 'Admin authentication is not configured' });
  }
  if (!apiKey || apiKey !== configuredAdminApiKey) {
    clearAdminSession(res);
    return res.status(401).json({ error: 'Invalid admin credentials' });
  }
  issueAdminSession(req, res);
  req.user = { id: 'admin', role: 'admin', auth_source: 'admin_session' };
  return res.json(buildAuthState(req));
});
app.post('/api/auth/logout', (req, res) => {
  clearAdminSession(res);
  req.user = null;
  res.json({ ok: true, role: 'user', isAdmin: false, canManage: false, observability: null });
});
// Issue a development JWT token
app.get('/api/auth/token', (req, res) => {
  const allowDevTokenEndpoint =
    config.get('auth.devNoAuth') ||
    `${process.env.ENABLE_DEV_TOKEN_ENDPOINT || ''}`.trim().toLowerCase() === 'true';
  if (!allowDevTokenEndpoint) {
    return res.status(404).json({ error: 'Not found' });
  }
  const token = jwt.sign({ id: 1, email: 'dev@example.com' }, process.env.JWT_SECRET || 'devsecret', { expiresIn: '1h' });
  res.json({ token });
});
// Serve product list. Accepts optional ?limit=N to restrict the number of rows returned.
app.get('/api/products', requireAdminAccess, async (req, res) => {
  if (!COMMERCE_CATALOG_ENABLED) {
    return res.status(410).json({ error: 'Commerce catalog is disabled; use /api/knowledge/search for LawVoice documents' });
  }
  const { limit } = req.query;
  const sqlParts = ['SELECT id, name, thickness_mm, coating, price_rub_m2 FROM products'];
  const params = [];
  // Optionally apply ordering and limit
  sqlParts.push('ORDER BY id');
  if (limit) {
    const parsedLimit = Math.max(1, Math.min(parseInt(limit, 10) || 0, 100));
    sqlParts.push('LIMIT $1');
    params.push(parsedLimit);
  }
  try {
    const result = await pool.query(sqlParts.join(' '), params);
    res.json(result.rows);
  } catch (err) {
    logger.error('Failed to load products', err);
    res.status(500).json({ error: 'Failed to load products' });
  }
});
app.get('/api/admin/log-sources', requireAdminAccess, async (req, res) => {
  try {
    const sources = await buildLogSourcesPayload();
    res.json({ sources });
  } catch (err) {
    logger.error({ err }, 'Error listing admin log sources');
    res.status(500).json({ error: 'Failed to list log sources' });
  }
});

app.get('/api/admin/logs', requireAdminAccess, async (req, res) => {
  const source = typeof req.query?.source === 'string' ? req.query.source : 'app';
  const lines = Math.max(1, Math.min(parseInt(req.query?.lines, 10) || 200, 1000));
  try {
    const payload = await readLogSourceTail(source, lines);
    res.json(payload);
  } catch (err) {
    logger.error({ err, source }, 'Error reading admin logs');
    res.status(err.statusCode || 500).json({ error: err.statusCode === 404 ? 'Unknown log source' : 'Failed to read logs' });
  }
});

app.post('/api/session-recordings', async (req, res) => {
  try {
    const recording = await saveSessionRecording(req.body || {});
    recordSessionRecording({
      mode: recording.session?.mode,
      status: 'saved',
      endReason: recording.endReason,
      durationMs: recording.durationMs,
      userTurns: Array.isArray(recording.transcript) ? recording.transcript.filter(item => item.role === 'user').length : 0,
      assistantTurns: Array.isArray(recording.transcript) ? recording.transcript.filter(item => item.role === 'assistant').length : 0,
      tokens: recording.metrics?.tokens,
      estimatedCostUsd: recording.metrics?.estimatedCostUsd
    });
    logger.info({ sessionRecordingId: recording.id }, 'Saved session recording');
    res.status(201).json({ ok: true, id: recording.id });
  } catch (err) {
    recordSessionRecording({
      mode: req.body?.mode,
      status: 'error',
      endReason: req.body?.endReason || 'save_failed'
    });
    logger.error({ err }, 'Error saving session recording');
    res.status(err.statusCode || 500).json({ error: 'Failed to save session recording' });
  }
});

app.get('/api/admin/session-recordings', requireAdminAccess, async (req, res) => {
  const limit = Math.max(1, Math.min(parseInt(req.query?.limit, 10) || 50, 200));
  try {
    const items = await listSessionRecordings(limit);
    res.json({ items });
  } catch (err) {
    logger.error({ err }, 'Error listing session recordings');
    res.status(500).json({ error: 'Failed to list session recordings' });
  }
});

app.get('/api/admin/session-recordings/:id', requireAdminAccess, async (req, res) => {
  try {
    const recording = await readSessionRecording(req.params.id);
    res.json(recording);
  } catch (err) {
    logger.error({ err, id: req.params.id }, 'Error reading session recording');
    const statusCode = err.code === 'ENOENT' ? 404 : err.statusCode || 500;
    res.status(statusCode).json({ error: statusCode === 404 ? 'Session recording not found' : 'Failed to read session recording' });
  }
});

app.get('/api/logs', requireAdminAccess, async (req, res) => {
  try {
    const lines = Math.max(1, Math.min(parseInt(req.query?.lines, 10) || 100, 1000));
    const payload = await readLogSourceTail('app', lines);
    res.type('text/plain').send(payload.text || payload.message || '');
  } catch (err) {
    logger.error({ err }, 'Error reading logs');
    res.status(500).json({ error: 'Failed to read logs' });
  }
});

// Real-time agent console log stream
app.get('/api/agent-console', requireAdminAccess, (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders?.();
  res.write('\n');
  registerAgentConsoleClient(res);
});
app.post('/api/users/identify', async (req, res) => {
  const { phone, name } = req.body;
  try {
    const { rows } = await pool.query(
        `INSERT INTO users (phone, name) VALUES ($1, $2)
       ON CONFLICT (phone, name) DO UPDATE SET name = EXCLUDED.name
       RETURNING id`,
        [phone, name]
    );
    res.json({ user_id: rows[0].id });
  } catch (err) {
    logger.error('User identify failed', err);
    res.status(500).json({ error: 'Failed to identify user' });
  }
});
// Add item to cart and return subtotal
app.post('/api/cart', requireAdminAccess, async (req, res) => {
  if (!COMMERCE_CATALOG_ENABLED) {
    return res.status(410).json({ error: 'Commerce catalog is disabled' });
  }
  const { user_id, product_id, qty } = req.body;
  if (!user_id || !product_id || !qty) {
    return res.status(400).json({ error: 'Invalid request' });
  }
  try {
    await pool.query('BEGIN');
    const { rows: priceRows } = await pool.query('SELECT price_rub_m2 FROM products WHERE id = $1', [product_id]);
    if (priceRows.length === 0) {
      await pool.query('ROLLBACK');
      return res.status(400).json({ error: 'Product not found' });
    }
    const itemTotal = priceRows[0].price_rub_m2 * qty;
    await pool.query(
      'INSERT INTO orders (user_id, product_id, qty, total) VALUES ($1,$2,$3,$4)',
      [user_id, product_id, qty, itemTotal]
    );
    const { rows: sumRows } = await pool.query(
      'SELECT COALESCE(SUM(total),0) AS subtotal FROM orders WHERE user_id = $1 AND delivery_address IS NULL',
      [user_id]
    );
    await pool.query('COMMIT');
    res.json({ success: true, subtotal: sumRows[0].subtotal });
  } catch (err) {
    await pool.query('ROLLBACK');
    logger.error('Add to cart failed', err);
    res.status(500).json({ error: 'Failed to add to cart' });
  }
});

// Finalize order: update pending cart items with delivery details
app.post('/api/orders', requireAdminAccess, async (req, res) => {
  if (!COMMERCE_CATALOG_ENABLED) {
    return res.status(410).json({ error: 'Commerce catalog is disabled' });
  }
  const { user_id, delivery_address, contact_name, contact_phone } = req.body;
  if (!user_id) return res.status(400).json({ error: 'Invalid request' });
  try {
    await pool.query('BEGIN');
    const { rows: cartItems } = await pool.query(
      'SELECT * FROM orders WHERE user_id = $1 AND delivery_address IS NULL',
      [user_id]
    );
    if (cartItems.length === 0) {
      await pool.query('ROLLBACK');
      return res.status(400).json({ error: 'Cart empty' });
    }
    await pool.query(
      'UPDATE orders SET delivery_address=$2, contact_name=$3, contact_phone=$4 WHERE user_id=$1 AND delivery_address IS NULL',
      [user_id, delivery_address, contact_name, contact_phone]
    );
    const { rows: orders } = await pool.query(
      'SELECT * FROM orders WHERE user_id = $1 AND delivery_address = $2 AND contact_name = $3 AND contact_phone = $4',
      [user_id, delivery_address, contact_name, contact_phone]
    );
    const total = orders.reduce((sum, o) => sum + Number(o.total || 0), 0);
    await pool.query('COMMIT');
    res.json({ success: true, orders, total });
  } catch (err) {
    await pool.query('ROLLBACK');
    logger.error('Order submission failed', err);
    res.status(500).json({ error: 'Failed to submit order' });
  }
});

// Cancel pending order items
app.post('/api/orders/cancel', requireAdminAccess, async (req, res) => {
  if (!COMMERCE_CATALOG_ENABLED) {
    return res.status(410).json({ error: 'Commerce catalog is disabled' });
  }
  const { user_id } = req.body;
  if (!user_id) return res.status(400).json({ error: 'Invalid request' });
  try {
    await pool.query('DELETE FROM orders WHERE user_id = $1 AND delivery_address IS NULL', [user_id]);
    res.json({ success: true });
  } catch (err) {
    logger.error('Cancel order failed', err);
    res.status(500).json({ error: 'Failed to cancel order' });
  }
});
// Generate ephemeral token for OpenAI Realtime API
app.get('/api/session', async (req, res) => {
  const startedAtMs = Date.now();
  const requestLogger = req.log || logger;
  try {
    if (config.get('openai.mock')) {
      const sessionData = {
        client_secret: {
          value: 'mock-secret',
          expires_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
        },
        model: config.get('openai.model'),
      };
      if (SESSION_COST_LIMIT_USD !== null) {
        sessionData.session_cost_limit_usd = SESSION_COST_LIMIT_USD;
      }
      recordUpstreamRequest({
        operation: 'realtime_session',
        status: 'mock',
        durationMs: durationSince(startedAtMs)
      });
      requestLogger.info({ event: 'realtime_session_mock' }, 'Using mock OpenAI session data');
      return res.json(sessionData);
    }
    const response = await axios.post(
      'https://api.openai.com/v1/realtime/sessions',
      {
        model: config.get('openai.model'),
        voice: config.get('openai.voice'),
      },
      {
        headers: {
          Authorization: `Bearer ${config.get('openai.apiKey')}`,
          'Content-Type': 'application/json',
        },
      }
    );
    const sessionData = response.data;
    if (SESSION_COST_LIMIT_USD !== null) {
      sessionData.session_cost_limit_usd = SESSION_COST_LIMIT_USD;
    }
    recordUpstreamRequest({
      operation: 'realtime_session',
      status: 'ok',
      durationMs: durationSince(startedAtMs)
    });
    requestLogger.info(
      {
        event: 'realtime_session_created',
        model: sessionData.model,
        duration_ms: durationSince(startedAtMs)
      },
      'Ephemeral token generated successfully'
    );
    res.json(sessionData);
  } catch (error) {
    const status = error.response?.status || 500;
    const details = error.response?.data || error.message;
    recordUpstreamRequest({
      operation: 'realtime_session',
      status: 'error',
      durationMs: durationSince(startedAtMs)
    });
    requestLogger.error({ status, details }, 'Error generating ephemeral token');
    res.status(status).json({
      error: 'Internal server error while generating session token',
      message: error.message,
      details,
    });
  }
});
// Proxy SDP offer/answer exchange to avoid browser-side CORS issues.
app.post('/api/realtime/sdp', express.text({ type: ['application/sdp', 'text/plain'], limit: '2mb' }), async (req, res) => {
  const startedAtMs = Date.now();
  const requestLogger = req.log || logger;
  try {
    const authHeader = req.headers.authorization || '';
    const bearerPrefix = 'Bearer ';
    const ephemeralToken = authHeader.startsWith(bearerPrefix) ? authHeader.slice(bearerPrefix.length).trim() : '';
    if (!ephemeralToken) {
      return res.status(400).json({ error: 'Missing bearer token for realtime SDP exchange' });
    }

    const sdpOffer = typeof req.body === 'string' ? req.body : '';
    if (!sdpOffer.trim()) {
      return res.status(400).json({ error: 'Missing SDP offer body' });
    }

    const requestedModel = typeof req.query?.model === 'string' ? req.query.model.trim() : '';
    const model = requestedModel || config.get('openai.model');
    const openAiUrl = `https://api.openai.com/v1/realtime?model=${encodeURIComponent(model)}`;

    const upstream = await fetch(openAiUrl, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${ephemeralToken}`,
        'Content-Type': 'application/sdp'
      },
      body: sdpOffer
    });

    const answerBody = await upstream.text();
    const contentType = upstream.headers.get('content-type') || 'application/sdp';
    recordUpstreamRequest({
      operation: 'realtime_sdp_proxy',
      status: upstream.ok ? 'ok' : `http_${upstream.status}`,
      durationMs: durationSince(startedAtMs)
    });
    requestLogger.info(
      {
        event: 'realtime_sdp_proxy',
        model,
        status_code: upstream.status,
        sdp_offer_length: sdpOffer.length,
        duration_ms: durationSince(startedAtMs)
      },
      'Realtime SDP exchange completed'
    );
    res.status(upstream.status).type(contentType).send(answerBody);
  } catch (error) {
    recordUpstreamRequest({
      operation: 'realtime_sdp_proxy',
      status: 'error',
      durationMs: durationSince(startedAtMs)
    });
    requestLogger.error({ error: error?.message || error }, 'Error proxying realtime SDP exchange');
    res.status(502).json({
      error: 'Realtime SDP proxy error',
      message: error?.message || 'Unknown upstream error'
    });
  }
});
app.get('/api/products/search', requireAdminAccess, async (req, res) => {
  if (!COMMERCE_CATALOG_ENABLED) {
    return res.status(410).json({ error: 'Commerce catalog is disabled; use /api/knowledge/search for LawVoice documents' });
  }
  const { q, limit = 10, fuzzy = true, semantic = 'true', trigram = 'true' } = req.query;
  const parsedLimit = Math.max(1, Math.min(parseInt(limit, 10) || 10, 20));
  if (!q || typeof q !== 'string') {
    return res.status(400).json({ error: 'Missing query parameter "q"' });
  }
  const sanitizedQuery = q
    .trim()
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
  logger.info({ msg: '🛢️ DB search request', limit: parsedLimit, ...buildTextLogMeta(sanitizedQuery, 'query') });
  const results = { semantic: [], fts: [], trgm: [] };
  try {

    // Semantic (vector) search
    if (semantic !== 'false' && vectorExtensionAvailable) {
    const embedding = (await getEmbeddings([sanitizedQuery]))[0];
    logger.debug({ msg: 'Embedding generated', preview: embedding.slice(0,5) });
      const { rows: vecRows } = await pool.query(
        `SELECT p.id, p.name, p.thickness_mm, p.coating, p.price_rub_m2,
                1 - (pe.embedding <=> $1) AS semantic_score
           FROM products p
           JOIN product_embeddings pe ON p.id = pe.product_id
       ORDER BY pe.embedding <=> $1
          LIMIT $2`,
        [toSql(embedding), parsedLimit]
      );
      results.semantic = vecRows;
    } else if (semantic !== 'false' && !vectorExtensionAvailable) {
      logger.debug({ msg: 'Semantic search skipped (pgvector unavailable)' });
    }
    // Full‑text (tsvector) search
    const terms = expandTerms(sanitizedQuery);
    const tsQuery = terms.join(' | ');
    logger.debug({ msg: 'FTS terms', terms, tsQuery });
    const { rows: ftsRows } = await pool.query(
      `SELECT p.id, p.name, p.thickness_mm, p.coating, p.price_rub_m2,
              ts_rank(
                to_tsvector('russian', COALESCE(p.name,'') || ' ' || COALESCE(p.coating,'')),
                to_tsquery('russian', $1)
              ) AS rank
         FROM products p
        WHERE to_tsvector('russian', COALESCE(p.name,'') || ' ' || COALESCE(p.coating,'')) @@ to_tsquery('russian', $1)
        ORDER BY rank DESC
        LIMIT $2`,
      [tsQuery, parsedLimit]
    );
    results.fts = ftsRows;
    // Trigram (fuzzy) search
    if (trigram !== 'false') {
      const { rows: trgmRows } = await pool.query(
        `SELECT id, name, thickness_mm, coating, price_rub_m2,
                GREATEST(similarity(name, $1), similarity(coating, $1)) AS score
           FROM products
       ORDER BY score DESC
          LIMIT $2`,
        [sanitizedQuery, parsedLimit]
      );
      results.trgm = trgmRows;
    }
    // Log summary
    const totalCount = results.semantic.length + results.fts.length + results.trgm.length;
    logger.info({ msg: '🧾 DB search completed', results: totalCount, ...buildTextLogMeta(sanitizedQuery, 'query') });
    const combined = [...results.semantic, ...results.fts, ...results.trgm];
    res.json(combined);
  } catch (err) {
    logger.error('Hybrid search failed', err);
    res.status(500).json({ error: 'Search failed' });
  }
});

// List distinct product categories. A category is derived from the product name by
// removing everything after the first occurrence of the Cyrillic "x" character
// (used in product names as a separator) and trimming whitespace. For
// "Плоский лист *****" this leaves the base descriptor "Плоский лист *****"; for
// profiles like "С-8 х 1150- А, В" it becomes "С-8". You can optionally pass
// ?limit=N to restrict how many categories are returned. Results are sorted
// alphabetically.
app.get('/api/products/categories', requireAdminAccess, async (req, res) => {
  if (!COMMERCE_CATALOG_ENABLED) {
    return res.status(410).json({ error: 'Commerce catalog is disabled' });
  }
  const { limit } = req.query;
  const params = [];
  let sql = `SELECT DISTINCT TRIM(regexp_replace(name, '\\s*х.*$', '', 'g')) AS category
               FROM products
              WHERE name IS NOT NULL
              ORDER BY category`;
  if (limit) {
    const parsedLimit = Math.max(1, Math.min(parseInt(limit, 10) || 0, 100));
    sql += ' LIMIT $1';
    params.push(parsedLimit);
  }
  try {
    const { rows } = await pool.query(sql, params);
    const categories = rows.map(r => r.category);
    res.json(categories);
  } catch (err) {
    logger.error('Failed to fetch categories', err);
    res.status(500).json({ error: 'Failed to fetch categories' });
  }
});
app.get('/api/profiles', async (req, res) => {
  try {
    const files = await readdir(profilesDir);
    const profiles = [];
    for (const file of files) {
      if (!file.endsWith('.json')) continue;
      const data = await readFile(join(profilesDir, file), 'utf-8');
      const profile = JSON.parse(data);
      profile.id = file.replace(/\.json$/i, '');
      profiles.push(profile);
    }
    res.json(profiles);
  } catch (error) {
    console.error('Profiles list error:', error);
    res.status(500).json({ error: 'Failed to fetch profiles' });
  }
});
app.get('/api/profiles/:id', async (req, res) => {
  try {
    const filePath = join(profilesDir, `${req.params.id}.json`);
    const data = await readFile(filePath, 'utf-8');
    const profile = JSON.parse(data);
    profile.id = req.params.id;
    res.json(profile);
  } catch (error) {
    console.error('Profile fetch error:', error);
    res.status(404).json({ error: 'Profile not found' });
  }
});
app.post('/api/profiles', requireAdminAccess, async (req, res) => {
  try {
    const id = crypto.randomUUID();
    const filePath = join(profilesDir, `${id}.json`);
    await writeFile(filePath, JSON.stringify(req.body, null, 2));
    res.status(201).json({ id });
  } catch (error) {
    console.error('Profile save error:', error);
    res.status(500).json({ error: 'Failed to save profile' });
  }
});
app.put('/api/profiles/:id', requireAdminAccess, async (req, res) => {
  try {
    const filePath = join(profilesDir, `${req.params.id}.json`);
    let existing = {};
    try {
      const data = await readFile(filePath, 'utf-8');
      existing = JSON.parse(data);
    } catch {}
    const updated = { ...existing, ...req.body };
    await writeFile(filePath, JSON.stringify(updated, null, 2));
    res.json({ status: 'ok' });
  } catch (error) {
    console.error('Profile update error:', error);
    res.status(500).json({ error: 'Failed to update profile' });
  }
});
  // End product search endpoint
/*
SQL for analytics table:
CREATE TABLE analytics (
  id SERIAL PRIMARY KEY,
  session_id TEXT,
  duration_ms INTEGER,
  tokens INTEGER,
  queries INTEGER,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
*/
// In server.js: Add this after other app.get/post routes
app.post('/api/classify-intent', async (req, res) => {
  const startedAtMs = Date.now();
  const requestLogger = req.log || logger;
  const { transcript, mode } = req.body;
  if (!transcript) return res.status(400).json({ error: 'Missing transcript' });
  requestLogger.info({
    msg: '🎯 Intent detection request',
    mode: mode || 'auto',
    ...buildTextLogMeta(transcript, 'transcript')
  });
  try {
    const { toolCall, confidence, meta } = await classifyIntent(transcript, { mode });
    const toolName = toolCall?.function?.name || toolCall?.name || 'unknown';
    const highRiskTools = new Set(['detention_help', 'emergency_help', 'contact_trusted_adult', 'escalate_safety']);
    recordIntentRequest({
      mode: mode || 'auto',
      tool: toolName,
      status: 'ok',
      durationMs: durationSince(startedAtMs),
      highRisk: highRiskTools.has(toolName)
    });
    requestLogger.info({ msg: '🎯 Intent detection result', tool: toolName, confidence, meta, duration_ms: durationSince(startedAtMs) });
    res.json({ toolCall, confidence, meta: meta || null });
  } catch (err) {
    const dev = process.env.NODE_ENV !== 'production';
    const status  = err?.response?.status || 500;
    const details = err?.response?.data   || err.message;
    recordIntentRequest({
      mode: mode || 'auto',
      tool: 'unknown',
      status: 'error',
      durationMs: durationSince(startedAtMs)
    });
    requestLogger.error({ msg:'Intent classification failed', status, details, duration_ms: durationSince(startedAtMs) });
    res.status(status).json({
      error: 'Failed to classify intent',
      ...(dev ? { details } : {})
    });
  }
});
app.post('/api/knowledge/documents', requireAdminAccess, async (req, res) => {
  const normalized = normalizeKnowledgeDocumentPayload(req.body || {});
  if (!normalized.content) {
    return res.status(400).json({ error: 'Document content is required' });
  }

  const maxChars = 250000;
  if (normalized.content.length > maxChars) {
    return res.status(413).json({
      error: 'Document is too large',
      limit_chars: maxChars
    });
  }

  const chunks = splitTextIntoChunks(normalized.content);
  if (chunks.length === 0) {
    return res.status(400).json({ error: 'Unable to split document into chunks' });
  }

  const maxChunks = 300;
  if (chunks.length > maxChunks) {
    return res.status(413).json({
      error: 'Document has too many chunks',
      limit_chunks: maxChunks
    });
  }

  const requestedId = typeof req.body?.id === 'string' ? req.body.id.trim() : '';
  const documentId = requestedId || crypto.randomUUID();
  const extraMetadata =
    req.body?.metadata && typeof req.body.metadata === 'object' && !Array.isArray(req.body.metadata)
      ? req.body.metadata
      : {};
  const metadata = {
    ...extraMetadata,
    tags: normalized.tags,
    content_length: normalized.content.length,
    uploaded_at: new Date().toISOString()
  };

  let embeddings = [];
  try {
    embeddings = await getEmbeddings(chunks);
  } catch (err) {
    logger.warn({ err, documentId }, 'Embeddings failed for knowledge document, storing text only');
    embeddings = new Array(chunks.length).fill(null);
  }

  try {
    await pool.query('BEGIN');
    await pool.query(
      `INSERT INTO knowledge_documents (id, title, source_name, mime_type, content, metadata)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb)
       ON CONFLICT (id) DO UPDATE SET
         title = EXCLUDED.title,
         source_name = EXCLUDED.source_name,
         mime_type = EXCLUDED.mime_type,
         content = EXCLUDED.content,
         metadata = COALESCE(knowledge_documents.metadata, '{}'::jsonb) || EXCLUDED.metadata`,
      [
        documentId,
        normalized.title,
        normalized.sourceName,
        normalized.mimeType,
        normalized.content,
        JSON.stringify(metadata)
      ]
    );

    await pool.query('DELETE FROM knowledge_chunks WHERE document_id = $1', [documentId]);

    for (let index = 0; index < chunks.length; index += 1) {
      const chunkText = chunks[index];
      const embeddingValue = Array.isArray(embeddings[index])
        ? (vectorExtensionAvailable ? toSql(embeddings[index]) : JSON.stringify(embeddings[index]))
        : null;
      const embeddingPlaceholder = vectorExtensionAvailable ? '$4' : '$4::jsonb';
      await pool.query(
        `INSERT INTO knowledge_chunks (document_id, chunk_index, chunk_text, embedding, token_estimate)
         VALUES ($1, $2, $3, ${embeddingPlaceholder}, $5)`,
        [documentId, index, chunkText, embeddingValue, estimateTokens(chunkText)]
      );
    }

    await pool.query('COMMIT');
    res.status(201).json({
      success: true,
      document: {
        id: documentId,
        title: normalized.title,
        source_name: normalized.sourceName,
        mime_type: normalized.mimeType
      },
      stats: {
        characters: normalized.content.length,
        chunks: chunks.length,
        tokens: chunks.reduce((sum, chunk) => sum + estimateTokens(chunk), 0)
      }
    });
  } catch (err) {
    try {
      await pool.query('ROLLBACK');
    } catch {}
    logger.error({ err, documentId }, 'Knowledge document ingest failed');
    res.status(500).json({ error: 'Failed to ingest knowledge document' });
  }
});
app.get('/api/knowledge/documents', requireAdminAccess, async (req, res) => {
  const parsedLimit = Math.max(1, Math.min(parseInt(req.query?.limit, 10) || 20, 100));
  const parsedOffset = Math.max(0, parseInt(req.query?.offset, 10) || 0);
  const queryText = typeof req.query?.q === 'string' ? req.query.q.trim() : '';

  const params = [];
  let whereClause = '';
  if (queryText) {
    params.push(`%${queryText}%`);
    whereClause = `WHERE kd.title ILIKE $${params.length} OR COALESCE(kd.source_name, '') ILIKE $${params.length}`;
  }

  params.push(parsedLimit);
  const limitIndex = params.length;
  params.push(parsedOffset);
  const offsetIndex = params.length;

  try {
    const { rows } = await pool.query(
      `SELECT kd.id,
              kd.title,
              kd.source_name,
              kd.mime_type,
              kd.metadata,
              kd.created_at,
              COALESCE(COUNT(kc.id), 0)::INTEGER AS chunk_count,
              COALESCE(SUM(kc.token_estimate), 0)::INTEGER AS token_estimate
         FROM knowledge_documents kd
         LEFT JOIN knowledge_chunks kc ON kc.document_id = kd.id
         ${whereClause}
        GROUP BY kd.id
        ORDER BY kd.created_at DESC
        LIMIT $${limitIndex}
       OFFSET $${offsetIndex}`,
      params
    );
    res.json({
      items: rows,
      pagination: {
        limit: parsedLimit,
        offset: parsedOffset
      }
    });
  } catch (err) {
    logger.error({ err }, 'Failed to list knowledge documents');
    res.status(500).json({ error: 'Failed to list knowledge documents' });
  }
});
app.delete('/api/knowledge/documents/:id', requireAdminAccess, async (req, res) => {
  const documentId = typeof req.params?.id === 'string' ? req.params.id.trim() : '';
  if (!documentId) {
    return res.status(400).json({ error: 'Missing document id' });
  }

  try {
    await pool.query('BEGIN');
    const { rows: countRows } = await pool.query(
      'SELECT COUNT(*)::INTEGER AS count FROM knowledge_chunks WHERE document_id = $1',
      [documentId]
    );
    const chunkCount = Number(countRows?.[0]?.count || 0);
    const deleted = await pool.query(
      'DELETE FROM knowledge_documents WHERE id = $1 RETURNING id',
      [documentId]
    );
    if (!deleted.rowCount) {
      await pool.query('ROLLBACK');
      return res.status(404).json({ error: 'Knowledge document not found' });
    }
    await pool.query('COMMIT');
    res.json({
      success: true,
      id: documentId,
      deleted_chunks: chunkCount
    });
  } catch (err) {
    try {
      await pool.query('ROLLBACK');
    } catch {}
    logger.error({ err, documentId }, 'Failed to delete knowledge document');
    res.status(500).json({ error: 'Failed to delete knowledge document' });
  }
});
app.post('/api/knowledge/search', requireAdminAccess, async (req, res) => {
  const requestLogger = req.log || logger;
  const queryText =
    (typeof req.body?.query === 'string' && req.body.query.trim()) ||
    (typeof req.body?.query_text === 'string' && req.body.query_text.trim()) ||
    '';
  if (!queryText) {
    return res.status(400).json({ error: 'Missing query text' });
  }
  const parsedLimit = Math.max(1, Math.min(parseInt(req.body?.limit, 10) || 6, 20));

  try {
    requestLogger.info({
      event: 'knowledge_search_request',
      source: 'api_knowledge_search',
      limit: parsedLimit,
      ...buildTextLogMeta(queryText, 'query')
    });
    const { hits, backend } = await searchKnowledgeChunks(queryText, parsedLimit, {
      source: 'api_knowledge_search',
      logger: requestLogger
    });
    res.json({
      query: queryText,
      backend,
      hits,
      count: hits.length
    });
  } catch (err) {
    requestLogger.error({ err, ...buildTextLogMeta(queryText, 'query') }, 'Knowledge search failed');
    res.status(500).json({ error: 'Knowledge search failed' });
  }
});
app.post('/api/action-plan', requireAdminAccess, async (req, res) => {
  const startedAtMs = Date.now();
  const requestLogger = req.log || logger;
  const objective = typeof req.body?.objective === 'string' ? req.body.objective.trim() : '';
  const contextText =
    (typeof req.body?.context_text === 'string' && req.body.context_text.trim()) ||
    (typeof req.body?.contextText === 'string' && req.body.contextText.trim()) ||
    (typeof req.body?.context === 'string' && req.body.context.trim()) ||
    '';
  const constraints = Array.isArray(req.body?.constraints) ? req.body.constraints : [];
  const currentPlan = Array.isArray(req.body?.current_plan)
    ? req.body.current_plan
    : Array.isArray(req.body?.currentPlan)
      ? req.body.currentPlan
      : [];
  const knowledgeQuery =
    (typeof req.body?.knowledge_query === 'string' && req.body.knowledge_query.trim()) ||
    (typeof req.body?.knowledgeQuery === 'string' && req.body.knowledgeQuery.trim()) ||
    '';
  const queryForKnowledge = knowledgeQuery || objective || contextText;
  if (!queryForKnowledge) {
    return res.status(400).json({
      error: 'Provide at least one of: objective, context, knowledge_query'
    });
  }

  const knowledgeLimit = Math.max(1, Math.min(parseInt(req.body?.knowledge_limit, 10) || parseInt(req.body?.knowledgeLimit, 10) || 6, 20));
  requestLogger.info({
    event: 'action_plan_request',
    knowledge_limit: knowledgeLimit,
    ...buildTextLogMeta(objective, 'objective'),
    ...buildTextLogMeta(contextText, 'context'),
    ...buildTextLogMeta(queryForKnowledge, 'knowledge_query')
  });
  const { hits: knowledgeHits, backend: knowledgeBackend } = await searchKnowledgeChunks(queryForKnowledge, knowledgeLimit, {
    source: 'action_plan',
    logger: requestLogger
  });
  const planModel = config.get('openai.intentModel') || config.get('openai.model');

  try {
    const plan = await buildGroundedActionPlan({
      openai,
      model: planModel,
      objective,
      contextText,
      constraints,
      currentPlan,
      knowledgeHits,
      telemetry: event => {
        if (event?.type === 'llm_request') {
          recordLlmRequest({
            operation: event.operation,
            model: event.model,
            status: event.status,
            durationMs: event.durationMs
          });
        }
      }
    });
    recordActionPlan({
      mode: plan.mode,
      status: 'ok',
      durationMs: durationSince(startedAtMs),
      knowledgeHitCount: knowledgeHits.length
    });
    requestLogger.info({
      event: 'action_plan_result',
      mode: plan.mode,
      steps: Array.isArray(plan.steps) ? plan.steps.length : 0,
      knowledge_backend: knowledgeBackend,
      knowledge_hits: knowledgeHits.length,
      duration_ms: durationSince(startedAtMs)
    });

    res.json({
      mode: plan.mode,
      summary: plan.summary,
      steps: plan.steps,
      knowledge: {
        query: queryForKnowledge,
        backend: knowledgeBackend,
        count: knowledgeHits.length,
        hits: knowledgeHits
      }
    });
  } catch (err) {
    recordActionPlan({
      mode: currentPlan.length > 0 ? 'corrected' : 'draft',
      status: 'error',
      durationMs: durationSince(startedAtMs),
      knowledgeHitCount: knowledgeHits.length
    });
    requestLogger.error({ err, knowledge_hits: knowledgeHits.length }, 'Action plan generation failed');
    res.status(500).json({ error: 'Failed to build action plan' });
  }
});
app.post('/api/analytics', async (req, res) => {
  const session_id = req.body?.session_id ?? req.body?.sessionId ?? null;
  const duration_ms = Number(req.body?.duration_ms ?? req.body?.durationMs ?? 0);
  const tokens = Number(req.body?.tokens ?? 0);
  const queries = Number(req.body?.queries ?? 0);
  try {
    await pool.query(
      'INSERT INTO analytics (session_id, duration_ms, tokens, queries) VALUES ($1, $2, $3, $4)',
      [session_id, duration_ms, tokens, queries]
    );
    res.json({ success: true });
  } catch (err) {
    logger.error('Analytics insert failed', err);
    // Analytics are non-critical: keep voice/session flow working even when DB is down.
    res.status(202).json({ success: false, warning: 'Analytics unavailable' });
  }
});
app.get('/api/analytics', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT * FROM analytics ORDER BY created_at DESC LIMIT 100');
    res.json(rows);
  } catch (err) {
    logger.error('Analytics fetch failed', err);
    // Return empty dataset to avoid breaking the frontend dashboard.
    res.json([]);
  }
});
// Ловим CSRF-ошибку отдельно, чтобы не превращать в 500.
app.use((err, req, res, next) => {
  if (err && err.code === 'EBADCSRFTOKEN') {
    return res.status(403).json({
      error: 'Invalid CSRF token',
      hint: 'Fetch /api/csrf-token and send it in X-CSRF-Token header'
    });
  }
  next(err);
});
// Global error handler
app.use((err, req, res, next) => {
  logger.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error' });
});
// Start server with HTTPS if in production
let server;
const sslDomain = (process.env.SSL_DOMAIN || '').trim();
const defaultHttpsKeyPath = sslDomain ? `/etc/letsencrypt/live/${sslDomain}/privkey.pem` : '';
const defaultHttpsCertPath = sslDomain ? `/etc/letsencrypt/live/${sslDomain}/fullchain.pem` : '';
const httpsKeyPath = (process.env.HTTPS_KEY_PATH || defaultHttpsKeyPath).trim();
const httpsCertPath = (process.env.HTTPS_CERT_PATH || defaultHttpsCertPath).trim();
const httpsFlagRaw = `${process.env.ENABLE_HTTPS || ''}`.trim().toLowerCase();
const forceHttps = httpsFlagRaw === 'true';
const forceHttp = httpsFlagRaw === 'false';
const enableHttps = forceHttps || (!forceHttp && process.env.NODE_ENV === 'production' && httpsKeyPath && httpsCertPath);

if (enableHttps) {
  try {
    const options = {
      key: readFileSync(httpsKeyPath),
      cert: readFileSync(httpsCertPath)
    };
    server = https.createServer(options, app);
    logger.info(`HTTPS enabled using cert path: ${httpsCertPath}`);
  } catch (err) {
    logger.error({ err }, 'Failed to initialize HTTPS certificates; falling back to HTTP');
    server = http.createServer(app);
  }
} else {
  if (process.env.NODE_ENV === 'production') {
    logger.warn('NODE_ENV=production without HTTPS cert paths. Serving HTTP (expected behind reverse proxy).');
  }
  server = http.createServer(app);
}
const MAX_PORT_RETRIES = 5;
function startServer(port, retry = 0) {
  const onError = (err) => {
    if (err.code === 'EADDRINUSE' && retry < MAX_PORT_RETRIES) {
      const nextPort = Number(port) + 1;
      const retryMsg = `Port ${port} is busy, retrying on ${nextPort}`;
      logger.warn(retryMsg);
      agentConsoleLog(retryMsg);
      startServer(nextPort, retry + 1);
      return;
    }
    logger.error({ err }, 'Server startup failed');
    process.exit(1);
  };

  server.once('error', onError);
  server.listen(port, () => {
    server.off('error', onError);
    const msg = `Server running on port ${port}`;
    logger.info(msg);
    agentConsoleLog(msg);
  });
}

startServer(PORT);

export { app, server, pool };


// ---- ANTI-CANCEL VOICE ROUTES ----
const voiceSession = { ttsStartedAt: 0, lastCancelAt: 0 };

app.post('/api/voice/register-tts-start', express.json(), (req, res) => {
  voiceSession.ttsStartedAt = Date.now();
  res.json({ ok: true, ttsStartedAt: voiceSession.ttsStartedAt });
});

app.post('/api/voice/maybe-cancel', express.json(), (req, res) => {
  const now = Date.now();
  const vadActiveMs = Number(req.body?.vadActiveMs || 0);
  const rmsDb = Number(req.body?.rmsDb || 0);
  const MIN_SINCE_TTS_MS = 1200;
  const VAD_MIN_MS = 400;
  const CANCEL_COOLDOWN_MS = 1800;

  const allow =
    (now - voiceSession.ttsStartedAt) > MIN_SINCE_TTS_MS &&
    vadActiveMs >= VAD_MIN_MS &&
    (now - voiceSession.lastCancelAt) > CANCEL_COOLDOWN_MS;

  if (allow) {
    voiceSession.lastCancelAt = now;
    return res.json({ ok: true, cancel: true });
  } else {
    return res.json({ ok: true, cancel: false, ignored: true });
  }
});
// ---- END ANTI-CANCEL VOICE ROUTES ----

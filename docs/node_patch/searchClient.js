// node_patch/searchClient.js
// Клиент для общения с Python-поиском c таймаутами и health-пингом
const fetch = (...args) => import('node-fetch').then(({default: fetch}) => fetch(...args));

const SEARCH_API = process.env.SEARCH_API || "http://127.0.0.1:5051";

async function httpGetJson(url, { timeoutMs = 1200 } = {}) {
  const ctrl = new AbortController();
  const to = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const r = await fetch(url, { signal: ctrl.signal });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return await r.json();
  } finally {
    clearTimeout(to);
  }
}

async function healthOk() {
  try {
    const h = await httpGetJson(`${SEARCH_API}/healthz`, { timeoutMs: 800 });
    return !!h?.ok;
  } catch {
    return false;
  }
}

async function listProducts(limit = 10) {
  try {
    return await httpGetJson(`${SEARCH_API}/v1/products/list?limit=${limit}`);
  } catch (e) {
    if (!(await healthOk())) {
      const err = new Error("search_down");
      err.code = "search_down";
      throw err;
    }
    throw e;
  }
}

async function searchProducts(q, limit = 10) {
  try {
    return await httpGetJson(`${SEARCH_API}/v1/products/search?q=${encodeURIComponent(q)}&limit=${limit}`);
  } catch (e) {
    if (!(await healthOk())) {
      const err = new Error("search_down");
      err.code = "search_down";
      throw err;
    }
    throw e;
  }
}

module.exports = {
  listProducts,
  searchProducts,
  healthOk
};
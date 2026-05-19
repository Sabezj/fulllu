function toFiniteNumber(value) {
  const num = Number(value);
  return Number.isFinite(num) ? num : null;
}

function buildQueryFromAttrs(attrs) {
  const parts = [];

  if (attrs.category) parts.push(String(attrs.category));
  if (attrs.material) parts.push(String(attrs.material));
  if (attrs.coating) parts.push(String(attrs.coating));

  if (attrs.thickness != null) parts.push(`${attrs.thickness} мм`);
  if (attrs.width != null) parts.push(`${attrs.width} мм`);
  if (attrs.length != null) parts.push(`${attrs.length} мм`);

  return parts.join(' ').trim();
}

function filterProductsByLockedParams(products, locked) {
  if (!Array.isArray(products)) return [];

  const targetThickness = toFiniteNumber(locked.thickness_mm);
  if (targetThickness == null) return products;

  return products.filter((product) => {
    const value = toFiniteNumber(product?.thickness_mm);
    if (value == null) return true;
    return Math.abs(value - targetThickness) < 0.5;
  });
}

export async function strictSearchByParams(attrs = {}, options = {}) {
  if (window.LAWVOICE_COMMERCE_CATALOG_ENABLED !== true) {
    return {
      products: [],
      params_locked: {
        thickness_mm: toFiniteNumber(attrs.thickness ?? attrs.thickness_mm),
        width_mm: toFiniteNumber(attrs.width ?? attrs.width_mm),
        length_mm: toFiniteNumber(attrs.length ?? attrs.length_mm),
        category: attrs.category || null,
        material: attrs.material || null,
        coating: attrs.coating || null
      },
      disabled: true
    };
  }
  const limit = Math.max(1, Math.min(Number(options.limit) || 10, 20));
  const paramsLocked = {
    thickness_mm: toFiniteNumber(attrs.thickness ?? attrs.thickness_mm),
    width_mm: toFiniteNumber(attrs.width ?? attrs.width_mm),
    length_mm: toFiniteNumber(attrs.length ?? attrs.length_mm),
    category: attrs.category || null,
    material: attrs.material || null,
    coating: attrs.coating || null
  };

  const queryText = attrs.query_text || buildQueryFromAttrs(attrs);
  if (!queryText) {
    return { products: [], params_locked: paramsLocked };
  }

  const qs = new URLSearchParams({
    q: queryText,
    limit: String(limit),
    semantic: 'true',
    trigram: 'true'
  });

  const response = await fetch(`/api/products/search?${qs.toString()}`);
  if (!response.ok) {
    throw new Error(await response.text());
  }

  const payload = await response.json();
  const products = Array.isArray(payload)
    ? payload
    : [
        ...(Array.isArray(payload?.items) ? payload.items : []),
        ...(Array.isArray(payload?.semantic) ? payload.semantic : []),
        ...(Array.isArray(payload?.fts) ? payload.fts : []),
        ...(Array.isArray(payload?.trgm) ? payload.trgm : [])
      ];
  const filtered = filterProductsByLockedParams(products, paramsLocked);

  return {
    products: filtered.slice(0, limit),
    params_locked: paramsLocked
  };
}

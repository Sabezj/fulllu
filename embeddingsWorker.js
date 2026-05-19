import OpenAI from "openai";
import { Pool } from "pg";
import config from "./config.js";

const openai = new OpenAI({ apiKey: config.get("openai.apiKey") });
const pool = new Pool({ connectionString: config.get("database.url") });

/**
 * Return products for which we still have no embedding.
 * Additionally, guard against rows that contain invalid or empty numeric values in thickness_mm.
 */
async function fetchUnembeddedProducts() {
  const res = await pool.query(`
    SELECT id,
           name,
           profile_code,
           -- Cast to text so that even malformed numerics ('' etc.) won't break the driver:
           COALESCE(thickness_mm::text, '')   AS thickness_mm,
           coating
      FROM products AS p
     WHERE NOT EXISTS (SELECT 1
                         FROM product_embeddings pe
                        WHERE pe.product_id = p.id)
     ORDER BY updated_at DESC
     LIMIT 100
  `);
  return res.rows;
}

/**
 * Assemble a compact string that is sent to OpenAI for embedding.
 */
function textForEmbed(p) {
  // join with spaces, drop empty parts
  return [
    p.name,
    p.profile_code,
    p.thickness_mm ? p.thickness_mm + "мм" : "",
    p.coating
  ].filter(Boolean).join(" ");
}

/**
 * Call OpenAI Embeddings once for a (small) batch.
 */
async function embed(texts) {
  const resp = await openai.embeddings.create({
    model: "text-embedding-ada-002",
    input: texts,
  });
  return resp.data.map((d) => d.embedding);
}

/**
 * Store embedding vector in Postgres.
 * The `vector` extension expects an array literal, e.g. '[1,2,3]'::vector
 */
async function saveEmbedding(productId, embedding) {
  // Ensure we serialise as '[0.1,0.2,…]' instead of '{"0.1","0.2"}'
  const pgVector = '[' + embedding.join(',') + ']';
  await pool.query(
    `    INSERT INTO product_embeddings (product_id, embedding)
         VALUES ($1, $2::vector)
    ON CONFLICT (product_id)
       DO UPDATE SET embedding = EXCLUDED.embedding,
                     updated_at = now();
    `,
    [productId, pgVector]
  );
}

(async () => {
  try {
    const products = await fetchUnembeddedProducts();
    if (products.length === 0) {
      console.log("No products found for embedding.");
      process.exit(0);
    }

    const texts      = products.map(textForEmbed);
    const embeddings = await embed(texts);

    for (let i = 0; i < products.length; i++) {
      await saveEmbedding(products[i].id, embeddings[i]);
      console.log(`Embedded product #${products[i].id}`);
    }

    console.log("Done.");
    process.exit(0);
  } catch (err) {
    console.error("Embedding worker failed:", err);
    process.exit(1);
  }
})();
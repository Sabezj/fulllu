# LawVoice Thesis Defense Fixes

## Output

- Revised thesis DOCX: `C:\Users\xsanf\Downloads\Telegram Desktop\HSE_Bachelor_Thesis_LawVoice_revised_defense.docx`
- Retrieval benchmark JSON: `F:\GitHub\vangZ_strict_patched_plus_voice_assistant\docs\defense\lawvoice_retrieval_benchmark.json`
- Backend benchmark JSON: `F:\GitHub\vangZ_strict_patched_plus_voice_assistant\docs\defense\lawvoice_backend_benchmark.json`

## Main thesis corrections

1. The goal was narrowed to a backend-centered prototype of a real-time RAG voice assistant, with explicit emphasis on retrieval placement, safety enforcement and measurability.
2. The RAG description was corrected so that retrieval clearly happens before generation: user query -> intent/risk detection -> retrieval -> grounded prompt assembly -> LLM response -> post-generation validation.
3. The work now includes explicit retrieval metrics: Hit@1=0.90, Hit@3=0.90, MRR@3=0.90, nDCG@3=0.884.
4. The evaluation chapter now includes a synthetic backend benchmark with route-level latency and throughput numbers.
5. Security claims were narrowed: the revised text states clearly that a proprietary external LLM prevents any claim of full confidentiality, so the correct claim is risk reduction rather than absolute security.
6. Observability was promoted to an architectural requirement. The revised thesis explicitly recommends Langfuse for LLM request tracing and Prometheus/Grafana for metrics, dashboards and alerts.
7. The scalability section now identifies the stateless backend layer, the PostgreSQL/pgvector retrieval layer and provider latency as the main performance boundaries.

## Backend benchmark snapshot

- GET /api/profiles: p50 14.31 ms, p95 16.21 ms, throughput 136.94 requests/s ; POST /api/classify-intent (lawvoice rule path): p50 12.21 ms, p95 15.99 ms, throughput 153.04 requests/s ; POST /api/knowledge/search: p50 7.88 ms, p95 9.14 ms, throughput 239.86 requests/s ; POST /api/action-plan: p50 8.08 ms, p95 10.26 ms, throughput 246.49 requests/s

## Defense positioning

- Defend the work as a backend/system prototype, not as a fully validated legal product.
- When asked about RAG, say that retrieval is evaluated before generation and that post-generation validation only constrains format and citations.
- When asked about security, say that the prototype reduces risk but does not provide absolute confidentiality because the provider-side LLM remains external.
- When asked about scaling, say that the current artifact is single-node and prototype-level, but the thesis now identifies the concrete bottlenecks and the target service decomposition.

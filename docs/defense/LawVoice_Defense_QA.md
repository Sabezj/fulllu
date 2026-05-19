# LawVoice Defense Q&A

## Positioning

- Defend the work as a backend-centered prototype of a real-time RAG voice assistant for adolescent legal literacy.
- Do not defend it as a fully validated legal product, a privacy-complete system or a finished production deployment.

## Likely questions

### Where is RAG in the pipeline?

Retrieval happens before generation. The backend first detects intent and risk, then retrieves relevant chunks, assembles a grounded prompt, sends that grounded context to the model and only after that validates the output format and citations. Post-generation validation does not replace retrieval.

### What RAG metrics do you have?

For the current prototype, the thesis now reports a proxy retrieval benchmark over the shipped internal corpus. The reported values are Hit@1 = 0.90, Hit@3 = 0.90, MRR@3 = 0.90 and nDCG@3 = 0.884. The correct interpretation is prototype-level retrievability of the curated corpus, not final legal-answer quality.

### Why are the metrics only proxy-level?

Because the repository snapshot available in the defense environment does not contain a reproducible expert-labelled legal corpus or a stable production database dump. Instead of pretending otherwise, the work now states this limitation explicitly and uses a reproducible proxy benchmark plus synthetic backend measurements.

### What about monitoring and observability?

The revised work treats observability as part of the architecture. Langfuse is proposed for request tracing at the LLM boundary, while Prometheus and Grafana are proposed for metrics, dashboards and alerts. The key point is that the prototype now specifies where monitoring belongs and which signals should be collected.

### Is the system secure?

Not in the absolute sense. Because the current prototype uses a proprietary external LLM API, it cannot claim full institutional confidentiality. The correct claim is that the architecture reduces risk through server-side credentials, limited tools, safety routing, constrained evidence references and planned redaction-aware tracing.

### Why is there no full load test?

The revised thesis acknowledges that limitation directly. What is included now is a synthetic backend benchmark that isolates the local orchestration overhead from provider latency. This supports a narrow but defensible claim: local route overhead is low, while the likely future bottlenecks are provider latency, database retrieval and concurrent session management.

### How does the architecture scale?

The backend layer is structurally scalable because session bootstrap, retrieval orchestration and action-plan generation are stateless. The main bottlenecks are PostgreSQL/pgvector search, external provider latency and shared analytics or cache services. A production-ready decomposition would separate the realtime gateway, domain orchestration, retrieval and observability services.

### What is the personal contribution?

The personal contribution is the integration and evaluation of the prototype as a coherent backend system: domain framing, architecture, retrieval flow, safety routing, observability plan, measurable evaluation and defense-ready documentation.

## Answers to avoid

- "This is not the goal of my work."
- "I only have one user."
- "Scalability is not my problem."
- "The system is secure because logs are stored locally."

## Better alternatives

- "The scope of the work is a backend-centered prototype, but within that scope I still measured retrieval quality, backend behavior and the main operational limitations."
- "I do not claim production scalability, but I do identify the concrete bottlenecks and the service boundaries that would matter in the next stage."
- "I do not claim full confidentiality because the model provider is external; I claim risk reduction through architecture and operational controls."

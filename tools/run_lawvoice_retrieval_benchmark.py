from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics.pairwise import cosine_similarity


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs" / "defense" / "lawvoice_retrieval_benchmark.json"


@dataclass(frozen=True)
class QueryCase:
    query: str
    gold_docs: tuple[str, ...]


def read_document(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".json":
        data = json.loads(text)
        parts = [data.get("name", ""), data.get("rules", ""), data.get("instructions", "")]
        return "\n".join(part for part in parts if part)
    return text


def split_text_into_chunks(
    text: str,
    max_chars: int = 1400,
    overlap_chars: int = 180,
    min_chunk_chars: int = 260,
) -> list[str]:
    source = text.strip()
    if not source:
        return []

    chunks: list[str] = []
    cursor = 0
    while cursor < len(source):
        end = min(cursor + max_chars, len(source))
        if end < len(source):
            window_text = source[cursor:end]
            split_point = max(
                window_text.rfind(". "),
                window_text.rfind("! "),
                window_text.rfind("? "),
                window_text.rfind("\n"),
            )
            if split_point >= min_chunk_chars:
                end = cursor + split_point + 1

        chunk = source[cursor:end].strip()
        if len(chunk) >= min(40, min_chunk_chars):
            chunks.append(chunk)

        if end >= len(source):
            break
        cursor = max(cursor + 1, end - overlap_chars)

    return chunks


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    sorted_values = sorted(values)
    index = min(len(sorted_values) - 1, max(0, math.ceil((p / 100.0) * len(sorted_values)) - 1))
    return sorted_values[index]


def build_corpus() -> list[dict[str, str]]:
    files = {
        "general_prompt": ROOT / "docs" / "lawvoice_general_prompt.md",
        "mentor_profile": ROOT / "profiles" / "lawvoice_mentor.json",
        "safety_profile": ROOT / "profiles" / "lawvoice_safety.json",
        "analyst_profile": ROOT / "profiles" / "lawvoice_analyst.json",
        "architecture_doc": ROOT / "docs" / "voice-assistant-architecture.md",
        "tts_doc": ROOT / "docs" / "tts_module.md",
    }

    chunks: list[dict[str, str]] = []
    for doc_id, path in files.items():
        document_text = read_document(path)
        doc_chunks = split_text_into_chunks(document_text) or [document_text]
        for index, chunk_text in enumerate(doc_chunks):
            chunks.append(
                {
                    "doc_id": doc_id,
                    "chunk_id": f"{doc_id}_{index}",
                    "text": chunk_text,
                }
            )
    return chunks


def build_queries() -> list[QueryCase]:
    return [
        QueryCase(
            "Меня задержала полиция, я в отделе и боюсь ошибиться в разговоре",
            ("general_prompt", "safety_profile"),
        ),
        QueryCase(
            "Мне угрожают слить интимные фото и шантажируют",
            ("general_prompt", "safety_profile"),
        ),
        QueryCase(
            "Меня травят в школьном чате и оскорбляют одноклассники",
            ("general_prompt", "mentor_profile"),
        ),
        QueryCase(
            "Учитель забрал телефон и угрожает директором, что мне делать в школе",
            ("general_prompt", "mentor_profile"),
        ),
        QueryCase(
            "Заказ на маркетплейсе пришёл бракованный, как оформить возврат",
            ("general_prompt", "mentor_profile"),
        ),
        QueryCase(
            "Помоги спокойно объяснить подростку права и риски простым языком",
            ("general_prompt", "mentor_profile"),
        ),
        QueryCase(
            "Нужен стиль, где факты отделяются от эмоций и даются варианты действий",
            ("analyst_profile",),
        ),
        QueryCase(
            "Как в системе создаётся WebRTC-сессия и временный токен",
            ("architecture_doc",),
        ),
        QueryCase(
            "Какие сервисы синтеза речи поддерживаются и как выбирается голос",
            ("tts_doc",),
        ),
        QueryCase(
            "Когда нужно сразу звать взрослого и звонить 112",
            ("general_prompt", "safety_profile"),
        ),
    ]


def run_benchmark() -> dict:
    corpus = build_corpus()
    queries = build_queries()

    vectorizer = TfidfVectorizer(analyzer="char_wb", ngram_range=(3, 5), lowercase=True)
    matrix = vectorizer.fit_transform([item["text"] for item in corpus])

    hit_at_1 = 0
    hit_at_3 = 0
    mrr_at_3 = 0.0
    ndcg_at_3 = 0.0
    ranks: list[int] = []
    details: list[dict] = []

    for case in queries:
        query_vector = vectorizer.transform([case.query])
        sims = cosine_similarity(query_vector, matrix)[0]
        ranked_indices = sims.argsort()[::-1]
        top_indices = ranked_indices[:3]
        top_chunks = [corpus[index] for index in top_indices]
        top_docs = [item["doc_id"] for item in top_chunks]

        reciprocal_rank = 0.0
        relevances: list[int] = []
        first_rank = None
        for rank, index in enumerate(top_indices, start=1):
            relevant = 1 if corpus[index]["doc_id"] in case.gold_docs else 0
            relevances.append(relevant)
            if relevant and first_rank is None:
                first_rank = rank
                reciprocal_rank = 1.0 / rank

        hit_at_1 += 1 if top_docs[0] in case.gold_docs else 0
        hit_at_3 += 1 if any(doc_id in case.gold_docs for doc_id in top_docs) else 0
        mrr_at_3 += reciprocal_rank
        if first_rank is not None:
            ranks.append(first_rank)

        dcg = sum(rel / math.log2(idx + 2) for idx, rel in enumerate(relevances))
        ideal = sorted(relevances, reverse=True)
        idcg = sum(rel / math.log2(idx + 2) for idx, rel in enumerate(ideal)) or 1.0
        ndcg_at_3 += dcg / idcg

        details.append(
            {
                "query": case.query,
                "gold_docs": list(case.gold_docs),
                "top_docs": top_docs,
                "top_chunk_ids": [item["chunk_id"] for item in top_chunks],
                "top_scores": [round(float(sims[index]), 4) for index in top_indices],
            }
        )

    total = len(queries)
    return {
        "benchmark_type": "offline_proxy_retrieval_benchmark",
        "environment": {
            "retriever": "character_ngram_tfidf_proxy",
            "note": (
                "Uses the shipped internal corpus, the same chunking policy as the prototype, "
                "and a Russian-friendly lexical proxy because the repository snapshot does not "
                "ship a reproducible PostgreSQL knowledge dump."
            ),
        },
        "corpus": {
            "documents": len({item["doc_id"] for item in corpus}),
            "chunks": len(corpus),
        },
        "metrics": {
            "queries": total,
            "hit_at_1": round(hit_at_1 / total, 4),
            "hit_at_3": round(hit_at_3 / total, 4),
            "mrr_at_3": round(mrr_at_3 / total, 4),
            "ndcg_at_3": round(ndcg_at_3 / total, 4),
            "median_rank_of_first_relevant": percentile(ranks, 50),
            "p95_rank_of_first_relevant": percentile(ranks, 95),
        },
        "details": details,
    }


def main() -> None:
    result = run_benchmark()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(OUTPUT)


if __name__ == "__main__":
    main()

# Project 4 — Streaming RAG Platform (Kafka → Vectors → LLM)

> Build the system the Cisco JD literally asks for: *"LLM-based agents, **RAG systems**… integrating and scaling **vector databases**."* Documents stream through Kafka, get embedded into **Qdrant**, and a FastAPI service answers questions **grounded in your data** via your Project-2 vLLM endpoint — with **LangFuse tracing** on every request and the whole thing deployed by **ArgoCD**.

| | |
|---|---|
| **Difficulty** | Hard |
| **Time** | 3 weekends |
| **Prereq** | Project 2 (vLLM endpoint). Kafka from Project 3 if you have it, else the mini-Kafka included below. |
| **Cloud cost** | Embeddings run on CPU; only vLLM needs the GPU node. ~$0.25–0.60/hr while testing. |
| **Skills proven** | Vector DB ops (Qdrant), embedding pipelines, chunking strategies, RAG API design, LLM observability (LangFuse: traces/tokens/cost), GitOps (ArgoCD app-of-apps), Python services on K8s |
| **JD keywords hit** | "RAG systems" · "vector databases (Pinecone, FAISS)" · "LangChain" · "ArgoCD/GitOps" · "Golang and/or **Python** backend services" |
| **Book/course mapping** | GenAI book ch. 4–5, 12 · Big Data book ch. 7, 11 · Udemy: RAG, embedding caches, OpenTelemetry-style tracing |

---

## 1. The mental model

RAG is **90% data infrastructure** (your home turf) and 10% AI:

```
WRITE PATH (async, streaming):
  docs → Kafka topic → indexer service → chunk → embed (CPU model) → upsert Qdrant

READ PATH (sync, latency-sensitive):
  question → embed → Qdrant top-k search → build prompt with context → vLLM → answer + citations
```

Two SLOs, two scaling models: the write path scales on **Kafka lag** (KEDA), the read path scales on **request latency**. Saying that sentence is the interview.

## 2. Repo layout (structured for ArgoCD from day one)

```
rag-platform/
├── apps/                          # ArgoCD Applications (app-of-apps)
│   ├── root.yaml
│   ├── qdrant.yaml  kafka-mini.yaml  langfuse.yaml
│   ├── indexer.yaml  rag-api.yaml
├── services/
│   ├── indexer/    main.py  Dockerfile  requirements.txt
│   └── rag-api/    main.py  Dockerfile  requirements.txt
├── manifests/
│   ├── qdrant/values.yaml
│   ├── langfuse/values.yaml
│   ├── indexer/deployment.yaml  keda.yaml
│   └── rag-api/deployment.yaml  service.yaml  servicemonitor.yaml
└── seed/ publish_docs.py          # pushes sample docs into Kafka
```

## 3. Phase 1 — Vector database (Qdrant)

```bash
helm repo add qdrant https://qdrant.github.io/qdrant-helm
helm install qdrant qdrant/qdrant -n rag --create-namespace \
  --set persistence.size=10Gi --set replicaCount=1
```

Why Qdrant for this project: K8s-native Helm deploy, HNSW index, payload filtering, snapshot backups. Be ready to compare: **pgvector** (Postgres extension — simplest when you already run PG), **Milvus** (heaviest, most scalable), **Pinecone** (managed), **FAISS** (a *library*, not a service — common trap question).

Create the collection (one-time job or curl):

```bash
kubectl -n rag port-forward svc/qdrant 6333:6333 &
curl -X PUT http://localhost:6333/collections/docs \
  -H 'Content-Type: application/json' -d '{
    "vectors": { "size": 384, "distance": "Cosine" },
    "optimizers_config": { "default_segment_number": 2 }
  }'
```

`384` = output dim of `BAAI/bge-small-en-v1.5`, the CPU-friendly embedding model we'll use. (Interview note: **embedding model choice pins the collection schema** — changing models means re-embedding everything; version your collections like `docs_bge_v1`.)

## 4. Phase 2 — The indexer (write path)

`services/indexer/main.py` — Kafka consumer → chunk → embed → upsert:

```python
import json, os, uuid, logging
from kafka import KafkaConsumer
from fastembed import TextEmbedding          # ONNX, fast on CPU
from qdrant_client import QdrantClient
from qdrant_client.models import PointStruct

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("indexer")

BOOTSTRAP = os.environ["KAFKA_BOOTSTRAP"]     # lake-kafka-bootstrap.kafka.svc:9092
QDRANT    = os.environ["QDRANT_URL"]          # http://qdrant.rag.svc:6333
COLLECTION = os.getenv("COLLECTION", "docs")

embedder = TextEmbedding("BAAI/bge-small-en-v1.5")
qdrant   = QdrantClient(url=QDRANT)

def chunk(text: str, size: int = 800, overlap: int = 120):
    """Sliding-window chunking. Know the trade-off: small chunks = precise
    retrieval, less context; big chunks = opposite. 500-1000 chars + overlap
    is the sane default; semantic/heading-aware chunking is the upgrade."""
    step = size - overlap
    return [text[i:i+size] for i in range(0, max(len(text)-overlap, 1), step)]

consumer = KafkaConsumer(
    "docs.raw",
    bootstrap_servers=BOOTSTRAP,
    group_id="indexer",
    value_deserializer=lambda v: json.loads(v.decode()),
    enable_auto_commit=False,                 # commit AFTER successful upsert
)

for msg in consumer:
    doc = msg.value                            # {"doc_id","title","text","source"}
    chunks = chunk(doc["text"])
    vectors = list(embedder.embed(chunks))     # batch-embeds internally
    points = [
        PointStruct(
            id=str(uuid.uuid5(uuid.NAMESPACE_URL, f"{doc['doc_id']}-{i}")),  # idempotent
            vector=v.tolist(),
            payload={"doc_id": doc["doc_id"], "title": doc["title"],
                     "source": doc["source"], "chunk_index": i, "text": c},
        )
        for i, (c, v) in enumerate(zip(chunks, vectors))
    ]
    qdrant.upsert(collection_name=COLLECTION, points=points)
    consumer.commit()
    log.info("indexed doc=%s chunks=%d", doc["doc_id"], len(points))
```

Deterministic UUIDs + commit-after-write = **idempotent, at-least-once-safe** indexing. That's a distributed-systems answer, not an AI answer — your advantage.

`manifests/indexer/keda.yaml` — scale on **consumer lag**:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: indexer, namespace: rag }
spec:
  scaleTargetRef: { name: indexer }
  minReplicaCount: 1
  maxReplicaCount: 5
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: lake-kafka-bootstrap.kafka.svc:9092
        consumerGroup: indexer
        topic: docs.raw
        lagThreshold: "50"
```

Seed data (`seed/publish_docs.py`): publish 20–50 markdown docs — use your **own study notes / the two field guides' text** so demo answers are personally meaningful.

## 5. Phase 3 — The RAG API (read path)

`services/rag-api/main.py`:

```python
import os, time
import httpx
from fastapi import FastAPI
from pydantic import BaseModel
from fastembed import TextEmbedding
from qdrant_client import QdrantClient
from langfuse import Langfuse
from prometheus_fastapi_instrumentator import Instrumentator

QDRANT   = os.environ["QDRANT_URL"]
VLLM     = os.environ["VLLM_URL"]            # http://vllm-qwen.llm.svc:8000
MODEL    = os.environ["MODEL_NAME"]          # Qwen/Qwen2.5-1.5B-Instruct
TOP_K    = int(os.getenv("TOP_K", "4"))

app = FastAPI(title="rag-api")
Instrumentator().instrument(app).expose(app)   # /metrics for Prometheus

embedder = TextEmbedding("BAAI/bge-small-en-v1.5")
qdrant   = QdrantClient(url=QDRANT)
langfuse = Langfuse()                          # keys via env/secret

SYSTEM = ("Answer ONLY from the provided context. "
          "Cite sources as [title#chunk]. If the context is insufficient, say so.")

class Ask(BaseModel):
    question: str

@app.post("/ask")
async def ask(req: Ask):
    trace = langfuse.trace(name="rag-query", input=req.question)

    t0 = time.perf_counter()
    qvec = list(embedder.embed([req.question]))[0].tolist()
    hits = qdrant.search(collection_name="docs", query_vector=qvec, limit=TOP_K)
    trace.span(name="retrieval",
               metadata={"latency_ms": (time.perf_counter()-t0)*1000,
                         "scores": [h.score for h in hits]})

    context = "\n\n".join(
        f"[{h.payload['title']}#{h.payload['chunk_index']}]\n{h.payload['text']}"
        for h in hits)

    gen = trace.generation(name="llm", model=MODEL, input=req.question)
    async with httpx.AsyncClient(timeout=120) as client:
        r = await client.post(f"{VLLM}/v1/chat/completions", json={
            "model": MODEL,
            "messages": [
                {"role": "system", "content": SYSTEM},
                {"role": "user",
                 "content": f"Context:\n{context}\n\nQuestion: {req.question}"},
            ],
            "max_tokens": 400, "temperature": 0.2,
        })
    body = r.json()
    answer = body["choices"][0]["message"]["content"]
    gen.end(output=answer, usage=body.get("usage"))   # tokens → cost in LangFuse

    trace.update(output=answer)
    return {"answer": answer,
            "sources": [{"title": h.payload["title"],
                         "chunk": h.payload["chunk_index"],
                         "score": round(h.score, 3)} for h in hits]}
```

Deployment env wires `VLLM_URL` to **Project 2's Service** — your projects compose into a platform, which is exactly the portfolio story you want.

## 6. Phase 4 — LLM observability with LangFuse

```bash
helm repo add langfuse https://langfuse.github.io/langfuse-k8s
helm install langfuse langfuse/langfuse -n rag -f manifests/langfuse/values.yaml
# values: bundled postgres for lab; set NEXTAUTH_SECRET/SALT; create project → API keys → K8s Secret
```

What you now see per request (this is the "generic observability doesn't cover LLMs" story from your field guide, made real): full trace (retrieval span + generation), retrieval scores, prompt/completion, **token counts and cost**, latency breakdown (retrieval vs generation — usually 5% vs 95%). Add user feedback later via `langfuse.score()`.

## 7. Phase 5 — GitOps with ArgoCD (app-of-apps)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

`apps/root.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: rag-platform, namespace: argocd }
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/rag-platform.git
    targetRevision: main
    path: apps
  destination: { server: https://kubernetes.default.svc }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

Each child app (`apps/qdrant.yaml`, etc.) points at a chart or `manifests/` path. Demo for the portfolio video: `kubectl delete deploy rag-api -n rag` → ArgoCD **self-heals it back** in seconds. You already run ArgoCD at work — here it manages an *AI* platform, which is the resume delta.

## 8. Validation & a tiny eval

- [ ] Publish a new doc to Kafka → queryable via `/ask` within seconds (streaming freshness — screenshot lag graph)
- [ ] Ask something *not* in the corpus → model says "insufficient context" (grounding works)
- [ ] LangFuse trace shows retrieval scores + token cost per request
- [ ] Scale test: `kafka-producer-perf-test` 10k docs → KEDA scales indexer to 5, lag drains

Mini-eval (`eval/golden.jsonl`, 15 Q/A pairs from your docs) — script loops questions, checks expected keyword in answer + expected doc in sources, prints **retrieval hit-rate** and **answer accuracy**. Crude but honest; name-drop **RAGAS** as the production-grade version.

## 9. Teardown

`kubectl delete ns rag argocd` (+ Project 2 teardown for the GPU). Qdrant PVC deletion wipes vectors — snapshot first if you want to keep them (`POST /collections/docs/snapshots`).

## 10. Interview ammunition

- *"Built a streaming RAG platform: Kafka-fed embedding pipeline (KEDA-scaled on consumer lag) into Qdrant, FastAPI retrieval service calling a self-hosted vLLM endpoint, per-request LangFuse tracing with token-level cost, all GitOps-managed via ArgoCD app-of-apps."*
- Whiteboard-ready: write-path vs read-path scaling; chunk-size trade-off; why embedding-model choice pins the collection; idempotent upserts under at-least-once delivery; HNSW in one sentence (approximate nearest-neighbor graph — recall vs latency knob); pgvector vs Qdrant vs Milvus vs FAISS.

## 11. Stretch goals

1. **Hybrid search**: add BM25/sparse vectors in Qdrant, fuse with RRF — measurably better retrieval.
2. **Reranker** (`bge-reranker-base`) between search and prompt; show hit-rate delta in your eval.
3. **Semantic cache**: Redis keyed on question-embedding similarity → skip the LLM for repeat questions; graph the cost drop in LangFuse.
4. Multi-tenant collections + API keys — direct feed into Project 6.

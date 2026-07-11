# Project 11 — Feed: A Multi-Tenant Data & Feature Platform for ML (Lakehouse 2.0)

**Difficulty:** ★★★★☆ | **Time:** 3–4 weekends | **Cost:** ~$10–25 (all CPU: m6i/m7g spot; S3)

## 1. The production problem

Your first-track lakehouse proved Spark+Kafka+Airflow on K8s. Production ML data platforms (and the "Big Data" half of your target JDs) add five hard requirements the basic build skips:

1. A **catalog as a service** — Iceberg **REST catalog** so Spark, Flink, and Trino share one table namespace with credential vending, instead of per-engine Hive/Glue wiring.
2. **Exactly-once CDC**: operational Postgres → lakehouse via Debezium + Flink with checkpointed, upsert (MERGE) writes — no dupes, no loss, ~minute freshness.
3. **Shuffle that survives spot**: Spark dynamic allocation is useless if executor loss kills shuffle data — Apache **Celeborn** (remote shuffle service) fixes it.
4. A **feature store** (Feast): the offline/online split, point-in-time-correct training sets, low-latency online serving — the piece that connects Big Data to inference (your P09).
5. **Governance**: data quality gates (Great Expectations), lineage (OpenLineage→Marquez), and table maintenance (compaction, snapshot expiry) as scheduled platform jobs.

This maps the Cisco AI-platform JD lines: "data pipelines and time-series systems… Kubeflow pipelines… Airflow… vector databases."

## 2. Architecture

```
 Postgres (ops DB) ──Debezium──▶ Kafka (Strimzi) ──Flink SQL (exactly-once, upsert)──▶
                                                        │
        Airflow (batch backfills) ──Spark-on-K8s ───────┤        Iceberg tables on S3
        (SparkApplication + Celeborn shuffle)           ▼
                                             Iceberg REST Catalog (Lakekeeper/Polaris)
                                                        │
              Trino (ad-hoc SQL) ── dbt models ─────────┤
              Feast: offline (Spark/Trino) ─ materialize ─▶ Redis online store ─▶ P09 inference
 Governance: Great Expectations gates · OpenLineage→Marquez · maintenance CronJobs
```

## 3. Phase 1 — catalog + storage

Deploy an Iceberg REST catalog (**Lakekeeper** has a clean Helm chart; **Apache Polaris** is the heavyweight alternative — deploy one, read the other):

```bash
helm repo add lakekeeper https://lakekeeper.github.io/lakekeeper-charts
helm upgrade -i lakekeeper lakekeeper/lakekeeper -n lakehouse --create-namespace \
  --set catalog.warehouse.s3.bucket=<bucket> --set postgresql.enabled=true
```

Every engine then speaks one dialect:

```
spark.sql.catalog.lake=org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.lake.type=rest
spark.sql.catalog.lake.uri=http://lakekeeper.lakehouse:8181/catalog
spark.sql.catalog.lake.warehouse=prod
spark.sql.defaultCatalog=lake
```

Talking point: REST catalog = *decoupled metadata plane* → multi-engine, server-side auth/credential-vending, and future features (server-side commits/conflict handling) without upgrading every engine.

## 4. Phase 2 — Spark on K8s, production-grade

Spark Operator `SparkApplication` with **dynamic allocation + Celeborn** (install Celeborn via its Helm chart, 3 workers on spot):

```yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata: {name: features-daily, namespace: pipelines}
spec:
  type: Python
  mode: cluster
  image: <ecr>/spark-iceberg:3.5
  mainApplicationFile: s3a://code/jobs/build_features.py
  sparkVersion: "3.5.1"
  dynamicAllocation: {enabled: true, minExecutors: 2, maxExecutors: 40}
  sparkConf:
    spark.shuffle.service.enabled: "false"
    spark.celeborn.master.endpoints: "celeborn-master-0.celeborn:9097"
    spark.shuffle.manager: "org.apache.spark.shuffle.celeborn.SparkShuffleManager"
    spark.sql.adaptive.enabled: "true"
    # OpenLineage → Marquez
    spark.extraListeners: "io.openlineage.spark.agent.OpenLineageSparkListener"
    spark.openlineage.transport.type: "http"
    spark.openlineage.transport.url: "http://marquez.lineage:5000"
    spark.openlineage.namespace: "pipelines"
  driver:   {cores: 1, memory: 2g, serviceAccount: spark}
  executor: {cores: 2, memory: 6g, instances: 2,
             nodeSelector: {karpenter.sh/capacity-type: spot}}
```

**Prove Celeborn's value:** run a 200 GB-shuffle job on spot with aggressive Karpenter consolidation, with and without Celeborn; count stage retries and wall-clock. That experiment sentence belongs on your resume.

## 5. Phase 3 — Flink CDC, exactly-once

Debezium (Kafka Connect on Strimzi) captures Postgres WAL → Flink SQL upserts into Iceberg. FlinkDeployment (flink-kubernetes-operator):

```yaml
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata: {name: cdc-orders}
spec:
  image: <ecr>/flink-iceberg:1.19
  flinkVersion: v1_19
  flinkConfiguration:
    state.backend: rocksdb
    state.checkpoints.dir: s3://<bucket>/flink/ckpt
    execution.checkpointing.interval: "60s"
    execution.checkpointing.mode: EXACTLY_ONCE
    high-availability.type: kubernetes
  jobManager: {resource: {cpu: 1, memory: 2g}}
  taskManager: {resource: {cpu: 2, memory: 4g}, replicas: 2}
  job: {jarURI: local:///opt/flink/usrlib/cdc.jar, upgradeMode: savepoint, parallelism: 4}
```

The SQL inside (source can also be `postgres-cdc` connector directly, skipping Kafka):

```sql
CREATE TABLE src_orders (... , PRIMARY KEY (order_id) NOT ENFORCED)
WITH ('connector'='kafka','topic'='pg.public.orders',
      'format'='debezium-json','scan.startup.mode'='earliest-offset', ...);

CREATE TABLE lake.silver.orders (...) WITH ('write.upsert.enabled'='true');

INSERT INTO lake.silver.orders SELECT ... FROM src_orders;
```

**Exactly-once drill:** kill the TaskManager mid-stream 3 times; row counts and sums in Iceberg must match Postgres exactly. Explain *why*: Flink 2-phase-commit sink + Iceberg atomic snapshot commits keyed to checkpoint IDs.

## 6. Phase 4 — feature store (the ML bridge)

```yaml
# feature_store.yaml
project: mec_like_features
registry: s3://<bucket>/feast/registry.db
provider: local
offline_store: {type: spark}         # or trino
online_store:  {type: redis, connection_string: "redis.feast:6379"}
entity_key_serialization_version: 2
```

Define entities/feature-views over your Iceberg silver tables; run point-in-time-correct `get_historical_features` for a training set (be ready to explain *why* PIT-correctness prevents label leakage); materialize:

```bash
feast apply
feast materialize-incremental $(date -u +%Y-%m-%dT%H:%M:%S)   # → CronJob every 15 min
```

Then hit the online store from a FastAPI shim at p99 < 10 ms — and wire one feature into your P09 gateway (e.g., per-user rate-tier lookup) to show the full loop: **CDC → lakehouse → features → live inference**.

## 7. Phase 5 — governance as platform jobs

- **Quality gate**: Great Expectations suite (row-count deltas, null %, referential checks) as an Airflow task *before* silver→gold promotion; failed suite = no promotion + Slack alert.
- **Lineage**: Marquez UI showing Postgres→Kafka→Flink→Iceberg→Spark→Feast end-to-end (OpenLineage emitters on Spark + Airflow + Flink).
- **Maintenance CronJobs** (Spark procedures) — the bit everyone forgets until small-files kill them:

```sql
CALL lake.system.rewrite_data_files(table=>'silver.orders', options=>map('target-file-size-bytes','536870912'));
CALL lake.system.expire_snapshots(table=>'silver.orders', older_than=>TIMESTAMP '...' , retain_last=>50);
CALL lake.system.remove_orphan_files(table=>'silver.orders');
```

Measure query latency on `orders` before/after compaction with Trino — another concrete number for interviews.

## 8. Done criteria & interview ammo

- [ ] Three engines (Spark, Flink, Trino) reading/writing the same tables through one REST catalog.
- [ ] Exactly-once proven under repeated TaskManager kills.
- [ ] Celeborn spot-resilience experiment written up.
- [ ] PIT-correct training set + <10 ms online features consumed by P09.
- [ ] Lineage graph screenshot + compaction before/after numbers.

**Resume bullet:** *"Built a multi-engine lakehouse & feature platform on EKS: Iceberg REST catalog (Lakekeeper) shared by Spark (dynamic allocation + Celeborn remote shuffle on spot), Flink exactly-once CDC (Debezium, upsert MERGE) and Trino; Feast offline/online feature store with point-in-time-correct training sets and p99<10 ms Redis serving; OpenLineage lineage, Great-Expectations promotion gates, and automated Iceberg maintenance."*

**Teardown:** everything is Helm/CRDs on CPU spot — `helmfile destroy`; S3 lifecycle rules pre-set.

## 9. Extensions

- Vector pipeline: Spark job embedding documents → LanceDB/pgvector, tying into your first-track RAG project (and the JD's "vector databases").
- dbt on Trino for the gold layer with CI (dbt build in GitHub Actions against an ephemeral schema).
- Table-format bake-off memo: Iceberg vs Delta vs Hudi for this workload.

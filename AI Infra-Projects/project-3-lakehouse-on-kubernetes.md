# Project 3 — Lakehouse Data Platform on Kubernetes

> Implement the *entire* "Big Data on Kubernetes" book as one coherent platform: **Kafka (Strimzi) → Spark (operator) → S3/MinIO medallion lakehouse → Airflow orchestration → Trino SQL** — batch *and* streaming paths of a Lambda architecture, all declarative.

| | |
|---|---|
| **Difficulty** | Hard (many moving parts, each individually familiar) |
| **Time** | 3–4 weekends |
| **Cloud cost** | CPU-only. Runs on 3–4 `t3.large`/`m5.large` spot, or **free on a local `kind` cluster with MinIO** (recommended for dev). |
| **Skills proven** | Strimzi/Kafka ops, Spark-on-K8s (operator, driver/executor pods), Airflow KubernetesExecutor, Iceberg lakehouse, Trino, medallion pipelines, Kafka Connect CDC |
| **JD keywords hit** | "data pipelines and time-series systems" · "Kubeflow pipelines, **Airflow**, MLflow" · "deep understanding of… data pipelines" · "streaming data pipelines (Kafka)" |
| **Book/course mapping** | Big Data book ch. 4–10 (all of it) · Udemy: Kafka streaming, databases, pipelines |

---

## 1. Why this project

Every "AI infrastructure" role secretly contains a data-platform role: models are downstream of pipelines. The Cisco platform JD explicitly lists **Airflow**; the SentinelOne and Cisco JDs demand data-pipeline fluency. This project is your proof — and it's the highest-volume *code* project of the six, which matters because it exercises your Python.

## 2. Architecture (Lambda, as in the book)

```
                       ┌──────────────  BATCH PATH ───────────────┐
Postgres (source DB) ──┤ Airflow DAG → SparkApplication (bronze)  │
                       │             → SparkApplication (silver)  │
                       │             → SparkApplication (gold)    │
                       └──────────────────────┬───────────────────┘
                                              ▼
                       ┌── SPEED PATH ──┐   S3/MinIO  ◄─ Iceberg tables
web events ─► Kafka ───┤ Spark          │   bronze/ silver/ gold/
(producer.py) (Strimzi)│ Structured     ├──►    ▲
              + Connect│ Streaming      │       │
              (CDC)    └────────────────┘       │
                                          Trino (SQL) ──► DBeaver / Superset
```

## 3. Repo layout

```
lakehouse-k8s/
├── platform/                  # infrastructure, applied once
│   ├── 00-namespaces.yaml
│   ├── minio/ (helm values)
│   ├── postgres/ (source db + metastore db)
│   ├── strimzi/  kafka.yaml  connect.yaml  connector-cdc.yaml
│   ├── spark-operator/ values.yaml
│   ├── airflow/ values.yaml
│   └── trino/ values.yaml
├── jobs/                      # PySpark
│   ├── batch/ bronze_ingest.py  silver_clean.py  gold_aggregate.py
│   └── streaming/ events_to_bronze.py
├── dags/ retail_medallion_dag.py
├── sparkapps/ bronze.yaml silver.yaml gold.yaml streaming.yaml
├── producer/ producer.py Dockerfile
└── sql/ trino_checks.sql
```

## 4. Phase 1 — Storage + source database

**MinIO** (S3-compatible; swap for real S3 later by changing one endpoint):

```bash
helm repo add minio https://charts.min.io/
helm install minio minio/minio -n lakehouse --create-namespace \
  --set mode=standalone --set persistence.size=20Gi \
  --set rootUser=admin --set rootPassword=minio12345 \
  --set 'buckets[0].name=lakehouse,buckets[0].policy=none'
```

Convention inside the bucket: `s3a://lakehouse/bronze/`, `/silver/`, `/gold/`, `/checkpoints/`.

**Postgres** (source of truth to ingest from, seeded with a retail schema):

```yaml
# platform/postgres/postgres.yaml (trimmed)
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: pg-source, namespace: lakehouse }
spec:
  serviceName: pg-source
  replicas: 1
  selector: { matchLabels: { app: pg-source } }
  template:
    metadata: { labels: { app: pg-source } }
    spec:
      containers:
        - name: postgres
          image: postgres:16
          env:
            - { name: POSTGRES_USER, value: shop }
            - { name: POSTGRES_PASSWORD, value: shop12345 }
            - { name: POSTGRES_DB, value: shop }
          args: ["-c", "wal_level=logical"]     # required for Debezium CDC
          ports: [{ containerPort: 5432 }]
          volumeMounts: [{ name: data, mountPath: /var/lib/postgresql/data }]
  volumeClaimTemplates:
    - metadata: { name: data }
      spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: 5Gi } } }
```

Seed it:

```sql
CREATE TABLE orders (
  order_id SERIAL PRIMARY KEY,
  customer_id INT NOT NULL,
  amount NUMERIC(10,2) NOT NULL,
  status TEXT NOT NULL DEFAULT 'placed',
  created_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO orders (customer_id, amount, status)
SELECT (random()*1000)::int, round((random()*500)::numeric,2),
       (ARRAY['placed','shipped','returned'])[1+floor(random()*3)]
FROM generate_series(1, 50000);
```

## 5. Phase 2 — Kafka with Strimzi (+ CDC)

```bash
helm repo add strimzi https://strimzi.io/charts/
helm install strimzi strimzi/strimzi-kafka-operator -n kafka --create-namespace
```

`platform/strimzi/kafka.yaml` — KRaft (no ZooKeeper), lab-sized:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual
  namespace: kafka
  labels: { strimzi.io/cluster: lake }
spec:
  replicas: 1
  roles: [controller, broker]
  storage:
    type: jbod
    volumes:
      - { id: 0, type: persistent-claim, size: 10Gi, deleteClaim: true }
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: lake
  namespace: kafka
  annotations:
    strimzi.io/kraft: enabled
    strimzi.io/node-pools: enabled
spec:
  kafka:
    version: 3.9.0
    listeners:
      - { name: plain, port: 9092, type: internal, tls: false }
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator: { topicOperator: {}, userOperator: {} }
```

Topic + Connect + Debezium CDC connector (streams every `orders` change into Kafka — the pattern from book ch. 7/8):

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata: { name: shop.public.orders, namespace: kafka, labels: { strimzi.io/cluster: lake } }
spec: { partitions: 3, replicas: 1 }
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnect
metadata:
  name: lake-connect
  namespace: kafka
  annotations: { strimzi.io/use-connector-resources: "true" }
spec:
  version: 3.9.0
  replicas: 1
  bootstrapServers: lake-kafka-bootstrap:9092
  build:                       # Strimzi builds an image WITH the Debezium plugin
    output:
      type: docker
      image: <your-registry>/lake-connect:latest   # ttl.sh works for labs
    plugins:
      - name: debezium-postgres
        artifacts:
          - type: tgz
            url: https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/2.7.3.Final/debezium-connector-postgres-2.7.3.Final-plugin.tar.gz
  config:
    group.id: lake-connect
    config.storage.replication.factor: 1
    offset.storage.replication.factor: 1
    status.storage.replication.factor: 1
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata: { name: orders-cdc, namespace: kafka, labels: { strimzi.io/cluster: lake-connect } }
spec:
  class: io.debezium.connector.postgresql.PostgresConnector
  tasksMax: 1
  config:
    database.hostname: pg-source.lakehouse.svc
    database.port: 5432
    database.user: shop
    database.password: shop12345
    database.dbname: shop
    topic.prefix: shop
    plugin.name: pgoutput
    table.include.list: public.orders
```

Also add a tiny Python **clickstream producer** (`producer/producer.py`) writing JSON events to topic `web.events` — 30 lines with `kafka-python`, run as a Deployment. This gives the speed layer non-CDC traffic too.

## 6. Phase 3 — Spark on Kubernetes (operator) + Iceberg

```bash
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm install spark-operator spark-operator/spark-operator \
  -n spark-operator --create-namespace \
  --set spark.jobNamespaces={lakehouse}
```

**Bronze batch job** — `jobs/batch/bronze_ingest.py` (JDBC → Iceberg bronze):

```python
import sys
from pyspark.sql import SparkSession

RUN_DATE = sys.argv[1]  # e.g. 2026-07-11, passed by Airflow

spark = (SparkSession.builder.appName(f"bronze-orders-{RUN_DATE}")
    .getOrCreate())

orders = (spark.read.format("jdbc")
    .option("url", "jdbc:postgresql://pg-source.lakehouse.svc:5432/shop")
    .option("dbtable", "public.orders")
    .option("user", "shop").option("password", "shop12345")
    .option("partitionColumn", "order_id")          # parallel read — book ch. 4 tip
    .option("lowerBound", "1").option("upperBound", "50000")
    .option("numPartitions", "4")
    .load())

(orders.writeTo("lake.bronze.orders")
    .using("iceberg")
    .createOrReplace())

print(f"bronze rows: {spark.table('lake.bronze.orders').count()}")
spark.stop()
```

**Silver** (`silver_clean.py`): dedupe on `order_id`, cast types, filter bad rows, write `lake.silver.orders` partitioned by `days(created_at)`.
**Gold** (`gold_aggregate.py`): daily revenue + status counts → `lake.gold.daily_revenue`. (Both ~25 lines; standard DataFrame ops — your Python practice.)

**SparkApplication** — `sparkapps/bronze.yaml` (silver/gold are copies with different `mainApplicationFile`):

```yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata: { name: bronze-orders, namespace: lakehouse }
spec:
  type: Python
  mode: cluster
  image: apache/spark:3.5.3-python3
  mainApplicationFile: s3a://lakehouse/jobs/bronze_ingest.py   # upload jobs/ to MinIO
  arguments: ["{{ds}}"]           # templated by Airflow
  sparkVersion: 3.5.3
  deps:
    packages:
      - org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.7.1
      - org.apache.hadoop:hadoop-aws:3.3.4
      - org.postgresql:postgresql:42.7.4
  sparkConf:
    spark.sql.catalog.lake: org.apache.iceberg.spark.SparkCatalog
    spark.sql.catalog.lake.type: jdbc
    spark.sql.catalog.lake.uri: jdbc:postgresql://pg-source.lakehouse.svc:5432/shop
    spark.sql.catalog.lake.jdbc.user: shop
    spark.sql.catalog.lake.jdbc.password: shop12345
    spark.sql.catalog.lake.warehouse: s3a://lakehouse/warehouse
    spark.hadoop.fs.s3a.endpoint: http://minio.lakehouse.svc:9000
    spark.hadoop.fs.s3a.access.key: admin
    spark.hadoop.fs.s3a.secret.key: minio12345
    spark.hadoop.fs.s3a.path.style.access: "true"
  driver:   { cores: 1, memory: 1g, serviceAccount: spark-operator-spark }
  executor: { instances: 2, cores: 1, memory: 1g }
  restartPolicy: { type: Never }
```

> Interview note: Iceberg's **JDBC catalog** (metadata in Postgres) replaces a Hive Metastore — one less service, same ACID/schema-evolution story. Know that Hive Metastore / Glue / Nessie are the alternatives.

**Streaming job** — `jobs/streaming/events_to_bronze.py` (speed layer):

```python
from pyspark.sql import SparkSession
from pyspark.sql.functions import from_json, col, current_timestamp
from pyspark.sql.types import StructType, StringType, IntegerType, DoubleType

spark = SparkSession.builder.appName("events-stream").getOrCreate()

schema = (StructType()
    .add("event_type", StringType()).add("customer_id", IntegerType())
    .add("value", DoubleType()).add("ts", StringType()))

raw = (spark.readStream.format("kafka")
    .option("kafka.bootstrap.servers", "lake-kafka-bootstrap.kafka.svc:9092")
    .option("subscribe", "web.events")
    .option("startingOffsets", "earliest")
    .load())

events = (raw.select(from_json(col("value").cast("string"), schema).alias("e"))
    .select("e.*").withColumn("ingested_at", current_timestamp()))

(events.writeStream
    .format("iceberg")
    .outputMode("append")
    .option("checkpointLocation", "s3a://lakehouse/checkpoints/web_events")
    .toTable("lake.bronze.web_events"))

spark.streams.awaitAnyTermination()
```

Deploy it as a **long-running** SparkApplication (`restartPolicy: Always`) — micro-batches land in Iceberg continuously. Kill the driver pod and watch it resume from the checkpoint: **exactly-once, demonstrated.**

## 7. Phase 4 — Airflow orchestration (KubernetesExecutor)

```bash
helm repo add apache-airflow https://airflow.apache.org
helm install airflow apache-airflow/airflow -n airflow --create-namespace \
  -f platform/airflow/values.yaml
```

`platform/airflow/values.yaml` essentials:

```yaml
executor: KubernetesExecutor          # one pod per task — the book's production choice
dags:
  gitSync:                            # DAGs live in Git = GitOps for pipelines
    enabled: true
    repo: https://github.com/<you>/lakehouse-k8s.git
    branch: main
    subPath: dags
extraPipPackages:
  - apache-airflow-providers-cncf-kubernetes
```

`dags/retail_medallion_dag.py`:

```python
from datetime import datetime
from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator
from airflow.providers.cncf.kubernetes.sensors.spark_kubernetes import SparkKubernetesSensor

def spark_task(dag, name):
    submit = SparkKubernetesOperator(
        task_id=f"submit_{name}",
        namespace="lakehouse",
        application_file=f"sparkapps/{name}.yaml",   # templated {{ds}} inside
        do_xcom_push=True, dag=dag)
    watch = SparkKubernetesSensor(
        task_id=f"watch_{name}",
        namespace="lakehouse",
        application_name=f"{{{{ task_instance.xcom_pull(task_ids='submit_{name}')['metadata']['name'] }}}}",
        dag=dag)
    submit >> watch
    return submit, watch

with DAG(
    dag_id="retail_medallion",
    start_date=datetime(2026, 7, 1),
    schedule="@daily",
    catchup=False,
    tags=["lakehouse"],
) as dag:
    b_sub, b_watch = spark_task(dag, "bronze")
    s_sub, s_watch = spark_task(dag, "silver")
    g_sub, g_watch = spark_task(dag, "gold")
    b_watch >> s_sub
    s_watch >> g_sub
```

Trigger it, then **backfill** three past days from the UI — mention backfilling in interviews; it signals real Airflow experience.

## 8. Phase 5 — Trino serving layer

```bash
helm repo add trino https://trinodb.github.io/charts
helm install trino trino/trino -n trino --create-namespace -f platform/trino/values.yaml
```

`platform/trino/values.yaml` (Iceberg catalog matching Spark's):

```yaml
server: { workers: 1 }
catalogs:
  lake: |
    connector.name=iceberg
    iceberg.catalog.type=jdbc
    iceberg.jdbc-catalog.driver-class=org.postgresql.Driver
    iceberg.jdbc-catalog.connection-url=jdbc:postgresql://pg-source.lakehouse.svc:5432/shop
    iceberg.jdbc-catalog.connection-user=shop
    iceberg.jdbc-catalog.connection-password=shop12345
    iceberg.jdbc-catalog.catalog-name=lake
    iceberg.jdbc-catalog.default-warehouse-dir=s3a://lakehouse/warehouse
    fs.native-s3.enabled=true
    s3.endpoint=http://minio.lakehouse.svc:9000
    s3.path-style-access=true
    s3.aws-access-key=admin
    s3.aws-secret-key=minio12345
```

`sql/trino_checks.sql` — the money demo (one engine querying batch + streaming tables):

```sql
-- gold layer, built by the batch path
SELECT * FROM lake.gold.daily_revenue ORDER BY day DESC LIMIT 7;

-- speed layer, landing continuously from Kafka
SELECT event_type, count(*) AS events, max(ingested_at) AS freshest
FROM lake.bronze.web_events
GROUP BY 1;

-- Iceberg time travel — always gets a "wait, what?" in demos
SELECT * FROM lake.silver.orders FOR TIMESTAMP AS OF TIMESTAMP '2026-07-10 00:00:00 UTC' LIMIT 5;
```

Connect DBeaver → `jdbc:trino://localhost:8080/lake` (port-forward). Optional: Superset dashboard on `gold.daily_revenue`.

## 9. Validation checklist

- [ ] Debezium: `UPDATE orders SET status='shipped' WHERE order_id=1;` → message visible in `shop.public.orders` topic within seconds
- [ ] Airflow DAG green end-to-end; each task ran as its own pod (`kubectl get pods -n airflow`)
- [ ] Spark UI reachable (`kubectl port-forward` driver 4040) — identify a **shuffle** stage in gold job
- [ ] Kill the streaming driver pod → restarts → no duplicate rows (checkpoint recovery)
- [ ] Trino time-travel query works

## 10. Teardown

Local kind: `kind delete cluster`. Cloud: helm uninstall all namespaces, `terraform destroy`. Nothing here needs GPUs — leave GPU NodePool at 0.

## 11. Interview ammunition

- *"Built a Lambda-architecture lakehouse on Kubernetes: Debezium CDC into Kafka (Strimzi), Spark batch + Structured Streaming into Iceberg on S3 (medallion bronze/silver/gold), orchestrated by Airflow KubernetesExecutor, served by Trino — fully declarative via operators and GitOps-synced DAGs."*
- Whiteboard-ready: Lambda vs Kappa trade-offs; why Iceberg over raw Parquet (ACID, schema evolution, time travel); exactly-once via streaming checkpoints; narrow vs wide transformations and where the gold job shuffles; why KubernetesExecutor over Celery.

## 12. Stretch goals

1. **Data quality gates**: add a Soda/Great Expectations check task between silver and gold; fail the DAG on violations.
2. Iceberg **compaction** maintenance job (small-files problem — very real interview topic).
3. Swap MinIO → real S3 + IRSA (no static keys) — write up the diff.
4. KEDA-scale a Kafka consumer on **consumer lag** (bridges to Project 2's scaling story).

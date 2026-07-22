# Section 01 — Project Overview: The Retail Store Microservices App

> Transcript: `0) Intro to retail Microservice project` · ~8 min · Repo: [`../devops-real-world-project-implementation-on-aws/01-Project-Files/`](../devops-real-world-project-implementation-on-aws/01-Project-Files/)

## 0. 🧭 Beginner Follow-Along Guide (start here)

> This section has no commands to run — it's the map of the app you'll deploy 22 different ways. So this guide does the one thing you SHOULD do before Section 02: **install and verify every tool the whole course needs, once**. Tags used in every file's §0: **[Terminal]** = your Ubuntu laptop's shell · **[Editor]** = editing a file in VS Code · **[AWS Console]** = console.aws.amazon.com in the browser · **[Browser]** = any other web page.

### 📊 The whole section at a glance — components & workflow

*Read top to bottom; boxes are components, arrows are the flow (the same shape as your terminal→shell→fork diagram).*

```
┌──────────────────────────────────────────────────────────────────────┐
│                            USER (browser)                            │
│                                                                      │
│ Shops the retail store                                               │
└──────────────────────────────────────────────────────────────────────┘
                                    │  HTTP
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                        UI  (Java Spring Boot)                        │
│                                                                      │
│ The web front end — calls the four APIs below                        │
└──────────────────────────────────────────────────────────────────────┘
        │                │                 │                  │
        ▼                ▼                 ▼                  ▼
┌──────────────┐ ┌──────────────┐ ┌─────────────────┐ ┌───────────────┐
│ catalog (Go) │ │ carts (Java) │ │ checkout (Node) │ │ orders (Java) │
│ browse       │ │ add          │ │ pay             │ │ buy           │
└──────────────┘ └──────────────┘ └─────────────────┘ └───────────────┘

            │             │             │                │
            ▼             ▼             ▼                ▼
      ┌───────────┐ ┌──────────┐ ┌─────────────┐ ┌──────────────┐
      │ RDS MySQL │ │ DynamoDB │ │ ElastiCache │ │ RDS Postgres │
      │ products  │ │ cart     │ │ Redis cache │ │ + SQS event  │
      └───────────┘ └──────────┘ └─────────────┘ └──────────────┘

  (orders writes TWICE on purpose: durable row in Postgres  +  event to SQS
   so future inventory/delivery services can react — DB + event pattern)
```

### Where you are in the course

```
YOU ARE AT THE VERY START ─▶ THIS: S01 meet the app ─▶ S02 Docker ─▶ … ─▶ S22 Istio
Foundations first: read 00A (Linux) + 00B (Networking) ladders alongside S01–S04.
```

**Must already exist/be running:** Nothing — this is a fresh start. (An AWS account is needed from S06 onward, not yet.)

### Words you'll meet (plain English)

| Word | Plain meaning |
|---|---|
| microservice | one small app owning one job (e.g. "carts") with its own database |
| polyglot | the services are written in different languages (Go, Java, Node.js) |
| data plane | the group of databases/cache/queue the services depend on |
| in-cluster vs AWS managed | you run the DB in a container yourself vs AWS runs it for you (RDS etc.) |
| message broker/queue | a mailbox (RabbitMQ/SQS) where one service drops events for others to read later |
| cache | fast temporary storage (Redis) — speed, not the system of record |

### The simplified play-by-play (set up your toolbox once)

Every step is **[Terminal]** unless tagged otherwise. Each install is skipped automatically if already present.

1. **Update apt + basics** — `sudo apt-get update && sudo apt-get install -y git curl unzip jq dnsutils`
   → **you should see:** apt finish without errors; `git --version` and `jq --version` answer.
2. **Docker Engine** — `command -v docker >/dev/null || (curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER)` — then **log out & back in** once so the group applies.
   → **you should see:** `docker run --rm hello-world` prints "Hello from Docker!" *without* sudo. (Used from S02.)
3. **kubectl** — `command -v kubectl >/dev/null || (curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install kubectl /usr/local/bin/ && rm kubectl)`
   → **you should see:** `kubectl version --client` prints a version. (Used from S07.)
4. **helm** — `command -v helm >/dev/null || (curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash)`
   → **you should see:** `helm version` prints a version. (Used from S12.)
5. **terraform** — install via HashiCorp's apt repo (their official Ubuntu instructions), or: `command -v terraform || (curl -fsSLo tf.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip && unzip tf.zip && sudo install terraform /usr/local/bin/ && rm -f tf.zip terraform)`
   → **you should see:** `terraform -version`. (Used from S06.)
6. **AWS CLI v2** — `command -v aws >/dev/null || (curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip)`
   → **you should see:** `aws --version` prints `aws-cli/2.x`. (Configured with credentials in S06.)
7. **Clone the course repo** — `git clone https://github.com/stacksimplify/devops-real-world-project-implementation-on-aws.git` (into a folder you like)
   → **you should see:** folders `01-Project-Files/ … 21_DevOps_CICD/` — the source of truth every section's README points into.
8. **[Browser] Read the app's story in THIS file** — §4's inventory table + the user-journey block. Then do Lab A (map the repo folders) and Lab B (redraw the diagram from memory).
   → **you should see:** you can name all 5 services, their languages, and their datastores without looking. That's this section's real deliverable.

### ✅ Done-check

```
[ ] docker run hello-world works WITHOUT sudo
[ ] kubectl, helm, terraform, aws, git, jq, dig all answer --version/-version
[ ] course repo cloned; you matched its folders to sections via 00-INDEX.md
[ ] from memory: 5 services → 5 stores, including BOTH Orders→PostgreSQL and Orders→RabbitMQ arrows
```

🧹 **Teardown before you stop:** nothing — everything here is local and free. 💰 Nothing bills yet; the first AWS money appears in S06 (and every section from there has its own 💰 warning — read them).

---

## 1. Objective

Know the **reference application** used in every demo of this course cold: its 5 microservices, 3 databases, cache, and message broker — and the exact user-journey each service handles. Every later section (Docker → Terraform → EKS → Helm → Karpenter → ADOT → CI/CD) deploys *this same app* in progressively more production-grade ways.

## 2. Problem Statement

You can't learn "real-world DevOps" on `hello-world`. You need an app that is genuinely polyglot (Go, Java, Node.js), genuinely stateful (SQL + NoSQL + cache + queue), and genuinely multi-component (10 containers) — so that every tool in the stack has a *reason* to exist when you meet it.

## 3. Why This Approach

Why this app over a single-language demo app:

| Property | Single demo app | Retail store app | Why it matters later |
|---|---|---|---|
| Languages | 1 | Go, Java Spring Boot ×3, Node.js | Multi-stage Dockerfiles differ per runtime (S03) |
| State | none | MySQL, PostgreSQL, DynamoDB, Redis, RabbitMQ/SQS | Drives Secrets (S09), Storage (S10), AWS data plane (S14) |
| Component count | 1 container | 10 containers | Justifies Compose (S04) → Kubernetes (S07+) → Helm (S12) |
| Cloud swap-ability | n/a | in-cluster DB ↔ AWS managed service per microservice | The "persistent data plane" migration story (S13–S14, S19) |

## 4. How It Works — Under the Hood

### Component inventory

| Service | Language | Backing store (in-cluster → AWS production) | Role |
|---|---|---|---|
| **UI** | Java Spring Boot | — | Web front end; calls all other APIs |
| **Catalog** | Go | MySQL → **AWS RDS MySQL** | Product listings |
| **Carts** | Java Spring Boot | DynamoDB-local → **AWS DynamoDB** | Shopping cart state |
| **Checkout** | Node.js | Redis → **Amazon ElastiCache (Redis)** | Orchestrates checkout; caches session/checkout state |
| **Orders** | Java Spring Boot | PostgreSQL → **AWS RDS PostgreSQL**; RabbitMQ → **AWS SQS** | Persists orders; publishes order events |

Total when containerized: **10 containers** (5 services + MySQL + PostgreSQL + DynamoDB-local + Redis + RabbitMQ).

### Architecture

```mermaid
flowchart LR
    U[User browser] --> UI[UI Service<br/>Spring Boot]
    UI --> CAT[Catalog API<br/>Go]
    UI --> CART[Carts API<br/>Spring Boot]
    UI --> CHK[Checkout API<br/>Node.js]
    UI --> ORD[Orders API<br/>Spring Boot]
    CAT --> MYSQL[(MySQL<br/>→ RDS MySQL)]
    CART --> DDB[(DynamoDB<br/>→ AWS DynamoDB)]
    CHK --> REDIS[(Redis<br/>→ ElastiCache)]
    ORD --> PG[(PostgreSQL<br/>→ RDS PostgreSQL)]
    ORD --> MQ[[RabbitMQ<br/>→ AWS SQS]]
    MQ -. future consumers .-> INV[Inventory / Delivery services<br/>out of course scope]
```

### The user journey (request path)

```
browse products      → UI → Catalog API → MySQL          (product data rendered)
"Add to cart"        → UI → Carts API   → DynamoDB       (cart state saved)
"Start checkout"     → UI → Checkout API→ Redis           (address/delivery/card cached)
"Purchase"           → UI → Orders API  → PostgreSQL      (order row written)
                                        → RabbitMQ/SQS    (same order event published
                                                           for downstream consumers)
```

Two details the instructor stresses:
- Checkout state goes to **Redis** *for speed* during the multi-step checkout flow — it's a cache, not the system of record.
- The order is written **twice on purpose**: durably to PostgreSQL *and* as an event to the message broker, so future services (inventory, delivery) can consume it without touching the Orders DB. That's the standard **database + event** integration pattern.

### Vocabulary map

| Term in course | Plain English |
|---|---|
| Microservice | One独立 deployable service owning one business capability + its own datastore |
| Polyglot | Each service picks its own language/runtime |
| Data plane (later sections) | The set of backing stores (DBs/cache/queue) the services depend on |
| In-cluster vs AWS managed | Run the DB as a container yourself vs let AWS run it (RDS/DynamoDB/ElastiCache/SQS) |

## 5. Instructor's Approach

1. **Component diagram first, architecture second** — inventory before interactions.
2. **Walk the buying journey twice** in the live demo UI (browse → cart → checkout → purchase), explicitly naming which API and which datastore serves each click. He repeats it verbatim so the flow sticks.
3. States the course path out loud: *the same app* goes **Docker → Kubernetes → Helm → …** — deliberately re-deploying one app with increasingly production-grade tooling rather than switching demo apps per topic.
4. Scope call-out: only the 5 services are in scope; inventory/delivery consumers of the message queue are mentioned only to justify RabbitMQ/SQS's existence.

## 6. Code & Commands, Line by Line

This section is conceptual — no commands are executed. The demo store shown is the app you will build/run starting Section 02. Paths seen on screen map to the repo:

| On screen | In your clone |
|---|---|
| Retail store project files | `01-Project-Files/` |
| Per-topic working folders | `02_Docker_Commands/` … `14_RetailStore_Microservices_with_AWS_Data_Plane/` |

## 7. Complete Code Reference

None for this section (first commands arrive in Section 02).

## 8. Hands-On Labs

> All three labs are free/local — no AWS resources. 💰 n/a.

### Lab A — Reproduce: inventory the app from the repo
- **Prerequisites:** the course repo cloned (`devops-real-world-project-implementation-on-aws/`).
- **Steps:**
  1. `ls 01-Project-Files/` and each `NN_*/` folder — match folders to course sections.
  2. Find the Docker Compose file (used in S04): `grep -ril "catalog" --include="*.y*ml" . | head`.
  3. In the compose file, count services and map each to its image + datastore.
- **Expected output:** 10 container definitions (5 apps + 5 stores).
- **Verify:** your table matches §4's component inventory exactly.
- 🧹 **Teardown:** none.

### Lab B — Variation: draw the flow from memory
- **Steps:** without looking, draw the mermaid diagram of §4 (5 services, 5 stores, arrows). Then diff against §4.
- **Verify:** you drew *both* Orders→PostgreSQL and Orders→RabbitMQ arrows — the double-write is the detail most people drop.
- 🧹 none.

### Lab C — Break-it thought drill: failure domains
- **Steps:** for each store going down (MySQL / DynamoDB / Redis / PostgreSQL / RabbitMQ), state which user action breaks and which still works.
- **Expected answers:** MySQL down → browsing breaks, existing carts still readable; Redis down → checkout flow degraded; RabbitMQ down → orders still persist to PostgreSQL but downstream events stop; etc.
- **Verify:** each answer names exactly one service pair (API + store).
- 🧹 none.

## 9. Troubleshooting

Nothing executable yet — but one navigational gotcha:

| Symptom | Likely cause | Confirm | Fix |
|---|---|---|---|
| Course folder names don't match section numbers | Repo folders are numbered by *topic* (`02_Docker_Commands`…), transcripts by *file* (`0)`–`21)`), curriculum by *section* (01–21) | compare all three | Use [00-INDEX.md](00-INDEX.md)'s mapping table |

## 10. Interview Articulation

**90-second explanation:**
> "The reference app is a retail store built as five microservices — a Spring Boot UI, a Go catalog service backed by MySQL, a Spring Boot carts service on DynamoDB, a Node.js checkout service using Redis as a fast checkout-state cache, and a Spring Boot orders service that writes each order durably to PostgreSQL *and* publishes the same event to RabbitMQ or SQS so future consumers like inventory can react without coupling to the orders database. It's deliberately polyglot and stateful — ten containers total — because the whole course re-deploys this one app up the maturity ladder: Docker, Compose, EKS with Terraform, Helm, then swapping every in-cluster datastore for its AWS managed equivalent — RDS, DynamoDB, ElastiCache, SQS — which is exactly the migration story you'd run in production."

<details>
<summary>5 self-test questions</summary>

1. **Which services are Java Spring Boot?** — UI, Carts, Orders (3 of 5). Catalog is Go; Checkout is Node.js.
2. **Where does checkout state live during the checkout flow, and why?** — Redis (ElastiCache in prod) — a cache for speed across the multi-step flow; not the system of record.
3. **Why is an order written to two places?** — PostgreSQL is the durable record; RabbitMQ/SQS carries the same event so downstream services (inventory/delivery) integrate without touching the DB.
4. **How many containers does the full app need, and why?** — 10: five services + MySQL, PostgreSQL, DynamoDB-local, Redis, RabbitMQ.
5. **What is each in-cluster store's AWS production replacement?** — MySQL→RDS MySQL, PostgreSQL→RDS PostgreSQL, DynamoDB-local→DynamoDB, Redis→ElastiCache, RabbitMQ→SQS.

</details>

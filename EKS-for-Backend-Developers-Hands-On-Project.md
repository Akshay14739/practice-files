# From Backend Developer to AWS EKS — A Complete Hands-On Project 🚀
### For a .NET / Node / Python backend developer who asked: *"Is Kubernetes/EKS related to backend, or something different — and how do I learn it?"*

---

## Part 0 — First, the answer to your question

**Yes, this is absolutely related to backend — it's the other half of it.**

You already write the services. Docker, Kubernetes, and EKS are how those services **get to production and stay alive there**:

```
 WHAT YOU DO TODAY                      WHAT THIS PROJECT ADDS
┌──────────────────────────┐           ┌──────────────────────────────────────┐
│  Write the API           │           │  Package it so it runs ANYWHERE      │
│  (.NET / Node / Python)  │  ──────▶  │  (Docker)                            │
│  Business logic, DBs,    │           │  Run many copies, self-healing,      │
│  auth, tests             │           │  zero-downtime deploys (Kubernetes)  │
│                          │           │  Do all that on AWS's managed        │
│                          │           │  Kubernetes (EKS)                    │
└──────────────────────────┘           └──────────────────────────────────────┘
```

Three facts to set your expectations:

1. **It's a skill layer, not a career change.** Modern backend teams live by *"you build it, you run it"* — the engineer who can write a service **and** deploy/scale/debug it on Kubernetes is simply a more senior version of the engineer who can only write it. Job ads calling for "Backend Engineer" increasingly list Docker/K8s in the requirements; "DevOps/Platform Engineer" is the deep-end specialization of this same layer.
2. **Your backend knowledge transfers directly.** Environment variables, health endpoints, statelessness, connection strings, graceful shutdown — you already know these. Kubernetes just gives them infrastructure-level names (ConfigMap, probes, replicas, Secrets, SIGTERM handling).
3. **The fastest way to learn it is to deploy YOUR OWN code** — not someone's demo. That's exactly what this project does: you'll write a tiny API in the stack you like best, then take it all the way to a real AWS cluster.

**Time:** ~2–4 evenings. **Cost:** Phases 1–3 are **completely free** (your laptop). Phase 4 uses real AWS ≈ **$0.20–0.30/hour** — with a strict teardown step so a session costs under $2.

---

## The journey at a glance

```
 PHASE 1              PHASE 2              PHASE 3                    PHASE 4
 Build a tiny API ──▶ Put it in a     ──▶  Run it on Kubernetes  ──▶ Run it on AWS EKS
 in YOUR stack        container            ON YOUR LAPTOP (free)     (the real thing)
 (.NET/Node/Python)   (Docker)             kind: deploy, scale,      eksctl + ECR +
                                           self-heal, roll out       LoadBalancer
                                           ← 80% of the learning     ← same YAML files!
                                             happens HERE, free
 PHASE 5 (stretch): autoscaling · CI/CD with GitHub Actions · what to learn next
```

The single most important design point: **the YAML files you write in Phase 3 are exactly the ones you deploy to AWS in Phase 4.** That's Kubernetes' superpower — the skills and files are portable; only the cluster underneath changes.

---

## Prerequisites & toolbox (install once)

You need: a laptop (Linux/Mac/Windows-WSL2), a free Docker Hub or AWS account (Phase 4 only), and these tools:

```bash
# 1. Docker Engine  (packaging + running containers)
#    Linux:  curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER  (then re-login)
#    Mac/Windows: install Docker Desktop
docker run --rm hello-world        # → "Hello from Docker!" = working

# 2. kubectl  (the Kubernetes remote control)
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/ && rm kubectl
kubectl version --client           # → prints a version

# 3. kind  (Kubernetes-IN-Docker: a full free cluster on your laptop)
curl -Lo kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
sudo install kind /usr/local/bin/ && rm kind
kind version                       # → prints a version

# 4. (Phase 4 only) AWS CLI v2 + eksctl
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz
sudo install eksctl /usr/local/bin/ && rm eksctl
aws --version && eksctl version    # → both print versions
```

### Jargon table — read once, refer back often

| Term | What it actually means (in backend-developer language) |
|---|---|
| **image** | your app + its runtime + dependencies, frozen into one shippable file (like a `publish` folder that includes the OS libraries) |
| **container** | one running instance of an image — an isolated process, NOT a VM |
| **Dockerfile** | the build script that produces the image |
| **registry** (Docker Hub / ECR) | the "NuGet/npm/PyPI for images" — where you push/pull them |
| **Kubernetes (K8s)** | software that runs your containers across many machines: keeps N copies alive, replaces dead ones, rolls out new versions |
| **cluster / node** | the whole K8s installation / one machine in it |
| **pod** | K8s' wrapper around your running container (smallest deployable unit) |
| **Deployment** | "keep N pods of this image running, and replace them safely when I update" |
| **Service** | a stable internal name + IP in front of your pods (pods come and go; the Service name doesn't) |
| **ConfigMap / Secret** | your `appsettings.json` / `.env`, externalized so the same image runs in dev & prod |
| **liveness / readiness probe** | K8s calling your `/health` endpoint: "restart it?" / "send it traffic?" |
| **kubectl** | the CLI you'll use for everything (`kubectl get pods`, `kubectl logs …`) |
| **kind** | a real K8s cluster running inside Docker on your laptop — free practice |
| **EKS** | AWS runs the K8s "brain" for you (~$0.10/hr); you bring worker machines + your YAML |
| **eksctl** | the official CLI that creates/deletes EKS clusters with one command |
| **ECR** | AWS's private image registry (Docker Hub, but inside your AWS account) |

---

## Phase 1 — The API (in YOUR stack)

**Concept:** we need a small, honest backend service: a couple of endpoints, a `/health` endpoint (Kubernetes will call it), and one **environment-variable config** (`APP_GREETING`) — because "config comes from the environment, not the code" is the single habit that makes an app cloud-ready (12-factor).

Pick **one** stack below (all three behave identically for the rest of the project). The walkthrough continues with Python/FastAPI for brevity — substitute your choice everywhere.

### Option A — Python (FastAPI)

```python
# app/main.py
import os
from fastapi import FastAPI

app = FastAPI()
GREETING = os.getenv("APP_GREETING", "Hello from the default config")
VERSION = os.getenv("APP_VERSION", "v1")

todos: list[dict] = []           # in-memory on purpose — see "state" note below

@app.get("/")
def root():
    return {"message": GREETING, "version": VERSION}

@app.get("/health")               # Kubernetes will call this every few seconds
def health():
    return {"status": "ok"}

@app.get("/api/todos")
def list_todos():
    return todos

@app.post("/api/todos")
def add_todo(item: dict):
    todos.append(item)
    return {"added": item, "count": len(todos)}
```
```
# app/requirements.txt
fastapi
uvicorn[standard]
```

### Option B — Node (Express)

```js
// app/server.js
const express = require("express");
const app = express();
app.use(express.json());
const GREETING = process.env.APP_GREETING || "Hello from the default config";
const VERSION = process.env.APP_VERSION || "v1";
let todos = [];
app.get("/", (_, res) => res.json({ message: GREETING, version: VERSION }));
app.get("/health", (_, res) => res.json({ status: "ok" }));
app.get("/api/todos", (_, res) => res.json(todos));
app.post("/api/todos", (req, res) => { todos.push(req.body); res.json({ added: req.body, count: todos.length }); });
app.listen(8000, () => console.log("listening on 8000"));
```

### Option C — .NET (minimal API)

```csharp
// Program.cs  (dotnet new web)
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
var greeting = Environment.GetEnvironmentVariable("APP_GREETING") ?? "Hello from the default config";
var version  = Environment.GetEnvironmentVariable("APP_VERSION") ?? "v1";
var todos = new List<object>();
app.MapGet("/", () => new { message = greeting, version });
app.MapGet("/health", () => new { status = "ok" });
app.MapGet("/api/todos", () => todos);
app.MapPost("/api/todos", (object item) => { todos.Add(item); return new { added = item, count = todos.Count }; });
app.Run("http://0.0.0.0:8000");
```

**Run it plain first** (FastAPI: `pip install -r requirements.txt && uvicorn main:app --port 8000`), then:
```bash
curl localhost:8000/            # → {"message":"Hello from the default config","version":"v1"}
curl localhost:8000/health      # → {"status":"ok"}
APP_GREETING="Hi from an env var" uvicorn main:app --port 8000   # restart with config injected
curl localhost:8000/            # → {"message":"Hi from an env var",...}
```

**⚠️ The "state" teaching moment:** the todo list lives in the process's memory. Remember this — in Phase 3, when Kubernetes runs *two* copies and restarts them freely, you'll SEE why real apps keep state in a database (Postgres/Redis/DynamoDB), never in the process. That's not a Kubernetes rule — it's the same statelessness you already apply behind a load balancer.

---

## Phase 2 — Containerize it (Docker)

**Concept:** "works on my machine" dies here. An **image** freezes your app + runtime + OS libraries into one artifact; a **container** is that artifact running as an isolated process. Every machine that can run containers can now run your app identically — that's the whole pitch.

```dockerfile
# Dockerfile  (FastAPI version; Node/.NET notes below)
FROM python:3.12-slim                  # start from a minimal OS+Python image ("base image")

WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt   # deps FIRST = this layer caches;
                                                     # code changes won't re-install deps
COPY app/ .

RUN useradd -m appuser                 # never run as root inside containers
USER appuser

EXPOSE 8000                            # documentation of the listen port
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

> **Node:** base `node:22-slim`, `COPY package*.json` → `npm ci` → `COPY . .` → `CMD ["node","server.js"]`.
> **.NET:** use the two-stage pattern — build with `mcr.microsoft.com/dotnet/sdk:8.0`, copy the publish output into `mcr.microsoft.com/dotnet/aspnet:8.0`. (Multi-stage = tools stay out of the final image.)

**The logic of the layer order:** each Dockerfile line becomes a cached "layer." Dependencies change rarely, code changes constantly — so copy dependency manifests and install *before* copying source. Result: your second build takes ~1 second instead of minutes. This one habit is 80% of Dockerfile craft.

```bash
docker build -t todo-api:v1 .
# → step-by-step build log ending "naming to docker.io/library/todo-api:v1"

docker run -d --name todo -p 8000:8000 -e APP_GREETING="Hello from a container" todo-api:v1
#            │            │            └ env var injected at RUN time (same image, any config)
#            │            └ host port 8000 → container port 8000
#            └ detached (background)

curl localhost:8000/            # → {"message":"Hello from a container","version":"v1"}
docker logs todo                # → your app's startup logs
docker exec -it todo sh -c 'whoami && ps aux'   # → appuser; ONLY your process — the isolation is real
docker rm -f todo               # clean up
```

**✅ Phase 2 done-check:** image builds; container serves on :8000; a rebuild after touching only source code is near-instant (layer cache); `whoami` inside says `appuser`, not root.

---

## Phase 3 — Kubernetes on your laptop (free — where the real learning happens)

**Concept:** one container on one machine is a demo. Production questions are: *who restarts it at 3am? how do I run 3 copies? how do I update without downtime? where does config live?* Kubernetes answers all four with one idea: **you declare the desired state in YAML ("2 copies of image X with this config"), and controllers work forever to make reality match.** You never start containers by hand again; you edit the declaration.

```bash
kind create cluster --name backend-lab
# → creates a full single-node Kubernetes cluster inside Docker (~1 min)
kubectl get nodes
# → backend-lab-control-plane   Ready   ...
```

### 3.1 The manifests (the files you'll reuse on AWS unchanged)

```yaml
# k8s/configmap.yaml — your externalized appsettings/.env
apiVersion: v1
kind: ConfigMap
metadata:
  name: todo-config
data:
  APP_GREETING: "Hello from Kubernetes"
  APP_VERSION: "v1"
```

```yaml
# k8s/deployment.yaml — "keep 2 copies alive, replace them safely"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: todo-api
spec:
  replicas: 2                          # ← desired copies; K8s enforces this forever
  selector:
    matchLabels: { app: todo-api }
  template:                            # ← the pod blueprint
    metadata:
      labels: { app: todo-api }        # labels wire everything together (Service finds pods by these)
    spec:
      containers:
      - name: todo-api
        image: todo-api:v1
        ports: [{ containerPort: 8000 }]
        envFrom:
        - configMapRef: { name: todo-config }    # ConfigMap → environment variables
        readinessProbe:                # "may I send it traffic?"  — your /health, called by K8s
          httpGet: { path: /health, port: 8000 }
          initialDelaySeconds: 3
        livenessProbe:                 # "is it alive, or restart it?"
          httpGet: { path: /health, port: 8000 }
          initialDelaySeconds: 10
        resources:                     # be a good tenant: reserve a little, cap the max
          requests: { cpu: 50m, memory: 64Mi }
          limits:   { memory: 256Mi }
```

```yaml
# k8s/service.yaml — the stable front door (pods churn; this name/IP doesn't)
apiVersion: v1
kind: Service
metadata:
  name: todo-api
spec:
  selector: { app: todo-api }          # matches the pods' labels — that's the whole wiring
  ports:
  - port: 80                           # the Service's port (what callers use)
    targetPort: 8000                   # the container's port
```

### 3.2 Deploy and poke it

```bash
kind load docker-image todo-api:v1 --name backend-lab   # hand your local image to the cluster
kubectl apply -f k8s/
# → configmap/todo-config created, deployment.apps/todo-api created, service/todo-api created

kubectl get pods
# → todo-api-xxxxx-aaaaa   1/1   Running
#   todo-api-xxxxx-bbbbb   1/1   Running          ← two copies, as declared

kubectl port-forward svc/todo-api 8080:80 &             # temporary tunnel for local testing
curl localhost:8080/          # → {"message":"Hello from Kubernetes","version":"v1"}
```

### 3.3 The four "aha" experiments (do all of them — this IS the course)

**A. Self-healing.** Kill a pod on purpose:
```bash
kubectl delete pod <one-of-the-pod-names>
kubectl get pods
# → the deleted pod is Terminating AND a brand-new one is already ContainerCreating.
#   You declared replicas: 2 — the controller restores reality. Nobody paged you.
```

**B. The statelessness lesson (from Phase 1).** POST a few todos, then GET repeatedly:
```bash
curl -X POST localhost:8080/api/todos -H 'content-type: application/json' -d '{"task":"learn k8s"}'
for i in 1 2 3 4; do curl -s localhost:8080/api/todos; echo; done
# → sometimes your todo is there, sometimes [] — requests load-balance across the two pods,
#   and each keeps its OWN in-memory list. THIS is why state belongs in a database.
#   (And a pod restart wipes it entirely.) You now understand statelessness at gut level.
```

**C. Scaling is a one-liner.**
```bash
kubectl scale deployment todo-api --replicas=5
kubectl get pods    # → 5 Running. Scale back: --replicas=2
```

**D. Zero-downtime rolling update + instant rollback.** Change the greeting in the ConfigMap to prove config redeploys, then ship a "code" change:
```bash
# build v2 (e.g. change the default message in code), load it, update the Deployment:
docker build -t todo-api:v2 . && kind load docker-image todo-api:v2 --name backend-lab
kubectl set image deployment/todo-api todo-api=todo-api:v2
kubectl rollout status deployment/todo-api
# → pods replaced ONE AT A TIME; readiness probe gates each new pod before it takes traffic.
#   Keep a curl loop running in another terminal: not a single failed request.
kubectl rollout undo deployment/todo-api      # → instant rollback to v1 (old version kept on standby)
```

**✅ Phase 3 done-check:** you watched a deleted pod resurrect · you explained the flickering todos without looking · a rolling update ran with zero failed curls · rollback was instant.

---

## Phase 4 — The real thing: AWS EKS

**Concept:** EKS = AWS operates the Kubernetes control plane (the "brain") for you at ~$0.10/hour; you rent worker machines (EC2) and apply **the same YAML from Phase 3**. Two things change and only two: your image must live in a registry AWS can reach (**ECR** — kind's hand-delivery trick doesn't exist here), and the Service can ask AWS for a real internet-facing **load balancer**.

> 💰 **Cost, honestly:** control plane $0.10/hr + 2× t3.small ≈ $0.042/hr + a classic load balancer ≈ $0.025/hr ⇒ **~$0.20–0.30/hour total**. Create → test → **delete the same session**, and a full run costs under $2. The teardown block at the end is not optional.

```bash
aws configure                        # access key, secret, region (e.g. us-east-1), json

# 1. Create the cluster (this is genuinely all it takes — takes ~15 min, go make coffee)
eksctl create cluster --name backend-lab --region us-east-1 \
  --nodegroup-name workers --node-type t3.small --nodes 2
# → eksctl builds the VPC, control plane, and 2 worker nodes, and configures kubectl for you
kubectl get nodes
# → 2 nodes, STATUS Ready — same kubectl, real cluster

# 2. Push your image to ECR (AWS's registry)
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr create-repository --repository-name todo-api
aws ecr get-login-password | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
docker tag todo-api:v1 $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/todo-api:v1
docker push $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/todo-api:v1

# 3. Point the Deployment at the ECR image (edit k8s/deployment.yaml):
#      image: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/todo-api:v1
# 4. Give the Service a real front door (edit k8s/service.yaml — add one line):
#      spec:
#        type: LoadBalancer          # ← asks AWS for an internet-facing load balancer

kubectl apply -f k8s/
kubectl get svc todo-api
# → EXTERNAL-IP: a1b2c3...us-east-1.elb.amazonaws.com   (takes ~2 min to appear)

curl http://<that-address>/
# → {"message":"Hello from Kubernetes","version":"v1"}
#   YOUR code, YOUR yaml, on the public internet, load-balanced across 2 machines. 🎉
```

Re-run the Phase-3 experiments (delete a pod, scale to 5, rolling update) — they behave **identically**, which is the entire point: *you learned Kubernetes once; the cluster underneath is interchangeable.*

**🧹 Teardown (do this before you close the laptop):**
```bash
kubectl delete -f k8s/               # deletes the AWS load balancer (it bills hourly!)
eksctl delete cluster --name backend-lab --region us-east-1     # ~10 min — deletes nodes + control plane + VPC
aws ecr delete-repository --repository-name todo-api --force
# Verify in the AWS console: EC2 → no instances, no load balancers; EKS → no clusters.
```

**✅ Phase 4 done-check:** curl against a real AWS URL returned your JSON · the same experiments worked unchanged · the console shows zero leftover resources after teardown.

---

## Phase 5 — Stretch goals (pick any, in order of value)

1. **Autoscaling:** install metrics-server, add a `HorizontalPodAutoscaler` (target 60% CPU, min 2 / max 6), load-test with `hey` or `k6`, and watch replicas grow and shrink.
2. **CI/CD:** a 25-line GitHub Actions workflow: on push → `docker build` → push to ECR → `kubectl set image`. Congratulations, you've built a deploy pipeline.
3. **Real state:** add Redis or Postgres via Helm (`helm install`), point the API at it via the ConfigMap, and watch the flickering-todos bug from Phase 3B disappear — the correct fix, deployed the correct way.
4. **Ingress + HTTPS:** replace the LoadBalancer-per-service pattern with an Ingress (one front door, path routing, TLS) — the production-standard layout.
5. **A Secret:** move a fake DB password from ConfigMap to a `Secret` and note it's base64-encoded, *not* encrypted — the gateway to real secret managers.

---

## Troubleshooting — the errors you WILL hit (everyone does)

| Symptom | What it means | Fix |
|---|---|---|
| `ImagePullBackOff` | cluster can't fetch your image | kind: forgot `kind load docker-image`; EKS: wrong ECR URL/tag, or repo not created |
| `CrashLoopBackOff` | your process keeps exiting | `kubectl logs <pod>` — it's YOUR app's error (missing env var, port taken, bad code). Read logs first, always |
| Pod `Pending` forever | no node has room | lower `resources.requests`, or add/resize nodes |
| Probes keep restarting a healthy app | `/health` path/port wrong, or app slow to boot | fix the path; raise `initialDelaySeconds` |
| `curl` to Service times out | Service selector ≠ pod labels | `kubectl get endpoints todo-api` — empty = label mismatch; diff selector vs pod labels |
| EXTERNAL-IP stuck `<pending>` (EKS) | LB still provisioning (2–3 min) or account/service quota issue | wait; then `kubectl describe svc todo-api` events |
| AWS bill surprise | forgot teardown | the teardown block above; check EC2 + Load Balancers consoles |

---

## Courses & resources (the question you actually asked)

**Free — start here:**
- **Kubernetes official tutorials** (kubernetes.io/docs/tutorials) — the "Kubernetes Basics" interactive module mirrors this project's Phase 3.
- **EKS Workshop** (eksworkshop.com) — AWS's own free, excellent hands-on EKS labs; natural next step after Phase 4.
- **TechWorld with Nana — Kubernetes course** (YouTube, ~4h) — the best free conceptual walkthrough.
- **Play with Docker / killercoda.com** — browser-based sandboxes, zero installs.

**Paid (Udemy sales make these ~$10–15 each):**
- **Docker & Kubernetes: The Practical Guide** (Maximilian Schwarzmüller) or **Docker Mastery** (Bret Fisher) — the Docker + K8s foundation, developer-oriented.
- **Certified Kubernetes Application Developer (CKAD)** course by **Mumshad Mannambeth / KodeKloud** — CKAD is *the* certification aimed at developers (you), with built-in hands-on labs.
- **AWS EKS Kubernetes — Masterclass** (Stacksimplify) — EKS-specific depth: real DNS, ingress, storage, CI/CD on AWS.

**Suggested order:** this project → Nana's video (fills concept gaps) → CKAD course (makes it stick + a resume credential) → EKS Workshop / Stacksimplify (AWS depth).

---

## The mental model to keep (read this last, remember it forever)

> **Docker freezes your app into a portable artifact. Kubernetes runs declared copies of that artifact and never stops correcting reality to match your declaration — healing, scaling, and rolling updates all fall out of that one loop. EKS is just AWS running the Kubernetes brain for you. And every backend habit you already have — health endpoints, env-var config, statelessness, graceful shutdown — is exactly what makes an app thrive there.**

You're not leaving backend. You're becoming the backend engineer whose code actually ships.

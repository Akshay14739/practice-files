# Project 14 — Conduct: NVIDIA Dynamo, the Datacenter-Scale Inference OS (NVIDIA 2/3)

**Difficulty:** ★★★★★ | **Time:** 3–4 weekends | **Cost:** ~$20–40 (2–4× g5/g6 spot; optional A100/EFA window borrowed from P15)

*NVIDIA's answer to the question you already answered by hand in [P09](project-09-disaggregated-inference-llm-d.md): how do you run inference across a **fleet**, not a pod? Dynamo is the Apache-2.0 orchestration layer that sits **above** vLLM, SGLang and TensorRT-LLM — OpenAI-compatible frontend, KV-cache-aware router, disaggregated prefill/decode over NIXL, tiered KV memory (KVBM), and an SLA-driven Planner — packaged as a Kubernetes operator with a `DynamoGraphDeployment` CRD. NVIDIA calls it "the operating system of the AI factory." In this project you deploy it on your own EKS cluster, drive the same benchmarks you drove against llm-d and Triton/TRT-LLM ([P13](project-13-nvidia-tensorrt-llm-triton-factory.md)), and end up as one of very few engineers who has personally operated **both** the OSS and the vendor version of the frontier serving pattern — and can say, with numbers, when each one wins.*

> ⚠️ **Pin your release.** Dynamo moves monthly. As of **July 2026** the latest stable is **v1.2.1** (2026-06-13); **1.0 went GA at GTC on 2026-03-16** (NVIDIA's "Dynamo Enters Production — Inference Operating System for AI Factories" release, with adopters including AWS, Azure, Google Cloud, OCI, CoreWeave, Perplexity, Cursor and Baseten), and v1.3.0 dev builds are already in the wild. Pin a tag from `github.com/ai-dynamo/dynamo`, pin the Helm chart version, and expect flags and CRD fields to have drifted by the time you read this. The **architecture** below is the durable part; every version number here carries a date on purpose.

## 1. What Dynamo is — and what it is not

Dynamo is **not an inference engine**. It does not replace vLLM, SGLang or TensorRT-LLM; it *conducts* them. Its own README says so. Workers run the engines directly — there is no Triton in the data path. Internally it's Rust (frontend, router, runtime) with Python bindings for the worker glue.

It productizes, component for component, exactly what you hand-assembled in P09 — which is why doing P09 first makes you dangerous here:

| Dynamo component | What it does | Your P09 equivalent |
|---|---|---|
| **Frontend** | OpenAI-compatible HTTP entrypoint, Rust, high-QPS | your gateway |
| **Router** (KV-aware) | routes on worker load **+ KV-cache prefix overlap**; NVIDIA claims ~2× faster TTFT vs load-only routing | Inference-Extension EPP |
| **Workers** | engine-agnostic: **vLLM, SGLang, TensorRT-LLM** ([P13](project-13-nvidia-tensorrt-llm-triton-factory.md) builds the TRT-LLM ones) | your vLLM pools |
| **Disaggregated serving** | prefill/decode split as a first-class deployment mode, per engine | your P/D split |
| **NIXL** | NVIDIA Inference Xfer Library — point-to-point KV/weight transfer (GPU↔GPU/CPU/NVMe, RDMA/EFA-capable) | same library, raw |
| **KVBM** (KV Block Manager) | tiered KV memory: GPU HBM → host RAM → SSD → remote/S3/Azure blob | LMCache |
| **SLA Planner** | profiling autoscaler: shifts the prefill:decode worker *ratio* to hold TTFT/TPOT targets | your HPA + judgment |
| **AIConfigurator** | offline simulator: picks a deployment config for a model+GPU+SLA before you burn a GPU-hour | your spreadsheet |
| **ModelExpress** | NIXL/NVLink weight streaming — NVIDIA claims ~7× faster cold start | your PVC + `initContainer` |
| **Grove** | K8s gang-scheduling operator for multinode inference graphs | Kueue/Volcano ([P07](project-07-topology-aware-gang-scheduler.md)) |

**Two things almost every blog post gets wrong — get them right and you sound senior:**

1. **"Dynamo is Triton's successor" is half-true.** NVIDIA's launch materials *did* call Dynamo the successor to Triton for **datacenter-scale generative-AI serving**, and Triton was rebranded **Dynamo-Triton**. But Triton was not retired and is **not** the per-node server inside Dynamo. It is very much alive (**v2.70.0, 2026-06-26**) as the general-purpose inference server for TensorRT/PyTorch/ONNX/OpenVINO/Python/RAPIDS-FIL, ensembles, and real-time/batch audio-video workloads. The correct sentence: *"Dynamo succeeds Triton for datacenter-scale LLM serving, while Triton lives on as Dynamo-Triton for general-purpose per-node inference."*
2. **etcd and NATS are optional now, not required.** Older docs (and the old version of this project) describe etcd + NATS as the mandatory discovery/event plane. On Kubernetes, Dynamo v1.x uses **K8s-native discovery (CRDs + EndpointSlices) with a TCP request plane**; etcd/NATS remain for Slurm and non-K8s modes. Caveat you should verify yourself: the 1.2.1 `dynamo-platform` chart still brings up `etcd-*`/`nats-*` pods in the quickstart, so treat this as **"made optional," not "removed."** Checking which pods actually appear in *your* install is a nice five-minute reality check on the docs.

The senior-engineer question this project lets you answer with evidence: ***"Build the serving plane from open parts (llm-d style) or adopt Dynamo?"*** You'll have run both.

## 2. Phase 1 — platform install on EKS

Kubernetes is the canonical production path (there is a local/Slurm path; ignore it). Install from the **NGC OCI registry**, CRDs first:

```bash
export NS=dynamo-system
export DYNAMO_VER=1.2.1   # pin it; check github.com/ai-dynamo/dynamo/releases

# 1) CRDs
helm install dynamo-crds \
  oci://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds \
  --version $DYNAMO_VER -n $NS --create-namespace

# 2) Platform: the Dynamo Operator (+ etcd/nats if the chart still ships them)
helm install dynamo-platform \
  oci://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform \
  --version $DYNAMO_VER -n $NS

kubectl get pods -n $NS
kubectl get crds | grep nvidia.com   # dynamographdeployments, dynamocomponentdeployments, dynamographdeploymentrequests
```

**Prereqs you already own:** the **NVIDIA GPU Operator** (from [P08](project-08-fractional-gpu-dra-multitenancy.md)) is a hard requirement; Prometheus/Grafana from [P12](project-12-ai-fleet-sre-finops-aiops.md) for everything you're about to measure. Optional: **Grove** or the **KAI Scheduler** for multinode gang scheduling — skip on single-GPU workers, revisit in the extensions.

The operator reconciles **three CRDs** (`apiVersion: nvidia.com/v1beta1` as of 1.2.x — check yours, it was `v1alpha1` not long ago):

| CRD | Role |
|---|---|
| **DynamoGraphDeployment** (DGD) | the canonical object: one inference *graph* (frontend + workers + router) you write and apply |
| **DynamoComponentDeployment** (DCD) | per-component Deployments the operator creates **for** you — you read these, you don't write them |
| **DynamoGraphDeploymentRequest** (DGDR) | **beta**, "zero-config": you give it model + backend + SLA, it profiles (AIConfigurator + Planner) and *generates* a DGD. Runs to a terminal state like a Job. |

Tuned **recipes** (`deploy.yaml` DGD manifests per model/GPU) ship in the repo — read one before you write your own.

## 3. Phase 2 — aggregated baseline

Always get the boring topology working first. Aggregated = one worker class doing prefill **and** decode.

```yaml
apiVersion: nvidia.com/v1beta1
kind: DynamoGraphDeployment
metadata: {name: llama8b-agg, namespace: dynamo}
spec:
  services:
    Frontend:
      replicas: 1
      extraPodSpec:
        mainContainer: {image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.1}
    VllmDecodeWorker:            # aggregated mode: this worker does prefill+decode
      replicas: 2
      resources: {limits: {gpu: "1"}}
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.1
          args: ["python3 -m dynamo.vllm --model meta-llama/Llama-3.1-8B-Instruct"]
```

```bash
kubectl apply -f dgd-agg.yaml
kubectl get dynamographdeployment -n dynamo   # then watch the DCDs the operator spawns
kubectl get dcd -n dynamo
kubectl port-forward svc/llama8b-agg-frontend 8000:8000 -n dynamo
curl localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","messages":[{"role":"user","content":"hi"}]}'
```

Same OpenAI schema as everything else you've built — which is the point: you can put Dynamo behind the exact same client and benchmark harness as vLLM, llm-d, and `trtllm-serve`.

**Engine-agnosticism demo (cheap, high-signal):** swap the runtime image and worker module to SGLang, change nothing else, re-run the same curl. That's the whole thesis of Dynamo in one diff. Feature-matrix caveat as of July 2026: all three engines support disaggregation, KV-aware routing and the SLA Planner; **KVBM is ✅ on TensorRT-LLM and vLLM but still 🚧 on SGLang** — so do the KVBM phase on a vLLM graph.

## 4. Phase 3 — disaggregated prefill/decode + NIXL

Now the reason Dynamo exists. Add a prefill worker service (`--is-prefill-worker`), keep the decode workers, and the frontend/router will split the two phases, shipping KV blocks from prefill → decode over **NIXL**.

```yaml
    VllmPrefillWorker:
      replicas: 2
      resources: {limits: {gpu: "1"}}
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.1
          args: ["python3 -m dynamo.vllm --model meta-llama/Llama-3.1-8B-Instruct --is-prefill-worker"]
```

What to actually measure (this is where the portfolio value is):

- **Prompt-heavy vs decode-heavy:** run ISL 3000 / OSL 100, then ISL 200 / OSL 1000, against the agg graph and the disagg graph. Disagg should win TTFT on the prompt-heavy phase and *lose* on nothing important; if it loses everywhere, your P/D ratio is wrong — that's the lesson, write it down.
- **The NIXL transport story.** On plain TCP (g5/g6 spot, no EFA) disaggregation works but the KV transfer is visibly expensive — you can watch it in the NIXL transfer metrics during a long-prompt burst. Record the number. Then (optional, one paid session) repeat on the **EFA pair from [P15](project-15-nvidia-networking-nccl-cluster-validation.md)** with RDMA transports and watch the transfer cost collapse. That single before/after — *same manifest, same model, different fabric* — is the best systems story in this entire project, because it proves you understand that disaggregation is a **network** bet.

## 5. Phase 4 — the KV-aware Router

Enable KV-aware routing on the frontend (`--router-mode kv`), then prove it does something:

- Replay ~100 **multi-turn** conversations (shared system prompt + growing history — this is the case where prefix reuse is real).
- Watch router metrics / worker logs show sticky routing by prefix overlap.
- Compare **TTFT p50/p99 vs `--router-mode round-robin`** on the identical trace.
- Then the honest counter-test: replay 100 **unrelated single-turn** prompts. KV-aware routing should give you nearly nothing. *Knowing when a feature does nothing is worth more in an interview than knowing when it helps.*

Cross-link the write-up to P09's EPP scorer: same idea (prefix-aware scheduling), different implementation, and you have both TTFT curves.

## 6. Phase 5 — the SLA Planner (SLA-driven, not utilization-driven)

Classic HPA scales replicas on a proxy metric (queue depth, GPU util). Dynamo's **Planner** reasons about the *ratio* of prefill:decode capacity against **TTFT/TPOT targets** — an ISL-heavy burst needs more **prefill** workers, not more of everything.

Enable it with your SLOs (e.g. TTFT ≤ 800 ms, TPOT ≤ 40 ms), then drive two synthetic phases: prompt-heavy (ISL 3000 / OSL 100) → decode-heavy (ISL 200 / OSL 1000). **Capture the worker-count timeline showing the ratio shift.** A screenshot of prefill replicas climbing while decode holds flat, annotated with the SLO line, is one of the most legible artifacts you will produce in this whole track.

Then write the memo: **Planner vs HPA-on-queue-depth (P09)** — when is SLA-planning worth its complexity? (Answer sketch: at multi-model / multi-node scale on expensive GPUs, where getting the ratio wrong wastes real money. Below that, HPA is simpler and good enough. Say that out loud; vendors won't.)

## 7. Phase 6 — KVBM tiering

Enable **KVBM** offload on a vLLM graph — host RAM tier first, NVMe if your instance has it (g6 does), object/S3 tier as a paper-study unless you have somewhere fast to put it. Then rerun P09's multi-turn benchmark.

The question KVBM answers: *how much conversation history can I keep hot for how much money?* Measure cache **hit rate** and **multi-turn TTFT** as you (a) shrink GPU KV space, (b) add tiers. The expected shape: HBM-only falls off a cliff as the working set grows; HBM+RAM degrades gracefully; NVMe buys you capacity at a latency you can quote. Put the cliff on a chart.

## 8. Phase 7 — benchmark honestly (and with the *current* tool)

**Use AIPerf** (`ai-dynamo/aiperf`) — it is NVIDIA's current generative-AI benchmarking tool and the one Dynamo's own benchmarking guides use.

Tooling facts that trip people up (verified July 2026 — this is a great "I actually track this ecosystem" flex):
- **`genai-perf` is the one being deprecated**, with a documented migration path to **AIPerf**. Not the other way round.
- **Triton Model Analyzer is NOT deprecated** (v1.55.0, 2026-06-26, released in lockstep with Triton v2.70.0). It also never did genai-perf's job — Model Analyzer is *server-side Triton model-config optimization*; AIPerf/genai-perf are *client-side LLM benchmarking*. If a blog says one replaced the other, the blog is wrong. (You use Model Analyzer in [P13](project-13-nvidia-tensorrt-llm-triton-factory.md), for Triton; you use AIPerf here, for Dynamo.)

Final deliverable — the table across **five** serving stacks you have now *personally operated*, same model, same GPU class, same trace, same client:

| Stack | TTFT p99 | TPOT p99 | tok/s/GPU | Multi-turn TTFT (cache reuse) | $/1M tok | Ops complexity (your 1–5) |
|---|---|---|---|---|---|---|
| vLLM plain (P2 baseline) | *measured* | | | | | |
| Your P09 stack (llm-d pattern) | *measured* | | | | | |
| Triton + TensorRT-LLM (P13) | *measured* | | | | | |
| `trtllm-serve` (PyTorch backend, P13) | *measured* | | | | | |
| **Dynamo — aggregated** | *measured* | | | | | |
| **Dynamo — disaggregated + KV router + KVBM** | *measured* | | | | | |

Nobody interviewing you will have this table. It converts *"I read about disaggregation"* into *"I measured it five ways, and here's the one where it didn't help."*

## 9. Phase 8 — DGDR: let Dynamo configure itself

The **DynamoGraphDeploymentRequest** (beta) is the "zero-config" path: hand it a model, a backend and an SLA; it runs a profiling job (AIConfigurator + Planner), and emits a DGD.

```yaml
apiVersion: nvidia.com/v1beta1
kind: DynamoGraphDeploymentRequest
metadata: {name: llama8b-auto, namespace: dynamo}
spec:
  model: meta-llama/Llama-3.1-8B-Instruct
  backendFramework: vllm
  # SLA targets drive the generated prefill:decode topology
  sla: {ttft: 800ms, itl: 40ms}
```

```bash
kubectl get dgdr -n dynamo -w        # runs to a terminal state, like a Job
kubectl get dgd -n dynamo -o yaml    # <- read the DGD it generated
```

**The deliverable is the diff:** DGDR's generated topology vs the one *you* tuned by hand in Phases 3–6. Where does the machine beat you? Where does it over-provision? On a 2-GPU budget it will often produce something conservative — say so. This phase is cheap and it is the single most "I'm operating 2026's stack, not 2024's" thing in the doc.

## 10. Phase 9 — NIM, the packaged alternative (cheap, mostly judgment)

Deploy one **NIM microservice** — a prebuilt, optimized, OpenAI-compatible inference container from NGC — via the **NIM Operator** (**v3.1.1**, NGC chart updated 2026-05-20) and its `NIMService` CRD:

```yaml
apiVersion: apps.nvidia.com/v1alpha1
kind: NIMService
metadata: {name: llama-nim, namespace: nim}
spec:
  image: {repository: nvcr.io/nim/meta/llama-3.1-8b-instruct, tag: latest}
  resources: {limits: {nvidia.com/gpu: 1}}
  expose: {service: {type: ClusterIP, port: 8000}}
```

The NIM Operator also ships `NIMCache` (pull/cache model profiles from NGC to shared storage), `NIMPipeline`, `NIMBuild` (builds optimized TRT-LLM engines from profiles), plus the **NeMo** microservice CRDs (Customizer / Evaluator / Guardrails / Data Store / Entity Store). v3.1.x added Gateway API routing, DRA support, multi-node NIM via Ray, and — note this — an **experimental Dynamo CRD and KServe integration**, i.e. the two stacks are converging.

**Licensing, stated precisely** (people get this wrong and it costs them credibility):
- **Free** for **NVIDIA Developer Program** members for research / development / testing — self-hosting up to **16 GPUs**. That covers this entire project.
- **Production requires an NVIDIA AI Enterprise subscription**: ~**$4,500/GPU/year** list, or ~**$1/GPU/hour** on cloud marketplaces; 90-day evaluation available.

Then write the memo everyone actually wants to read — **`docs/serving-platform-selection.md`**:

| | NIM | Dynamo | Open assembly (P09/llm-d) |
|---|---|---|---|
| Time to first token served | minutes | hours | days |
| Who tunes it | NVIDIA | you, with tools (Planner/AIConfigurator) | you, with judgment |
| Engines | NVIDIA's (TRT-LLM) | vLLM / SGLang / TRT-LLM | anything |
| Disagg P/D, KV router | not the point | first-class | you built it |
| Cost | licensed per GPU (see above) | Apache-2.0 | Apache-2.0 |
| Lock-in | high | medium (NGC images, NVIDIA GPUs) | low |
| When it wins | small team, enterprise support, standard models | large fleet, expensive GPUs, SLA pressure | you need control, custom scorers, non-NVIDIA silicon |

## 11. What runs on cheap GPUs vs what is paper-study

Be ruthlessly honest about this in your posts — it's a *credibility* multiplier, not a weakness:

**Runs for real on 2–4× g5/g6 spot (~$20–40 total):** the operator + all three CRDs; agg and disagg graphs; the KV-aware router A/B; the SLA Planner ratio shift; KVBM HBM→RAM (→NVMe on g6); AIPerf benchmarking; the engine swap to SGLang; DGDR; a NIM under the free developer tier.

**One paid session, worth it:** the NIXL **TCP vs RDMA/EFA** before/after, borrowing the P15 EFA pair. This is the money shot.

**Paper-study — read, diagram, don't pretend you ran it:** NVIDIA's headline **"up to 7× Blackwell throughput"** claim (GB200 NVL72 — you do not have one, and repeating the number as if you measured it will get you caught); wide-EP / large-MoE serving across dozens of GPUs; ModelExpress cold-start streaming at fleet scale; Grove gang-scheduled multinode graphs; the KVBM remote/S3 tier at datacenter capacity. Write the **design note** for each instead — "here's the topology I would deploy on NVL72 and why" — and label it as design. Frontier-lab interviewers respect the label; they *always* catch the fake.

## 12. Done criteria & interview ammo

- [ ] Dynamo platform (operator + CRDs) live on EKS from a **pinned** chart version; you can state which pods actually appeared (etcd/NATS or not).
- [ ] Aggregated and disaggregated `DynamoGraphDeployment` graphs serving the OpenAI endpoint.
- [ ] Engine swap demonstrated (vLLM → SGLang) with no other change.
- [ ] KV-aware routing benefit **measured** vs round-robin — *and* the null result on single-turn traffic.
- [ ] Planner prefill:decode ratio-shift captured under a workload phase change, against stated TTFT/TPOT SLOs.
- [ ] KVBM tiering: cache-hit-rate and multi-turn TTFT curve as the KV working set grows.
- [ ] NIXL transfer cost measured on TCP; (stretch) same run on EFA/RDMA, delta reported.
- [ ] Five-stack AIPerf benchmark table published.
- [ ] DGDR-generated topology diffed against your hand-tuned one.
- [ ] `docs/serving-platform-selection.md` (NIM vs Dynamo vs open assembly) + `docs/disagg-comparison.md` (vLLM-native disagg vs llm-d ([P09](project-09-disaggregated-inference-llm-d.md)) vs Dynamo: architecture, KV transfer mechanism, scheduler, maturity, lock-in).

**Resume bullet:** *"Deployed NVIDIA Dynamo (v1.2.x) on EKS via the Dynamo Operator and DynamoGraphDeployment CRDs: disaggregated prefill/decode graphs with NIXL KV transfer, KV-cache-aware routing, KVBM tiered KV memory, and SLA-driven Planner autoscaling across vLLM and SGLang backends; benchmarked with AIPerf against vLLM, an llm-d-pattern stack, and Triton/TensorRT-LLM, and authored the platform-selection recommendation (NIM vs Dynamo vs open assembly) including licensing economics."*

Whiteboard-ready after this: what disaggregation actually costs you (a network); why a KV-aware router beats a load-aware one *only* under prefix reuse; why an SLA planner beats an HPA at fleet scale; where Dynamo ends and the engine begins; and the sentence that separates you from the blog posts — *"Dynamo succeeds Triton for datacenter-scale LLM serving; Triton lives on as Dynamo-Triton for general-purpose per-node inference."*

## 13. Teardown

```bash
kubectl delete dgd,dgdr --all -n dynamo
helm uninstall dynamo-platform dynamo-crds -n dynamo-system
kubectl delete ns dynamo dynamo-system
eksctl scale nodegroup --cluster $CLUSTER --name gpu-spot --nodes 0   # or your Karpenter NodePool limit → 0
```
Keep: the AIPerf result JSONs, the Grafana screenshots, the generated DGD from DGDR, and both memos. They are the project.

## 14. Extensions

1. **Multi-node TP worker** across 2× g5.12xlarge — then add **Grove** (or KAI) so the graph gang-schedules instead of deadlocking half-placed; ties straight back to [P07](project-07-topology-aware-gang-scheduler.md).
2. **GAIE topology:** Dynamo also supports a **Gateway API Inference Extension** routing topology via a **Dynamo Endpoint Picker plugin** — swap the built-in router for GAIE and compare against P09's EPP directly. Same interface, two implementations, one benchmark.
3. **ModelExpress cold starts:** measure pod-ready→first-token with and without weight streaming on an 8B model; even a modest speedup is a real number for a spot-heavy fleet ([P12](project-12-ai-fleet-sre-finops-aiops.md) FinOps angle).
4. **AIConfigurator offline sweep:** simulate configs for a model you *can't* afford to run, then check its predictions against the one config you can. Cheapest possible way to earn an opinion about a GPU you don't own.
5. **Multimodal / video:** Dynamo now does multimodal E/P/D disaggregation and video generation (FastVideo, SGLang Diffusion). Serve an image-input model and see whether the encode phase wants its own worker class.
6. **The closed loop:** fine-tune a LoRA with **NeMo Customizer** (K8s, Volcano-scheduled, deployed by the NIM Operator's NeMo CRDs) → evaluate with **NeMo Evaluator** → serve it through Dynamo. Customize → evaluate → serve, entirely on your own cluster.
7. **Edge angle:** single-GPU Dynamo frontend + worker as a "micro-cell" — the smallest thing that still speaks the datacenter API.

## 📣 Build in public

- **LinkedIn:** post the five-stack table (vLLM → llm-d → Triton/TRT-LLM → `trtllm-serve` → Dynamo agg/disagg) with TTFT p99, tok/s/GPU and $/1M tokens on the same ~$1/hr spot GPU — then lead with the *uncomfortable* row: the case where KV-aware routing bought me **nothing** (single-turn traffic, measured), and why I'd still ship it for a chat product. Close with the NIM licensing math ($4,500/GPU/yr list vs Apache-2.0) so the post is about a **decision**, not a demo.
- **X/Twitter thread:** "Everything you've read about NVIDIA's inference stack is 12 months stale," with receipts from my own cluster — Dynamo v1.2.1, `DynamoGraphDeployment`/`DGDR` on `nvidia.com/v1beta1`, etcd+NATS now **optional** on K8s (here's `kubectl get pods` showing what actually came up), Dynamo does **not** run Triton in the data path, `genai-perf` is deprecated in favor of **AIPerf** while Model Analyzer is alive and never did that job — each claim one screenshot deep.
- **YouTube:** the NIXL fabric demo. Same DGD manifest, same model, two clusters: disaggregated prefill/decode over **TCP** on g5 spot, then over **EFA/RDMA** on the P15 pair — KV-transfer time and TTFT p99 side by side on one Grafana board while a long-prompt burst runs. Then flip to the SLA Planner and let the camera sit on the prefill replica count climbing during an ISL-3000 phase while decode holds flat. Two shots, zero slides, and the whole argument for disaggregation lands.

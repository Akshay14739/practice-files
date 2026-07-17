# Interview Question Bank — DevOps / SRE / Kubernetes Platform Engineer

> Generated from my resume + [DevOps-SRE-Interview-Prep.md](DevOps-SRE-Interview-Prep.md) (referenced below as **Prep §X**).
> Format: **[B]** Basic · **[I]** Intermediate · **[A]** Advanced · **[S]** Scenario/Experience-based.
> Each question has "→" = the key points your answer must hit. Practice answering OUT LOUD, then check against Prep §.

---

## How to use this bank

1. **Round 1 (screening)**: expect [B] + a few [I] from every section — rapid, breadth-first.
2. **Round 2 (technical deep-dive)**: [I]/[A] from 3–4 sections tied to the JD, plus "explain your resume line" questions.
3. **Round 3 (architecture/manager)**: [S] questions, war stories, trade-off discussions.
4. Self-test: cover the "→" line, answer, then compare. If you can't speak for 60–90 seconds on an [I] question, revisit that Prep §.

---

## 1. Kubernetes — Architecture & Core (Prep §2)

### Basics
1. **[B]** What problem does Kubernetes solve that Docker alone doesn't? → scheduling, self-healing, service discovery, rolling updates, scaling; declarative reconciliation.
2. **[B]** Explain Kubernetes architecture — control plane and worker components. → API server, etcd, scheduler, controller-manager, cloud-controller; kubelet, kube-proxy, containerd. (Draw Prep §2.2.)
3. **[B]** What is a Pod and why is it the smallest unit (not a container)? → shared network namespace/localhost, shared volumes, sidecar pattern.
4. **[B]** Deployment vs ReplicaSet vs Pod — relationship? → Deployment manages RS (versioned), RS keeps replica count, rollout = new RS scaled up / old down.
5. **[B]** What is etcd and what happens if it goes down? → desired-state KV store; cluster keeps running existing workloads but no changes/scheduling; only API server talks to it.
6. **[B]** What is a namespace? Are all resources namespaced? → logical isolation; no — Nodes, PVs, ClusterRoles, StorageClasses are cluster-scoped.

### Intermediate
7. **[I]** Walk me through EXACTLY what happens when you run `kubectl apply -f deployment.yaml`. → authN → RBAC → admission → etcd write → controller creates RS/Pods → scheduler binds → kubelet pulls & runs → probes → endpoints. (The #1 filter question — rehearse Prep §2.2 flow.)
8. **[I]** Deployment vs StatefulSet vs DaemonSet — when each? → interchangeable replicas / stable identity + per-pod PVC + ordered / one-per-node (cite your real DaemonSets: Falcon, node-exporter, Filebeat).
9. **[I]** Requests vs limits — what does each actually do? → requests = scheduler guarantee + quota accounting; limits = cgroup cap; CPU throttled, memory OOMKilled (exit 137).
10. **[I]** Explain QoS classes and eviction order. → Guaranteed / Burstable / BestEffort; BestEffort evicted first under node pressure.
11. **[I]** Liveness vs readiness vs startup probes — and what goes wrong with a bad liveness probe? → restart vs endpoint-removal vs slow-boot protection; bad liveness = restart storm during dependency blips.
12. **[I]** Taints/tolerations vs nodeAffinity — difference and a combined use case? → node repels vs pod attracts; dedicated tenant node group needs BOTH (taint keeps others out, affinity pulls tenant in).
13. **[I]** What is a PodDisruptionBudget and when did you need one? → min available during voluntary disruption; node drains during upgrades/decommissions.
14. **[I]** How does HPA work and what does it need? → metrics-server; desired = ceil(current × currentMetric/target); mention custom metrics via Prometheus adapter.
15. **[I]** What are admission controllers? Name uses. → mutate/validate before etcd write; sidecar injection, PodSecurity, policy engines (Kyverno/OPA), ArgoCD-adjacent webhooks.

### Advanced
16. **[A]** What happens, step by step, when a node dies? → NotReady ~40s → pod eviction after tolerance (~5m) → reschedule; StatefulSet waits (at-most-one); LB health checks remove node earlier.
17. **[A]** How does the scheduler pick a node? → filter (resources, taints, affinity, PVC topology) → score (spread, utilization) → bind; mention `WaitForFirstConsumer` interaction with AZs.
18. **[A]** Explain Kubernetes garbage collection / ownerReferences. → child objects deleted with owner (cascade), orphan/background/foreground propagation — tie to your Python cleanup tool deleting Jobs with propagation_policy.
19. **[A]** What are finalizers and how do they cause "stuck Terminating"? → pre-delete hooks; controller must remove them; stuck = controller dead → patch finalizer away (carefully).
20. **[A]** How do you achieve a true zero-downtime deployment? → readiness + maxSurge/maxUnavailable + PDB + preStop sleep + SIGTERM handling + connection draining at LB.
21. **[A]** API deprecations — how do you upgrade a cluster safely across versions? → pluto/kubent scan, one minor at a time, plane → nodes → addons, PDB-respecting drains. (Your EKS upgrade story.)

### Scenario
22. **[S]** A pod is stuck `Pending` — debug it live. → describe → events: resources/PVC/taints/affinity (Prep §2.7 tree).
23. **[S]** Pods are `Running` but the service returns 503 — go. → `kubectl get endpoints` empty? → readiness failing / selector mismatch / wrong targetPort → then ingress/LB layer.
24. **[S]** `CrashLoopBackOff` at 2am — your first three commands? → `logs --previous`, `describe pod` (exit code: 137=OOM, 1=app), `get events`.
25. **[S]** One tenant's workload is starving others on shared nodes — fix short-term and long-term. → short: quotas/limits, evict; long: LimitRange defaults, dedicated tainted node group, monitoring per namespace. (Multi-tenancy, Prep §2.6.)
26. **[S]** DNS resolution is intermittently failing in-cluster. → CoreDNS pod health/restarts, ndots:5 issue, conntrack exhaustion, NetworkPolicy blocking UDP 53, node-local DNS cache as fix.

### Related topics they'll pull in
27. **[I]** How does Kubernetes networking differ from Docker networking? → flat pod network, every pod an IP, no NAT pod-to-pod, CNI plugin responsibility.
28. **[I]** kube-proxy iptables vs IPVS mode? → linear rules vs hash — scale difference; both DNAT to pod IPs.
29. **[B]** What's a CRD and an operator? → extend the API; controller reconciling custom resources — you ran many: Prometheus Operator, ArgoCD Application, Velero Backup, SecretProviderClass.

---

## 2. AWS EKS (Prep §3)

1. **[B]** What does EKS manage for you vs what do you manage? → plane/etcd/HA vs nodes, addons, workloads, upgrades. (Prep §3.1 table.)
2. **[B]** How does kubectl authenticate to EKS? → STS token via aws cli → IAM identity mapped by access entries (legacy aws-auth ConfigMap) → K8s RBAC authorizes. "IAM authenticates, RBAC authorizes."
3. **[I]** Explain the AWS VPC CNI — pros/cons. → pods get real VPC IPs from ENIs; pro: native routing, SG support, ALB pod targets; con: IP exhaustion → prefix delegation / secondary CIDR.
4. **[I]** Managed node groups vs self-managed vs Fargate vs Karpenter? → ASG+graceful drain managed by AWS / DIY / serverless pods / just-in-time right-sized nodes.
5. **[I]** How do you expose an app on EKS end-to-end? → Ingress + AWS Load Balancer Controller → ALB with pod-IP target groups; subnet discovery tags; TLS via ACM. (Prep §2.4 diagram.)
6. **[A]** Walk me through your EKS upgrade process. → deprecation scan → control plane one minor → node groups (new AMI launch template, rolling with PDBs) → addons (CoreDNS, VPC CNI, kube-proxy, EBS CSI) → validate.
7. **[A]** Your cluster ran out of pod IPs — what happened and what are the fixes? → VPC CNI ENI/IP limits per instance type; prefix delegation, bigger/secondary CIDR, smaller subnets audit.
8. **[S]** Design a production EKS setup from scratch — whiteboard it. → 3-AZ VPC, private nodes/endpoint, public ALB, node groups (tainted platform + apps), addons, IAM/IRSA-or-PodIdentity, observability, GitOps bootstrap. (Prep §3.2.)
9. **[S]** You ran EKS AND on-prem — biggest operational differences? → etcd backup ownership, LoadBalancer (MetalLB vs NLB), storage CSI choices, node capacity planning, upgrade drills. (Prep §3.3 — YOUR differentiator, have 2 stories.)
10. **[I]** Private vs public API endpoint — what did you use and why? → private for prod; access via VPN/bastion/VPC-peered runners.

### Related AWS questions (expect these!)
11. **[B]** VPC basics: subnets, route tables, IGW vs NAT gateway? → public = route to IGW; private egress via NAT; K8s nodes in private.
12. **[B]** Security groups vs NACLs? → stateful instance-level vs stateless subnet-level.
13. **[I]** How do you keep AWS costs down on EKS? → right-size requests, cluster-autoscaler/Karpenter, Spot for stateless, gp3 over gp2, cleanup automation (your Python tool!), decommission unused clusters (your resume!).
14. **[B]** S3 storage classes / lifecycle? → tie to Velero backups TTL and ELK ILM analogy.
15. **[I]** IAM role vs user vs instance profile? → roles everywhere, no long-lived keys; leads into OIDC/Pod Identity.

---

## 3. Terraform (Prep §4)

### Basics
1. **[B]** What is Terraform state and why does it exist? → maps config → real resource IDs; without it TF can't diff or own resources.
2. **[B]** Explain init / plan / apply / destroy. → providers+backend / diff (desired vs state vs refreshed real) / execute graph / teardown.
3. **[B]** What's a provider? A module? → API plugin; reusable resource bundle with variables/outputs.
4. **[B]** Where should state live for a team, and why not locally? → remote S3 + locking (DynamoDB/lockfile), encrypted, versioned; local = no collaboration, no locking, loss risk.

### Intermediate
5. **[I]** What happens if two engineers `apply` simultaneously? → state lock blocks the second; explain lock table and `force-unlock` (rare, careful).
6. **[I]** Someone changed infra in the console — how do you detect and handle drift? → `plan` shows diff; scheduled plan in CI (I ran this); decide: revert infra or codify change.
7. **[I]** How do you bring existing (click-ops) infra under Terraform? → `terraform import` / import blocks + write matching config, plan until clean.
8. **[I]** Workspaces vs directory-per-environment — your choice and why? → dirs + shared modules: explicit state files, safer prod isolation, per-env versions.
9. **[I]** How do you structure Terraform for multiple environments? → Prep §4.2 layout: modules/ + envs/dev|prod with own backend + tfvars.
10. **[I]** How do secrets end up in state, and what do you do about it? → resource attributes stored plaintext in state → encrypted locked backend, least-access, `sensitive=true`, fetch via data sources at apply.
11. **[I]** What Terraform checks run in your CI? → fmt -check, validate, tflint, tfsec/checkov, plan on PR, gated apply on merge.

### Advanced
12. **[A]** You lost the state file — recovery plan? → S3 versioning restore first; else re-import resource by resource; prevention: versioned+replicated backend.
13. **[A]** `-target`, `taint`/`-replace`, `state mv`, `moved` blocks — when have you used them? → surgical applies during incidents; force node group recreation; refactoring without destroy.
14. **[A]** `count` vs `for_each` — and the classic pitfall? → for_each keyed by map = stable addresses; count index shifts destroy/recreate siblings on list reorder.
15. **[A]** How do you manage provider/module version upgrades safely? → pinned versions, lock file, upgrade in dev first, read changelogs, plan diff review.

### Scenario (your resume stories)
16. **[S]** Walk me through how you provisioned EKS clusters with Terraform. → Prep §4.2: VPC module → EKS module (node groups, addons, endpoint config) → boundary: "infra in TF, apps in GitOps."
17. **[S]** Your resume says you DECOMMISSIONED clusters — walk me through that safely. → Prep §4.3 staged flow: inventory → sign-off → traffic drain → final Velero backup → delete K8s-created cloud resources FIRST (LBs/ENIs/EBS from Services/PVCs) → targeted destroy → orphan sweep + billing verify. Have the ENI-blocks-VPC-deletion war story ready.
18. **[S]** `terraform destroy` hangs on the VPC — why? → K8s-created ENIs/LBs/volumes not in state still reference subnets; delete Services/PVCs in-cluster first.
19. **[S]** A `plan` in prod shows 40 unexpected changes — what do you do? → STOP; diff cause: provider upgrade? drift? refactor? state issue? Review resource-by-resource, never blind-apply.

---

## 4. GitOps & ArgoCD (Prep §5)

### Basics
1. **[B]** What is GitOps? → Git = single source of truth for desired state; deploy = PR merge; audit, rollback, drift detection for free.
2. **[B]** Pull vs push deployment — why is pull safer? → cluster creds never leave the cluster; ArgoCD pulls from inside.
3. **[B]** Name ArgoCD's components and roles. → repo-server (render), application-controller (diff+sync), argocd-server (UI/API), dex (SSO), Redis.
4. **[B]** Synced/OutOfSync vs Healthy/Degraded — difference? → Git-vs-live diff vs resource health checks; can be Synced AND Degraded.

### Intermediate
5. **[I]** Explain the Application CRD fields that matter. → source (repo/path/targetRevision/helm values), destination, project, syncPolicy (automated, prune, selfHeal, retry). (Recite Prep §5.3.)
6. **[I]** What do `prune` and `selfHeal` do — and the risk of each? → delete removed resources / revert manual changes; risk: pruning shared resources, selfHeal undoing emergency fixes (→ your conflict story: agreed emergency-change process).
7. **[I]** How do you order resources in a sync? → sync waves + phases (PreSync/Sync/PostSync hooks); CRDs wave -1, migration Job PreSync, app after.
8. **[I]** App-of-Apps vs ApplicationSet? → root app bootstraps child Applications (cluster bootstrap); ApplicationSet generates apps from generators (cluster/git/matrix) for many envs/clusters.
9. **[I]** How does ArgoCD render Helm charts — and why is `helm history` empty? → `helm template` under the hood, no release objects; history lives in Git.
10. **[I]** How do you do multi-tenancy in ArgoCD? → AppProjects restricting source repos, destination namespaces, resource kinds; RBAC per team.
11. **[I]** How do secrets work in a GitOps world? → never plaintext in Git: SOPS/SealedSecrets or (my choice) external references — Secrets Manager + CSI (Prep §12).

### Advanced / Scenario
12. **[S]** How do you roll back a bad deployment in GitOps — exact steps? → `git revert` the values bump → auto-sync (preferred, keeps history); emergency `argocd app rollback` + pause auto-sync + fix Git after. Time-to-mitigate story.
13. **[S]** An Application is stuck OutOfSync — debug path. → `app get` conditions → repo-server logs (template error?), controller RBAC for new CRD, failing hook Job, finalizers blocking prune.
14. **[S]** Someone kubectl-edited prod and selfHeal reverted their hotfix mid-incident — how did you handle the team conflict? → behavioral+technical: emergency process (pause auto-sync window / break-glass), then PR follow-up; "all changes via PR" as a feature.
15. **[A]** How did you bootstrap a brand-new cluster with ArgoCD? → install ArgoCD (Terraform helm_release or manifests) → root App-of-Apps → platform stack (ingress, monitoring, Falcon, Velero) → team apps. ArgoCD manages itself.
16. **[A]** ArgoCD vs Flux — compare. → both pull-based reconcilers; ArgoCD: UI, app-centric, AppProjects, great day-2 ops; Flux: GitOps toolkit CRDs, lighter. I ran ArgoCD at scale.
17. **[S]** Design GitOps repo structure for 10 teams × 3 environments. → deploy-config repo(s): charts/ + values-{env}.yaml per app, AppProjects per team, ApplicationSet per env; discuss mono-repo vs repo-per-team trade-offs.
18. **[I]** How does ArgoCD detect Git changes? → default 3-min polling; webhook for instant; reconciliation timeout for drift.

---

## 5. Helm (Prep §6)

1. **[B]** Why Helm over raw YAML? → templating across envs, packaging, versioned releases, rollback.
2. **[B]** Chart.yaml `version` vs `appVersion`? → chart packaging version vs application image version.
3. **[B]** Walk through chart structure. → Chart.yaml, values.yaml + env overrides, templates/, _helpers.tpl, charts/ deps. (Prep §6.2.)
4. **[I]** `helm template` vs `install` vs `upgrade --install`? → render-only / create release / idempotent CI pattern; add `--atomic --wait` for auto-rollback on failure.
5. **[I]** How do you roll pods when only a ConfigMap changes? → checksum/config annotation trick (sha256 of rendered configmap in pod template). (Interviewers LOVE this.)
6. **[I]** `include` vs `template`, and why `toYaml | nindent`? → include returns string (pipeable), template doesn't; nindent for correct YAML indentation of nested values.
7. **[I]** What are Helm hooks and a real use? → pre-install/pre-upgrade Jobs — DB migrations before app rollout; hook-delete-policy.
8. **[I]** How do you manage chart dependencies? → Chart.yaml dependencies + `helm dependency update`, condition flags to toggle subcharts.
9. **[A]** How do you test/validate charts in CI? → helm lint, `helm template | kubectl apply --dry-run=server`, unittest plugins, kubeconform.
10. **[S]** An app team's chart works in dev but breaks in prod — common causes? → values-prod overrides (resources, replicas, ingress hosts), missing prod secrets, quota limits, nodeSelector/tolerations mismatch.
11. **[S]** How did you standardize charts across teams? → shared library chart / scaffold with helpers (labels, probes, securityContext defaults), values schema (values.schema.json).

---

## 6. CI/CD & GitHub Actions (Prep §7)

1. **[B]** CI vs CD — where did you draw the line and why? → GHA = build/test/scan/push/bump; ArgoCD = deploy. Pipeline never runs kubectl against prod. (Say this sentence.)
2. **[B]** Workflow anatomy: triggers, jobs, steps, runners? → on: push/PR/schedule/workflow_call; jobs parallel by default, `needs` for ordering.
3. **[I]** How do you authenticate GitHub Actions to AWS WITHOUT stored keys? → OIDC: GH issues short-lived JWT → IAM role trusts token.actions.githubusercontent.com filtered by repo/branch claims → `configure-aws-credentials` assumes role. (Seniority signal — rehearse.)
4. **[I]** How did you implement environment promotion with approvals? → GH Environments: dev auto, prod requires reviewers; env-scoped secrets.
5. **[I]** Your resume: "reusable pipelines across 15+ apps" — how? → `workflow_call` reusable workflows + composite actions; app repos consume with inputs (image name, chart path).
6. **[I]** How do you speed up slow pipelines? → dependency + Docker layer caching, matrix parallelism, concurrency groups cancelling stale runs, self-hosted runners near ECR.
7. **[I]** What security scanning ran in your pipeline? → trivy image scan (fail on CRITICAL), SAST, helm lint/kubeconform, secret scanning; SBOM mention.
8. **[A]** How does the image tag get from CI into the cluster? → yq bump of values-{env}.yaml in deploy-config repo (commit/PR) → ArgoCD sync. Tag = git SHA for traceability.
9. **[S]** A deploy broke prod — trace the full recovery through your pipeline design. → alert → identify bad sync → `git revert` bump → ArgoCD rolls back → post-incident: add gate that would've caught it. Time yourself narrating.
10. **[S]** Design a pipeline for a new microservice from repo-create to prod. → scaffold from template repo, reusable workflow, ECR repo via Terraform, chart + Application CRD, env promotion. End-to-end in one answer = strong hire signal.
11. **[I]** Rolling vs blue-green vs canary — which did you use, and how would you add canary? → rolling via Deployments; canary via Argo Rollouts (analysis on Prometheus metrics) — name it as the natural next step.
12. **[B]** Git strategy questions: trunk-based vs GitFlow? PR hygiene? → trunk-based + short-lived branches for CD; protected main, required checks.

---

## 7. Observability — Prometheus / Grafana / Loki (Prep §8)

### Basics
1. **[B]** Three pillars of observability — and what each answers. → metrics (what/when), logs (why), traces (where in the call path).
2. **[B]** How does Prometheus collect metrics? → pull model, scrapes /metrics, K8s service discovery; push-gateway only for batch jobs.
3. **[B]** Counter vs gauge vs histogram? → monotonic (rate) / point-in-time / buckets (histogram_quantile for p99).
4. **[B]** What do node-exporter, kube-state-metrics, and cAdvisor each give you? → node OS metrics / object states (replicas, phases) / container cpu-mem. (People mix these up — you won't.)

### Intermediate
5. **[I]** What does the Prometheus Operator add? → ServiceMonitor/PodMonitor/PrometheusRule CRDs → monitoring-as-code, teams self-serve via GitOps.
6. **[I]** Write PromQL for: pod CPU vs requests; p99 latency; 5xx error ratio; crash-looping pods. → Prep §8.3 — practice writing these cold.
7. **[I]** Why `rate()` before `sum()` on counters? What's a sensible range window? → counters reset; rate handles it; window ≥ 2× scrape interval, commonly [5m].
8. **[I]** What does `for:` do in an alert rule and why does it matter? → condition must hold N min — anti-flapping.
9. **[I]** Explain Alertmanager grouping, inhibition, silences. → 1 notification per group not 40; NodeDown suppresses its pod alerts; maintenance silences.
10. **[I]** Your alert philosophy? → page on user-visible symptoms (errors, latency, saturation), actionable+urgent only; causes → tickets/dashboards; every alert links a runbook.
11. **[I]** Loki vs Elasticsearch? → label-only index (cheap, grep-style LogQL) vs full-text inverted index (powerful, heavy). I ran BOTH — pick by query needs/budget.
12. **[I]** Dashboards as code — how? → JSON in Git → ConfigMaps → Grafana sidecar loads; no click-ops; reviewable.

### Advanced / Scenario
13. **[S]** Resume: "cut time-to-detect" — how exactly? → before: users/tickets first; after: symptom alerts + platform dashboards + routed paging; give the mechanism + a number/story.
14. **[S]** Design monitoring for a brand-new multi-tenant cluster. → kube-prometheus-stack via ArgoCD, platform dashboards (API server, nodes, pods, PVCs), per-namespace RED, PrometheusRules in Git, Alertmanager routes per team label.
15. **[S]** An alert fires but the dashboard looks fine — what's wrong? → time-range/staleness, alert expr vs dashboard query mismatch, evaluation vs scrape interval, thanos/federation lag if used.
16. **[A]** Prometheus is OOMing / cardinality explosion — diagnose and fix. → top series by metric (`topk(10, count by (__name__)(...))`), drop high-cardinality labels (pod UID, path), recording rules, retention/remote-write.
17. **[A]** How do you monitor the monitoring? → meta-alerts: Prometheus up, Alertmanager reachable, dead-man's-switch (always-firing alert → external check).
18. **[I]** How did app teams onboard their custom metrics? → instrument (client lib) → expose /metrics → ServiceMonitor via their GitOps repo → grafana folder + alert rules PR.

---

## 8. ELK Stack + SLO/SLI/Error Budgets (Prep §9)

1. **[B]** Walk through your ELK pipeline. → Filebeat DaemonSet (adds K8s metadata) → Logstash (grok/json filters) → ES (datastreams, ILM) → Kibana → xMatters. (Prep §9.1 diagram.)
2. **[B]** Why push teams to structured JSON logging? → no grok fragility, queryable fields, cheaper parsing.
3. **[I]** What is ILM and how did you use it? → hot→warm→cold→delete tiers; cost control; retention per index/datastream.
4. **[I]** Shards and replicas — sizing basics? → shard = Lucene index unit; too many small shards = overhead; replicas = HA + read throughput.
5. **[I]** Define SLI, SLO, SLA — precisely, with your real example. → measurement / internal target / external contract; "99.5% of ArgoCD syncs complete successfully within 5 min over 30 days."
6. **[I]** What is an error budget and what does it CHANGE about how teams work? → 1−SLO = allowed badness; budget healthy → ship; burned → freeze + reliability work. "The mechanism that ends dev-vs-ops fights."
7. **[A]** Explain multi-window burn-rate alerting. → page at 14.4× burn over 1h AND 5m (fast), ticket at 3× over 6h (slow); avoids false pages and silent budget death. (Prep §9.2.)
8. **[S]** How did you pick SLIs for ArgoCD/EKS platform services? → user-journey based: sync success+latency, API server availability/latency; baseline first, then set achievable SLO.
9. **[S]** ES cluster is yellow/red — what do you check? → unassigned shards (`_cluster/allocation/explain`), disk watermarks, node loss, replica settings.
10. **[I]** How did xMatters fit in? → Kibana/Alertmanager connector → on-call schedules, escalation chains, ack-or-escalate.
11. **[I]** Logs vs metrics for alerting — when each? → metrics for thresholds/ratios (cheap, fast); log-based alerts for patterns (error signatures, security events).

---

## 9. Velero — Backup & DR (Prep §10)

1. **[B]** AWS backs up EKS's etcd — why did you still need Velero? → can't selectively restore YOUR workloads, no PV data, no cross-cluster migration.
2. **[B]** What does Velero back up and where? → K8s object JSON → S3 (backup storage location); volumes via CSI snapshots or file-system backup → snapshots/S3.
3. **[I]** CSI VolumeSnapshots vs file-system backup (Kopia/restic) — when each? → native EBS snapshot: fast, same-cloud; FSB: cross-storage/cross-cloud (on-prem→EKS), slower. Know BOTH.
4. **[I]** How did you schedule and retain backups? → Schedule CRDs via GitOps, cron + TTL; daily all-ns + hourly critical-ns; RPO = schedule frequency.
5. **[I]** How does Velero authenticate to S3/EBS? → IAM via Pod Identity/IRSA — no keys.
6. **[S]** Resume says "implemented and TESTED" — describe your restore validation drill. → quarterly restore to sandbox: object counts, PVC data checksum, app boots, certs/webhooks valid; measured RTO documented. (Prep §10.4 — the differentiator.)
7. **[S]** What broke during restore tests? (war stories) → old LB annotations spawning new LBs; ownerReferences to missing owners; CRD-before-CR ordering with operators; IRSA mappings cluster-specific on cross-cluster restore.
8. **[S]** Someone deleted a production namespace — exact recovery steps. → identify latest good backup (`backup describe --details`) → `restore create --from-backup` (optionally --namespace-mappings to stage) → validate data → RCA the deletion (RBAC gap?).
9. **[I]** Define RTO vs RPO and yours. → time-to-restore vs data-loss window; RPO 24h default / 1h critical; RTO = measured drill number — have one.
10. **[A]** How would you migrate a namespace from on-prem to EKS with Velero? → FSB backup (storage-agnostic) → restore with storageClass mapping ConfigMap, fix ingress/identity deltas, cutover DNS.
11. **[I]** How do you monitor backup health? → alert on failed/partial backups (velero metrics → Prometheus), backup age > RPO, node-agent pod health.

---

## 10. Kubernetes Security & CrowdStrike (Prep §11)

1. **[B]** Image scanning vs runtime security — why both? → CI scan catches known CVEs pre-deploy; runtime catches live behavior: miners, reverse shells, drift from image.
2. **[B]** How is Falcon deployed on K8s? → sensor DaemonSet (privileged, kernel visibility, covers all containers on node) + admission controller + protection agent → console. Via Helm through ArgoCD.
3. **[I]** The security tool itself needs privileged access — how do you scope that risk? → PSA exception ONLY for its namespace, documented, RBAC-limited, monitored. (Interviewers love this discussion.)
4. **[I]** How did you roll Falcon out across clusters safely? → staged dev→nonprod→prod, node overhead measured on Grafana before/after, detection-mode first → tune false positives → prevention mode.
5. **[I]** How do you monitor the sensor itself? → DaemonSet desired vs ready alert, version currency, console health.
6. **[S]** A pod is compromised — what limits the blast radius in your platform? → least-priv SA (no default token), NetworkPolicy egress deny, non-root + readOnlyRootFilesystem, seccomp, namespace isolation, Falcon detection → SOC. (Prep §11.3 checklist.)
7. **[I]** RBAC: Role vs ClusterRole, RoleBinding vs ClusterRoleBinding? → namespaced vs cluster-scoped; CRB of a Role? No — but RoleBinding CAN reference a ClusterRole (scoped grant of a reusable role).
8. **[I]** What is Pod Security Admission and its levels? → privileged/baseline/restricted namespace labels replacing PSP; enforce vs warn vs audit modes.
9. **[I]** Default K8s network posture and how you fixed it? → allow-all → default-deny NetworkPolicy per tenant namespace + explicit allows; needs CNI support.
10. **[A]** How would you detect crypto-mining in your cluster without Falcon? → CPU anomaly per namespace (Prometheus), egress to mining pools (NetPol logs/VPC flow logs), process drift (Falco as OSS alternative — name it).
11. **[B]** Why is base64 not encryption? → encoding, reversible, no key. (Weed-out question.)
12. **[I]** kube-bench / CIS — what did hardening actually change? → anonymous auth off, audit logs on, encryption at rest for secrets, restricted kubelet ports.

---

## 11. Secrets, Pod Identity & Storage (Prep §12)

### Secrets & identity
1. **[B]** Why aren't K8s Secrets enough for enterprise? → base64 in etcd, RBAC-wide visibility, no rotation/audit → external store (Secrets Manager: KMS, rotation, CloudTrail).
2. **[I]** IRSA vs EKS Pod Identity — compare deeply. → OIDC federation + per-cluster trust policy (breaks on rebuild) vs pod-identity-agent + association + generic principal reusable across clusters. (Prep §12.2 table — YOUR resume says Pod Identity; own this.)
3. **[I]** Trace the credential flow when a pod calls Secrets Manager. → SDK credential chain → node's pod-identity agent → exchanges projected SA token via EKS Auth → temp role creds. "No keys anywhere."
4. **[I]** How does the Secrets Store CSI driver + ASCP work? → SecretProviderClass CRD → mount at pod start using POD's IAM identity → secret as file; optional syncSecret for env vars. (Recite Prep §12.3 YAML.)
5. **[I]** How is least privilege enforced per app? → role policy scoped to `prod/payments/*` ARNs; different SA → AccessDenied (your negative test in Scenario 4).
6. **[I]** What happens when a secret rotates? → rotationPollInterval re-mounts file; app must re-read or restart; synced K8s Secret needs consumers restarted (reloader mention).
7. **[A]** CSI driver vs External Secrets Operator — trade-off and your choice? → ESO persists values as K8s Secrets (convenient, but back in etcd); CSI keeps them as mounted files — I chose CSI to minimize etcd exposure.

### Storage
8. **[B]** PV vs PVC vs StorageClass — and dynamic provisioning flow. → claim → SC provisioner creates volume → PV bound → kubelet mounts.
9. **[I]** Why `volumeBindingMode: WaitForFirstConsumer` on EBS? → EBS is AZ-bound; delay creation until pod scheduled → volume lands in pod's AZ. (Classic deadlock question.)
10. **[I]** ReclaimPolicy Delete vs Retain — when each, and how do you recover a Released PV? → Delete for ephemeral, Retain for precious; recover by new PV pointing at same volume ID.
11. **[S]** Pod stuck ContainerCreating with volume attach errors — debug. → describe events → wrong AZ? volume attached to dead node (force detach)? CSI controller/node pods healthy? IAM for CSI?
12. **[I]** RWO vs RWX — what does EBS give you and what if you need shared writes? → EBS = RWO; RWX → EFS CSI.
13. **[I]** How do you expand a PVC? → allowVolumeExpansion on SC → edit PVC size → online for gp3; can't shrink.
14. **[A]** StatefulSet + storage: what happens to PVCs when you scale down or delete? → PVCs retained by default (data safety) → your cleanup automation caught orphans (nice tie-in!).

---

## 12. Portainer & Multi-cluster Management (Prep §13)

1. **[B]** What is Portainer and why did your org use it? → multi-cluster UI + RBAC; scoped self-service for app teams without kubeconfigs; single pane for on-prem estate.
2. **[I]** How does the agent architecture work behind firewalls? → Edge agent connects OUTBOUND to server — no inbound holes to on-prem.
3. **[I]** How did you map access? → AD groups → Portainer teams → namespace-scoped permissions.
4. **[S]** Portainer lets people click-deploy — doesn't that break GitOps? → positioned as read/troubleshoot/RBAC layer for humans; deploys stayed ArgoCD; discuss guardrails. (Honest positioning = credibility.)
5. **[I]** Alternatives you'd consider? → Rancher, Lens, ArgoCD UI itself, k9s for CLI folks — why Portainer won for your mixed-skill teams.

---

## 13. OpenShift (Prep §14)

1. **[B]** OpenShift vs vanilla Kubernetes — top differences. → opinionated supported platform; Routes vs Ingress; SCCs restricted-by-default; BuildConfigs/S2I; Projects; oc CLI; Cluster Operators. (Prep §14.1 table.)
2. **[I]** What are SCCs and why did they break your workloads in the PoC? → SecurityContextConstraints assign random non-root UID; images expecting root/fixed UID fail → the #1 migration finding.
3. **[I]** Route vs Ingress? → Route = OpenShift-native L7 (HAProxy router, predates Ingress); conversion needed for migration.
4. **[S]** Walk me through your PoC and the recommendation you presented. → CRC locally → deployed real Helm charts → catalogued SCC failures, Route deltas, registry integration → findings: effort = image non-root compliance + manifest deltas; value = supported stack + security posture. (Complete story = Prep §14.2.)
5. **[I]** Does ArgoCD work on OpenShift? → yes — OpenShift GitOps IS ArgoCD; monitoring stack overlap considerations.
6. **[B]** What is CRC/OpenShift Local? → single-node OpenShift for workstations; PoC sizing ~4vCPU/12GB.

---

## 14. Python Automation (Prep §15)

1. **[B]** What did your cleanup tool do and what was the impact? → orphaned PVCs, completed/failed Jobs, 0-replica ReplicaSets across namespaces/clusters → 15+ hrs/week saved, EBS cost reclaimed, etcd bloat cut.
2. **[I]** Walk through the design — and the SAFETY rails. → dry-run default, `cleanup.io/skip` exclusion label, age thresholds, report-before-delete to Slack, minimal RBAC ServiceAccount, audit log. (Lead with safety — that's the senior answer.)
3. **[I]** How does the kubernetes Python client authenticate in-cluster vs locally? → load_incluster_config (SA token) vs load_kube_config; the try/except pattern.
4. **[I]** How did you find "orphaned" PVCs programmatically? → set of (claim, ns) mounted by any pod vs all PVCs, minus age threshold. (Sketch the code — Prep §15.2.)
5. **[I]** How was it deployed and run across clusters? → containerized CronJob per cluster with scoped Role; multi-cluster loop over kubeconfig contexts from CI.
6. **[S]** Your script deleted something it shouldn't have — what would you do / how do you prevent? → restore from Velero (nice cross-link!); prevention: dry-run review gate, exclusion labels, protected-namespace list, deletion audit.
7. **[I]** Other Python automation you've done? → boto3 idle/untagged resource reports, Prometheus API capacity reports, ArgoCD API health sweeps.
8. **[B]** Coding screen basics — be ready to write: parse a log file and count top-N error codes (dict + sort), call a REST API with retries, list pods via client lib. Practice each once.

---

## 15. Incident Management & SRE Practice (Prep §16)

1. **[B]** Walk through your incident lifecycle. → detect (alert/xMatters) → triage/SEV → MITIGATE FIRST → communicate cadence → resolve → blameless postmortem. (Prep §16.1.)
2. **[B]** Define MTTD, MTTA, MTTR. → detect / acknowledge / restore; know which your 40% improved (MTTR) and the mechanisms.
3. **[I]** What roles exist on a major incident bridge — which did you play? → Incident Commander (me), comms lead, ops/SME; one person ≠ all roles on SEV1.
4. **[I]** "Mitigate before you diagnose" — what does that mean in your GitOps world? → rollback = git revert first; root cause after service is healthy. Big chunk of the −40% MTTR.
5. **[I]** What made your RCAs effective? → blameless, timeline with timestamps, 5 Whys, action items with owners/dates tracked in Jira weekly.
6. **[S]** Tell me about your toughest production incident. → HAVE THIS REHEARSED with timeline + numbers (Prep §16.2 template if needed: OOMKill rollout → revert in ~10 min → PR resource-diff bot action item).
7. **[S]** You're paged at 3am for a service you don't own — first 10 minutes? → ack, assess user impact (dashboards), engage owning team via escalation, mitigate if runbook exists, comms; don't hero-debug alone.
8. **[I]** What is toil and how did you fight it? → manual/repetitive/automatable; measured & burned down — the Python cleanup = 15 hrs/wk toil eliminated.
9. **[I]** How did runbooks reduce MTTR concretely? → every alert links its runbook; Confluence culture — new joiners resolve incidents without tribal knowledge (resume line).
10. **[I]** Page vs ticket criteria? → urgent + actionable + user-impacting = page; else ticket/dashboard. Pager fatigue = real reliability risk.
11. **[S]** An exec demands root cause DURING the outage — how do you handle it? → comms lead shields, IC states "mitigation first, RCA follows by <date>"; cadence updates buy trust.
12. **[I]** How do error budgets connect to incident load? → repeated budget burn → freeze features, invest reliability; policy agreed BEFORE the argument happens.

---

## 16. Ansible & Config Management (Prep §17)

1. **[B]** Terraform vs Ansible — when each? → provisioning (declarative, state, immutable) vs configuration (agentless SSH, idempotent modules, no state). (Guaranteed question.)
2. **[B]** What is idempotency in Ansible? → rerun = no change unless drift; modules check state before acting.
3. **[I]** How did TF and Ansible work TOGETHER in your ITC role? → TF creates EC2 fleet → dynamic AWS EC2 inventory plugin → playbooks configure (packages, hardening, app config).
4. **[I]** What are handlers and why? → run once at end, only if notified by a changed task — e.g., reload nginx only when config actually changed.
5. **[I]** Roles structure and why use them? → tasks/handlers/templates/defaults/vars — reusable, shareable units.
6. **[I]** How do you manage secrets in Ansible? → ansible-vault encrypt, vault-id per env; never plaintext in group_vars.
7. **[I]** How do you dry-run? → `--check --diff`; caveats: some modules can't predict.
8. **[S]** A playbook works on one host, fails on another — debug approach. → `-vvv`, facts differences (`ansible -m setup`), OS family conditionals, package name variance.

---

## 17. Linux (Prep §18)

1. **[B]** SIGTERM vs SIGKILL — and the Kubernetes connection. → 15 graceful (trappable) vs 9 immediate; K8s: TERM → terminationGracePeriodSeconds → KILL. (Beautiful bridging answer — use it.)
2. **[B]** How do you check why a server is slow? → uptime (load vs cores) → top/vmstat (CPU vs iowait) → free -h → df -h && df -i → iostat -x → ss -tulpn. (Ordered method = senior.)
3. **[I]** What ARE containers, in Linux terms? → process + namespaces (pid/net/mnt/uts/ipc/user) + cgroups (limits — source of OOMKill) + union FS layers. "A container is just a Linux process wearing isolation." (THE senior signal answer.)
4. **[I]** Disk has free space but writes fail — what's going on? → inode exhaustion (`df -i`) — classic; also read-only remount after FS errors (dmesg).
5. **[I]** Where does OOMKilled actually come from? → kernel OOM killer within the cgroup memory limit; `dmesg -T | grep -i oom`; exit code 137 = 128+9.
6. **[I]** Explain load average properly. → runnable + uninterruptible (D-state, usually IO) tasks averaged 1/5/15m; compare against core count.
7. **[B]** Hard link vs symlink? → same inode vs pointer file; hardlink survives original deletion, can't cross filesystems.
8. **[I]** How do you debug a service on a K8s node? → systemctl status kubelet/containerd, journalctl -u kubelet --since "1h ago", dmesg, disk pressure paths (/var/lib/containerd).
9. **[I]** ndots:5 — what is it and why does it hurt K8s DNS? → resolv.conf tries search domains first for names with <5 dots → external lookups make 4+ queries; fix: FQDN with trailing dot or ndots tuning.
10. **[B]** One-liner: top 10 IPs from an access log. → `awk '{print $1}' access.log | sort | uniq -c | sort -rn | head`. (Practice typing it.)
11. **[I]** File permissions 750, suid, sticky bit? → rwxr-x---; run-as-owner; /tmp deletion protection.
12. **[I]** A process is in D state — what does that mean? → uninterruptible sleep, usually stuck IO (NFS, dying disk); can't be killed until IO returns.

---

## 18. Docker & Containers (related topic — always asked)

1. **[B]** Image vs container? → immutable layered template vs running instance with writable layer.
2. **[B]** What makes a good Dockerfile? → minimal base, multi-stage builds, layer-cache ordering (deps before src), non-root USER, .dockerignore, pinned versions.
3. **[I]** Multi-stage build — why and how? → build tools stay in stage 1; final image = runtime only → smaller, fewer CVEs; `COPY --from=build`.
4. **[I]** How do layers and caching work? → each instruction = layer; change invalidates downstream; order least→most volatile.
5. **[I]** Why run containers as non-root — and what breaks? → container escape blast radius; ports <1024, file ownership — ties to your OpenShift SCC findings!
6. **[B]** ENTRYPOINT vs CMD? → fixed executable vs default args (overridable).
7. **[I]** How does K8s run containers without Docker? → CRI → containerd directly; Docker shim removed 1.24; images unchanged (OCI standard).
8. **[I]** PID 1 problem in containers? → no default signal handling/zombie reaping → use exec form, tini/dumb-init, or proper handler — connects to graceful shutdown.

---

## 19. Networking & DNS (related topic)

1. **[B]** Walk through what happens when you hit https://app.example.com. → DNS → TCP → TLS handshake (SNI, cert) → LB → ingress → service → pod. (Have the K8s-flavored version ready.)
2. **[B]** TCP vs UDP — where does each show up in your platform? → TCP: apps, API server; UDP: DNS (CoreDNS!), some metrics.
3. **[I]** What layers do ALB vs NLB operate at, and when did you pick each? → L7 (host/path routing, TLS, WAF) vs L4 (raw TCP performance, static IPs); ALB via Ingress, NLB for non-HTTP.
4. **[I]** How does DNS resolution work inside a pod? → resolv.conf → CoreDNS service → cluster domain search list; svc.ns.svc.cluster.local.
5. **[I]** How would you debug intermittent connection timeouts pod→external API? → DNS first, then conntrack limits, NAT gateway port exhaustion, security groups/NetPol, tcpdump + curl -v from a debug pod.
6. **[B]** What is a CIDR? Size a /19 vs /24. → /19 = 8190 hosts, /24 = 254 — connects to VPC CNI IP planning.
7. **[I]** TLS termination options in your stack? → at ALB (ACM certs, simplest), at ingress controller, or e2e mTLS (service mesh mention).

---

## 20. Git & Collaboration (related topic)

1. **[B]** merge vs rebase — team policy? → merge preserves history, rebase linearizes; never rebase shared branches.
2. **[B]** How do you undo a bad commit already pushed? → `git revert` (safe, forward) not reset --force on shared branches — SAME principle as your GitOps rollbacks.
3. **[I]** Branch protection you enforced? → protected main, required status checks (lint/plan/tests), required reviewers, no force push.
4. **[I]** cherry-pick — a real use? → hotfix to release branch; mention trade-off vs reverting forward.
5. **[B]** `git fetch` vs `pull`? → download refs vs fetch+merge.

---

## 21. Architecture & System Design (Round 3 — whiteboard)

1. **[S]** Design the complete platform for a company moving 20 microservices to Kubernetes. → EKS multi-AZ (Terraform) → GitOps (ArgoCD, app-of-apps) → CI (GHA+OIDC) → observability (Prometheus+Loki, SLOs) → security (Falcon, Pod Identity, NetPol) → DR (Velero + drills). This is literally your resume as one diagram — practice drawing it in 5 minutes.
2. **[S]** Multi-environment strategy: how many clusters, how do changes promote? → cluster per env (or ns-per-env trade-off discussion), values-{env}.yaml promotion via PR + approval gates, ApplicationSets.
3. **[S]** How would you design for a region failure? → multi-region trade-offs: active-passive with Velero restore + DNS failover (your world) vs active-active (data replication cost); state is the hard part.
4. **[S]** A company has click-ops AWS + kubectl-apply deployments — 90-day migration plan to your model. → import to Terraform incrementally, GitOps one app at a time (ArgoCD adopt-existing), observability first (baseline), no big-bang.
5. **[S]** Where are the single points of failure in YOUR platform design, honestly? → ArgoCD down (deploys stop, apps keep running!), Prometheus gap (alerting blind), state bucket, DNS; mitigations for each. (Self-critique = strong senior signal.)
6. **[S]** Scale: 5 clusters → 50. What breaks first? → per-cluster ArgoCD → hub-spoke or ApplicationSets; dashboard sprawl → federated/central observability (Thanos/Mimir mention); IAM trust per cluster → Pod Identity advantage; config drift → stronger templating.
7. **[S]** Cost review time: cut the platform bill 30% without hurting reliability. → requests right-sizing from Prometheus data, Spot for stateless, Karpenter consolidation, gp3, log ILM/retention, orphan cleanup (your tool), decommission (your process).

---

## 22. Resume-specific "Explain this line" questions

They WILL read lines aloud and say "explain exactly how." One-line ammunition per bullet:

| Resume line | They'll ask | Your anchor |
|---|---|---|
| "Multi-tenant Kubernetes platforms" | How was tenancy enforced? | Prep §2.6: ns+quota+RBAC+NetPol+tainted pools+AppProjects |
| "Automated full lifecycle with Terraform" | Show the structure; what's hard about destroy? | Prep §4.2–4.3; ENI/LB war story |
| "Retired legacy on-prem clusters, no disruption" | Exact staging? | inventory→sign-off→drain→backup→destroy→verify |
| "Cut time-to-detect" | Before/after mechanism? | symptom alerts + dashboards + routed paging |
| "CrowdStrike across clusters" | Deployment model + rollout? | DaemonSet via ArgoCD, staged, detection→prevention |
| "Implemented and tested Velero" | How TESTED? | quarterly sandbox restores, checksums, measured RTO |
| "Portainer + ArgoCD syncs, rollbacks" | A real rollback you did? | git revert flow, emergency app rollback caveat |
| "OpenShift PoC, presented findings" | What did you find? | SCC/non-root #1, Routes delta, supported-stack value |
| "Secrets Manager, Pod Identity, EBS CSI" | Trace a secret into a pod | Prep §12.3 flow; least-priv negative test |
| "SLOs/SLIs, xMatters, runbooks" | Define your actual SLO | ArgoCD sync 99.5%/5min/30d + burn-rate alerts |
| "Deploy time −60%, 5 EKS environments" | −60% from what mechanism? | self-service reusable pipelines + GitOps promotion vs manual/ticketed deploys |
| "Python cleanup, 15 hrs/week" | Show me the logic | orphan detection sets + safety rails (Prep §15.2) |
| "MTTR −40%" | What specifically changed? | mitigate-first + runbook links + routing + GitOps revert |
| "Deployment failures −75% across 15+ apps" | What checks? | reusable workflow gates: lint, scan, dry-run, smoke tests |
| "Provisioning days → hours" | Module design? | versioned TF modules + Ansible dynamic inventory |

Rule: every number gets a MECHANISM. "60% because deploys went from ticket+manual-runbook (~half a day) to merge+auto-sync (~30 min)."

---

## 23. Behavioral (STAR — prepare ONE polished story each)

1. Toughest production incident you led. (Timeline, your role as IC, numbers.)
2. The decommissioning project — risk, stakeholders, zero-disruption outcome.
3. A disagreement with an app team (selfHeal vs hotfix) — how you reached the emergency-change compromise.
4. Automation with measurable impact (cleanup tool: problem → safety-first design → 15 hrs/wk).
5. A mistake you made and what changed after. (Aggressive alert thresholds → pager fatigue → burn-rate redesign works well.)
6. Learning something fast under pressure (OpenShift PoC from zero → stakeholder presentation).
7. Influencing without authority (pushing teams to JSON logging / GitOps adoption).
8. Prioritization under fire (feature deploy request during error-budget burn — how the policy decided, not you).
9. Mentoring/onboarding (runbook culture reducing tribal knowledge — resume line).
10. Why are you leaving / why this company? (Growth framing, never negativity — prepare per company.)

**STAR discipline**: Situation 15s → Task 10s → Action 60s (say "I", not "we", for YOUR actions) → Result 15s with a number.

---

## 24. Questions YOU ask the interviewer (pick 3–4)

Signal seniority with platform-shaped questions:
1. "What does your deploy path look like today — who can ship to prod, and how long does it take?"
2. "How do you handle on-call — rotation size, page volume per week, and is there an error-budget policy?"
3. "What's the biggest reliability incident of the last year, and what changed after it?"
4. "Is infrastructure fully in Terraform/GitOps, or is that part of the roadmap I'd own?"
5. "How do platform and app teams split responsibility for Kubernetes resources?"
6. "What would success look like for this role in the first 6 months?"

---

## 25. Mock-interview drill plan (final week)

| Day | Drill |
|---|---|
| 1 | Sections 1–2 (K8s+EKS): answer every [B]/[I] out loud; whiteboard the architecture twice |
| 2 | Sections 3–5 (TF, ArgoCD, Helm): recite the Application CRD + decommission flow from memory |
| 3 | Sections 6–8 (CI/CD + observability): write the 4 PromQL queries cold; narrate OIDC flow |
| 4 | Sections 9–11 (Velero, security, secrets): trace secret-to-pod and backup-restore flows unaided |
| 5 | Sections 12–17 (Portainer→Linux): rapid-fire, 30s each |
| 6 | Sections 21–23: two full system designs on paper + rehearse all 10 STAR stories out loud |
| 7 | Full mock: have someone (or an AI) fire random questions from this bank for 60 minutes |

**Red flags to avoid in answers**: "we" with no "I" · tool name-dropping without mechanism · numbers without causes · trashing past employers · "I'd Google it" without a reasoning attempt first.

*Every question here maps back to something you actually did. Confidence = mechanism + story + number.*

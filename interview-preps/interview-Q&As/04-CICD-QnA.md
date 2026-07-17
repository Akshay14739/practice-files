# CI/CD Interview Q&A — GitHub Actions, Jenkins, Git, Helm, ArgoCD/GitOps

Real questions from Akshay's past interviews (HDFC, Trianz, Accion, Pure Storage, PwC, Shell, Barclays, Virtusa, GlobalLogic, HCL, HTC, Persistent).
Each entry keeps the faithful transcript answer, then an authoritative correct answer plus a runnable snippet. WRONG/PARTIAL answers come first in each section so the gaps are obvious. Weak spots flagged with ⚠️.

---

# 1. CI/CD Concepts & Pipeline Flow

## Q1. A release went to Dev, Integration and UAT all at once and caused an incident — how did a bad release reach all environments, and how do you prevent it?
**Asked in:** HDFC  |  **My performance:** Partial → Correct

**My answer (from transcript):**
Best practice was Dev first, then Integration, then UAT. The app team deployed to all three at the same time, which triggered multiple alerts and became an incident. Setup was a Helm repo integrated into CI/CD — a parent chart with a sub-chart per environment, each with its own values; a change to an environment's values triggers a deploy to that environment. Production had CODEOWNERS + an RC/change process; the lower three did not, so the app team updated all three at once. After the incident, architects enforced one-environment-at-a-time deploys.

**✅ Correct answer:**
The root cause is a missing *promotion gate* between environments. Environments must be strictly ordered (Dev → Integration → UAT → Prod), and promotion to the next stage must be blocked until the previous one is verified. Fixes: (1) put every non-prod environment behind a protected deployment `environment` with required reviewers and/or a wait timer, exactly like prod; (2) make promotion an explicit action (a PR that bumps the image tag in the *next* environment's `values.yaml`, or a `workflow_dispatch`/`needs:` dependency), never a fan-out that can touch all envs from one commit; (3) add `concurrency` groups so overlapping deploys serialize; (4) add post-deploy health/smoke checks so a bad Dev deploy fails the promotion instead of propagating. The real defect was that lower environments had *no* gate — guardrails must apply everywhere, not only prod.

```yaml
# .github/workflows/promote.yml — ordered, gated promotion (no fan-out)
name: promote
on: { workflow_dispatch: { inputs: { image_tag: { required: true } } } }
jobs:
  deploy-dev:
    environment: dev
    runs-on: ubuntu-latest
    steps: [{ run: "make deploy ENV=dev TAG=${{ inputs.image_tag }}" }]
  deploy-integration:
    needs: deploy-dev            # cannot start until dev succeeded
    environment: integration     # protected env -> requires reviewer
    runs-on: ubuntu-latest
    steps: [{ run: "make deploy ENV=integration TAG=${{ inputs.image_tag }}" }]
  deploy-uat:
    needs: deploy-integration
    environment: uat
    runs-on: ubuntu-latest
    steps: [{ run: "make deploy ENV=uat TAG=${{ inputs.image_tag }}" }]
```

---

## Q2. I'm a new developer who wants a Node/TypeScript project deployed to AWS Lambda — how would your IDP/template help me self-serve?
**Asked in:** Virtusa  |  **My performance:** Vague

**My answer (from transcript):**
Initially misread it as onboarding a Lambda onto Kubernetes. Then said they'd integrate open-source Backstage into their AWS accounts, customize the TypeScript templates to connect to AWS Lambda, and provide a UI. Interviewer redirected; the answer stayed abstract without a concrete self-service flow.

**✅ Correct answer:**
A self-service flow should be describable end-to-end without the platform team touching anything. Concretely: the developer opens the IDP portal (Backstage), picks the **"Node Lambda (TypeScript)"** software template, fills a form (service name, owner, runtime, region). Backstage's **Scaffolder** then: (1) renders a new Git repo from a cookiecutter/skeleton (handler code, `package.json`, IaC — SAM/CDK/Terraform for the Lambda + API Gateway + IAM), (2) registers a `catalog-info.yaml` so the service appears in the catalog with ownership, (3) wires the CI/CD (GitHub Actions workflow that builds, tests, and `sam deploy`/`cdk deploy` via OIDC), and (4) creates the dev environment. The developer just pushes code; promotion to higher envs is a gated PR. The key idea I missed: the template *generates a repo + pipeline + infra*, it is not "put a Lambda on Kubernetes."

```yaml
# Backstage software template (catalog: Template) — self-service scaffold
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata: { name: node-lambda-ts, title: "Node Lambda (TypeScript)" }
spec:
  parameters:
    - title: Service
      properties:
        name: { type: string }
        region: { type: string, default: us-east-1 }
  steps:
    - id: fetch
      action: fetch:template          # render skeleton (handler + SAM/CDK + CI)
      input: { url: ./skeleton, values: { name: "${{ parameters.name }}" } }
    - id: publish
      action: publish:github          # create the repo
      input: { repoUrl: "github.com?owner=org&repo=${{ parameters.name }}" }
    - id: register
      action: catalog:register        # add to Backstage catalog
      input: { catalogInfoUrl: ".../catalog-info.yaml" }
```

---

## Q3. Was all the DevOps handled by an IDP tool, and did you build the templates/IDP or just manage them?
**Asked in:** Virtusa  |  **My performance:** Partial

**My answer (from transcript):**
No dedicated IDP tool as such — everything was done via GitHub repository templates with pre-existing tools already integrated (ArgoCD, SonarQube, Veracode). Mostly managed the existing platform and helped app teams, but did a PoC integrating **Backstage** into the "golden path" platform; it was about to take off but I left the company. It was moving from GitHub-templates toward a UI-based IDP before leadership paused it.

**✅ Correct answer:**
Be precise about the maturity ladder: **golden-path GitHub repo templates + org-level reusable workflows = a "platform," but not yet an IDP.** A true Internal Developer Platform adds a self-service *interface* (portal or CLI), a *service catalog* with ownership/metadata, *scorecards*, and *golden paths* as first-class scaffolder actions — Backstage is the common OSS choice. Framing: "We had a code-template-driven platform (golden path) that standardized CI/CD, security scanning and GitOps; I ran/operated it and onboarded teams, and I ran a PoC to add Backstage as the self-service UI layer on top." That cleanly separates *building the platform* from *operating it* and shows you know what "IDP" actually means.

```yaml
# catalog-info.yaml — the metadata that turns a repo into a catalog entry
apiVersion: backstage.io/v1alpha1
kind: Component
metadata: { name: payments-api, annotations: { github.com/project-slug: org/payments-api } }
spec: { type: service, lifecycle: production, owner: team-payments, system: payments }
```

---

## Q4. What is a deployment pipeline and how is it different from a CI pipeline?
**Asked in:** PwC-1  |  **My performance:** Correct

**My answer (from transcript):**
Framed the deployment pipeline as the GitOps approach. Previously the whole CI/CD ran from GitHub Actions; moving to GitOps uses a reconciliation loop (ArgoCD) that constantly compares current state (cluster) vs desired state (repo) and auto-deploys so both match. Production adds approval gates via CODEOWNERS and an RCA process.

**✅ Correct answer:**
**CI (Continuous Integration)** validates a *code change*: it builds, unit/integration tests, scans (SAST/DAST/SBOM), and produces a versioned, immutable artifact (a container image pushed to a registry). Its output is "this commit produces a good artifact." **CD (the deployment/delivery pipeline)** takes that artifact and *promotes it through environments* to running infrastructure, with gates, approvals, health checks and rollback. With **GitOps** the CD half is *pull-based*: CI only updates a desired-state manifest in Git (the image tag), and an in-cluster agent (ArgoCD) reconciles the cluster to Git. So CI = "is the artifact good?", CD = "get the right artifact safely running everywhere." GitOps is one *implementation* of CD, not a synonym for it.

```yaml
# CI produces the artifact; CD (ArgoCD) reconciles it. Two distinct stages.
# --- CI job (push-based): build + scan + push, then bump desired state ---
- run: docker build -t $ECR/app:${{ github.sha }} .
- run: docker push $ECR/app:${{ github.sha }}
- run: yq -i '.image.tag="${{ github.sha }}"' env/dev/values.yaml   # commit to Git
# --- CD (pull-based): ArgoCD Application watches Git and syncs the cluster ---
# spec.source.path=env/dev  spec.syncPolicy.automated={prune,selfHeal}
```

---

## Q5. What is the purpose of a staging environment in a CI/CD pipeline?
**Asked in:** PwC-1  |  **My performance:** Correct

**My answer (from transcript):**
Treat staging as a pre-production environment that replicates production, where you run load testing and security testing (SQL injection, DDoS, load tests). Once staging is good, you promote to production.

**✅ Correct answer:**
Staging is a production-like environment (same topology, config shape, data volume, and ideally the *exact same immutable image* you'll ship to prod) used as the final gate before release. It's where you run the tests you can't safely run in prod against the *real* deployable: end-to-end/integration tests, performance/load and soak tests, security tests (DAST, pen-test-style checks), DB migration dry-runs, and smoke tests. Its purpose is to catch environment- and integration-level failures (config drift, capacity, migration issues) that unit tests can't. The golden rule: **promote the same artifact you validated in staging — do not rebuild for prod**, or you invalidate the test.

```yaml
# Run smoke + load against staging before allowing prod promotion
staging-verify:
  environment: staging
  steps:
    - run: helm upgrade --install app ./chart -f env/staging/values.yaml --wait
    - run: ./smoke.sh https://staging.app.internal        # health / critical path
    - run: k6 run --vus 200 --duration 5m load-test.js      # load / soak
```

---

## Q6. What is the purpose of deploying to Dev and Integration first — why not go straight to QA/Prod?
**Asked in:** HCL  |  **My performance:** Correct

**My answer (from transcript):**
In Dev it's just deployment and testing — checking whether the app deploys and works as expected. In Integration they do load testing, threat analysis, and another round of testing (three testings total), then promote to production.

**✅ Correct answer:**
Each lower environment de-risks a *different class* of failure before the change is expensive to fix. **Dev** proves the artifact even builds and boots (deploys cleanly, config resolves, container starts, basic functionality). **Integration** proves it works *with its dependencies* — other microservices, databases, queues, third-party APIs — plus load, security/threat scanning and contract tests. Only after those pass do you promote the *same image* upward, so QA/Prod see a change that already survived deployability + integration + performance gates. Skipping straight to prod means a bad build takes down customers instead of an empty dev cluster.

```bash
# Progressive gates: each stage must be green before promotion advances
deploy dev        && smoke dev          || exit 1   # boots & basic health
deploy integration && integration-tests && load-test || exit 1  # deps + perf
promote-to qa                                       # same artifact moves up
```

---

## Q7. Walk me through the flow of your CI/CD pipeline, end to end, all stages.
**Asked in:** Persistent, Accion-1, Accion-2, Barclays, Trianz-K8s, HCL  |  **My performance:** Correct

**My answer (from transcript):**
GitOps: CI by GitHub Actions, CD by ArgoCD. On commit/merge to main the CI runs unit testing, SAST static analysis, code-vulnerability checks (SonarQube), builds/compiles the image, runs DAST (Veracode), and pushes to ECR. Tools: pre-commit, Checkov, SonarQube, Veracode, Trivy. When the image tag changes, ArgoCD detects it, pulls from the config repo/ECR, and deploys to the target EKS cluster. App teams use a GitHub repo template with prebuilt pipelines where they add Dockerfile, env vars and secrets.

**✅ Correct answer:**
Solid answer — tighten the ordering and the CI/CD boundary. Canonical GitOps flow:
1. **PR opened** → CI runs on the PR: lint, pre-commit hooks, unit tests, SAST (SonarQube), IaC scan (Checkov), dependency scan (Dependabot/Trivy). Branch protection blocks merge until green + required reviews.
2. **Merge to main** → build the **immutable image** tagged by commit SHA (and/or semver), scan the image (Trivy) and the running app (Veracode DAST), generate an SBOM, sign the image (cosign), **push to ECR**.
3. **Update desired state** → CI writes the new tag into the config repo's `values.yaml` (this is the CI→CD handoff — the only thing that "deploys" is a Git commit).
4. **CD (ArgoCD)** → reconciliation loop sees the changed tag, pulls that image from ECR, and syncs it to the target EKS cluster via Helm; self-heal/prune keep the cluster == Git.
5. **Verify + gate** → post-sync smoke/health checks; prod additionally requires CODEOWNERS/Jira approval before sync.
Key point interviewers look for: **CI ends at "artifact pushed + desired state committed"; CD is the pull-based reconcile.**

```yaml
name: ci
on: { pull_request: {}, push: { branches: [main] } }
jobs:
  test:                      # runs on PR: fail fast before build
    steps: [{ run: pre-commit run -a }, { run: make unit }, { run: sonar-scanner }]
  build-and-ship:            # runs on merge to main
    if: github.ref == 'refs/heads/main'
    needs: test
    steps:
      - run: docker build -t $ECR/app:${{ github.sha }} .
      - run: trivy image --exit-code 1 $ECR/app:${{ github.sha }}
      - run: docker push $ECR/app:${{ github.sha }}
      - run: cosign sign --yes $ECR/app:${{ github.sha }}
      - run: yq -i '.image.tag="${{ github.sha }}"' env/dev/values.yaml && git commit -am "bump dev" && git push
```

---

## Q8. Describe a deployment failure that changed your approach.
**Asked in:** Shell-2  |  **My performance:** Correct

**My answer (from transcript):**
Junior engineers (2–3 yrs) promoting apps to production were triggering many P1/P2 incidents. I introduced a CODEOWNERS approval guardrail in the CD pipeline so only the app team's manager or architect could approve merges to the production main branch, which drastically reduced production deployment failures. Learned it's a merger of process and tooling.

**✅ Correct answer:**
Good story — strengthen it by naming the layered controls, since "one approver" is a single point of failure. The durable fix combines: (1) **CODEOWNERS** so changes to prod paths require named approvers; (2) **protected `environment`** in GitHub Actions with *required reviewers* so even a merged commit pauses before prod deploy; (3) **branch protection** requiring ≥1–2 reviews + green checks; (4) a **change record** (Jira/CAB) linked to the deploy; and (5) automated **post-deploy verification + rollback** so a bad approval still self-corrects. Lesson framing interviewers like: *guardrails, not gates* — make the safe path the easy path (templates, required reviewers) rather than relying on humans to be careful.

```
# CODEOWNERS — merges touching prod manifests require the platform leads
/env/production/**   @org/platform-leads @org/app-architects
/charts/**           @org/platform-leads
```

---

## Q9. Describe the architecture of one application you're comfortable with and how it behaves.
**Asked in:** Virtusa  |  **My performance:** Correct

**My answer (from transcript):**
A .NET application deployed via an in-built CI/CD GitOps template with all platform tools integrated (ArgoCD, SonarQube, Veracode). App teams use the template to onboard; the initial image was built with semantic versioning, and for later versions app teams provide the tag; on update ArgoCD picks it up and deploys to the target Kubernetes cluster.

**✅ Correct answer:**
Answer in layers: **app tier** (.NET service, containerized, stateless, horizontally scaled behind a Service/Ingress), **config/state** (ConfigMaps + secrets via External Secrets/Infisical, DB/cache as managed services), **delivery** (golden-path template → GitHub Actions CI → ECR → ArgoCD → EKS via Helm), and **operability** (HPA, readiness/liveness probes, resource requests/limits, PodDisruptionBudget, and observability). The behaviour worth calling out: it's **immutable + declarative** — every change is a new image tag committed to Git, and ArgoCD reconciles the cluster to match, so the running state is always traceable back to a commit.

```yaml
# The app's runtime contract that makes "how it behaves" predictable
spec:
  replicas: 3
  containers:
    - name: dotnet-api
      image: <ECR>/payments:1.4.2
      readinessProbe: { httpGet: { path: /healthz, port: 8080 } }
      livenessProbe:  { httpGet: { path: /healthz, port: 8080 } }
      resources: { requests: { cpu: 250m, memory: 256Mi }, limits: { memory: 512Mi } }
```

---

# 2. GitHub Actions

## Q10. How does the pipeline authenticate with your container registry (ECR)?
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
Images are in ECR; authentication via AWS IAM roles and secrets stored in GitHub environments/secrets at the org level (not repo level). Each pipeline run fetches the secrets from GitHub and talks to ECR.

**✅ Correct answer:**
The modern, correct answer is **OIDC federation — no long-lived AWS keys stored in GitHub at all.** GitHub Actions issues a short-lived OIDC token; you configure an IAM role with a trust policy that trusts GitHub's OIDC provider (scoped to your org/repo/branch), and `aws-actions/configure-aws-credentials` exchanges the token for temporary STS credentials. Then `aws ecr get-login-password | docker login` (or `aws-actions/amazon-ecr-login`) authenticates Docker to ECR. Storing static `AWS_ACCESS_KEY_ID`/`SECRET` in org secrets (what I described) works but is the legacy pattern — it's a standing credential to rotate and leak. Lead with OIDC and mention least-privilege IAM + repo/branch-scoped trust.

```yaml
permissions: { id-token: write, contents: read }   # required for OIDC
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::1234567890:role/gha-ecr-push
      aws-region: us-east-1                          # NO stored keys
  - uses: aws-actions/amazon-ecr-login@v2            # docker login to ECR
  - run: docker push $ECR/app:${{ github.sha }}
```

---

## Q11. Instead of running Terraform from the CLI, could you run it in a GitHub Actions pipeline on push — do you do that?
**Asked in:** HCL  |  **My performance:** Partial

**My answer (from transcript):**
Yes, correct — a PoC was in place; implementation was ~50–60% completed for the dev environment when I left. The CI/CD pipeline for Terraform scripts was in progress.

**✅ Correct answer:**
Yes — the standard pattern is a **plan-on-PR / apply-on-merge** Terraform pipeline. On PR: `terraform fmt -check`, `validate`, `plan`, and post the plan as a PR comment plus a Checkov/tfsec scan; nothing is applied. On merge to main (behind a protected `environment` with an approver): `terraform apply` the saved plan. Critical details: **remote state** (S3 + DynamoDB lock) so runs don't collide, **OIDC** for cloud auth (no static keys), a **saved plan artifact** so apply runs exactly what was reviewed, and `concurrency` to serialize. This is how you avoid the "someone ran apply from their laptop with stale state" problem.

```yaml
on: { pull_request: {}, push: { branches: [main] } }
concurrency: terraform-${{ github.ref }}          # serialize state changes
jobs:
  plan:
    steps:
      - run: terraform init && terraform validate
      - run: terraform plan -out=tf.plan          # PR shows the plan
  apply:
    if: github.ref == 'refs/heads/main'
    needs: plan
    environment: infra-prod                        # requires approval
    steps: [{ run: terraform apply -auto-approve tf.plan }]
```

---

## Q12. In GitHub Actions, where do you define the environment parameters/secrets needed to run the pipeline?
**Asked in:** Trianz, HDFC  |  **My performance:** Correct

**My answer (from transcript):**
Stored in GitHub environment variables/secrets at the org level, which only 2–3 people can access.

**✅ Correct answer:**
Three scopes, chosen deliberately: **Organization secrets** (shared across repos, e.g. a registry endpoint) with repo-access policies; **Repository secrets** (single repo); and **Environment secrets** (bound to a deployment `environment` like `prod`, and only exposed to jobs targeting that environment — plus you can require reviewers/wait timers). Non-sensitive config goes in `vars`, sensitive in `secrets`; both are masked in logs. Best practice: put *deployment* credentials in **environment** secrets (so prod creds are unreachable from a dev job), prefer **OIDC** over stored cloud keys, and pull app secrets at runtime from a manager (Vault/Infisical/External Secrets) rather than duplicating them in GitHub.

```yaml
jobs:
  deploy:
    environment: production          # binds prod-scoped secrets to this job only
    steps:
      - run: ./deploy.sh
        env:
          API_TOKEN: ${{ secrets.PROD_API_TOKEN }}   # environment secret
          REGION:    ${{ vars.AWS_REGION }}          # non-secret variable
```

---

## Q13. If a GitHub Actions pipeline fails after merging a PR, where do you start troubleshooting, and from which step?
**Asked in:** Accion-2, Persistent  |  **My performance:** Correct

**My answer (from transcript):**
Once merged the CI/CD triggers; on failure, go to the **Actions** tab, find which step failed, and read that step's logs. Common issues: wrong image tag versions, ImagePullBackOff, application config issues, wrong Dockerfile configs, missing dependencies.

**✅ Correct answer:**
Good instinct. Structure it: (1) open the failed run → the failed **job** → the red **step** (steps run top-down, so the first red step is the cause; later failures are usually downstream). (2) Read that step's log; enable step-debug (`ACTIONS_STEP_DEBUG=true`) for verbose output. (3) Classify: *build/test* failure (code/deps/Dockerfile), *auth* failure (OIDC/registry login), *deploy* failure (ImagePullBackOff = tag/registry/permission mismatch; CrashLoopBackOff = app/config; OOMKilled = resources). (4) Reproduce locally where possible (`act`, or run the same docker/helm command). (5) Fix forward via a new PR — never edit prod manually — and for flaky infra add retries. The discriminator interviewers want: **read the log first, don't blind-rerun.**

```bash
gh run list --workflow=ci.yml --limit 5              # find the failed run
gh run view <run-id> --log-failed                    # jump straight to failed steps
# ImagePullBackOff during CD? verify the tag actually exists in the registry:
aws ecr describe-images --repository-name app --image-ids imageTag=$SHA
```

---

## Q14. Would you have the team rerun a failed pipeline, or troubleshoot first?
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
It depends on the logs. If it's an image issue, rerunning ends with the same problem, so find root cause first. But transient cases (e.g., ECR connection timing out) can be fixed by a rerun. In most cases, look at the error log first.

**✅ Correct answer:**
Exactly right — decide by **failure class, not reflex**. *Deterministic* failures (compile error, test failure, wrong tag, bad config, permission denied) will fail identically on rerun — investigate. *Transient/infra* failures (registry/network timeout, runner eviction, rate limit, flaky external dependency) are legitimate rerun candidates. Best practice is to make the pipeline *tell you which it is*: build retries only around network I/O (not around tests, which would hide real bugs), and treat "rerun made it pass" flakiness as a bug to fix, not a workflow. Blind reruns waste minutes and can mask a real regression.

```yaml
# Retry only the flaky network step, not the whole job (don't mask real failures)
- name: push image (network-flaky)
  uses: nick-fields/retry@v3
  with: { max_attempts: 3, timeout_minutes: 5, retry_wait_seconds: 15,
          command: "docker push $ECR/app:${{ github.sha }}" }
```

---

## Q15. You said you made a pipeline reusable — what made it reusable?
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
The Terraform + Infisical integration. Every app stores its secret in Terraform and onboards its Terraform directory into the org repo, then references that path in its CI/CD. My colleague and I built a Terraform module for Infisical for the platform, with a separate Terraform file per app; on PR merge the pipeline runs the Terraform resources and onboards the app.

**✅ Correct answer:**
What you described is *reusable infrastructure code* (a parametrized Terraform module) — good, but the GitHub Actions-native mechanisms are: **reusable workflows** (`on: workflow_call`) that a repo calls with `uses: org/repo/.github/workflows/ci.yml@v1` and passes `inputs`/`secrets`; and **composite actions** for reusable *step* sequences. Reusability principles: parametrize everything (image name, env, region) as inputs, pin to a version/tag, centralize the pipeline in one place so 15 apps inherit fixes at once, and keep app repos thin (just a Dockerfile + values). So the full answer is "reusable Terraform modules *for secrets/infra* **plus** a centralized reusable GitHub Actions workflow that every app repo calls."

```yaml
# Central reusable workflow (org/.github/workflows/ci.yml)
on: { workflow_call: { inputs: { app: { required: true, type: string } },
                       secrets: { ECR_ROLE: { required: true } } } }
# App repo consumes it — the entire pipeline is one line:
jobs:
  build:
    uses: org/.github/workflows/ci.yml@v1
    with: { app: payments-api }
    secrets: { ECR_ROLE: ${{ secrets.ECR_ROLE }} }
```

---

## Q16. Was the build triggered on PR opened or merged, and how do you stop a wrong PR from being merged?
**Asked in:** Accion-1  |  **My performance:** Correct

**My answer (from transcript):**
Org-level policy requiring 2–3 approvals from leads/architects before merge to main. Engineers raise PRs, seniors review and approve, then merge; on merge the approval gates and tests run and only then is it merged.

**✅ Correct answer:**
Clarify the timing: **CI validation runs on `pull_request` (before merge)** — that's the whole point, so a broken change never reaches main. **CD (build image → push → deploy) runs on `push` to main (after merge).** A wrong PR is stopped by **branch protection**: require status checks to pass, require N approvals, require CODEOWNERS review for sensitive paths, dismiss stale approvals on new commits, require branches up-to-date, and forbid direct pushes to main. (Your description had the tests running "on merge," which is backwards — they must run on the PR to be a gate.)

```yaml
on:
  pull_request: { branches: [main] }   # CI gate BEFORE merge
  push:         { branches: [main] }   # CD AFTER merge
jobs:
  ci:  { if: github.event_name == 'pull_request', steps: [{ run: make test }] }
  cd:  { if: github.event_name == 'push',         steps: [{ run: make build-push-deploy }] }
```

---

## Q17. Scenario — deploy the whole infra + apps into a customer's AWS account, with no communication between your account and theirs; how do you get the Docker image into their cluster?
**Asked in:** Trianz-K8s  |  **My performance:** Partial

**My answer (from transcript):**
Deploy the entire infra and apps into the customer's AWS account per their request; make sure K8s components are running, then run GitHub Actions with the customer code base on their cluster. Set env variables for the target ECR registries, semantic versioning, and target K8s/Git environment. With these top-level configs we can provision and test. (Didn't clearly solve cross-account ECR / cross-account access.)

**✅ Correct answer:**
If the two accounts genuinely can't talk, the image must live **in the customer's account** — you can't have their pods pull from your private ECR without granting cross-account access. Options: (1) **Replicate/copy the image into the customer's ECR** — ECR cross-region/cross-account **replication**, or `skopeo copy`/`crane cp` from your registry to theirs as part of an air-gapped handoff. (2) If limited cross-account pull *is* allowed, attach an **ECR repository policy** granting the customer account's node role `ecr:GetDownloadUrlForLayer`/`BatchGetImage`, and configure an `imagePullSecret`/ECR credential helper in their cluster. (3) Fully air-gapped: **export the image as a tarball** (`docker save`), transfer it, `docker load` into their registry, and run the GitOps stack entirely inside their account (their ArgoCD points at a repo/registry they own). The principle: pods pull from a registry they can reach; solve *image locality* first, deployment second.

```bash
# Copy image across accounts/registries without any runtime coupling
crane cp   <your-acct>.dkr.ecr.us-east-1.amazonaws.com/app:1.4.2 \
           <cust-acct>.dkr.ecr.eu-west-1.amazonaws.com/app:1.4.2
# OR fully air-gapped hand-off:
docker save app:1.4.2 -o app.tar    # export -> transfer -> on customer side:
docker load -i app.tar && docker push <cust-acct>.dkr.ecr.../app:1.4.2
```

---

# 3. Jenkins

> **Not asked in any of these interviews** — every pipeline was GitHub Actions + ArgoCD. Prepare one crisp comparison so a Jenkins question doesn't catch you cold.

## Q18. (Prep) How would your GitHub Actions + ArgoCD flow map onto Jenkins?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Jenkins is a **self-hosted, plugin-driven** CI/CD server; a pipeline is declarative Groovy in a `Jenkinsfile` versioned in the repo. Mapping: GitHub Actions *workflow* → `Jenkinsfile` `pipeline{}`; *jobs* → `stages{}`; *steps* → `steps{}`; *runners* → *agents/nodes* (you manage them, often ephemeral via the Kubernetes plugin that spins a pod per build); *secrets* → the **Credentials** store (`withCredentials`); *reusable workflows* → **Shared Libraries**. Triggers come from the GitHub webhook / Multibranch Pipeline. Jenkins gives you total control and a huge plugin ecosystem at the cost of maintaining the controller, agents, and plugin security. In a GitOps setup Jenkins would still only do **CI** (build/scan/push + commit the tag); **ArgoCD stays the CD engine**.

```groovy
pipeline {
  agent { kubernetes { yaml 'spec:\n  containers:\n  - name: docker\n    image: docker:dind' } }
  stages {
    stage('Test')  { steps { sh 'make unit' } }
    stage('Build') { steps { sh 'docker build -t $ECR/app:$GIT_COMMIT .' } }
    stage('Push')  { steps { withCredentials([usernamePassword(credentialsId:'ecr', usernameVariable:'U', passwordVariable:'P')]) {
                        sh 'echo $P | docker login -u $U --password-stdin $ECR && docker push $ECR/app:$GIT_COMMIT' } } }
    stage('Bump')  { steps { sh 'yq -i ".image.tag=env(GIT_COMMIT)" env/dev/values.yaml && git commit -am bump && git push' } }
  }
}
```

---

# 4. Git (branching, rebase, submodules, tags)

## Q19. Are you aware of Git rebase?
**Asked in:** PwC-1  |  **My performance:** Didn't-know  ⚠️ **NAIL THIS**

**My answer (from transcript):**
"I've worked on it long back, but rebase I've forgotten that concept — I can look into it, shouldn't be a problem." (Could not explain rebase.)

**✅ Correct answer:**
`git rebase` **re-applies your commits on top of a new base**, producing a *linear* history — unlike `git merge`, which ties two branches together with a merge commit. `git rebase main` on your feature branch replays each of your commits as if you'd started from the current tip of `main`, so there's no merge bubble. Uses: (1) **update a feature branch** to the latest `main` cleanly (`git pull --rebase`); (2) **interactive rebase** (`git rebase -i`) to squash/reorder/reword commits before opening a PR — clean, atomic history. Golden rule: **never rebase commits that are already pushed and shared** — rebasing rewrites commit SHAs, so force-pushing a shared branch breaks everyone else's history. Rebase = rewrite/linearize (private branches); merge = preserve/combine (shared branches).

```bash
git switch feature
git fetch origin
git rebase origin/main          # replay feature's commits on top of latest main
# clean up commits before the PR:
git rebase -i HEAD~3            # squash/fixup/reword the last 3 commits
git push --force-with-lease      # safe force-push (only if nobody else has the branch)
```

---

## Q20. What are Git submodules?
**Asked in:** PwC-1  |  **My performance:** Partial (answered about Terraform submodules)  ⚠️ **NAIL THIS**

**My answer (from transcript):**
Interpreted it as Terraform submodules — described them as modules created for individual resources (a VPC submodule, an ECS submodule inside a Terraform module). Did not address the Git concept.

**✅ Correct answer:**
A **Git submodule** is a Git repository nested inside another Git repository, pinned to a **specific commit** of the child repo. The parent repo doesn't store the child's files — it stores a *pointer* (the child's URL in `.gitmodules` + the exact commit SHA in the tree). Use it to include a shared library or a common Helm/chart repo across projects while keeping histories separate and version-pinned. Workflow: `git submodule add <url>`, then clone with `git clone --recurse-submodules` (or `git submodule update --init --recursive`); to move to a newer child commit you `cd` in, checkout, and commit the updated pointer in the parent. Trade-offs: pinning is explicit and reproducible, but submodules are famously fiddly (detached HEADs, forgotten `--recurse`); alternatives are Git subtree or a package manager. (What I described — VPC/ECS Terraform child modules — is a *different concept*; the Git answer is "a repo pinned inside another repo at a commit.")

```bash
git submodule add https://github.com/org/shared-charts.git charts/shared
git clone --recurse-submodules https://github.com/org/app.git   # get parent + children
git submodule update --remote charts/shared                     # bump to newer child commit
git add charts/shared && git commit -m "bump shared-charts pin" # record the new pointer
```

---

## Q21. What Git branching strategy do you use?
**Asked in:** Barclays  |  **My performance:** Vague  ⚠️ **NAIL THIS**

**My answer (from transcript):**
First fumbled ("Git rebase... GitFlow... merge base"). When re-asked: one main branch plus multiple feature branches; a feature branch merge to main needs PR approvals from ≥3 engineers, and on merge to main the CD kicks in. (Described branch protection more than a *named* strategy.)

**✅ Correct answer:**
Name the strategy and why it fits GitOps/CD. The main options: **GitHub Flow / Trunk-Based Development** — a single long-lived `main`, short-lived feature branches, frequent PR merges behind branch protection; ideal for continuous deployment (which is what my setup actually was). **GitFlow** — long-lived `main` + `develop`, plus `feature/`, `release/`, `hotfix/` branches; heavier, suits scheduled releases, generally overkill for CD. **Release branches** — cut `release/x.y` for stabilization. Given my pipeline auto-deploys on merge to `main`, the honest answer is **trunk-based / GitHub Flow with branch protection and hotfix branches for prod incidents** — not GitFlow. The mistake to avoid is describing branch *protection rules* when asked for a branching *model*; state the model first, then the protections that enforce it.

```
main ─────●───────●───────●────────●   (protected; every merge auto-deploys)
           \     /         \      /
   feature/login●   feature/pay●          # short-lived, PR + reviews to merge
                                 \
                          hotfix/pay-crash●  # branch off main, fix, merge back fast
```

---

## Q22. Are you aware of Git tags?
**Asked in:** PwC-1  |  **My performance:** Correct

**My answer (from transcript):**
Yes, at the repository level. Git tags were a primary feature for ArgoCD ApplicationSet/templator functions — ArgoCD scanned for repos with a given tag/label ("golden path"); any repo with that tag gets picked up and deployed to EKS.

**✅ Correct answer:**
A **Git tag** is a named, usually **immutable** pointer to a specific commit — used to mark releases (`v1.4.2`). **Annotated tags** (`git tag -a`) carry a message, tagger and date and can be GPG-signed (use these for releases); **lightweight tags** are just a bare pointer. Tags don't move as branches advance, which makes them the natural anchor for reproducible releases and for image tags. Note: what you described (ArgoCD scanning repos by *label*) conflates **Git tags** (commit markers) with **repo topics/labels** and ArgoCD **ApplicationSet generators** — worth separating those. Tags are commonly used to *drive* a release pipeline (`on: push: tags: v*`) and to derive the image tag.

```yaml
# Cut a release with an annotated, signed tag → triggers the release pipeline
# $ git tag -s v1.4.2 -m "release 1.4.2" && git push origin v1.4.2
on: { push: { tags: ['v*.*.*'] } }
jobs:
  release:
    steps:
      - run: docker build -t $ECR/app:${GITHUB_REF_NAME} .   # image tag == git tag
      - run: docker push $ECR/app:${GITHUB_REF_NAME}
```

---

# 5. Helm & Image-Tag Promotion Across Environments

> ⚠️ **The interviewers at HCL and Trianz-K8s repeatedly said "I didn't get that."** The whole promotion story must be crisp: **same-image promotion vs rebuild**, and exactly how a tag in `values.yaml` maps to a tag in the registry. Q23–Q26 fix this.

## Q23. If an image tested in QA is good, do you deploy the *same* image to production, or build a new one?
**Asked in:** HCL  |  **My performance:** Partial (inconsistent)  ⚠️ **NAIL THIS**

**My answer (from transcript):**
In most cases the same image is promoted up to production by replicating the same image-tag values in the next environment's `values.yaml`. But if it breaks in QA/prod, we roll back, fix at app level, generate a new image with a separate tag, and redeploy. (Interviewers probed repeatedly; answers were inconsistent about whether new images are rebuilt per environment.)

**✅ Correct answer:**
State the principle without wobbling: **build once, promote the same immutable artifact.** The exact bytes you validated in Dev/QA must be what runs in Prod — you do **not** rebuild per environment, because a rebuild can pull newer base layers/dependencies and invalidate every test you ran. Promotion = **change the image *reference* in the next environment's `values.yaml` to the already-built tag** (`sha-abc123`), which triggers ArgoCD to deploy that same image to the next cluster. Environment *differences* live in per-env `values.yaml` (replicas, resources, config, secrets) — **never** in a different image. You only ever build a *new* image when the **code changes** (a fix). "Rebuild for prod" is the anti-pattern; "re-point the tag" is the pattern.

```yaml
# The ONLY thing that changes between envs is the tag reference — same image bytes.
# env/qa/values.yaml
image: { repository: 1234.dkr.ecr.../payments, tag: sha-abc123 }   # tested here
# env/prod/values.yaml   <-- promotion = copy that SAME tag up
image: { repository: 1234.dkr.ecr.../payments, tag: sha-abc123 }   # identical artifact
replicaCount: 6        # prod DIFFERS only in config, never in the image
```

---

## Q24. How is the image tag fixed/updated when promoting — a semantic version in the registry won't match a hand-edited `values.yaml` version?
**Asked in:** HCL, Trianz-K8s (asked twice, "honestly I didn't get that")  |  **My performance:** Partial  ⚠️ **NAIL THIS**

**My answer (from transcript):**
For new versions we update the Dockerfile, rebuild to generate a new image, give it custom tags, and run the pipelines. In higher environments app teams give custom image-tag versions following conventional commits (e.g., 1.2.5), updated in that environment's Helm `values.yaml`. (Interviewer stayed confused; the tag-mismatch question wasn't resolved.)

**✅ Correct answer:**
The mismatch disappears once you see there is **one source of truth for the tag: whatever the CI pushed to the registry.** The flow: (1) CI builds the image and tags it deterministically — usually the **commit SHA** (and optionally a semver from a Git tag); (2) CI **pushes that exact tag to ECR**; (3) CI (or a bot like Argo CD Image Updater) **writes that same tag string into `values.yaml`** — it is *not* hand-typed. So `image.tag` in `values.yaml` is *literally the registry tag* — they can't diverge because the same pipeline sets both. Helm renders `image: repo:<tag>` → the pod pulls `repo:<tag>` from ECR → the tag exists because CI just pushed it. Hand-editing `values.yaml` to a version the registry doesn't have is exactly what causes `ImagePullBackOff`; the fix is **automation writes the tag, humans don't**. Promotion to the next env is then just "copy that verified tag into the next env's values" (Q23).

```yaml
# ONE pipeline sets both the registry tag AND the values.yaml tag — they can't drift.
- run: |
    TAG=sha-$(git rev-parse --short HEAD)
    docker build -t $ECR/payments:$TAG . && docker push $ECR/payments:$TAG  # (a) registry
    yq -i ".image.tag = \"$TAG\"" env/dev/values.yaml                        # (b) desired state
    git commit -am "deploy $TAG to dev" && git push
# Helm then renders:  image: $ECR/payments:$TAG   -> pod pulls exactly what (a) pushed
```

---

## Q25. Do you have a separate repo/pipeline per environment, and how does the CI trigger differ per env when the pipeline is the same?
**Asked in:** Barclays, HCL  |  **My performance:** Partial

**My answer (from transcript):**
One single repo, not different repos — different Helm chart subfolders (`values.yaml`) per environment, coupled with ArgoCD templating. When a PR to the Helm charts merges to main, CI kicks in, detects the latest image version, runs the 4 stages, pushes to ECR, across the relevant subfolder. Only the environment whose values changed gets triggered; production additionally requires the Jira/RCA gate.

**✅ Correct answer:**
Clean model: **one app repo + one config repo, one pipeline, multiple env overlays.** Structure is `env/dev/values.yaml`, `env/integration/…`, `env/prod/…` (or a base chart + per-env value files). Environment selectivity is achieved with **path filters** — a change under `env/dev/**` only triggers the dev deploy — and/or a **matrix**/separate ArgoCD `Application` per env watching its own path. So it's not "different pipelines," it's **one reusable pipeline parameterized by env**, with per-env protection: dev auto-syncs, prod's `Application`/`environment` requires approval (CODEOWNERS + Jira). This avoids drift between per-env pipelines (the reason not to copy a pipeline four times).

```yaml
on:
  push:
    paths: ['env/dev/**']           # only dev changes trigger the dev deploy
jobs:
  deploy-dev:
    steps: [{ run: "helm upgrade --install app ./chart -f env/dev/values.yaml" }]
# Each env = its own ArgoCD Application watching env/<name>; prod App has manual sync + approval
```

---

## Q26. Are you deploying with Helm or Ansible, and how does ArgoCD detect changes from the registry via Helm?
**Asked in:** PwC-K8s, Barclays  |  **My performance:** Correct

**My answer (from transcript):**
Helm charts with GitOps via ArgoCD (Argo + Helm), not Ansible. Used an open-source repo ("helm kubernetes service") integrated into the platform so app teams could make changes and deploy. Values are variableized to avoid misconfiguration.

**✅ Correct answer:**
Helm is the **templating/packaging** layer: a chart = templated K8s manifests + a `values.yaml` of parameters, so you variableize image tag, replicas, resources, env — one chart, many environments. ArgoCD doesn't "watch ECR" — it **watches the Git repo** (the source of truth). When CI commits a new `image.tag` into `values.yaml`, ArgoCD's reconcile loop renders the chart (`helm template`), diffs against live cluster state, and syncs. The pod then pulls that tag from ECR. (If you *do* want ArgoCD to react to a new registry tag directly, that's **Argo CD Image Updater** writing the tag back to Git.) Key correction to a common myth: **the trigger is a Git change, not a registry poll.** Variableized values + validated templates are exactly what reduces misconfiguration.

```yaml
# ArgoCD Application: source of truth is GIT; Helm renders it; sync to cluster.
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  source:
    repoURL: https://github.com/org/config.git
    path: charts/app
    helm: { valueFiles: [../../env/prod/values.yaml] }   # tag lives here, in Git
  destination: { server: https://eks-prod, namespace: payments }
  syncPolicy: { automated: { prune: true, selfHeal: true } }
```

---

# 6. ArgoCD / GitOps

## Q27. How do you do multi-cluster deployment with ArgoCD?
**Asked in:** GlobalLogic  |  **My performance:** Partial (rambling)

**My answer (from transcript):**
We had one app repo with multiple environments in the Helm chart (dev, integration, production). ArgoCD was configured so that as soon as we change a respective environment it deploys to the matching cluster; each environment had its own separate ArgoCD application. (Somewhat garbled.)

**✅ Correct answer:**
Two clean patterns. (1) **Register each cluster** with ArgoCD (`argocd cluster add`), then point each `Application`'s `destination.server` at the right cluster — one Argo control plane fans out to many clusters. (2) **ApplicationSets** to avoid hand-writing an Application per cluster: a **cluster generator** or **matrix generator** templates one Application per registered cluster/env automatically, so onboarding a new cluster/env is adding one list entry, not copying manifests. That's the scalable answer — "one Application per env" works but doesn't scale; **ApplicationSet generates them from a template.** Add **app-of-apps** or **sync waves** for ordering across clusters.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
spec:
  generators:
    - clusters: { selector: { matchLabels: { env: prod } } }  # every registered prod cluster
  template:
    metadata: { name: 'payments-{{name}}' }
    spec:
      source: { repoURL: '...', path: 'env/prod', targetRevision: main }
      destination: { server: '{{server}}', namespace: payments }  # per-cluster fan-out
```

---

## Q28. If ArgoCD is not syncing properly, how do you debug it?
**Asked in:** GlobalLogic  |  **My performance:** Partial

**My answer (from transcript):**
First check whether multiple Argo apps have the issue or just one. For a single failing app, find which CD stage fails — ImagePullBackOff, OOMKilled, or vulnerability failures. Go to the ArgoCD console, check the app's logs for real-time logs, and troubleshoot from the error messages.

**✅ Correct answer:**
Work from Argo outward. (1) **App status**: `argocd app get <app>` — is it `OutOfSync`, `SyncFailed`, `Degraded`, or `Unknown`? (2) **Sync errors**: `argocd app sync <app>` output and conditions often show the exact failure (bad manifest, hook failure, RBAC denied, image error). (3) **Diff**: `argocd app diff` to see desired vs live. (4) **Common causes**: repo/credentials unreachable, Helm render error (bad values), the target namespace/cluster unreachable, RBAC/`AppProject` restrictions, a stuck sync hook, or resources that won't become healthy (ImagePullBackOff/CrashLoop/OOM — those are *app* problems Argo just surfaces). (5) **Controller logs**: `kubectl logs deploy/argocd-application-controller -n argocd` for reconcile-level errors; check `argocd-repo-server` for source/render errors. (6) If drift keeps reverting, someone edited the cluster manually — that's self-heal working, fix it in Git. Distinguish **"Argo can't sync"** (source/RBAC/render) from **"synced but unhealthy"** (app runtime).

```bash
argocd app get payments-prod                 # sync + health status, conditions
argocd app diff payments-prod                # desired (Git) vs live (cluster)
argocd app sync payments-prod --dry-run      # surface the exact sync error
kubectl logs deploy/argocd-repo-server -n argocd        # Helm/manifest render errors
kubectl logs deploy/argocd-application-controller -n argocd  # reconcile errors
```

---

## Q29. What is GitOps and how is it implemented?
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
GitOps treats Git as the single source of truth. The GitOps tool runs a reconciliation loop continuously comparing desired state vs current state. If we change the repo, ArgoCD recognizes it immediately, pulls the latest image from ECR, and deploys to the target cluster, keeping repo and cluster in the same state.

**✅ Correct answer:**
Good. The four GitOps principles: (1) **Declarative** — the whole system is described declaratively (K8s manifests/Helm). (2) **Versioned & immutable** — that desired state lives in Git, so every change is auditable and revertible (`git revert` = rollback). (3) **Pulled automatically** — an in-cluster agent (ArgoCD/Flux) pulls approved changes; nobody `kubectl apply`s from a laptop. (4) **Continuously reconciled** — the agent constantly diffs desired (Git) vs actual (cluster) and corrects drift (self-heal). Benefits: audit trail, easy rollback, no cluster credentials in CI (pull not push), and drift detection. Implementation = repo of manifests + ArgoCD `Application`s with `automated: {prune, selfHeal}`.

```yaml
syncPolicy:
  automated: { prune: true, selfHeal: true }   # continuously reconcile Git -> cluster
  syncOptions: [CreateNamespace=true]
# Rollback is just Git:  git revert <bad-commit>  ->  ArgoCD syncs back to the good state
```

---

## Q30. Explain how ArgoCD detects configuration drift and self-heals (and confirm it reconciles manual cluster changes).
**Asked in:** HTC-1, Trianz-K8s  |  **My performance:** Correct

**My answer (from transcript):**
ArgoCD works on a reconciliation loop comparing current state (cluster) vs desired state (Git). If you change the repo, ArgoCD recognizes it and deploys to the target cluster. It also cross-verifies manual changes on the cluster and reconciles back to desired. (Initially misstated which was current vs desired, then self-corrected.)

**✅ Correct answer:**
Fix the vocabulary so you never flip it: **desired state = Git**, **live/actual state = cluster**. The application-controller reconciles on a timer (default ~3 min) and on webhook events: it renders the manifests from Git and computes a **diff** against live objects. If they differ the app is **OutOfSync**. With **`selfHeal: true`**, a *manual* cluster edit (someone `kubectl edit`s a Deployment) is detected as drift and **reverted to Git** — so Git always wins. With **`prune: true`**, objects deleted from Git are deleted from the cluster. That's exactly why GitOps is safe: out-of-band changes don't persist; to change prod you must change Git (auditable). So yes — a manual change is reconciled away automatically.

```yaml
syncPolicy:
  automated:
    selfHeal: true    # kubectl-edited drift -> reverted to Git automatically
    prune: true       # removed-from-Git objects -> deleted from cluster
# Try it: kubectl scale deploy/app --replicas=9  ->  Argo restores Git's replica count
```

---

## Q31. How does your Kubernetes handle image pulling / did you set up ArgoCD yourself?
**Asked in:** HDFC, HCL, PwC-1  |  **My performance:** Correct

**My answer (from transcript):**
GitOps with ArgoCD ApplicationSet/template functions that scan repos with a specific label ("golden path"); ArgoCD recognizes matching repos and deploys to the cluster. ArgoCD itself was set up by the architects; I built the observability for ArgoCD and onboarded/troubleshot app teams.

**✅ Correct answer:**
Two things to separate cleanly. **Image pulling** is a Kubernetes concern, not ArgoCD's: the Deployment references `repo:tag`; the kubelet pulls it using an **imagePullSecret** or (on EKS) the node's **IAM role / IRSA** authorizing ECR — ArgoCD only *declares* the tag, the kubelet does the pull. **Repo selection** is where **ApplicationSet generators** come in — a Git/SCM generator can template an Application for every repo matching a topic/label ("golden-path"), so onboarding is automatic. Being honest that architects stood up ArgoCD while you owned observability + onboarding is a *strong* answer — it shows scope awareness. Just don't conflate "ArgoCD deploys" with "ArgoCD pulls the image"; the node pulls, authorized by IRSA.

```yaml
# EKS: nodes pull from ECR via IRSA — no imagePullSecret needed
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments
  annotations: { eks.amazonaws.com/role-arn: arn:aws:iam::123:role/ecr-pull }
# ApplicationSet SCM generator picks up every repo topic'd "golden-path" automatically
```

---

# 7. Deployment Strategies (Blue-Green / Canary)

## Q32. Is blue-green or canary deployment possible with ArgoCD? How does traffic switch?
**Asked in:** GlobalLogic  |  **My performance:** Partial (didn't mention Argo Rollouts; contradicted self on traffic switching)  ⚠️ **NAIL THIS**

**My answer (from transcript):**
Yes, defined in the strategy section of the deployment file (default being rolling update). Once you define canary it has input variables such as what percentage of traffic goes to the new pod version. Define the strategy in the deployment definition file and execute. (Didn't mention Argo Rollouts.)

**✅ Correct answer:**
Important correction: a native Kubernetes `Deployment` only supports **`RollingUpdate`** and **`Recreate`** — it has **no** blue-green or canary `strategy`, and no traffic-percentage field. To do those you either (a) use **Argo Rollouts** (a `Rollout` CRD that replaces `Deployment` and adds `blueGreen`/`canary` strategies with real traffic shaping), or (b) do it manually with **two Deployments + a Service selector**.

- **Blue-green**: run **blue** (current) and **green** (new) side by side; the **Service `selector` points at blue**; validate green privately; **flip the selector to green** for an instant cutover; keep blue for fast rollback. *The traffic switch is literally editing the Service's `selector` label* (or the Ingress/Rollout's active service) — that's the detail I contradicted myself on.
- **Canary**: shift a *percentage* of traffic to the new version (10% → 50% → 100%), which requires a traffic manager (Ingress-NGINX canary, Istio/SMI, or Argo Rollouts + a `TrafficRouting` provider) — you can't do true percentage splitting with a plain Service, only pod-count-ratio approximations.

```yaml
# Argo Rollouts — real canary with automated traffic steps + analysis
apiVersion: argoproj.io/v1alpha1
kind: Rollout
spec:
  strategy:
    canary:
      canaryService: app-canary        # blue-green would use activeService/previewService
      trafficRouting: { nginx: { stableIngress: app } }
      steps:
        - setWeight: 10                 # 10% of real traffic to new version
        - pause: { duration: 5m }
        - analysis: { templates: [{ templateName: error-rate }] }  # auto-abort if bad
        - setWeight: 50
        - pause: {}
```
```yaml
# Blue-green the manual way — the "traffic switch" IS this one selector edit:
kind: Service
spec:
  selector: { app: payments, slot: green }   # was slot: blue -> flip = instant cutover
```

---

# 8. Rollback

## Q33. Using GitHub Actions CD (image already built), a prod deploy fails and the app stops — how do you *automate* a rollback to the previous running version?
**Asked in:** PwC-K8s  |  **My performance:** Didn't-know  ⚠️ **NAIL THIS**

**My answer (from transcript):**
"We have not done that, but I'll definitely give it a try." Then: since each build creates a new image tag tied to a commit ID, call the previous commit's image tag and re-run the CD pipeline (git revert to bring back v1), deploying the older version with a rolling or canary strategy.

**✅ Correct answer:**
Your instinct (redeploy the previous known-good tag) is right — make it **automatic and gated on a health check**. Patterns:
- **Kubernetes-native**: `kubectl rollout undo deployment/app` reverts to the previous ReplicaSet; Helm has `helm rollback <release> <prev-revision>`. Wrap the deploy in `kubectl rollout status --timeout` and, on failure, run the undo in an `if: failure()` step.
- **GitOps-native (best)**: since desired state is Git, rollback = **`git revert`** the tag-bump commit; ArgoCD syncs back to the last good image. `argocd app rollback <app> <prev>` does it imperatively.
- **Progressive delivery**: Argo Rollouts **auto-aborts** a canary when its `AnalysisTemplate` (error rate/latency) breaches, rolling back with no human — the gold standard.
The key idea you were missing: don't roll back *manually*; make the pipeline **detect failure (health/smoke check) and trigger the undo itself**.

```yaml
- name: deploy
  run: helm upgrade --install app ./chart -f env/prod/values.yaml --wait --timeout 5m
- name: verify
  run: kubectl rollout status deploy/app --timeout=120s && ./smoke.sh
- name: auto-rollback
  if: failure()                         # deploy or smoke failed -> revert automatically
  run: |
    helm rollback app 0                 # previous good Helm revision
    # GitOps variant: git revert HEAD --no-edit && git push  (ArgoCD re-syncs good tag)
```

---

## Q34. What is your rollback strategy for a production issue?
**Asked in:** PwC-1, Barclays  |  **My performance:** Correct

**My answer (from transcript):**
Primary strategy was a hotfix branch plus `git revert` to roll back to the previous image version as an immediate remedy. In the hotfix branch we revert to the previous image and merge to main in prod as remediation; once fully fixed, code is promoted to the hotfix branch, tested, then merged to main for a new deployable version. Production picks from main (no separate prod branch), then an RCA call.

**✅ Correct answer:**
Right shape — separate **mitigation** from **fix**. **Mitigate first** (restore service fast): re-point to the last known-good image tag — in GitOps that's `git revert` of the tag-bump (ArgoCD re-syncs the previous image) or `helm rollback`/`kubectl rollout undo`. This is instant and needs no new build because the old image still exists in ECR. **Then fix**: branch a `hotfix/`, patch the code, run the full CI (tests + scans), and roll *forward* to a new tag through the normal gated promotion. Finally run the **RCA/postmortem**. The nuance to add: rollback is safe *only* if the release was an immutable, versioned artifact and DB migrations are backward-compatible (a forward-only migration can make image rollback unsafe — see Q38).

```bash
# Mitigate NOW (no rebuild): revert the desired-state commit -> Argo syncs old image
git revert <bad-tag-bump-commit> --no-edit && git push
# or imperative:
helm rollback payments 0        # last good revision
kubectl rollout undo deploy/payments
# THEN fix forward on a hotfix branch and promote a new tag through CI gates.
```

---

# 9. Security Scanning, Quality Gates & Testing

## Q35. Do you implement smoke testing in a CI/CD pipeline?
**Asked in:** PwC-1  |  **My performance:** Didn't-know  ⚠️ **NAIL THIS**

**My answer (from transcript):**
"Smoke testing — sorry, I'm not aware of that."

**✅ Correct answer:**
A **smoke test** is a small, fast **post-deployment** check that the critical paths of a freshly deployed app actually work — "is it on fire?" — before you send real traffic or promote further. It's *not* exhaustive testing; it hits a handful of vital endpoints (health, login, one core transaction) right after deploy. In CI/CD it's the **verification gate** after `helm upgrade`: if the smoke test fails, you **abort the promotion and roll back automatically** (ties directly into Q33). Distinguish it from unit tests (pre-build), integration tests (dependencies), and load tests (capacity). Every deploy step should be followed by a smoke check; a green deploy with a failing smoke test is still a failed release.

```yaml
- run: helm upgrade --install app ./chart -f env/staging/values.yaml --wait
- name: smoke test        # fast, critical-path only; gate promotion on it
  run: |
    set -e
    curl -fsS https://staging.app/healthz            # is it up?
    curl -fsS https://staging.app/api/v1/ping        # core route responds?
    curl -fsS -X POST https://staging.app/api/login -d @creds.json  # key flow works?
```

---

## Q36. How do you enforce code quality in GitHub?
**Asked in:** Pure-SW  |  **My performance:** Partial (muddled)

**My answer (from transcript):**
Enable Dependabot to check module versions/vulnerabilities, enable pre-commit checks that scan infrastructure code before commit, and use conventional commits for naming standards. (Loosely phrased.)

**✅ Correct answer:**
Layer the controls so quality is *enforced*, not *hoped for*: (1) **pre-commit hooks** (lint, format, secret-scan, `terraform fmt`, Checkov) — fast local feedback; (2) **required status checks** on PRs (unit tests, **SAST** via SonarQube/CodeQL, **IaC scan** via Checkov/tfsec, **SCA** via Dependabot/Trivy) — the PR can't merge red; (3) **branch protection** — required reviews + CODEOWNERS + up-to-date branch + no direct pushes; (4) **conventional commits** enforced by a commit-lint check (also powers automated semver/changelog); (5) **quality gates** (Sonar "fail the build if coverage < X or new critical issues"). The through-line: put each check *in the pipeline as a required gate* so it blocks merge — a linter nobody's forced to pass isn't enforcement.

```yaml
# PR gate — every check below is marked "required" in branch protection
jobs:
  quality:
    steps:
      - uses: pre-commit/action@v3.0.1          # lint / fmt / secret scan
      - run: sonar-scanner -Dsonar.qualitygate.wait=true   # fail on gate breach
      - uses: bridgecrewio/checkov-action@v12    # IaC misconfig scan
      - run: commitlint --from origin/main       # conventional commits
```

---

## Q37. Besides `prevent_destroy`, how do you avoid accidental destruction via CI/CD?
**Asked in:** Pure-SW  |  **My performance:** Partial (needed a hint to reach approval gates)

**My answer (from transcript):**
Initially "CI/CD, I'm not sure." After a hint, agreed you can add approval gates — once a PR is raised, have multiple approval-gate tests, and once everything passes, merge to main.

**✅ Correct answer:**
Several CI/CD-side guardrails beyond Terraform's `prevent_destroy` lifecycle block: (1) **plan-on-PR** so every destroy shows up in the reviewed `terraform plan` diff *before* apply; (2) **fail the pipeline if the plan contains destroys** (grep the plan JSON / `-detailed-exitcode`) unless explicitly approved; (3) **protected `environment` with required reviewers** so apply pauses for a human on prod; (4) **saved plan artifact** so apply runs exactly what was reviewed (no drift between plan and apply); (5) **state locking** (DynamoDB) to prevent concurrent clobbering; (6) least-privilege CI role that can't delete critical resources; (7) **drift detection** + backups. So: approval gates *and* make the pipeline surface/deny unexpected destroys automatically.

```yaml
- run: terraform plan -out=tf.plan -json | tee plan.json
- name: block unexpected destroys
  run: |
    if jq -e '.resource_changes[] | select(.change.actions[]=="delete")' plan.json >/dev/null; then
      echo "::error::Plan contains resource destruction — needs explicit approval"; exit 1
    fi
- name: apply
  environment: infra-prod          # required reviewer before this runs
  run: terraform apply tf.plan
```

---

## Q38. How do you handle database migration in a CI/CD pipeline?
**Asked in:** PwC-1  |  **My performance:** Partial (Liquibase, only a PoC)

**My answer (from transcript):**
We created a PoC (in progress) with Liquibase, which handled database and schema migrations. (Brief; not fully implemented.)

**✅ Correct answer:**
Migrations must be **versioned, ordered, idempotent and automated** — via a migration tool (Liquibase, Flyway) whose changelog lives in Git alongside the code. Run migrations as a **discrete, gated pipeline step before/with the app deploy** — commonly a Kubernetes **Job** or an ArgoCD **PreSync hook** so schema changes apply before the new pods roll. The critical rule for zero-downtime + safe rollback: **make migrations backward-compatible (expand/contract)** — add columns/tables first (new + old code both work), deploy code, then remove the old schema in a later release. That way an image rollback doesn't hit a schema the old code can't read. Never let uncontrolled app startup code mutate the schema; keep migrations explicit and reversible.

```yaml
# ArgoCD PreSync hook: run Liquibase/Flyway BEFORE the new app pods sync
apiVersion: batch/v1
kind: Job
metadata:
  annotations: { argocd.argoproj.io/hook: PreSync, argocd.argoproj.io/hook-delete-policy: HookSucceeded }
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: liquibase/liquibase
          args: ["--changeLogFile=changelog.xml","update"]   # expand-only, backward-compatible
```

---

## Q39. What checks reduced deployment failures by 75% across 15+ applications?
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
Static code analysis tools, pre-commit hooks, Checkov for IaC scanning, SonarQube for vulnerability checks, and Veracode for dynamic scanning of the image. Code goes through static analysis first, then Veracode dynamic scanning; only if tests pass is the image pushed to ECR, then ArgoCD deploys to EKS.

**✅ Correct answer:**
Strong answer — frame it as **shift-left gates that fail the build early**, mapped to the DevSecOps taxonomy: **pre-commit hooks** (fast local), **SAST** (SonarQube/CodeQL — static code vulns), **IaC scanning** (Checkov/tfsec — misconfigured infra), **SCA/dependency** (Dependabot/Trivy — vulnerable libs), **container image scanning** (Trivy/Grype), and **DAST** (Veracode — runtime/app scanning). Ordered cheapest-and-earliest first, each a **required, blocking** check so a failing scan stops the artifact from ever reaching ECR. The 75% comes from catching config/dependency/image issues *before* deploy rather than in the cluster. Add a metric: track failure rate before/after to prove the impact (which you did).

```yaml
jobs:
  gate:                       # every step blocks the build on failure (shift-left)
    steps:
      - uses: pre-commit/action@v3.0.1
      - run: sonar-scanner -Dsonar.qualitygate.wait=true    # SAST
      - uses: bridgecrewio/checkov-action@v12               # IaC
      - run: trivy fs --exit-code 1 --severity HIGH,CRITICAL .   # SCA
  build:
    needs: gate                                             # image only builds if gate is green
    steps:
      - run: docker build -t $ECR/app:$SHA . && trivy image --exit-code 1 $ECR/app:$SHA
      - run: veracode scan --image $ECR/app:$SHA            # DAST
      - run: docker push $ECR/app:$SHA
```

---

## Q40. How do you enforce code at the branch level (branch protection)?
**Asked in:** Pure-SW, Accion-1  |  **My performance:** Correct

**My answer (from transcript):**
Enforce a policy where code can only merge to main through a PR, add SonarQube to CI to assess vulnerabilities, and require 2–3 PR approvals from leads/architects before merge. On merge the gates/tests run.

**✅ Correct answer:**
Branch protection on `main` should require: (1) **PR before merge** (no direct pushes, including admins); (2) **required status checks** that must pass (CI tests + SAST + IaC/image scans) and the branch be **up to date**; (3) **required reviews** (N approvals) plus **CODEOWNERS** review for sensitive paths; (4) **dismiss stale approvals** when new commits land; (5) **signed/verified commits** and **linear history** if desired; (6) **conversation resolution** required. One correction to a common phrasing: the checks run **on the PR to gate the merge**, not "after merge." Manage these as code via a ruleset/Terraform so all 15 repos are consistent.

```yaml
# GitHub branch protection as code (Terraform) — consistent across every repo
resource "github_branch_protection" "main" {
  repository_id = github_repository.app.node_id
  pattern       = "main"
  required_pull_request_reviews {
    required_approving_review_count = 2
    require_code_owner_reviews      = true
    dismiss_stale_reviews           = true
  }
  required_status_checks { strict = true, contexts = ["ci/test","ci/sonar","ci/trivy"] }
  enforce_admins = true
}
```

---

# 10. Config Management & Golden Images (Ansible / Packer / Docker)

## Q41. Have you worked with handlers in Ansible?
**Asked in:** Shell-1  |  **My performance:** Didn't-know

**My answer (from transcript):**
"I'm sorry, no." (Did not know handlers.)

**✅ Correct answer:**
An Ansible **handler** is a task that runs **only when notified by another task that reported `changed`**, and it runs **once, at the end of the play** (after all tasks), even if notified multiple times. Classic use: restart/reload a service *only if* its config file actually changed — you `notify` the handler from the config task, and if the file was already correct (no change), the restart is skipped. This is what makes Ansible **idempotent and efficient**: you don't bounce services on every run, only when something actually changed. Handlers are defined under `handlers:` and referenced by name in `notify:`.

```yaml
tasks:
  - name: Deploy nginx config
    ansible.builtin.template: { src: nginx.conf.j2, dest: /etc/nginx/nginx.conf }
    notify: Restart nginx          # fires ONLY if this task changed the file
handlers:
  - name: Restart nginx            # runs once, at end of play, if notified
    ansible.builtin.service: { name: nginx, state: restarted }
```

---

## Q42. Do you use a configuration management tool (Ansible/Puppet/Chef)?
**Asked in:** Persistent, PwC-K8s  |  **My performance:** Didn't-know / N/A

**My answer (from transcript):**
No, we did not use a configuration management tool. (Some early, small Ansible experience only.)

**✅ Correct answer:**
Perfectly valid — explain *why*, which shows maturity: in a **container + Kubernetes + GitOps** world, config management largely shifts. Instead of Ansible/Puppet mutating long-lived servers, you bake config into **immutable images** (Dockerfile / Packer for AMIs) and manage runtime config **declaratively** (Helm values, ConfigMaps/Secrets, ArgoCD). The cattle-not-pets model replaces "converge a running box" with "rebuild and redeploy." Ansible/Puppet still matter for **provisioning the nodes/VMs themselves, bootstrapping, or non-containerized legacy fleets**. So the honest answer: "We used immutable images + Helm/GitOps for app config, which is the CM layer in a K8s platform; classic CM tools would come in for host/OS-level provisioning."

```dockerfile
# "Config management" in a container world = immutable image + declarative runtime config
FROM python:3.12-slim
COPY requirements.txt . && RUN pip install --no-cache-dir -r requirements.txt
COPY app/ /app
# runtime config injected declaratively at deploy time (Helm values / ConfigMap / Secret),
# NOT mutated on a running host by a CM agent.
```

---

## Q43. Explain your Ansible experience, what an Ansible module is, and give a scenario for using one.
**Asked in:** Shell-1  |  **My performance:** Partial → Correct

**My answer (from transcript):**
Wrote a playbook that installed dependency packages across six remote servers (~4 years back). A module is a prebuilt set of functions to execute a task (e.g. infrastructure config, altering a remote server's config). Scenario: when scripts/packages must be installed across a fleet, Ansible has the server inventory, so execute via playbooks across all of them in parallel, then verify.

**✅ Correct answer:**
An **Ansible module** is a discrete, mostly **idempotent** unit of work Ansible ships (or you write) that performs one action on a target — `apt`/`yum` (packages), `service` (services), `copy`/`template` (files), `user`, `git`, `ec2_instance`, etc. You call modules from **tasks** in a **playbook**; Ansible runs them over SSH against hosts in the **inventory**, in parallel, and reports `ok`/`changed`/`failed`. Idempotency is the key property: running the same play twice makes no changes the second time. Good scenario: install and *ensure running* a package fleet-wide — `apt` installs it (only if missing), `service` ensures it's enabled/started, and a handler restarts it only on config change. That "declare desired state, converge safely, re-runnable" framing is what interviewers want.

```yaml
- hosts: web            # inventory group -> runs in parallel across the fleet
  become: true
  tasks:
    - name: Ensure nginx installed        # 'apt' module — idempotent
      ansible.builtin.apt: { name: nginx, state: present, update_cache: true }
    - name: Ensure nginx running/enabled  # 'service' module
      ansible.builtin.service: { name: nginx, state: started, enabled: true }
```

---

## Q44. What is a "golden machine image," and how would you build a CI/CD pipeline to deliver a Python golden Docker image to production?
**Asked in:** Shell-1  |  **My performance:** Partial → Correct

**My answer (from transcript):**
Golden images are internal, enterprise-scale base images (like an "image bakery") with all company security parameters (certs, baseline) built in; apps build on top. To deliver a Python golden image: pull a common base from Docker Hub / Red Hat repo; install company certs and Python deps; add RUN commands and entrypoints; use multi-stage builds and distroless; build; push to ECR / corporate registry for app teams to consume.

**✅ Correct answer:**
A **golden image** is a hardened, pre-approved base image (VM AMI via **Packer**, or a base container image) that bakes in the OS baseline, CIS hardening, corporate CA certs, required agents, and a pinned runtime, so every app inherits a compliant, consistent starting point — "build once, reuse everywhere." The delivery pipeline: (1) start from a **minimal, pinned** base (`python:3.12-slim` or UBI, pinned by digest); (2) apply hardening + certs + patched deps; (3) **multi-stage build** → final **distroless/non-root** image, small attack surface; (4) **scan** (Trivy/Grype) and **fail on HIGH/CRITICAL**; (5) generate an **SBOM** and **sign** the image (cosign) for supply-chain provenance; (6) push to the internal registry with an **immutable version tag**; (7) publish so app teams pin *your* digest as their `FROM`. Add automated **rebuild-on-CVE** so the golden image is re-baked and re-scanned when base CVEs drop. That last part (scan + sign + SBOM + auto-rebuild) is what elevates "we build a base image" to a real golden-image program.

```dockerfile
# multi-stage, pinned, non-root, distroless golden Python image
FROM python:3.12-slim@sha256:<digest> AS build
COPY corp-ca.crt /usr/local/share/ca-certificates/ && RUN update-ca-certificates
COPY requirements.txt . && RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
FROM gcr.io/distroless/python3-debian12:nonroot    # minimal, no shell, non-root
COPY --from=build /install /usr/local
```
```bash
# pipeline tail: scan -> SBOM -> sign -> push immutable tag
trivy image --exit-code 1 --severity HIGH,CRITICAL $REG/py-golden:1.0.0
syft $REG/py-golden:1.0.0 -o spdx-json > sbom.json
cosign sign --yes $REG/py-golden:1.0.0
docker push $REG/py-golden:1.0.0
```

---

## Q45. Have you worked with Packer?
**Asked in:** Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
Yes, long back — created 1–2 images using Packer. It was a while ago.

**✅ Correct answer:**
**Packer** (HashiCorp) builds **immutable machine images** (AWS AMIs, Azure images, Docker images, etc.) from a declarative template (HCL2). You define a **source/builder** (e.g., a base AMI + instance type), **provisioners** (shell/Ansible to install and harden), and it produces a versioned artifact you then launch identically everywhere. It's the canonical **golden-AMI** tool: bake the OS baseline, agents and certs into an AMI once, then ASGs/EKS node groups boot from it — no per-boot configuration drift. It pairs naturally with **Ansible** (as the provisioner) and **Terraform** (which consumes the resulting AMI ID). CI angle: run `packer build` in a pipeline, scan the image, publish the AMI ID as an output, and rebuild on base-CVE.

```hcl
source "amazon-ebs" "golden" {
  source_ami_filter { filters = { name = "al2023-ami-*" }, most_recent = true, owners = ["amazon"] }
  instance_type = "t3.micro"
  ami_name      = "golden-al2023-{{timestamp}}"
}
build {
  sources = ["source.amazon-ebs.golden"]
  provisioner "ansible" { playbook_file = "harden.yml" }   # bake baseline + certs
}
```

---

# 🔺 Advanced Questions to Master (not asked yet — practice these)

## Q46. How do you authenticate GitHub Actions to AWS/GCP/Azure without storing long-lived cloud keys?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Use **OIDC federation**. GitHub's OIDC provider issues a short-lived JWT per job describing the repo/branch/environment (the `sub` claim). You register GitHub as an OIDC identity provider in the cloud and create a role whose **trust policy** allows that specific `sub` (e.g. `repo:org/app:ref:refs/heads/main`) to assume it. The job requests `id-token: write`, exchanges the JWT for **temporary STS credentials**, and gets least-privilege, auto-expiring access — **zero standing secrets** to rotate or leak. Scope trust as tightly as possible (branch/environment), and use one role per environment.

```yaml
permissions: { id-token: write, contents: read }
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with: { role-to-assume: arn:aws:iam::123:role/gha-deploy-prod, aws-region: us-east-1 }
# IAM trust: "token.actions.githubusercontent.com:sub": "repo:org/app:environment:prod"
```

---

## Q47. Reusable workflows vs composite actions — when do you use each?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**Reusable workflows** (`on: workflow_call`) encapsulate whole **jobs** (multiple jobs, their runners, secrets, environments) and are called with `uses:` at the job level — use them to standardize an entire CI or deploy pipeline across many repos. **Composite actions** bundle a sequence of **steps** into one reusable step (`uses:` inside a job) — use them for a repeated snippet (setup, login, cache) within a job. Rule of thumb: reusing *jobs/pipeline shape* → reusable workflow; reusing *a few steps* → composite action. Version both with tags and pass `inputs`/`secrets` explicitly.

```yaml
# caller pins a versioned central pipeline:
jobs: { build: { uses: org/.github/workflows/ci.yml@v2, with: { app: api }, secrets: inherit } }
```

---

## Q48. How do matrix builds work and when are they worth it?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
A **matrix** fans one job out into parallel variants across dimensions (OS, language version, arch, environment). Use it to test a library against multiple runtimes, build multi-arch images, or deploy to multiple regions/clusters. Control it with `fail-fast` (stop all on first failure vs run all), `max-parallel`, and `include`/`exclude` to add or prune specific combos. It cuts wall-clock time and enforces broad compatibility, but watch runner-minute cost and don't matrix things that must run sequentially.

```yaml
strategy:
  fail-fast: false
  matrix: { python: ["3.10","3.11","3.12"], os: [ubuntu-latest, windows-latest] }
runs-on: ${{ matrix.os }}
steps: [{ uses: actions/setup-python@v5, with: { python-version: "${{ matrix.python }}" } }]
```

---

## Q49. How do you speed up pipelines with dependency and layer caching?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Cache anything expensive and deterministic: language deps (`~/.m2`, `node_modules`/npm cache, pip wheels, Go module cache) via `actions/cache` keyed on a **lockfile hash** (so the cache invalidates when deps change), with a `restore-keys` fallback for partial hits. For images, use **BuildKit layer caching** (`cache-from`/`cache-to` with a registry or GHA cache backend) and order the Dockerfile so rarely-changing layers (deps) come before frequently-changing ones (source). Caching turns multi-minute installs into seconds; the pitfalls are stale keys (fix by hashing the lockfile) and cache poisoning (scope caches per branch).

```yaml
- uses: actions/cache@v4
  with: { path: ~/.npm, key: npm-${{ hashFiles('**/package-lock.json') }}, restore-keys: npm- }
- uses: docker/build-push-action@v6
  with: { cache-from: type=gha, cache-to: type=gha,mode=max }
```

---

## Q50. What is software supply-chain security — SLSA, provenance, cosign, SBOM — and how do you implement it? (includes code/image signing)
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*  ⚠️ **Covers the code-signing gap**

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Supply-chain security proves an artifact is **authentic and untampered from source to deploy**. Pieces: **SBOM** (Software Bill of Materials — a manifest of every component, via Syft/CycloneDX) so you can answer "am I affected by CVE-X?"; **image/code signing** with **cosign** (Sigstore) — sign the image digest, ideally **keyless** using OIDC identity so there's no private key to steal, and verify signatures at deploy/admission time; **provenance/attestations** — SLSA-compliant metadata signed by the build system attesting *how/where* the artifact was built (defends against a compromised build); and **verification gates** — an admission controller (Kyverno/Sigstore policy-controller) that **refuses to run unsigned or unattested images**. Together: sign in CI, attach SBOM + provenance, verify in cluster. This is the modern answer to "code signing."

```bash
cosign sign --yes $ECR/app@$DIGEST                       # keyless (OIDC) signature
syft $ECR/app@$DIGEST -o cyclonedx-json > sbom.json
cosign attest --yes --predicate sbom.json --type cyclonedx $ECR/app@$DIGEST
cosign verify $ECR/app@$DIGEST --certificate-identity-regexp '.*' --certificate-oidc-issuer https://token.actions.githubusercontent.com
# cluster: Kyverno policy `verifyImages` blocks any image without a valid cosign signature
```

---

## Q51. What is progressive delivery with Argo Rollouts, and how does automated canary analysis abort a bad release?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**Argo Rollouts** replaces the `Deployment` with a `Rollout` CRD that adds real **canary** and **blue-green** strategies with **traffic shaping** (via Ingress-NGINX/Istio/SMI) and **automated analysis**. In a canary you define weighted steps (10% → 50% → 100%) with pauses; between steps an **AnalysisTemplate** queries a metrics provider (Prometheus/Datadog) for error rate / latency / success rate against a threshold. If the metric breaches, the rollout **auto-aborts and rolls back to stable** with no human — that's progressive delivery: releases are gated on live SLO evidence, not a timer. It solves the "canary but nobody was watching the dashboard at 2am" problem.

```yaml
kind: AnalysisTemplate
spec:
  metrics:
    - name: error-rate
      interval: 1m
      failureLimit: 2                 # 2 bad readings -> abort + rollback to stable
      provider: { prometheus: { address: http://prom, query: 'rate(http_5xx[2m])' } }
      successCondition: "result < 0.01"
```

---

## Q52. How do you manage multi-cluster / many-environment deployments with ArgoCD ApplicationSets?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
An **ApplicationSet** templates many `Application`s from a **generator**, eliminating per-cluster/per-env copy-paste. Generators: **List** (static set), **Cluster** (every registered cluster, optionally label-filtered), **Git** (a folder or file per app in a repo), **SCM/PR** (per repo/PR), and **Matrix/Merge** (combine generators, e.g. every app × every cluster). Change the template once and every generated Application updates. Pair with **AppProjects** for RBAC boundaries and **app-of-apps** for bootstrapping. This is the scalable pattern for "50 services across dev/stage/prod on N clusters."

```yaml
generators:
  - matrix:
      generators:
        - git: { repoURL: '...', directories: [{ path: apps/* }] }     # per app
        - clusters: { selector: { matchLabels: { env: prod } } }        # per cluster
template: { spec: { source: { path: '{{path}}' }, destination: { server: '{{server}}' } } }
```

---

## Q53. What are Helm hooks and library charts, and when do you use them?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**Helm hooks** run resources at defined points in a release lifecycle via the `helm.sh/hook` annotation — `pre-install`/`pre-upgrade` (e.g. a DB migration Job before pods roll), `post-install`, `test` (`helm test` smoke checks), with `hook-weight` for ordering and `hook-delete-policy` for cleanup. **Library charts** (`type: library`) contain **reusable template helpers** (named templates for labels, resource blocks, probes) that other charts import as a dependency — they render nothing on their own; they DRY up common boilerplate across many app charts. Use hooks for lifecycle actions, library charts to standardize chart authoring across teams.

```yaml
# pre-upgrade migration hook
metadata:
  annotations: { "helm.sh/hook": pre-upgrade, "helm.sh/hook-weight": "-1",
                 "helm.sh/hook-delete-policy": hook-succeeded }
```

---

## Q54. Monorepo vs polyrepo for CI/CD — trade-offs and how you handle each?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**Monorepo**: all services in one repo — atomic cross-service changes, unified tooling/versioning, easy shared-code refactors; but CI must be **selective** (only build/test what changed) using **path filters** or a build graph tool (Bazel/Nx/Turborepo) or you rebuild the world on every commit. **Polyrepo**: one repo per service — clean ownership/isolation, independent release cadence, smaller blast radius; but shared changes span many PRs and you need cross-repo orchestration and dependency management. CI implications: monorepo → path-filtered/affected-only pipelines + `CODEOWNERS` per directory; polyrepo → reusable central workflows so N repos stay consistent, plus a config repo for GitOps. Pick based on team topology and coupling.

```yaml
# monorepo: only run a service's pipeline when its files change
on: { push: { paths: ['services/payments/**'] } }
```

---

## Q55. How do you handle secrets in CI/CD pipelines securely (no plaintext, no long-lived tokens)?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Layered rules: (1) **Never** commit secrets or bake them into images — scan for leaks (gitleaks/trufflehog) in pre-commit + CI. (2) Prefer **OIDC** over stored cloud keys (Q46) so there's nothing to steal. (3) For app secrets, pull at runtime from a **manager** (Vault, AWS/GCP Secrets Manager, Infisical) via **short-lived** dynamic credentials; in-cluster use **External Secrets Operator** to sync into K8s Secrets, or **Sealed Secrets/SOPS** to keep *encrypted* secrets safely in Git for GitOps. (4) Scope secrets to **environments** so prod creds are unreachable from dev jobs; mask in logs; rotate automatically. (5) Least privilege + short TTL everywhere. The anti-patterns to name: plaintext in repo, static keys in org secrets, secrets in image layers.

```yaml
# External Secrets Operator: cluster pulls from Vault/SM, nothing secret lives in Git
kind: ExternalSecret
spec:
  secretStoreRef: { name: vault-backend, kind: ClusterSecretStore }
  data: [{ secretKey: db-pass, remoteRef: { key: prod/payments, property: db_password } }]
```

---

## Q56. How do you secure self-hosted GitHub Actions runners?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Self-hosted runners are risky because untrusted code can run on a persistent machine with network/credentials. Harden by: (1) using **ephemeral runners** — one job per runner, then destroyed (e.g. **Actions Runner Controller** on Kubernetes, or autoscaled VMs), so nothing persists between jobs; (2) **never** attaching self-hosted runners to **public** repos (fork PRs can execute arbitrary code); (3) least-privilege via **OIDC** rather than embedding cloud keys on the box; (4) network egress restrictions and no access to other environments; (5) pinning actions to a **full commit SHA** (not a mutable tag) to prevent supply-chain tampering; (6) isolating runners per team/environment. Ephemeral + isolated + OIDC + SHA-pinned is the safe baseline.

```yaml
# Actions Runner Controller — ephemeral, one-job-per-pod runners on K8s
kind: AutoscalingRunnerSet
spec: { template: { spec: { containers: [{ name: runner, image: ghcr.io/actions/actions-runner }] } } }
```

---

## Q57. What are ArgoCD sync waves and the app-of-apps pattern?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**Sync waves** order resource application *within* a sync using the `argocd.argoproj.io/sync-wave` annotation (lower waves apply first) — e.g. CRDs and namespaces in wave 0, databases/migrations next, then the app, then ingress — Argo waits for each wave's resources to become healthy before the next. **App-of-apps** is a bootstrapping pattern: a single "root" ArgoCD Application whose manifests are *other* Application definitions, so one apply installs an entire platform (ingress-nginx, cert-manager, monitoring, then workloads) with defined ordering. Together they give you dependency-ordered, one-click cluster bootstrap. (ApplicationSets are often preferred over hand-written app-of-apps for scale.)

```yaml
metadata:
  annotations: { argocd.argoproj.io/sync-wave: "-1" }   # DB/migrations before the app (wave 0)
```

---

## Q58. How do you shift security left with image scanning plus policy-as-code admission control?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Two enforcement points. **In CI (pre-deploy)**: scan the image (**Trivy/Grype**) and **fail the build** on HIGH/CRITICAL CVEs, generate an SBOM, and sign it — so vulnerable images never reach the registry. **In the cluster (deploy-time)**: an **admission controller** with **policy-as-code** (**Kyverno** or **OPA/Gatekeeper**) rejects non-compliant workloads regardless of how they were submitted — e.g. block `:latest` tags, unsigned images, running as root, missing resource limits, or images from untrusted registries. CI scanning is advisory-strong but bypassable; admission control is the *hard* gate. Together they enforce policy both where artifacts are built and where they run.

```yaml
# Kyverno: deny any Pod whose image isn't signed by our cosign key
kind: ClusterPolicy
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-signed-images
      match: { any: [{ resources: { kinds: [Pod] } }] }
      verifyImages: [{ imageReferences: ["*.dkr.ecr.*/*"], attestors: [{ entries: [{ keyless: { issuer: "https://token.actions.githubusercontent.com" } }] }] }]
```

---

## Q59. How do you use GitHub Actions deployment environments, required reviewers, and concurrency for safe prod deploys?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
GitHub **Environments** (`environment: production`) attach **protection rules** to a job: **required reviewers** (manual approval pauses the run before it touches prod), a **wait timer**, and **deployment branch restrictions** (only `main`/tags can deploy to prod). They also scope **environment secrets** so prod credentials are only available to prod jobs. **`concurrency`** groups serialize or cancel overlapping runs — e.g. `concurrency: deploy-prod` with `cancel-in-progress: false` ensures two deploys never race the same environment. Combined: only approved commits, only from allowed branches, only one at a time, with prod-only secrets — that's a safe deploy gate purely in Actions.

```yaml
concurrency: { group: deploy-prod, cancel-in-progress: false }   # never two prod deploys at once
jobs:
  deploy:
    environment: production      # required reviewers + branch restriction + prod secrets
    steps: [{ run: ./deploy.sh }]
```

---

## Q60. How do you version and release with automated semantic versioning and changelogs?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Drive versioning from **Conventional Commits**: `fix:` → patch, `feat:` → minor, `feat!:`/`BREAKING CHANGE` → major. A release tool (**semantic-release** or release-please) reads the commit history since the last tag, computes the next semver, generates a **changelog**, creates the **Git tag + GitHub Release**, and can publish the artifact — all automatically, so humans never hand-pick version numbers (which is exactly what caused the tag/values.yaml confusion in Q24). This gives deterministic, auditable versions that flow straight into image tags and Helm `appVersion`.

```yaml
- uses: googleapis/release-please-action@v4      # or cycjimmy/semantic-release-action
  with: { release-type: simple }
# feat: -> minor, fix: -> patch, feat!: -> major; auto tag + changelog + release
```

---

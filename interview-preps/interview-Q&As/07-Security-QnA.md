# 🔐 Security Interview Q&A — Senior DevOps / SRE

Real questions from Akshay's past interviews on secrets management, K8s RBAC, IAM, image & supply-chain security, runtime hardening, and network/PodSecurity.
Weak spots are called out with "🔴 NAIL THIS" so you can own the answers instead of outsourcing them.

---

# 🔑 Secrets Management

## Q1. Both DNS (ConfigMap) and credentials could be passed through Helm values — why the extensive custom EKS Pod Identity add-on when ready-made solutions (Secrets Manager CSI driver, mounting) already exist?
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
Built a Helm chart to install the EKS Pod Identity agent across clusters. Pod Identity gives pods temporary IAM roles/credentials so they fetch secrets from AWS Secrets Manager; defined pod identity in the deployment spec. Justified it as more secure/reliable — K8s secrets are only base64 encoded so anyone can decode them — and wanted to avoid IRSA because rotating those secrets is tedious, so used Pod Identity + Secrets Manager via ASCP for short-lived credentials. Did not clearly justify against the CSI driver.

**✅ Correct answer:**
The interviewer wanted a decision, not a description. The honest framing: the **Secrets Store CSI Driver with the AWS ASCP provider IS the off-the-shelf solution** — you don't build a custom add-on for that; you install the driver + provider and it mounts Secrets Manager/Parameter Store values as a tmpfs volume (and optionally syncs them to a native K8s Secret). What you legitimately standardized was the **identity layer**: EKS Pod Identity vs IRSA.

Own it with a crisp trade-off:
- **base64 ≠ encryption** — so don't stop at native Secrets; you need an external source of truth.
- **EKS Pod Identity over IRSA** because Pod Identity uses a cluster-side agent + an EKS API association (no OIDC provider per cluster, no annotation-baked role ARN, reusable roles across clusters, easier at fleet scale). IRSA needs an IAM OIDC provider per cluster and a trust policy tied to the SA — more moving parts to template and rotate.
- **CSI driver over Helm-injected values** because putting the secret in `values.yaml` puts it in Git/CI logs/Helm release history. The CSI mount keeps the secret out of the manifest entirely and refreshes it on rotation.
So the "custom" part is thin (a Helm chart to roll out the Pod Identity agent fleet-wide); the secret retrieval itself is the standard CSI + ASCP path.

```yaml
# SecretProviderClass — the off-the-shelf CSI + ASCP path (no custom code)
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: app-db-creds
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "prod/app/db-credentials"   # Secrets Manager secret
        objectType: "secretsmanager"
        jmesPath:
          - path: "username"
            objectAlias: "DB_USER"
          - path: "password"
            objectAlias: "DB_PASS"
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: app }
spec:
  template:
    spec:
      serviceAccountName: app-sa           # associated to an IAM role via EKS Pod Identity
      containers:
        - name: app
          image: app:1.0
          volumeMounts:
            - name: secrets-store
              mountPath: /mnt/secrets
              readOnly: true
      volumes:
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: app-db-creds
```

---

## Q2. In detail, how exactly are you updating secrets through the Git template?
**Asked in:** HCL  |  **My performance:** Partial

**My answer (from transcript):**
In the git template we had `.github/workflows` with pipelines, an `src` folder, and a Helm chart folder with per-environment subcharts, `values.yaml`, `Chart.yaml`, `.gitignore`, `Dockerfile`, pre-commits, and an Infisical file. Infisical was tied to each template with a specific path; the file got updated and executed as part of the CI process.

**✅ Correct answer:**
The precise mechanism matters. Secrets are **never** written into `values.yaml` or committed. Instead the repo holds a **reference/manifest** (an `.infisical.json` config or an `ExternalSecret`/`InfisicalSecret` CRD) that names *where* the secret lives — project + environment + path — not the secret value. At deploy time an operator or CI step authenticates (machine identity / OIDC), pulls the current values from Infisical, and materializes them into a native K8s Secret that the pod consumes. Rotation in Infisical propagates on the next sync — the Git template never changes.

Key points to say out loud: (1) the template stores **paths/identifiers, not values**; (2) auth is via a **machine identity token**, not a long-lived key; (3) the reconcile loop (operator) keeps the K8s Secret in sync so a rotation upstream flows to pods automatically.

```yaml
# What actually lives in the Git template — a reference, not the secret
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: app-secrets
spec:
  hostAPI: https://app.infisical.com/api
  authentication:
    universalAuth:
      credentialsRef:                 # machine-identity creds (bootstrap secret)
        secretName: infisical-machine-identity
        secretNamespace: default
  managedSecretReference:
    secretName: app-managed-secret     # native K8s Secret Infisical creates & keeps in sync
    secretNamespace: default
    creationPolicy: Orphan
  resyncInterval: 60                    # re-pull every 60s -> picks up rotations
```

---

## Q3. What exactly is Infisical? Is it licensed / open source?
**Asked in:** HCL  |  **My performance:** Partial

**My answer (from transcript):**
Infisical is a brand-new tool, open source but also has a licensed portion. We bought the license version and integrated it across the company's GitHub so both containerized and non-containerized apps could fetch secrets from it.

**✅ Correct answer:**
Infisical is an **open-source secrets management platform** (a HashiCorp Vault / AWS Secrets Manager alternative). Core is **MIT/Apache-style open source**; enterprise features (SSO/SAML, advanced RBAC, secret rotation at scale, audit, HSM/KMS integrations) sit behind a **commercial (Infisical Enterprise) license** — the classic open-core model. It offers a UI, CLI, Kubernetes operator, and SDKs; supports **secret versioning, point-in-time recovery, dynamic secrets, secret rotation, environment scoping (dev/stg/prod), and machine identities** for non-human auth. You can **self-host** (Docker/K8s/Helm) or use their **cloud**. It integrates with AWS Secrets Manager as a sync/backup target, and injects into both containerized (operator/CSI) and non-containerized (CLI/agent) workloads.

Compared to Vault: Infisical is easier to operate and developer-first; Vault is more powerful for dynamic backends (DB creds, PKI, transit encryption) and battle-tested at scale.

```bash
# Non-containerized app: Infisical CLI injects secrets as env vars at runtime
infisical login
infisical run --projectId=<id> --env=prod -- ./my-app     # secrets injected, never on disk

# Self-host via Helm (open-source core)
helm repo add infisical https://dl.infisical.com/helm-charts
helm install infisical infisical/infisical --set ingress.enabled=true
```

---

## Q4. Were there any pre-hooks like "no secrets should be committed," and how did you ensure it?
**Asked in:** Accion  |  **My performance:** Partial

**My answer (from transcript):**
Yes, had pre-commits plus another action (forgot its name), built into the CI/CD templates. If it detects a password keyword or encrypted information in the commit, the pipeline fails, because secrets must be stored in an external secret provider — we used Infisical integrated with the infra.

**✅ Correct answer:**
The "action he forgot" is almost certainly a **secret scanner** — `gitleaks`, `detect-secrets` (Yelp), `trufflehog`, or GitHub's native **push protection / secret scanning**. Defense in depth here is two layers: (1) a **pre-commit hook** on the developer's machine that runs the scanner *before* the commit is created, and (2) a **CI job + branch-protection required check** so nobody can bypass local hooks (they're opt-in). If the scanner matches entropy patterns or known credential formats, the pipeline **fails the merge**. The policy: secrets live only in the external provider (Infisical), never in Git — the scanner enforces it.

```yaml
# .pre-commit-config.yaml — local guard
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.4
    hooks:
      - id: gitleaks
  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: ['--baseline', '.secrets.baseline']
```
```yaml
# CI guard (non-bypassable, required status check)
jobs:
  secret-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: gitleaks/gitleaks-action@v2   # fails the build on any finding
        env: { GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
```

---

## Q5. How do you handle secrets in the cloud / in GitOps? What are your secrets-management best practices?
**Asked in:** Pure Software, HTC, GlobalLogic, HDFC  |  **My performance:** Correct

**My answer (from transcript):**
Two ways. (1) Secrets in AWS Secrets Manager with the ASCP via Pod Identity — define pod identity in the deployment, mount the Secrets Manager path, with dynamic rotation and no manual intervention. (2) Use an external secrets provider or Infisical integrated with AWS Secrets Manager, with pods fetching from the external provider via pod identities and pre-installed secret drivers. Always have an automated rotation policy so secrets rotate before expiry. In GitOps we store secrets in the secret manager and inject them into pods so they can talk to backend services.

**✅ Correct answer:**
Solid. Tighten it into principles an interviewer can score:
1. **Single source of truth** external to Git (Secrets Manager / Vault / Infisical). Native K8s Secrets are base64, not encrypted.
2. **Workload identity, not static keys** — EKS Pod Identity or IRSA give pods short-lived STS creds; no `AWS_ACCESS_KEY` anywhere.
3. **Sync into the cluster via operator/CSI** — Secrets Store CSI Driver (ASCP) or External Secrets Operator (ESO) reconcile the external secret into the pod.
4. **GitOps-safe**: commit only *references* (ExternalSecret CRDs) or **encrypted** blobs (SOPS/Sealed Secrets) — never plaintext.
5. **Rotation + audit**: automated rotation before TTL expiry, and access is logged.
6. **Encryption at rest**: enable EKS **KMS envelope encryption** for etcd so even the stored Secret objects are encrypted.

```yaml
# External Secrets Operator — GitOps-safe: this CRD is committable, the value is not
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: app-secret }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-secrets-manager, kind: SecretStore }
  target: { name: app-secret, creationPolicy: Owner }
  data:
    - secretKey: DB_PASSWORD
      remoteRef: { key: prod/app/db, property: password }
```

---

## Q6. How did you integrate AWS Secrets Manager with Kubernetes?
**Asked in:** Accion  |  **My performance:** Correct

**My answer (from transcript):**
First the secrets CSI driver, then the pod identity agent installed on the cluster as a DaemonSet. With those in place we define the pod identity in the deployment; pod identity gains temporary IAM credentials and talks to AWS Secrets Manager via the ASCP (AWS Secrets and Configuration Provider) to fetch secrets and provide them to the deployment.

**✅ Correct answer:**
Correct and well-sequenced. The full chain, named precisely:
1. Install the **Secrets Store CSI Driver** (Helm) — the generic mount mechanism.
2. Install the **AWS provider (ASCP)** — teaches the CSI driver how to talk to Secrets Manager / Parameter Store.
3. Install the **EKS Pod Identity Agent** (a DaemonSet) — provides the STS credential path to pods.
4. Create an **IAM role** with a `secretsmanager:GetSecretValue` policy and **associate it to the ServiceAccount** via an EKS Pod Identity association.
5. Author a **SecretProviderClass** naming the secret ARNs/paths; reference it as a CSI volume in the deployment.
When the pod starts, the CSI driver (using the pod's STS creds from Pod Identity) calls Secrets Manager and mounts the values at a path (and can `secretObjects`-sync them to a native Secret for env vars).

```bash
# 1-3: install the pieces
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver -n kube-system
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
aws eks create-addon --cluster-name prod --addon-name eks-pod-identity-agent

# 4: bind an IAM role to the ServiceAccount
aws eks create-pod-identity-association \
  --cluster-name prod --namespace default \
  --service-account app-sa --role-arn arn:aws:iam::111122223333:role/app-secrets-role
```

---

## Q7. How did you design the secret rotation strategy for microservices — how reliable, how frequent?
**Asked in:** Accion  |  **My performance:** Correct

**My answer (from transcript):**
We used Infisical (a Vault alternative). Infisical has a built-in default 30-day rotation policy for onboarded apps, and teams can tweak it. Infisical was integrated with AWS Secrets Manager as a bridge; in the deployment we defined pod identity and the Secrets Manager path, so when pod identity gets temporary credentials it fetches the secrets and provides them to the pod. Applied across all environments including production.

**✅ Correct answer:**
Good. Deepen the "how reliable" part, which is what senior interviews probe. Rotation reliability rests on two mechanisms:
- **Rotation Lambda / rotation function** (Secrets Manager) or Infisical's rotation engine creates a **new version** of the secret, tests it, then flips the `AWSCURRENT` label. If the new credential fails validation it stays on `AWSPENDING` and the old one keeps serving — **no outage**.
- **In-cluster reconcile** (CSI `rotation-reconciler` or ESO `refreshInterval`) re-pulls on an interval so pods pick up the new value. For apps that cache creds at startup, you either **restart via a checksum annotation** (Reloader) or the app re-reads the mounted file.

Frequency: 30 days default, shorter (7 days) for high-value creds, or **dynamic secrets** (Vault DB engine / Infisical dynamic) that mint a fresh credential per lease so there's nothing long-lived to rotate. Reinforce: their one prod incident came from *no* auto-rotation (expired secret) — auto-rotation fixed it.

```json
// Secrets Manager rotation config — new version tested before AWSCURRENT flips
{
  "SecretId": "prod/app/db",
  "RotationLambdaARN": "arn:aws:lambda:us-east-1:111122223333:function:SecretsManagerRotation",
  "RotationRules": { "AutomaticallyAfterDays": 30 },
  "RotateImmediately": false
}
```

---

## Q8. Every integration has limitations — what problems did you face, and would you have used Parameter Store instead of Secrets Manager?
**Asked in:** Accion  |  **My performance:** Correct

**My answer (from transcript):**
Initially tried native K8s secrets, but base64 means anyone can decode them. Before Infisical there was no automatic rotation; we had one production failure because secrets expired. After onboarding Infisical with auto-rotation these were fixed. (Did not directly compare Parameter Store vs Secrets Manager.)

**✅ Correct answer:**
Add the comparison you skipped — it's a common follow-up:

| | **Secrets Manager** | **SSM Parameter Store** |
|---|---|---|
| Built-in rotation | ✅ native (rotation Lambda) | ❌ (DIY via Lambda/EventBridge) |
| Cost | ~$0.40/secret/mo + API | Standard params **free**; Advanced ~$0.05 |
| Size limit | 64 KB | 4 KB (standard) / 8 KB (advanced) |
| Cross-account / replication | ✅ | limited |
| Best for | credentials, DB passwords, rotating secrets | config, feature flags, non-rotating params |

**Rule of thumb:** rotating credentials → Secrets Manager; plain config and low-cost non-secret params → Parameter Store. Many teams use **both** (SSM can even reference a Secrets Manager secret). Other real limitations to name: CSI mount adds pod-start latency and a hard dependency on the secrets backend being reachable; API throttling at scale; and native K8s Secret sync re-introduces base64-at-rest unless etcd KMS encryption is on.

```bash
# Parameter Store (SecureString, KMS-encrypted) — cheap config/secrets
aws ssm put-parameter --name /prod/app/db-password --type SecureString \
  --value 's3cr3t' --key-id alias/aws/ssm
aws ssm get-parameter --name /prod/app/db-password --with-decryption
```

---

## Q9. Did you use HashiCorp Vault — what's the difference / what did you use?
**Asked in:** Pure Software  |  **My performance:** Correct

**My answer (from transcript):**
Instead of HashiCorp we used Infisical (a Vault competitor), integrated at the platform level with AWS Secrets Manager acting as a backup, so all platform and application secrets were fetched from Infisical.

**✅ Correct answer:**
Correct. Sharpen the "difference" so you can defend the choice:
- **Vault** — the enterprise standard. Strengths: **dynamic secrets** (mint DB/cloud creds on demand with a TTL/lease), **PKI engine** (issue short-lived certs), **transit engine** (encryption-as-a-service), pluggable auth (K8s, OIDC, AWS IAM), fine-grained policies. Cost: operationally heavy (unseal, HA, storage backend, upgrades).
- **Infisical** — developer-first, simpler UI/CLI/operator, faster onboarding, open-core. Great for static app secrets, env scoping, versioning, rotation. Less mature than Vault for dynamic backends and PKI.

Say why Infisical fit: lower operational burden, git-native workflow, good K8s operator, and Secrets Manager as the durable backup/sync target. If asked "when would you pick Vault?" — when you need **dynamic DB creds, PKI/cert issuance, or transit encryption**.

```bash
# Vault dynamic secret — a credential that never needs rotating (short lease)
vault read database/creds/readonly
# Key            Value
# lease_id       database/creds/readonly/abc123
# lease_duration 1h
# username       v-token-readonly-x9f2   (auto-revoked at TTL)
# password       A1b2C3d4...
```

---

# ☸️ Kubernetes RBAC

## Q10. What is Role and RoleBinding in Kubernetes?
**Asked in:** Pure Software  |  **My performance:** Partial 🔴 NAIL THIS

**My answer (from transcript):**
A Role provides permissions through policies so that once assigned to a pod/deployment, the pods can access a specific **cloud resource** (e.g., an AWS load balancer). Roles are assigned to deployments via RoleBinding through a service account.

**✅ Correct answer — this was WRONG, fix the mental model:**
Kubernetes RBAC has **nothing to do with cloud/AWS resources.** A `Role` grants permissions on the **Kubernetes API** — verbs (`get`, `list`, `watch`, `create`, `update`, `delete`) on resources (`pods`, `secrets`, `deployments`, `configmaps`) **within a namespace**. Access to *cloud* resources (an ALB, an S3 bucket) is granted by **IAM** via IRSA / EKS Pod Identity — that's a completely separate system. You conflated the two.

The four objects:
- **Role** — namespaced permissions (what API actions are allowed, on which resources).
- **ClusterRole** — same but cluster-wide, or for cluster-scoped resources (nodes, PVs) and non-namespaced verbs.
- **RoleBinding** — binds a Role (or ClusterRole) to a **subject** (User, Group, or **ServiceAccount**) *within a namespace*.
- **ClusterRoleBinding** — binds a ClusterRole cluster-wide.

So: RoleBinding attaches API permissions to a ServiceAccount; the pod uses that SA's **token** to call the kube-apiserver. It does **not** grant AWS access.

```yaml
# Role: read-only on pods & their logs, in namespace "dev" — pure K8s API perms
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { namespace: dev, name: pod-reader }
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { namespace: dev, name: read-pods }
subjects:
  - kind: ServiceAccount
    name: app-sa
    namespace: dev
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```
```bash
# Verify what a ServiceAccount can actually do (least-privilege check)
kubectl auth can-i list pods --as=system:serviceaccount:dev:app-sa -n dev   # yes
kubectl auth can-i delete secrets --as=system:serviceaccount:dev:app-sa -n dev  # no
```

---

## Q11. Explain RBAC in Kubernetes and why we use it.
**Asked in:** GlobalLogic  |  **My performance:** Partial

**My answer (from transcript):**
We use RBAC to harden and tighten the cluster against unwanted access. Only authorized access is given, otherwise users might misbehave, delete or change existing configurations, directly impacting applications. (Rambling; didn't mention Roles/RoleBindings/ServiceAccounts specifics.)

**✅ Correct answer:**
RBAC (Role-Based Access Control) governs **who can perform which actions on which Kubernetes API resources**. Structure it as: **Subjects** (Users, Groups, ServiceAccounts) are bound — via **RoleBinding/ClusterRoleBinding** — to **Roles/ClusterRoles** that list allowed **verbs on resources**. It's **additive and deny-by-default**: no rule = no access; there are no "deny" rules, you simply don't grant.

Why we use it — principle of **least privilege**:
- Humans get scoped access (e.g., devs read-only in their namespace, platform team admin).
- **Workloads** get scoped SAs so a compromised pod can't read every Secret or delete Deployments (blast-radius reduction).
- Enables auditing, separation of duties, and multi-tenancy.

Name the concrete objects (Role, ClusterRole, RoleBinding, ClusterRoleBinding, ServiceAccount) and the check tool (`kubectl auth can-i`) to avoid sounding vague.

```yaml
# Least-privilege ServiceAccount for a CI deployer, scoped to one namespace
apiVersion: v1
kind: ServiceAccount
metadata: { name: ci-deployer, namespace: app }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { namespace: app, name: deployer }
rules:
  - apiGroups: ["apps", ""]
    resources: ["deployments", "pods", "services", "configmaps"]
    verbs: ["get", "list", "create", "update", "patch"]   # no delete, no secrets
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { namespace: app, name: ci-deployer-binding }
subjects: [{ kind: ServiceAccount, name: ci-deployer, namespace: app }]
roleRef: { kind: Role, name: deployer, apiGroup: rbac.authorization.k8s.io }
```

---

# 🪪 IAM & Cloud Identity

## Q12. What are the important parameters inside an IAM policy (not the permission)?
**Asked in:** Barclays  |  **My performance:** Incorrect 🔴 NAIL THIS

**My answer (from transcript):**
Kept answering with permissions (S3 read / read-write / full bucket access). Interviewer wanted policy **elements** — Effect, Action, Resource, Principal. Only recalled "Resource is S3" and "access mode," admitted "I've done this long back... I need to look into that."

**✅ Correct answer — memorize the JSON structure:**
An IAM policy is a JSON document. The key **elements** (this is what he was asked):
- **`Version`** — policy language version (`2012-10-17`).
- **`Statement`** — array of one or more statements.
- **`Sid`** — optional statement ID/label.
- **`Effect`** — **`Allow`** or **`Deny`** (explicit Deny always wins).
- **`Action`** — the API operations, e.g. `s3:GetObject`, `s3:PutObject`.
- **`Resource`** — the ARN(s) the actions apply to.
- **`Principal`** — *who* the policy applies to (**resource-based** policies only: bucket policies, trust policies; not used in identity-based policies attached to a user/role).
- **`Condition`** — optional guardrails (source IP, MFA, tag match, `aws:SecureTransport`).

Mnemonic: **P-A-R-C-E** → Principal, Action, Resource, Condition, Effect. Also distinguish **identity-based** (attached to user/role, no Principal) vs **resource-based** (attached to a resource, has Principal).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowReadFromReportsBucket",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::reports-bucket",
        "arn:aws:s3:::reports-bucket/*"
      ],
      "Condition": {
        "IpAddress": { "aws:SourceIp": "10.0.0.0/16" },
        "Bool": { "aws:SecureTransport": "true" }
      }
    }
  ]
}
```

---

## Q13. An application on EC2 needs read access to an S3 bucket — how do you achieve that securely?
**Asked in:** Barclays  |  **My performance:** Partial

**My answer (from transcript):**
Assign the relevant IAM roles and policies to the EC2 instance; the instance assumes the role for that S3 bucket with read (or read/write) access. (Correct high-level but didn't name the instance profile explicitly.)

**✅ Correct answer:**
Right idea, name the missing piece: an EC2 instance can't hold an IAM role directly — it gets one through an **instance profile** (a container for exactly one role). The flow:
1. Create an **IAM role** with an EC2 trust policy (`Principal: ec2.amazonaws.com`) and attach a least-privilege S3 **read-only** policy (`s3:GetObject`, `s3:ListBucket` on the specific bucket ARN).
2. Attach the role to the instance via an **instance profile**.
3. The app uses the SDK's **default credential chain** — it pulls **temporary STS credentials** from **IMDSv2** at `http://169.254.169.254`. No access keys on disk, auto-rotated.
Say the security wins: **no static keys**, **short-lived rotating creds**, **least privilege scoped to one bucket**, and enforce **IMDSv2** (hop limit, token-required) to prevent SSRF credential theft.

```bash
# Role assumable by EC2, scoped read-only to one bucket, delivered via instance profile
aws iam create-role --role-name app-s3-read \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam put-role-policy --role-name app-s3-read --policy-name s3ro \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::my-bucket","arn:aws:s3:::my-bucket/*"]}]}'
aws iam create-instance-profile --instance-profile-name app-s3-read
aws iam add-role-to-instance-profile --instance-profile-name app-s3-read --role-name app-s3-read
# Enforce IMDSv2 so creds can't be stolen via SSRF
aws ec2 modify-instance-metadata-options --instance-id i-0abc --http-tokens required --http-put-response-hop-limit 1
```

---

# 🖼️ Image & Supply-Chain Security

## Q14. What is code signing?
**Asked in:** PwC  |  **My performance:** Didn't know 🔴 NAIL THIS

**My answer (from transcript):**
Didn't recognize the term (heard it as "port signing / quote signing"). After being told it secures the CI/CD pipeline, pivoted to general pipeline security (external secret tools, Infisical) rather than explaining code signing. Effectively did not know it.

**✅ Correct answer:**
**Code/image signing** cryptographically proves **who built an artifact and that it hasn't been tampered with** since. The builder signs the artifact (or its digest) with a **private key**; consumers verify with the **public key** before running it. In the container world the standard is **Sigstore/cosign**:
- **cosign** signs an image by its **digest** and stores the signature in the registry (as an OCI artifact).
- **Keyless signing** uses **Fulcio** (short-lived certs tied to an OIDC identity — e.g., the GitHub Actions workflow) and logs the signature in **Rekor** (a public transparency log) — so there's no long-lived private key to protect.
- At deploy time an **admission controller** (Kyverno / Sigstore Policy Controller / Connaisseur) **verifies the signature and rejects unsigned or untrusted images.**

Why it matters: it stops supply-chain attacks where an attacker pushes a malicious image to your registry — an unsigned or wrongly-signed image never gets admitted. This ties into **SLSA** provenance and image integrity.

```bash
# Keyless sign in CI (identity = the GitHub Actions OIDC token), then verify at deploy
cosign sign --yes \
  ghcr.io/acme/app@sha256:abcd1234...

cosign verify \
  --certificate-identity "https://github.com/acme/app/.github/workflows/build.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/acme/app@sha256:abcd1234...
```
```yaml
# Kyverno: reject any image that isn't cosign-verified
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: verify-image-signature }
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-signature
      match: { any: [{ resources: { kinds: ["Pod"] } }] }
      verifyImages:
        - imageReferences: ["ghcr.io/acme/*"]
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/acme/*"
```

---

## Q15. Are you familiar with the shift-left approach?
**Asked in:** Shell  |  **My performance:** Didn't know

**My answer (from transcript):**
Said no. After it was explained, noted they'd implemented SAST/DAST in the pipeline, which is a shift-left practice.

**✅ Correct answer:**
**Shift-left** = move testing and security **earlier** ("to the left") in the SDLC — catch issues at commit/build time instead of in production, when they're cheapest to fix. In DevSecOps it means embedding checks at every stage:
- **IDE / pre-commit**: secret scanning (gitleaks), linting, `detect-secrets`.
- **PR / build (SAST)**: SonarQube, Semgrep, Checkov/tfsec for IaC, dependency scanning (SCA — Snyk, Dependabot, Trivy fs).
- **Image build**: Trivy/Grype image scan, SBOM generation, image signing.
- **Pre-deploy (DAST)**: OWASP ZAP / Veracode against a running staging app.
- **Admission**: OPA/Kyverno policy gates.
The payoff: a vuln caught in a pre-commit hook costs minutes; the same vuln in prod costs an incident. You *did* practice it (SAST/DAST gates) — just name the term and the stage-by-stage mapping. Contrast with **shift-right** (observability, runtime security, chaos testing in prod) — mature teams do both.

```yaml
# One pipeline, checks shifted left across stages
stages:
  - pre-commit:  [gitleaks, detect-secrets]          # earliest
  - build-sast:  [sonarqube, semgrep, checkov]       # static analysis
  - image-scan:  [trivy image, syft sbom, cosign sign]
  - deploy-dast: [owasp-zap, veracode]               # against staging
  - admission:   [kyverno-verify-images]             # gate at cluster
```

---

## Q16. Did you use SAST tools or any dependency management?
**Asked in:** Accion  |  **My performance:** Didn't know

**My answer (from transcript):**
Aware that SAST was already part of the CI/CD templates but didn't personally work on it.

**✅ Correct answer:**
Own it concretely rather than deferring. Two distinct scan types:
- **SAST (Static Application Security Testing)** — scans **source code** without running it, for injection flaws, insecure APIs, hardcoded secrets. Tools: **SonarQube, Semgrep, Checkmarx, CodeQL**; for IaC: **Checkov, tfsec, KICS**.
- **SCA / Dependency management** — scans your **third-party libraries** for known CVEs and license risk. Tools: **Snyk, Dependabot, Trivy (fs mode), OWASP Dependency-Check, Renovate**. This is where most real-world vulns live (Log4Shell was a dependency CVE), so it's arguably more impactful than SAST.
Wire both as **required PR checks** that fail on high/critical findings. Even if a platform team owns the template, you should be able to explain what each stage does and read its output.

```yaml
# GitHub Actions: SAST + SCA as blocking checks
jobs:
  sast:
    steps:
      - uses: actions/checkout@v4
      - uses: returntocorp/semgrep-action@v1     # SAST
        with: { config: p/ci }
  sca:
    steps:
      - uses: actions/checkout@v4
      - uses: aquasecurity/trivy-action@master   # dependency/CVE scan
        with: { scan-type: fs, severity: HIGH,CRITICAL, exit-code: '1' }
```

---

## Q17. How do you scan images for vulnerabilities? Do you have hands-on with Trivy?
**Asked in:** GlobalLogic, Shell  |  **My performance:** Partial / Didn't know 🔴 NAIL THIS (own Trivy)

**My answer (from transcript):**
Use Trivy and SonarQube in CI. Previous org used Veracode to scan images; once no vulnerabilities it was pushed to ECR. (On Trivy hands-on at Shell: "No, that was done by the security team.")

**✅ Correct answer — own the image-scanning story yourself:**
**Trivy** (by Aqua) is the de-facto open-source scanner. It scans a container image layer-by-layer against vulnerability DBs (NVD, distro advisories) and reports **CVEs in OS packages and app dependencies**, plus **misconfigurations, hardcoded secrets, and licenses**. It can also generate an **SBOM**. Key facts to say:
- Scans by **severity** (`--severity HIGH,CRITICAL`) and can **fail the build** (`--exit-code 1`).
- Runs anywhere: CLI, CI step, or **as an admission/operator** (Trivy Operator continuously scans running workloads and writes `VulnerabilityReport` CRDs).
- Correct pipeline placement: build image → **Trivy scan** → fail on HIGH/CRITICAL → sign (cosign) → push to ECR → deploy.

Note the correction on your original answer: **SonarQube is SAST (source), not an image scanner**; **Trivy/Grype/ECR-native scanning** scan *images*. Don't conflate them. Even though the security team ran it before, you can now run `trivy image myapp:1.0` yourself — do it once so it's real.

```bash
# Scan an image, fail the pipeline on serious CVEs, and emit an SBOM
trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed myapp:1.0
trivy image --format cyclonedx --output sbom.json myapp:1.0

# Also scan IaC and filesystem
trivy config ./terraform          # misconfigurations
trivy fs --scanners vuln,secret . # deps + hardcoded secrets
```
```yaml
# Trivy Operator: continuous scanning of running workloads
# kubectl get vulnerabilityreports -A   -> shows CVE counts per workload
```

---

## Q18. In DevOps, what compliance best practices have you followed and applied?
**Asked in:** Compunnel  |  **My performance:** Partial

**My answer (from transcript):**
Branching strategy in the GitHub org — code merged via PR approved by 3+ engineers; for production, code-owners approval plus an RC process via Jira.

**✅ Correct answer:**
Good start (that's **change management / separation of duties**), but compliance is broader. Frame it against control families auditors care about:
- **Access control & least privilege** — RBAC, IAM, MFA, no shared creds, periodic access reviews.
- **Change management** — PR reviews, **branch protection**, CODEOWNERS, signed commits, immutable audit trail (who deployed what, when).
- **Secrets management** — no secrets in Git, external vault, rotation, encryption at rest/in transit.
- **Vulnerability & patch management** — SAST/DAST/SCA gates, image scanning, SLA to remediate CVEs.
- **Audit & logging** — CloudTrail, kube-apiserver audit logs, centralized/immutable log storage, retention.
- **Policy-as-code** — OPA/Kyverno/Checkov to *enforce* controls automatically.
- **Standards mapping** — SOC 2, ISO 27001, PCI-DSS, CIS Benchmarks (run **kube-bench** for CIS K8s). For a bank (HDFC/Barclays) mention **encryption, data residency, and segregation of duties** explicitly.

```yaml
# Branch protection as code (compliance control: change management + SoD)
# GitHub ruleset (illustrative)
required_pull_request_reviews:
  required_approving_review_count: 3
  require_code_owner_reviews: true
  dismiss_stale_reviews: true
required_status_checks:
  strict: true
  contexts: [secret-scan, sast, sca, image-scan]
enforce_admins: true
required_signatures: true          # signed commits
```

---

## Q19. Anything else in terms of compliance best practices? (policy-as-code)
**Asked in:** Compunnel  |  **My performance:** Partial

**My answer (from transcript):**
There was a POC for **Kyverno** to implement policy-as-code but it was still in progress and I wasn't much part of it.

**✅ Correct answer:**
**Policy-as-code** enforces compliance automatically at admission time so violations never reach the cluster. The two major engines:
- **Kyverno** — Kubernetes-native, policies are **YAML** (no new language). Can **validate** (reject bad resources), **mutate** (inject defaults like securityContext), **generate** (auto-create NetworkPolicies/RoleBindings), and **verifyImages** (cosign). Easiest to adopt.
- **OPA/Gatekeeper** — uses **Rego** language, more expressive for complex cross-object logic, portable beyond K8s.
Common enforced policies: disallow `:latest` tags, require resource limits, block privileged/hostPath pods, require signed images, enforce labels, restrict registries to your ECR. Since it was a POC you weren't deep in — but be able to write a basic Kyverno rule. Also mention **Checkov/OPA Conftest** for policy-as-code on **Terraform** before apply.

```yaml
# Kyverno: block privileged containers and require resource limits (compliance gate)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: pod-security-baseline }
spec:
  validationFailureAction: Enforce
  rules:
    - name: no-privileged
      match: { any: [{ resources: { kinds: ["Pod"] } }] }
      validate:
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false"
    - name: require-limits
      match: { any: [{ resources: { kinds: ["Pod"] } }] }
      validate:
        message: "CPU/memory limits are required."
        pattern:
          spec:
            containers:
              - resources: { limits: { memory: "?*", cpu: "?*" } }
```

---

## Q20. What is your take on "secure by design"? How do you ensure it, with an example?
**Asked in:** Shell  |  **My performance:** Partial

**My answer (from transcript):**
(Framed around K8s) Harden with least-privilege access, disable public/unauthorized access, provide a secure way to communicate secrets, set up network policies, security groups, and firewalls so requests flow through proper routes.

**✅ Correct answer:**
Good instincts; give it structure. **Secure by design** = security is a **default property of the architecture**, not bolted on later. Core principles:
- **Least privilege** everywhere (IAM, RBAC, SAs).
- **Secure defaults / deny-by-default** — default-deny NetworkPolicies, non-root containers, read-only root FS, drop all Linux capabilities.
- **Defense in depth** — multiple independent layers (WAF → SG → NetworkPolicy → PodSecurity → app authz).
- **Zero trust** — authenticate/authorize every request; no implicit network trust; mTLS between services (service mesh).
- **Minimize attack surface** — distroless/minimal base images, no shell in prod images, private subnets, no public API server endpoint.
- **Secure supply chain** — signed images, SBOMs, scanned dependencies.
- **Encryption** in transit (TLS) and at rest (KMS).

Concrete example to give: a pod that runs **non-root, read-only FS, all caps dropped, seccomp RuntimeDefault**, in a namespace with a **default-deny NetworkPolicy**, pulling only **signed images from ECR**, with secrets from Vault via short-lived identity. That's secure-by-design end to end.

```yaml
# Secure-by-design pod: hardened securityContext (deny-by-default posture)
apiVersion: v1
kind: Pod
metadata: { name: hardened-app }
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: app
      image: ghcr.io/acme/app@sha256:abcd...   # pinned digest, signed
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      resources: { limits: { cpu: "500m", memory: "256Mi" } }
```

---

## Q21. How do you ensure security in your CI/CD pipeline? What DevSecOps / vulnerability management do you follow?
**Asked in:** PwC, PwC-K8s, HTC, Shell  |  **My performance:** Correct

**My answer (from transcript):**
SAST + DAST. SAST: pre-commit, Checkov (IaC), SonarQube (code vulns); once quality gates pass the image is built. DAST: Veracode/Trivy scans the image and app; only if all pass is the image pushed to ECR, then ArgoCD deploys. Reinforced shift-left — catch vulns at the first stage.

**✅ Correct answer:**
Strong answer. One precision fix and a couple of additions:
- **Terminology:** SonarQube and Checkov are **SAST/IaC (static)**. **Trivy** is **image/dependency scanning (SCA)**. **Veracode/OWASP ZAP** are **DAST (dynamic, against a running app)**. Don't call SonarQube dynamic (you did in one transcript).
- **Full DevSecOps chain:** pre-commit secret scan → SAST (Sonar/Semgrep) → IaC scan (Checkov/tfsec) → SCA (Trivy/Snyk) → build → **image scan + SBOM + cosign sign** → push to ECR → DAST (ZAP/Veracode) on staging → **admission policy verify (Kyverno)** → ArgoCD deploy → **runtime scanning (Trivy Operator/Falco)**.
- **Vulnerability management as a lifecycle:** not just scanning — **triage by severity/CVSS, an SLA to remediate (e.g., critical in 24-48h), suppression of false positives with justification, and tracking/metrics** (mean time to remediate).
- **Pipeline hardening itself:** least-privilege runners, OIDC to cloud (no static keys), pinned action SHAs, protected secrets.

```yaml
# End-to-end DevSecOps gate (fails closed at each stage)
jobs:
  security:
    steps:
      - uses: actions/checkout@v4
      - uses: gitleaks/gitleaks-action@v2                 # secrets
      - uses: returntocorp/semgrep-action@v1              # SAST
      - run: checkov -d ./iac                             # IaC static
      - uses: aquasecurity/trivy-action@master            # SCA + image
        with: { image-ref: myapp:${{ github.sha }}, severity: CRITICAL, exit-code: '1' }
      - run: cosign sign --yes $ECR/myapp@${{ steps.build.outputs.digest }}
      - run: aws ecr describe-image-scan-findings --repository-name myapp # ECR native scan
```

---

## Q22. How do you secure your GitHub Actions pipeline?
**Asked in:** Pure Software  |  **My performance:** Correct

**My answer (from transcript):**
Secure via SAST and DAST; provide fine-grained least-privilege access so only required engineers get certain permissions; store secrets in an external provider like Infisical, Vault, or an external secrets provider.

**✅ Correct answer:**
Good — add the **GitHub-Actions-specific** hardening, which is what this question is really testing:
- **OIDC to cloud, not static keys** — use `id-token: write` + `aws-actions/configure-aws-credentials` to assume a role; delete all long-lived `AWS_ACCESS_KEY` secrets.
- **Least-privilege `GITHUB_TOKEN`** — set `permissions:` to `contents: read` by default; grant more only per-job.
- **Pin actions to a full commit SHA**, not a mutable tag (`@v4` can be re-pointed by a compromised maintainer).
- **Protect secrets** — use **environments** with required reviewers for prod; never `echo` secrets; beware `pull_request_target` with untrusted PRs.
- **Restrict which actions can run** (allowlist), require **branch protection + required checks**, and enable **secret scanning + push protection** on the repo.
- **Sign artifacts/images** produced by the pipeline (cosign keyless via the workflow's OIDC identity).

```yaml
# Hardened workflow: OIDC (no static keys), least-priv token, pinned action
permissions:
  contents: read
  id-token: write          # for OIDC to AWS
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29  # pinned SHA
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::111122223333:role/gha-deploy
          aws-region: us-east-1        # short-lived STS creds, no secrets stored
```

---

# 🛡️ Runtime / PodSecurity / Network

## Q23. What kind of security do you generally add to your pods in Kubernetes?
**Asked in:** PwC-K8s  |  **My performance:** Correct

**My answer (from transcript):**
Disable root access; scan images with Trivy for vulnerabilities/hardcoded secrets; enable Pod Security Standards (baseline and privileged levels).

**✅ Correct answer:**
Correct — one accuracy fix and depth. Pod Security Standards have **three** levels: **Privileged** (unrestricted), **Baseline** (blocks known privilege escalations), **Restricted** (heavily hardened — non-root, no caps, seccomp). You want **Restricted** for prod, not Privileged. Since Kubernetes 1.25, PSPs are gone; enforcement is via **Pod Security Admission (PSA)** — a built-in admission controller you enable per-namespace with labels (`enforce`, `audit`, `warn` modes).

Full pod hardening checklist:
- **securityContext:** `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `drop: [ALL]` capabilities, `seccompProfile: RuntimeDefault`.
- **PSA label** the namespace `restricted`.
- **Resource limits** (prevents noisy-neighbor / DoS).
- **NetworkPolicy** default-deny.
- **No hostPath/hostNetwork/hostPID**, no privileged.
- **Signed, scanned images**; secrets via CSI/external, not env from Git.
- **Runtime detection** (Falco / CrowdStrike Falcon) for anomalous syscalls.

```yaml
# Enforce the Restricted standard on a namespace via Pod Security Admission
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

---

## Q24. What will you do if you detect malicious / unauthorized access to a cluster?
**Asked in:** HTC  |  **My performance:** Correct

**My answer (from transcript):**
Cluster hardening: give RBAC access only to specific DevOps/K8s engineers, deny everyone else from kubectl. If malicious logins come from an IP range, enable kube-apiserver audits to find the source, then apply firewall rules (SGs, WAF, NACLs) to deny at the firewall level. Also set up network policies so engineers only access specific namespaces.

**✅ Correct answer:**
Good response — organize it as **incident response**, and mention **runtime detection** (this is where CrowdStrike fits):
1. **Detect** — runtime security tooling (**CrowdStrike Falcon / Falco**) alerts on anomalous behavior (shell in a container, unexpected outbound, privilege escalation). kube-apiserver **audit logs** + GuardDuty (EKS) identify the source and actions.
2. **Contain** — isolate the affected workload with a **default-deny NetworkPolicy**, cordon/quarantine the node, and **revoke credentials**: rotate the compromised ServiceAccount token/kubeconfig, cut the offending IAM role, tighten SGs/NACLs/WAF.
3. **Eradicate** — kill malicious pods, roll images back to a known-good signed digest, patch the exploited CVE.
4. **Recover** — redeploy from trusted artifacts, verify integrity (signatures), restore.
5. **Post-incident** — audit-log forensics, blast-radius review, harden (least-privilege RBAC, private API endpoint, network policies, PSA restricted).

Key additions to your answer: **runtime detection tool**, **token/credential rotation**, and **private API server endpoint** (so kubectl isn't reachable from the internet at all).

```yaml
# Containment: default-deny all traffic to/from a compromised namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: quarantine, namespace: compromised }
spec:
  podSelector: {}                 # all pods
  policyTypes: [Ingress, Egress]  # deny both directions (no rules = deny all)
```
```bash
# Revoke: rotate the ServiceAccount token, audit who did what
kubectl delete secret <sa-token> -n compromised     # invalidate token
kubectl create token <sa> --duration=10m -n app     # short-lived replacement
# Forensics from audit log
grep '"user":{"username":"suspect"' /var/log/kube-apiserver/audit.log | jq .
```

---

## Q25. How did you provide developers access to environments — direct access or only through the pipeline?
**Asked in:** Shell  |  **My performance:** Correct

**My answer (from transcript):**
Everything went through us. Developers had no cluster access; they only had access to their Git pipelines and ArgoCD applications to view logs, but no cluster access.

**✅ Correct answer:**
Correct — this is textbook **GitOps + least privilege**, articulate why it's the right control:
- **No direct kubectl to prod** — humans don't mutate the cluster; the only writer is the **GitOps controller** (ArgoCD) reconciling from Git. This gives an **immutable audit trail** (every change is a reviewed, signed commit) and **separation of duties**.
- Developers get **scoped, read-only visibility**: ArgoCD UI for sync status/logs, or read-only RBAC in their own namespace for `kubectl logs/get` — never `delete`/`exec` in prod.
- **Break-glass**: emergency elevated access is time-bound, logged, and reviewed (e.g., via a JIT access request), not standing.
- Enforced with **RBAC** (per-namespace read-only roles), **ArgoCD RBAC/SSO/projects**, and a **private API endpoint** so the cluster isn't directly reachable.

This is exactly the model to describe as "developers ship via PR → CI → ArgoCD, and observe via read-only tooling."

```yaml
# Developer gets read-only visibility in their namespace only — no write, no exec
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { namespace: team-a, name: dev-readonly }
rules:
  - apiGroups: ["", "apps"]
    resources: ["pods", "pods/log", "deployments", "services", "events"]
    verbs: ["get", "list", "watch"]      # explicitly no create/delete/exec
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { namespace: team-a, name: dev-readonly-binding }
subjects: [{ kind: Group, name: team-a-devs, apiGroup: rbac.authorization.k8s.io }]
roleRef: { kind: Role, name: dev-readonly, apiGroup: rbac.authorization.k8s.io }
```

---

# 🔺 Advanced Questions to Master (not asked yet — practice these)

## A1. How do you design RBAC for least privilege, and how do you audit for over-permissioned subjects?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Start from **deny-by-default**: grant the minimum verbs/resources per subject, prefer namespaced **Roles** over ClusterRoles, avoid wildcards (`*`) and the built-in `cluster-admin`. Give each workload its **own ServiceAccount** (never the `default` SA, and set `automountServiceAccountToken: false` when a pod needs no API access). Audit continuously: `kubectl auth can-i --list`, tools like **rbac-lookup**, **kubectl-who-can**, **rakkess**, and Krane/rbac-tool to find dangerous grants (secrets read, `escalate`, `bind`, `impersonate`, pod/exec). Review bindings to `system:masters`.

```bash
kubectl who-can get secrets -A                 # who can read secrets everywhere
kubectl auth can-i --list --as=system:serviceaccount:app:ci-deployer -n app
rbac-tool analysis                              # flag risky roles (escalate/bind/*)
```

---

## A2. Explain Kubernetes ServiceAccount tokens — legacy vs bound/projected tokens.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
**Legacy** SA tokens were non-expiring JWTs auto-created as a Secret per SA — a standing credential that never rotated (a real risk if leaked). Modern K8s (1.22+ **BoundServiceAccountTokenVolume**) uses **projected, time-bound tokens**: kubelet mints a short-lived JWT (default ~1h, auto-rotated) that is **audience-bound and tied to the pod's lifetime** — it's invalidated when the pod dies. Tokens are no longer auto-stored as Secrets (1.24+); create one explicitly with `kubectl create token` (short-lived) or a bound Secret only if you must. Projected tokens with a custom **audience** are what OIDC federation (IRSA) relies on.

```yaml
volumes:
  - name: token
    projected:
      sources:
        - serviceAccountToken:
            path: token
            expirationSeconds: 3600     # short-lived, auto-rotated
            audience: sts.amazonaws.com # bound to a specific audience
```

---

## A3. IRSA vs EKS Pod Identity — how do they differ and when do you choose each?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Both give pods **short-lived IAM credentials** without static keys, mapping a K8s ServiceAccount to an IAM role.
- **IRSA** — uses an **IAM OIDC provider per cluster**; the SA is annotated with the role ARN; the role's **trust policy** references the OIDC provider + SA. Works on EKS and self-managed clusters; more setup, and the trust policy must be edited per role.
- **Pod Identity** (newer) — a **cluster add-on agent**; you create an **association** (`cluster + namespace + SA → role`) via the EKS API. No per-cluster OIDC provider, **roles are reusable across clusters**, simpler trust policy (`pods.eks.amazonaws.com`). EKS-only.
**Choose Pod Identity** for new EKS setups at fleet scale (less config, reusable roles); **IRSA** if you need non-EKS clusters or already have it wired.

```bash
aws eks create-pod-identity-association --cluster-name prod \
  --namespace app --service-account app-sa \
  --role-arn arn:aws:iam::111122223333:role/app-role
```

---

## A4. Secrets Store CSI Driver vs External Secrets Operator — architecture and trade-offs.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
- **Secrets Store CSI Driver (+ provider)** — **mounts** external secrets into the pod as a **tmpfs volume** at runtime; nothing is stored in etcd unless you opt into `secretObjects` sync. Secret exists only while the pod runs; supports rotation reconcile. Best when you want secrets **only in memory** and never as a K8s Secret.
- **External Secrets Operator (ESO)** — a controller that **reconciles** an external secret into a **native K8s Secret** object (`ExternalSecret` CRD), refreshed on an interval. Best for **GitOps** (commit the CRD, not the value) and when apps consume secrets as env vars or when many workloads share one Secret.
Trade-off: CSI = smaller footprint, no etcd copy (more secure), but adds pod-start dependency; ESO = flexible/GitOps-friendly but the materialized Secret lives in etcd (enable KMS encryption).

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: db }
spec:
  secretStoreRef: { name: vault-backend, kind: ClusterSecretStore }
  target: { name: db-secret }
  data: [{ secretKey: password, remoteRef: { key: secret/data/db, property: password } }]
```

---

## A5. How does Pod Security Admission work, and how do you migrate from PodSecurityPolicy?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
PSPs were **removed in 1.25**. **Pod Security Admission (PSA)** is the built-in replacement — a **namespace-labeled** admission controller enforcing the three **Pod Security Standards** (Privileged/Baseline/Restricted) in three modes: **enforce** (reject), **audit** (log), **warn** (user warning). Migration path: label namespaces in **`warn`/`audit`** first to surface violations without breaking anything, fix workloads (add hardened securityContext), then flip to **`enforce: restricted`**. For rules PSA can't express (custom logic), use **Kyverno/Gatekeeper** alongside it.

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: baseline   # start lenient
    pod-security.kubernetes.io/warn: restricted     # surface future violations
    pod-security.kubernetes.io/audit: restricted
```

---

## A6. Design a default-deny NetworkPolicy posture and then allow only required traffic.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
NetworkPolicies are **additive allow-lists**; a pod selected by *any* policy denies everything not explicitly allowed. Best practice: apply a **default-deny** (ingress+egress) per namespace, then add targeted allows (e.g., app → DB on 5432, allow DNS egress to kube-dns). Requires a CNI that enforces them (Calico, Cilium; note plain AWS VPC CNI needs the Calico/Cilium policy engine). For L7 (HTTP methods, paths) use **Cilium** or a service mesh. Always remember to **allow DNS egress** or everything breaks.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: app }
spec: { podSelector: {}, policyTypes: [Ingress, Egress] }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-dns, namespace: app }
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to: [{ namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } } }]
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
```

---

## A7. What is SLSA, and how do you generate and consume SBOMs and provenance?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
**SLSA** (Supply-chain Levels for Software Artifacts) is a framework of increasing guarantees that an artifact was built from expected source by a trusted, tamper-resistant pipeline — culminating in **signed build provenance** (an attestation describing *how/where/from-what* the artifact was built). An **SBOM** (Software Bill of Materials — SPDX or CycloneDX) lists every component/dependency in the artifact, enabling instant CVE impact analysis (e.g., "am I affected by this new Log4j CVE?"). Generate SBOMs with **Syft/Trivy**, sign artifacts + attach provenance/SBOM attestations with **cosign attest**, record in **Rekor**, and verify at admission. GitHub's `slsa-github-generator` produces SLSA provenance in Actions.

```bash
syft myapp:1.0 -o cyclonedx-json > sbom.json
cosign attest --predicate sbom.json --type cyclonedx myapp@sha256:abcd...   # signed SBOM attestation
cosign verify-attestation --type slsaprovenance myapp@sha256:abcd...
```

---

## A8. How do admission controllers work, and OPA/Gatekeeper vs Kyverno?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Admission controllers intercept API requests **after authn/authz but before persistence**. Two dynamic (webhook) types: **MutatingAdmissionWebhook** (can modify objects — inject sidecars, defaults) runs first, then **ValidatingAdmissionWebhook** (accept/reject). Policy engines plug in here:
- **OPA/Gatekeeper** — **Rego** language, ConstraintTemplates + Constraints, very expressive, portable beyond K8s.
- **Kyverno** — **YAML** policies (no new language), K8s-native, does validate/mutate/generate/verifyImages. Lower learning curve.
Newer built-in option: **ValidatingAdmissionPolicy** (CEL-based, in-tree, no webhook). Use policy-as-code to enforce signed images, no `:latest`, required labels/limits, allowed registries.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: disallow-latest-tag }
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-digest-or-tag
      match: { any: [{ resources: { kinds: [Pod] } }] }
      validate:
        message: "Using ':latest' or no tag is not allowed."
        pattern: { spec: { containers: [{ image: "!*:latest" }] } }
```

---

## A9. Design an end-to-end secret rotation strategy with zero downtime.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Two credentials must coexist during a rotation window. Pattern (Secrets Manager rotation Lambda): **createSecret** (new version → `AWSPENDING`), **setSecret** (configure the service with the new cred), **testSecret** (validate it works), **finishSecret** (move `AWSCURRENT` → new). The old cred stays valid until the flip, so in-flight connections never break. Prefer **dynamic secrets** (Vault DB engine) to eliminate rotation entirely — each app leases a fresh short-TTL credential. For pods: use CSI/ESO reconcile to pick up new values; for apps that cache at startup, trigger a rolling restart on a **secret checksum annotation** (Reloader). Always enable **audit + alerting on rotation failures**.

```bash
vault write database/config/app plugin_name=postgresql-database-plugin \
  allowed_roles="app" connection_url="postgresql://{{username}}:{{password}}@db:5432"
vault write database/roles/app default_ttl=1h max_ttl=24h \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';"
# App leases a fresh 1h credential — nothing long-lived to rotate
```

---

## A10. How do you configure encryption at rest for Kubernetes Secrets with a KMS provider?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
By default etcd stores Secrets **base64-encoded, not encrypted** — anyone with etcd access reads them. Enable **encryption at rest** via an `EncryptionConfiguration` on the kube-apiserver using a **KMS v2 provider** (envelope encryption): a per-object DEK encrypts the data, and a **KMS KEK** (AWS KMS, etc.) encrypts the DEK — so the plaintext key never sits in etcd. On **EKS**, enable **envelope encryption** with a customer-managed KMS key at/after cluster creation. To encrypt already-stored secrets, rewrite them (`kubectl get secrets -A -o json | kubectl replace -f -`). Prefer `aescbc`/KMS over the weak `identity` provider.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - kms:
          apiVersion: v2
          name: aws-kms
          endpoint: unix:///var/run/kmsplugin/socket.sock
      - identity: {}   # fallback for reads of pre-existing plaintext
```
```bash
aws eks associate-encryption-config --cluster-name prod \
  --encryption-config '[{"resources":["secrets"],"provider":{"keyArn":"arn:aws:kms:...:key/abc"}}]'
```

---

## A11. How do you do runtime threat detection in Kubernetes (Falco / CrowdStrike Falcon)?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Pre-deploy scanning can't catch what happens **at runtime** (a container compromised via a zero-day, crypto-miner, lateral movement). Runtime security watches **syscalls/kernel events** (via eBPF or a kernel module) against behavioral rules and alerts/blocks on anomalies: an unexpected **shell in a container**, writes to sensitive paths, outbound to a C2 IP, privilege escalation, or a process not in the image. **Falco** (CNCF, open source, eBPF) ships default rulesets and integrates with alerting; **CrowdStrike Falcon** (commercial, agent/DaemonSet) adds managed threat intel, EDR, and cloud workload protection. Pair with **audit logs + GuardDuty** for control-plane detection, and feed alerts to SIEM/SOC.

```yaml
# Falco rule: alert on an interactive shell spawned inside a container
- rule: Terminal shell in container
  desc: A shell was used as the entrypoint/exec in a container
  condition: spawned_process and container and shell_procs and proc.tty != 0
  output: "Shell in container (user=%user.name container=%container.name cmd=%proc.cmdline)"
  priority: WARNING
```

---

## A12. What is image provenance — how do you trace a running image back to its Dockerfile and build?
**My answer:** *(Not asked — study & rehearse)* 🔴 (you struggled with this before — own it)

**✅ Correct answer:**
Never rely on the mutable **tag** — pin and trace by the **immutable digest** (`sha256:...`). To answer "what's in this running image and how was it built":
1. **Digest** — `kubectl get pod -o jsonpath='{..imageID}'` gives the exact `repo@sha256:...` running.
2. **OCI labels** baked at build time (**OCI image-spec annotations**) — `org.opencontainers.image.source` (Git repo), `.revision` (commit SHA), `.created`, `.version`. `docker inspect` / `crane config` reads them, tying the image to the exact commit → Dockerfile.
3. **SBOM** (Syft/Trivy) — lists every package/layer so you know contents without the source.
4. **Provenance attestation** (SLSA / `cosign attest` / `docker buildx --provenance`) — a **signed** record of the builder, source repo, commit, and build parameters, verifiable at admission.
So the chain is: running digest → OCI `source`+`revision` labels → Git commit → Dockerfile, corroborated by a signed SBOM + provenance attestation.

```dockerfile
# Bake provenance into the image so it's traceable later
LABEL org.opencontainers.image.source="https://github.com/acme/app" \
      org.opencontainers.image.revision="$GIT_SHA" \
      org.opencontainers.image.version="1.4.2"
```
```bash
kubectl get pod app -o jsonpath='{.status.containerStatuses[0].imageID}'  # repo@sha256:...
crane config acme/app@sha256:abcd... | jq '.config.Labels'               # -> source + revision
cosign verify-attestation --type slsaprovenance acme/app@sha256:abcd...   # signed build provenance
```

---

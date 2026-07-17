# Python / Automation — Interview Q&A (Senior DevOps/SRE)

Real questions from Akshay's past interviews (HTC, Accion, Pure Software, PwC, Shell, Barclays, GlobalLogic), deduped with faithful transcripts of what he actually said, plus authoritative answers and runnable, idiomatic snippets for every question.
Honest baseline: he self-rates ~6/10 — writes linear scripts that shell out to `kubectl`/`aws` via `subprocess`/`os`, has never used the Kubernetes Python client or `boto3` properly, no OOP, no unit tests. The corrected answers below close exactly those gaps.

---

## Q1. Do you have hands-on Python scripting experience? Describe the automation you built and its end goal.
**Asked in:** Accion-1, Accion-2, Pure-SW, PwC-K8s, Barclays  |  **My performance:** Correct

**My answer (from transcript):**
Yes. During the migration from Golden Path platform v1 (GitHub Actions CI/CD) to v2 (GitOps with ArgoCD, hub-and-spoke), apps were redeployed on v2 but the old v1 deployments/services lingered across ~20 namespaces per cluster on 4 EKS clusters and had to be removed. I wrote a Python script that takes an application name, loops through all namespaces, finds that app's deployments/services, deletes them, and moves on. Manual cleanup would be ~100 `kubectl` commands; the script cleared everything in ~40 minutes to a couple of hours, saving 15+ hours, and was later integrated into the centralized CI/CD tooling. (Implemented as a linear script using `os` and `subprocess`, shelling out to `kubectl`.)

**✅ Correct answer:**
The story and the business impact are solid — this is a legitimate day-2 automation win. The weak spot is *how* it was built: shelling out to `kubectl` via `subprocess` is brittle (parses text, no typed errors, depends on a `kubectl` binary + kubeconfig context on the runner). The idiomatic way is the official **`kubernetes` Python client**, which talks to the API server directly, returns typed objects, raises `ApiException` you can branch on, and lets you label-select instead of string-matching. A production version would: (1) load in-cluster or kubeconfig auth, (2) list namespaces, (3) use a **label selector** (e.g. `app.kubernetes.io/name=<app>`) rather than name-substring matching, (4) delete Deployments and Services via the typed APIs, (5) support `--dry-run`, and (6) log every action. Below is the correct client-based rewrite of exactly his script.

```python
#!/usr/bin/env python3
"""Delete a given app's Deployments and Services across every namespace."""
import argparse
import logging
from kubernetes import client, config
from kubernetes.client.rest import ApiException

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("app-cleanup")

def load_kube():
    try:
        config.load_incluster_config()      # running inside a pod
    except config.ConfigException:
        config.load_kube_config()           # local kubeconfig (respects current context)

def cleanup(app_name: str, dry_run: bool):
    load_kube()
    apps_v1, core_v1 = client.AppsV1Api(), client.CoreV1Api()
    selector = f"app.kubernetes.io/name={app_name}"     # label match, not string match

    for ns in core_v1.list_namespace().items:
        namespace = ns.metadata.name
        deps = apps_v1.list_namespaced_deployment(namespace, label_selector=selector).items
        svcs = core_v1.list_namespaced_service(namespace, label_selector=selector).items
        for d in deps:
            log.info("%s deployment %s/%s", "DRY-RUN would delete" if dry_run else "deleting",
                     namespace, d.metadata.name)
            if not dry_run:
                apps_v1.delete_namespaced_deployment(d.metadata.name, namespace)
        for s in svcs:
            log.info("%s service %s/%s", "DRY-RUN would delete" if dry_run else "deleting",
                     namespace, s.metadata.name)
            if not dry_run:
                core_v1.delete_namespaced_service(s.metadata.name, namespace)

def main():
    p = argparse.ArgumentParser(description="Delete an app's Deployments/Services in all namespaces")
    p.add_argument("app_name")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()
    try:
        cleanup(args.app_name, args.dry_run)
    except ApiException as e:
        log.error("Kubernetes API error: %s", e.reason)
        raise SystemExit(1)

if __name__ == "__main__":
    main()
```

---

## Q2. How did you identify unused resources, and how did you prevent deleting still-active resources?
**Asked in:** Accion-2, Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
On the old clusters, everything was slated for deletion — the apps weren't idle, they were active, but they'd been migrated to the new clusters and the old clusters were being decommissioned. So it was a straightforward script that deletes all matched deployments/services across all namespaces. (Did not describe a real safeguard against deleting still-active resources; the premise was that everything on the old cluster was going away.)

**✅ Correct answer:**
"Everything here is doomed anyway" is a valid one-off migration premise, but interviewers want to hear real safeguards for a script that could run against a live cluster. The professional guardrails: (1) **`--dry-run`** that prints what *would* be deleted and requires a second confirmed run; (2) filter by an explicit **label selector or annotation** (e.g. `migration-status=complete`) so you only touch resources someone tagged as safe; (3) an **activity/idle check** before deleting — e.g. a Deployment with `readyReplicas > 0` and recent traffic is *not* idle; (4) **exclude protected namespaces** (`kube-system`, `default`, anything without your ownership label); (5) log to an auditable location and optionally require an approval gate in CI. "Idle" is best defined by real signals (no ready replicas, zero request rate over N hours from Prometheus), not by name matching.

```python
from datetime import datetime, timezone, timedelta
from kubernetes import client, config

PROTECTED = {"kube-system", "kube-public", "kube-node-lease", "default"}

def is_idle(dep) -> bool:
    """A Deployment is 'idle' only if it has no ready replicas and was created > 24h ago."""
    ready = dep.status.ready_replicas or 0
    created = dep.metadata.creation_timestamp
    old_enough = created < datetime.now(timezone.utc) - timedelta(hours=24)
    return ready == 0 and old_enough

def find_safe_to_delete(label="migration-status=complete"):
    config.load_kube_config()
    apps = client.AppsV1Api()
    targets = []
    for dep in apps.list_deployment_for_all_namespaces(label_selector=label).items:
        ns = dep.metadata.namespace
        if ns in PROTECTED:
            continue
        if is_idle(dep):
            targets.append((ns, dep.metadata.name))
    return targets

if __name__ == "__main__":
    for ns, name in find_safe_to_delete():
        print(f"SAFE TO DELETE: {ns}/{name}")   # review this list before any real delete
```

---

## Q3. Are you good at Python or PowerShell? How would you rate yourself?
**Asked in:** Accion-2, Barclays, GlobalLogic  |  **My performance:** Partial / Vague

**My answer (from transcript):**
I prefer Python but I'm honest that I'm no expert — I can come up with the logic and Google to build the script. I prefer Python because PowerShell is tied to the OS while Python is platform-agnostic, and I can pick up PowerShell since the concepts carry over. Self-rated mid-level; wrote only one script; used Kubernetes/`os`/`subprocess`, did not use `boto3`.

**✅ Correct answer:**
The honesty is good and the platform-agnostic point is fair. To move a self-assessment from "mid-level" to "solid SRE Python", have concrete evidence ready: (1) you use the **native SDKs** — `kubernetes` client and `boto3` — not just shelling out; (2) you write **functions/classes with error handling** (`try/except` on `ApiException`/`ClientError`), not top-to-bottom scripts; (3) you handle **config via `argparse`/env vars** and **YAML/JSON** parsing; (4) you can add a **`pytest`** with mocked AWS/K8s calls; (5) you know the standard toolbox: `requests` (+retries), `psutil`, `boto3`, `kubernetes`, `PyYAML`, `logging`, `collections`. Being able to name that toolbox and show a class-based, tested example is what separates 6/10 from 8/10.

```python
"""A 'grown-up' script skeleton: argparse + logging + typed errors + a testable function."""
import argparse, logging, sys

log = logging.getLogger(__name__)

def do_work(target: str, dry_run: bool = False) -> int:
    """Pure, testable unit — returns count of items processed."""
    log.info("processing %s (dry_run=%s)", target, dry_run)
    return 0

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Well-structured DevOps script template")
    parser.add_argument("target")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)
    try:
        count = do_work(args.target, args.dry_run)
        log.info("done, %d items", count)
        return 0
    except Exception as e:                      # narrow this in real code
        log.error("failed: %s", e)
        return 1

if __name__ == "__main__":
    sys.exit(main())
```

---

## Q4. Is the Python tool you built class-based (OOP) or a linear script?
**Asked in:** Shell-1  |  **My performance:** Correct (honest)

**My answer (from transcript):**
Pretty much a linear script using `subprocess` and `os`. Algorithm: get the list of namespaces, for each namespace check if the application name exists, if found delete its deployment and service; run manually per cluster with the app name passed as an input parameter.

**✅ Correct answer:**
Honest and accurate. A linear script is fine for a one-off, but the reusable version wraps state (auth, clients, dry-run flag) and behavior (list, delete) into a **class**. Benefits: the API clients are created once in `__init__`, methods are individually testable, and you can subclass/extend (e.g. add PVC or ConfigMap cleanup) without rewriting the flow. See Q8 for the full class implementation.

```python
# Linear (what he wrote, conceptually) vs a small class wrapper:
class Cleaner:
    def __init__(self, app_name, dry_run=False):
        from kubernetes import client, config
        config.load_kube_config()
        self.app = app_name
        self.dry_run = dry_run
        self.core = client.CoreV1Api()
        self.apps = client.AppsV1Api()

    def namespaces(self):
        return [n.metadata.name for n in self.core.list_namespace().items]

    def run(self):
        for ns in self.namespaces():
            self._delete_in(ns)

    def _delete_in(self, ns):
        sel = f"app.kubernetes.io/name={self.app}"
        for d in self.apps.list_namespaced_deployment(ns, label_selector=sel).items:
            print(("DRY " if self.dry_run else "") + f"delete deploy {ns}/{d.metadata.name}")
            if not self.dry_run:
                self.apps.delete_namespaced_deployment(d.metadata.name, ns)
```

---

## Q5. What modules were you using in that script?
**Asked in:** Shell-1  |  **My performance:** Correct

**My answer (from transcript):**
The `os` module and the `subprocess` module.

**✅ Correct answer:**
Those work for shelling out, but name the *right* modules for each job so it's clear you know the ecosystem:
- **`kubernetes`** — official client for the K8s API (replaces `subprocess` + `kubectl`).
- **`boto3`** — AWS SDK (EC2, S3, CloudWatch, etc.).
- **`requests`** — HTTP/REST calls (with `urllib3.Retry` for backoff).
- **`subprocess`** — only when you genuinely must invoke an external binary; always pass a list of args (never `shell=True` with user input), and use `subprocess.run(..., capture_output=True, text=True, check=True)`.
- **`os` / `pathlib`** — env vars and filesystem paths (`pathlib` is the modern choice).
- **`argparse`** — CLI arguments. **`logging`** — structured output. **`json` / `yaml`** — config. **`psutil`** — local CPU/disk/memory. **`collections.Counter`** — tallying.

```python
import subprocess

# If you MUST shell out, do it safely (list args, no shell=True, check errors):
result = subprocess.run(
    ["kubectl", "get", "ns", "-o", "name"],
    capture_output=True, text=True, check=True,   # check=True raises on non-zero exit
)
namespaces = [line.split("/")[1] for line in result.stdout.splitlines()]
print(namespaces)
# ...but prefer the kubernetes client (Q1) so you get typed objects and real error handling.
```

---

## Q6. Were you using any of the Kubernetes Python client modules to talk to the API?
**Asked in:** Shell-1  |  **My performance:** Didn't-know

**My answer (from transcript):**
No — I used `subprocess`/`os` to shell out to `kubectl` rather than the Kubernetes Python client library.

**✅ Correct answer:**
This is the biggest single upgrade to make. The official **`kubernetes`** package (`pip install kubernetes`) talks to the API server directly. Key pieces: `config.load_kube_config()` (local) or `config.load_incluster_config()` (inside a pod); API groups `CoreV1Api` (pods, services, PVCs, namespaces, configmaps, secrets), `AppsV1Api` (deployments, statefulsets, daemonsets), `BatchV1Api` (jobs/cronjobs); `list_*` / `delete_*` / `create_*` / `patch_*` methods; `label_selector` / `field_selector` filters; and `kubernetes.client.rest.ApiException` (check `e.status == 404`, etc.). It returns typed Python objects, so no fragile text parsing. `watch.Watch()` streams events for controllers.

```python
from kubernetes import client, config
from kubernetes.client.rest import ApiException

config.load_kube_config()
v1 = client.CoreV1Api()

try:
    pods = v1.list_pod_for_all_namespaces(watch=False)
    for p in pods.items:
        print(f"{p.metadata.namespace:20} {p.metadata.name:40} {p.status.phase}")
except ApiException as e:
    if e.status == 403:
        print("RBAC: not allowed to list pods")
    else:
        raise
```

---

## Q7. Were you doing any unit testing around the script?
**Asked in:** Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
No unit tests — it was a simple, straightforward script for deleting old applications, so there was no unit-test requirement.

**✅ Correct answer:**
Understandable for a throwaway, but the right answer names how you'd test it *without touching a real cluster*: structure the code into small pure functions, then use **`pytest`** with **`unittest.mock`** to fake the Kubernetes/AWS client so `list_namespace()` returns canned objects and you assert `delete_namespaced_deployment` was called with the right args. This is exactly the "no OOP / no tests" gap to close — even one mocked test signals maturity. Bonus: `moto` mocks AWS for `boto3` tests, and `pytest` fixtures set up shared state.

```python
# test_cleanup.py  (run: pytest -q)
from unittest.mock import MagicMock, patch

def delete_app_deployments(apps_api, namespace, app):
    """Pure logic we can test in isolation."""
    sel = f"app.kubernetes.io/name={app}"
    deleted = []
    for d in apps_api.list_namespaced_deployment(namespace, label_selector=sel).items:
        apps_api.delete_namespaced_deployment(d.metadata.name, namespace)
        deleted.append(d.metadata.name)
    return deleted

def test_deletes_matching_deployments():
    fake_dep = MagicMock()
    fake_dep.metadata.name = "old-app"
    apps = MagicMock()
    apps.list_namespaced_deployment.return_value.items = [fake_dep]

    result = delete_app_deployments(apps, "team-a", "old-app")

    assert result == ["old-app"]
    apps.delete_namespaced_deployment.assert_called_once_with("old-app", "team-a")
```

---

## Q8. If you had to write a class-based (OOP) version of this, could you?
**Asked in:** Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
Yes, I can come up with it. I haven't programmed in class-based/OOP before, and honestly I hadn't scripted before this, but I managed to write and run this one, and I can do a class-based version if needed.

**✅ Correct answer:**
Yes — and here's what "class-based" buys you: `__init__` sets up auth and the API clients once; instance attributes hold config (`app_name`, `dry_run`, `protected` namespaces); each responsibility is its own method (`list_namespaces`, `find_resources`, `delete`); and it's trivially testable and extensible. Know the OOP vocabulary: `__init__` (constructor), `self`, instance vs class attributes, methods, inheritance, `@staticmethod`/`@classmethod`, `@property`, and `__repr__`. Here's the full idiomatic class version of his cleanup tool.

```python
import logging
from kubernetes import client, config
from kubernetes.client.rest import ApiException

class AppCleaner:
    PROTECTED = {"kube-system", "kube-public", "kube-node-lease"}

    def __init__(self, app_name: str, dry_run: bool = False):
        self.app_name = app_name
        self.dry_run = dry_run
        self.log = logging.getLogger(self.__class__.__name__)
        try:
            config.load_incluster_config()
        except config.ConfigException:
            config.load_kube_config()
        self.core = client.CoreV1Api()
        self.apps = client.AppsV1Api()

    @property
    def selector(self) -> str:
        return f"app.kubernetes.io/name={self.app_name}"

    def namespaces(self):
        return [n.metadata.name for n in self.core.list_namespace().items
                if n.metadata.name not in self.PROTECTED]

    def _delete(self, kind, name, ns, deleter):
        if self.dry_run:
            self.log.info("DRY-RUN would delete %s %s/%s", kind, ns, name)
            return
        try:
            deleter(name, ns)
            self.log.info("deleted %s %s/%s", kind, ns, name)
        except ApiException as e:
            self.log.error("failed deleting %s %s/%s: %s", kind, ns, name, e.reason)

    def run(self):
        for ns in self.namespaces():
            for d in self.apps.list_namespaced_deployment(ns, label_selector=self.selector).items:
                self._delete("deployment", d.metadata.name, ns, self.apps.delete_namespaced_deployment)
            for s in self.core.list_namespaced_service(ns, label_selector=self.selector).items:
                self._delete("service", s.metadata.name, ns, self.core.delete_namespaced_service)

    def __repr__(self):
        return f"AppCleaner(app_name={self.app_name!r}, dry_run={self.dry_run})"

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    AppCleaner("legacy-app", dry_run=True).run()
```

---

## Q9. What is the real benefit of the script over just running `kubectl delete`, and how long did it take to build?
**Asked in:** Accion-1  |  **My performance:** Partial (interviewer pushed back)

**My answer (from transcript):**
Manually you'd run `kubectl delete` for every app across all namespaces and all 4 clusters (~100 commands). The script took ~6-8 hours to write and then cleared everything in ~1 hour — roughly one man-day. The interviewer pushed back that manual could be faster; I defended it on the 20-namespaces × 4-clusters scale.

**✅ Correct answer:**
Don't defend the one-off time math — reframe around **durable engineering value**, which is what the interviewer was fishing for:
1. **Repeatability & reuse** — it became part of the CI/CD tooling, so it runs on demand forever, not once.
2. **Consistency & safety** — same logic every time; no fat-fingered `kubectl delete` in the wrong context. Add `--dry-run` and it's auditable.
3. **Scale/idempotency** — label-selecting across N clusters × M namespaces is linear for the script but error-prone by hand; re-running is safe.
4. **Auditability** — structured logs of exactly what was deleted, when, by whom.
A one-liner (`kubectl delete deploy,svc -l app.kubernetes.io/name=X --all-namespaces`) *can* beat a script for a true one-off — so the honest, strong answer is: "for a single cluster a labeled `kubectl` one-liner is faster; the script earns its keep because it's parameterized, dry-runnable, logged, multi-cluster, and integrated into the platform pipeline."

```python
"""The value is in being reusable + safe + auditable. A labeled one-liner is the baseline to beat:

    kubectl delete deploy,svc -l app.kubernetes.io/name=myapp -A

The script adds dry-run, logging, multi-cluster looping, and CI integration:"""
import logging
from kubernetes import client, config

def cleanup_across_clusters(app: str, kube_contexts: list[str], dry_run=True):
    logging.basicConfig(level=logging.INFO)
    for ctx in kube_contexts:                       # loop clusters via kubeconfig contexts
        config.load_kube_config(context=ctx)
        apps = client.AppsV1Api()
        sel = f"app.kubernetes.io/name={app}"
        for d in apps.list_deployment_for_all_namespaces(label_selector=sel).items:
            ns, name = d.metadata.namespace, d.metadata.name
            logging.info("[%s] %s %s/%s", ctx, "DRY-RUN" if dry_run else "DELETE", ns, name)
            if not dry_run:
                apps.delete_namespaced_deployment(name, ns)

cleanup_across_clusters("legacy-app", ["eks-prod-1", "eks-prod-2"], dry_run=True)
```

---

## Q10. Live coding — write the logic to send an alert when disk usage reaches 60%.
**Asked in:** Pure-SW  |  **My performance:** Partial

**My answer (from transcript):**
Shared my screen and wrote rough logic: use a `boto3` function to log into the node (EC2/K8s node), get current CPU and disk, add an `if` so that if disk usage > 60% it triggers a CloudWatch alert and sends to a Slack channel, and set the script as a cron job to run every few minutes.

**✅ Correct answer:**
The instinct (threshold check → alert → cron) is right, but **`boto3` is the wrong tool for reading local disk** — `boto3` is the AWS API SDK; it does not read the filesystem of the box it runs on and cannot "log into a node." To read **local** disk/CPU/memory, use **`psutil`** (`psutil.disk_usage('/')`, `psutil.cpu_percent()`), or `shutil.disk_usage`. Then send the alert to Slack via an **incoming webhook** (`requests.post`). `boto3`/CloudWatch is only relevant if you want to *push a custom metric* to CloudWatch and alarm centrally — that's a valid second pattern, but it's not how you read the disk. Two clean patterns below.

```python
#!/usr/bin/env python3
"""Alert to Slack when root-filesystem usage crosses a threshold. Run via cron every 5 min."""
import shutil
import psutil
import requests

SLACK_WEBHOOK = "https://hooks.slack.com/services/XXX/YYY/ZZZ"  # from env/secret in real life
THRESHOLD = 60  # percent

def disk_percent(path="/") -> float:
    usage = psutil.disk_usage(path)          # local disk — NOT boto3
    return usage.percent

def notify_slack(text: str):
    resp = requests.post(SLACK_WEBHOOK, json={"text": text}, timeout=10)
    resp.raise_for_status()

def main():
    pct = disk_percent("/")
    cpu = psutil.cpu_percent(interval=1)
    if pct >= THRESHOLD:
        notify_slack(f":warning: Disk on {psutil.os.uname().nodename} at {pct:.1f}% "
                     f"(threshold {THRESHOLD}%), CPU {cpu:.0f}%")
    else:
        print(f"OK: disk {pct:.1f}%, cpu {cpu:.0f}%")

if __name__ == "__main__":
    main()
```

```python
# OPTIONAL second pattern: push a CUSTOM metric to CloudWatch (this is the correct boto3 use).
import boto3, psutil
cw = boto3.client("cloudwatch", region_name="us-east-1")
cw.put_metric_data(
    Namespace="Custom/Host",
    MetricData=[{
        "MetricName": "DiskUsedPercent",
        "Value": psutil.disk_usage("/").percent,
        "Unit": "Percent",
    }],
)   # then create a CloudWatch alarm on this metric to fire at >= 60%.
```

---

## Q11. Write a script to list S3 buckets — how?
**Asked in:** Barclays  |  **My performance:** Partial (couldn't name the function)

**My answer (from transcript):**
Use a Python script with the `boto3` module — write "the AWS S3 list command", and with AWS configured it lists all S3 buckets. When asked which function, I said "`boto3`… I need to check which function exactly" — I couldn't name `list_buckets`. Right library, missing the exact call.

**✅ Correct answer:**
The library is right; memorize the calls. `boto3` has two interfaces: a low-level **client** (`boto3.client("s3")`) and a high-level **resource** (`boto3.resource("s3")`).
- Client: **`s3.list_buckets()`** returns a dict; buckets are under the **`"Buckets"`** key, each with `"Name"` and `"CreationDate"`.
- Resource: iterate **`s3.buckets.all()`**.
Credentials come from the standard chain (env vars, `~/.aws/credentials`, IAM role) — you don't pass keys in code. Wrap in `try/except ClientError`. For >1000 objects inside a bucket, use a **paginator**. Say the exact call out loud in interviews: *"`boto3.client('s3').list_buckets()['Buckets']`."*

```python
import boto3
from botocore.exceptions import ClientError

def list_buckets():
    s3 = boto3.client("s3")
    try:
        resp = s3.list_buckets()
    except ClientError as e:
        print(f"AWS error: {e}")
        return
    for b in resp["Buckets"]:
        print(f"{b['Name']:40} created {b['CreationDate']:%Y-%m-%d}")

# High-level resource equivalent:
def list_buckets_resource():
    for bucket in boto3.resource("s3").buckets.all():
        print(bucket.name)

if __name__ == "__main__":
    list_buckets()
```

---

## Q12. What Python libraries do you usually use? Do you use `boto3`?
**Asked in:** GlobalLogic  |  **My performance:** Vague

**My answer (from transcript):**
Self-rated mid-level. I've used the Kubernetes client, `os`, and `subprocess`. I did NOT work on `boto3` — we didn't have the scenario. I worked more on `subprocess` and `os`.

**✅ Correct answer:**
Have a crisp toolbox answer ready, grouped by purpose:
- **Cloud/K8s:** `boto3` (AWS), `kubernetes` (K8s API), `google-cloud-*`/`azure-*` if multi-cloud.
- **HTTP/APIs:** `requests` (+ `urllib3.Retry` or `tenacity` for backoff).
- **System/metrics:** `psutil` (CPU/mem/disk), `shutil`, `pathlib`, `os`, `subprocess`.
- **Config/data:** `PyYAML`, `json`, `configparser`, `python-dotenv`.
- **Structure/quality:** `argparse`/`click` (CLI), `logging`, `pytest` + `unittest.mock`/`moto`, `dataclasses`.
- **Tally/parse:** `collections.Counter`, `re`, `datetime`.
Then be honest but forward-looking on `boto3`: "I haven't had an AWS-scripting scenario yet, but I know the model — `client` vs `resource`, the credential chain, `list_buckets()`, `describe_instances()`, paginators, and `ClientError` handling." That converts "vague" into "aware."

```python
# A one-glance map of the SRE Python toolbox:
import boto3            # AWS SDK
import kubernetes       # Kubernetes API client
import requests         # HTTP/REST
import psutil           # local CPU/mem/disk
import yaml             # YAML config  (pip install pyyaml)
from collections import Counter   # tally top-N
import argparse, logging, json, re    # CLI, logs, data, regex

print("client vs resource:", bool(boto3.client), bool(boto3.resource))
```

---

## Q13. Implement a Python script to perform automated image scanning and deploy only verified images to Kubernetes.
**Asked in:** HTC  |  **My performance:** Didn't-know

**My answer (from transcript):**
I've used tools like Veracode and Trivy for that objective, but I haven't written Python scripts for it, so "I'm not sure how it's done."

**✅ Correct answer:**
You already named the right tools — the Python part is just orchestration: **scan → gate on results → deploy only if clean**. Practical design:
1. **Scan** the image with **Trivy** in machine-readable mode (`trivy image --format json --severity CRITICAL,HIGH <image>`), invoked via `subprocess` (Trivy has no official Python lib — shelling out is legitimate here).
2. **Parse** the JSON and **gate**: if any CRITICAL/HIGH vulnerabilities exist, fail and do not deploy.
3. Optionally verify a **signature** (cosign) / check the image is from a trusted registry.
4. If clean, **deploy** by patching the Deployment image via the `kubernetes` client (or apply the manifest).
In production this lives in the CI pipeline as an admission gate (or an admission controller like Kyverno/OPA), but the scriptable version is straightforward.

```python
#!/usr/bin/env python3
"""Scan an image with Trivy; deploy to K8s only if no CRITICAL/HIGH vulns."""
import json, subprocess, sys
from kubernetes import client, config

def scan(image: str) -> bool:
    """Return True if the image is clean (no CRITICAL/HIGH)."""
    result = subprocess.run(
        ["trivy", "image", "--quiet", "--format", "json",
         "--severity", "CRITICAL,HIGH", image],
        capture_output=True, text=True, check=True,
    )
    report = json.loads(result.stdout)
    findings = [v for res in (report.get("Results") or []) for v in (res.get("Vulnerabilities") or [])]
    if findings:
        print(f"BLOCKED: {len(findings)} CRITICAL/HIGH vulns in {image}")
        return False
    print(f"CLEAN: {image}")
    return True

def deploy(image: str, deployment: str, namespace: str):
    config.load_kube_config()
    apps = client.AppsV1Api()
    patch = {"spec": {"template": {"spec": {"containers": [
        {"name": deployment, "image": image}]}}}}
    apps.patch_namespaced_deployment(deployment, namespace, patch)
    print(f"deployed {image} to {namespace}/{deployment}")

def main():
    image, deployment, namespace = sys.argv[1], sys.argv[2], sys.argv[3]
    if not scan(image):
        sys.exit(1)                 # gate: block the deploy
    deploy(image, deployment, namespace)

if __name__ == "__main__":
    main()
```

---

## Q14. How would you use Python to enhance observability in Kubernetes clusters?
**Asked in:** HTC  |  **My performance:** Partial

**My answer (from transcript):**
Use Python scripts to fetch data via platform-specific API requests, store it in a centralized observability database, then run KQL queries on top to build custom dashboards and alerts.

**✅ Correct answer:**
The pipeline shape (collect → store → query → alert/dashboard) is correct. Sharpen it with the real tools:
- **Collect:** query the **Prometheus HTTP API** (`/api/v1/query`, `/api/v1/query_range`) with `requests`, or the K8s **metrics API** / events via the `kubernetes` client. For custom app signals, expose metrics with `prometheus_client` and let Prometheus scrape them.
- **Store/query:** Prometheus (PromQL) is the K8s-native default; Loki for logs; if you're in Azure it's Log Analytics/KQL (which matches his answer). Grafana sits on top for dashboards; Alertmanager (or Grafana alerts) for alerting.
- **Python's role:** not usually to *store* metrics (Prometheus does that) but to **collect custom signals, run synthetic checks, correlate across sources, and drive automated remediation** (e.g. query Prometheus, detect an anomaly, open a ticket / restart a pod). Below: pull a metric from Prometheus and alert on it.

```python
import requests

PROM = "http://prometheus.monitoring.svc:9090"

def query(promql: str):
    r = requests.get(f"{PROM}/api/v1/query", params={"query": promql}, timeout=10)
    r.raise_for_status()
    return r.json()["data"]["result"]

def pods_not_ready():
    # instant vector: count of pods reporting not-ready
    results = query('kube_pod_status_ready{condition="false"} == 1')
    for series in results:
        pod = series["metric"].get("pod", "?")
        ns = series["metric"].get("namespace", "?")
        print(f"NOT READY: {ns}/{pod}")
    return len(results)

if __name__ == "__main__":
    n = pods_not_ready()
    if n:
        print(f"ALERT: {n} pods not ready")   # hook to Slack/Alertmanager here
```

---

# 🔺 Advanced / Practice Coding Tasks (rehearse these)

New DevOps/SRE Python tasks he was *not* asked but should be able to write cold. Each targets a gap (real `boto3`, real `kubernetes` client, OOP, tests, retries, `psutil`, threading).

## A1. boto3 — list running EC2 instances and stop the idle ones
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
"Idle" needs a real signal — pull average CPU over the last hour from **CloudWatch** (`get_metric_statistics`), and stop instances under a threshold. Use `describe_instances` (paginated) to enumerate, and `stop_instances` to act. Tag-exempt anything labeled `keep-alive`.

```python
import boto3
from datetime import datetime, timedelta, timezone

ec2 = boto3.client("ec2", region_name="us-east-1")
cw = boto3.client("cloudwatch", region_name="us-east-1")

def avg_cpu(instance_id: str) -> float:
    end = datetime.now(timezone.utc)
    stats = cw.get_metric_statistics(
        Namespace="AWS/EC2", MetricName="CPUUtilization",
        Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
        StartTime=end - timedelta(hours=1), EndTime=end,
        Period=3600, Statistics=["Average"],
    )["Datapoints"]
    return stats[0]["Average"] if stats else 100.0   # no data -> treat as busy

def stop_idle(threshold=5.0, dry_run=True):
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(Filters=[{"Name": "instance-state-name", "Values": ["running"]}]):
        for res in page["Reservations"]:
            for inst in res["Instances"]:
                iid = inst["InstanceId"]
                tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                if tags.get("keep-alive") == "true":
                    continue
                cpu = avg_cpu(iid)
                if cpu < threshold:
                    print(f"{'DRY-RUN ' if dry_run else ''}stopping {iid} (cpu {cpu:.1f}%)")
                    if not dry_run:
                        ec2.stop_instances(InstanceIds=[iid])

if __name__ == "__main__":
    stop_idle(dry_run=True)
```

## A2. boto3 — list all S3 buckets with region and object count
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
`list_buckets()` gives names; `get_bucket_location()` gives the region (note: `us-east-1` returns `None`); a paginator over `list_objects_v2` counts objects without loading them all into memory.

```python
import boto3

s3 = boto3.client("s3")

def bucket_report():
    for b in s3.list_buckets()["Buckets"]:
        name = b["Name"]
        loc = s3.get_bucket_location(Bucket=name)["LocationConstraint"] or "us-east-1"
        count = 0
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=name):
            count += page.get("KeyCount", 0)
        print(f"{name:40} {loc:12} {count} objects")

if __name__ == "__main__":
    bucket_report()
```

## A3. boto3 — find resources missing required tags
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Governance staple: flag EC2 instances (and other resources) lacking mandatory tags like `owner`, `environment`, `cost-center`. Compare each resource's tag keys against a required set.

```python
import boto3

REQUIRED = {"owner", "environment", "cost-center"}
ec2 = boto3.client("ec2", region_name="us-east-1")

def untagged_instances():
    offenders = []
    for page in ec2.get_paginator("describe_instances").paginate():
        for res in page["Reservations"]:
            for inst in res["Instances"]:
                keys = {t["Key"] for t in inst.get("Tags", [])}
                missing = REQUIRED - keys
                if missing:
                    offenders.append((inst["InstanceId"], sorted(missing)))
    return offenders

if __name__ == "__main__":
    for iid, missing in untagged_instances():
        print(f"{iid} missing tags: {', '.join(missing)}")
```

## A4. kubernetes client — list pods across all namespaces with status
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
`list_pod_for_all_namespaces` plus a restart-count and phase readout — the client-native version of `kubectl get pods -A`.

```python
from kubernetes import client, config

config.load_kube_config()
v1 = client.CoreV1Api()

def list_pods():
    for p in v1.list_pod_for_all_namespaces(watch=False).items:
        restarts = sum(cs.restart_count for cs in (p.status.container_statuses or []))
        print(f"{p.metadata.namespace:20} {p.metadata.name:45} "
              f"{p.status.phase:10} restarts={restarts}")

if __name__ == "__main__":
    list_pods()
```

## A5. kubernetes client — delete completed (Succeeded) Jobs
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Use `BatchV1Api` to list Jobs and delete those with `status.succeeded`. Pass `propagation_policy="Background"` so the Job's pods are garbage-collected too.

```python
from kubernetes import client, config

config.load_kube_config()
batch = client.BatchV1Api()

def delete_completed_jobs(dry_run=True):
    for job in batch.list_job_for_all_namespaces().items:
        if job.status.succeeded:
            ns, name = job.metadata.namespace, job.metadata.name
            print(f"{'DRY-RUN ' if dry_run else ''}delete completed job {ns}/{name}")
            if not dry_run:
                batch.delete_namespaced_job(
                    name, ns,
                    body=client.V1DeleteOptions(propagation_policy="Background"),
                )

if __name__ == "__main__":
    delete_completed_jobs(dry_run=True)
```

## A6. kubernetes client — find orphaned PVCs (not used by any pod)
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Build the set of PVC names referenced by any pod's volumes, then report PVCs not in that set — candidates for cleanup (storage cost). Never auto-delete without review.

```python
from kubernetes import client, config

config.load_kube_config()
v1 = client.CoreV1Api()

def orphaned_pvcs():
    in_use = set()
    for pod in v1.list_pod_for_all_namespaces().items:
        for vol in (pod.spec.volumes or []):
            if vol.persistent_volume_claim:
                in_use.add((pod.metadata.namespace, vol.persistent_volume_claim.claim_name))
    for pvc in v1.list_persistent_volume_claim_for_all_namespaces().items:
        key = (pvc.metadata.namespace, pvc.metadata.name)
        if key not in in_use:
            print(f"ORPHANED PVC: {key[0]}/{key[1]} ({pvc.spec.resources.requests.get('storage')})")

if __name__ == "__main__":
    orphaned_pvcs()
```

## A7. Parse a log file and count the top-N error types
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
`collections.Counter` + a regex. Stream the file line-by-line (don't `read()` a huge log into memory). `Counter.most_common(n)` gives the top N.

```python
import re
from collections import Counter

ERROR_RE = re.compile(r"\b(ERROR|WARN|CRITICAL|FATAL)\b.*?:\s*(?P<msg>.+)")

def top_errors(path: str, n: int = 5):
    counts = Counter()
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = ERROR_RE.search(line)
            if m:
                # normalize the message (strip numbers/ids) so similar errors group
                key = re.sub(r"\d+", "#", m.group("msg").strip())[:80]
                counts[key] += 1
    return counts.most_common(n)

if __name__ == "__main__":
    for msg, c in top_errors("/var/log/app.log", 5):
        print(f"{c:6}  {msg}")
```

## A8. Call a REST API with retries and exponential backoff
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Don't hand-roll retry loops. Mount an `HTTPAdapter` with `urllib3.Retry` (backoff + retry on 429/5xx), and always set a `timeout`. (Alternative: the `tenacity` decorator.)

```python
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

def make_session(total=5, backoff=0.5):
    session = requests.Session()
    retry = Retry(
        total=total, backoff_factor=backoff,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST"],
    )
    session.mount("https://", HTTPAdapter(max_retries=retry))
    session.mount("http://", HTTPAdapter(max_retries=retry))
    return session

def get_json(url: str):
    s = make_session()
    resp = s.get(url, timeout=10)     # backoff: 0.5, 1, 2, 4, 8s on retryable errors
    resp.raise_for_status()
    return resp.json()

if __name__ == "__main__":
    print(get_json("https://httpbin.org/json"))
```

## A9. Query the Prometheus HTTP API
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
`GET /api/v1/query` for an instant vector; `/api/v1/query_range` for a time series. Check the `status` field and iterate `data.result`.

```python
import requests

class Prometheus:
    def __init__(self, base_url: str):
        self.base = base_url.rstrip("/")

    def query(self, promql: str):
        r = requests.get(f"{self.base}/api/v1/query", params={"query": promql}, timeout=10)
        r.raise_for_status()
        payload = r.json()
        if payload["status"] != "success":
            raise RuntimeError(payload.get("error", "query failed"))
        return payload["data"]["result"]

if __name__ == "__main__":
    prom = Prometheus("http://localhost:9090")
    for s in prom.query('sum by (namespace) (kube_pod_info)'):
        print(s["metric"].get("namespace"), s["value"][1])
```

## A10. Class-based design — a reusable cluster-health checker
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Wrap related behavior + state in a class: constructor sets up the client; methods each answer one health question; a `dataclass` carries the result. This is the OOP pattern to be fluent in.

```python
from dataclasses import dataclass
from kubernetes import client, config

@dataclass
class HealthReport:
    not_ready_pods: int
    failed_pods: int

class ClusterHealth:
    def __init__(self, context: str | None = None):
        config.load_kube_config(context=context)
        self.core = client.CoreV1Api()

    def _pods(self):
        return self.core.list_pod_for_all_namespaces().items

    def report(self) -> HealthReport:
        pods = self._pods()
        not_ready = sum(
            1 for p in pods
            if not all((c.ready for c in (p.status.container_statuses or [])), )
        )
        failed = sum(1 for p in pods if p.status.phase == "Failed")
        return HealthReport(not_ready_pods=not_ready, failed_pods=failed)

if __name__ == "__main__":
    print(ClusterHealth().report())
```

## A11. pytest — unit-test a boto3 function with mocking
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Never hit real AWS in a unit test. Either `unittest.mock` the client, or use **`moto`** to fake AWS entirely. Below uses plain mocking so it needs no extra services.

```python
# test_s3.py   (run: pytest -q)
from unittest.mock import MagicMock

def bucket_names(s3_client):
    return [b["Name"] for b in s3_client.list_buckets()["Buckets"]]

def test_bucket_names():
    fake = MagicMock()
    fake.list_buckets.return_value = {"Buckets": [{"Name": "logs"}, {"Name": "data"}]}
    assert bucket_names(fake) == ["logs", "data"]
    fake.list_buckets.assert_called_once()

# With moto (pip install moto):
# import boto3
# from moto import mock_aws
# @mock_aws
# def test_with_moto():
#     s3 = boto3.client("s3", region_name="us-east-1")
#     s3.create_bucket(Bucket="logs")
#     assert bucket_names(s3) == ["logs"]
```

## A12. Read configuration from YAML and JSON
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
`yaml.safe_load` (never plain `load` on untrusted input) and `json.load`. Merge env-var overrides on top for 12-factor config.

```python
import json, os
import yaml   # pip install pyyaml

def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        if path.endswith((".yaml", ".yml")):
            cfg = yaml.safe_load(f)
        elif path.endswith(".json"):
            cfg = json.load(f)
        else:
            raise ValueError(f"unsupported config type: {path}")
    # env overrides (e.g. LOG_LEVEL -> cfg['log_level'])
    if "LOG_LEVEL" in os.environ:
        cfg["log_level"] = os.environ["LOG_LEVEL"]
    return cfg

if __name__ == "__main__":
    print(load_config("config.yaml"))
```

## A13. Disk / CPU / memory check the RIGHT way (psutil)
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
This is the correction to Q10's `boto3` mistake. For **local** host metrics use **`psutil`**: `disk_usage`, `cpu_percent`, `virtual_memory`. Loop mount points for multi-disk hosts.

```python
import psutil

def health_check(disk_threshold=80, mem_threshold=90, cpu_threshold=85):
    alerts = []
    for part in psutil.disk_partitions(all=False):
        try:
            pct = psutil.disk_usage(part.mountpoint).percent
        except PermissionError:
            continue
        if pct >= disk_threshold:
            alerts.append(f"disk {part.mountpoint} at {pct:.0f}%")
    if psutil.virtual_memory().percent >= mem_threshold:
        alerts.append(f"memory at {psutil.virtual_memory().percent:.0f}%")
    cpu = psutil.cpu_percent(interval=1)
    if cpu >= cpu_threshold:
        alerts.append(f"cpu at {cpu:.0f}%")
    return alerts

if __name__ == "__main__":
    for a in health_check() or ["all healthy"]:
        print(a)
```

## A14. Threading basics — run health checks concurrently
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
For I/O-bound work (HTTP health checks across many hosts) use `concurrent.futures.ThreadPoolExecutor` — threads overlap network waits despite the GIL. (For CPU-bound work you'd use `ProcessPoolExecutor` instead.)

```python
import concurrent.futures
import requests

HOSTS = ["https://example.com", "https://httpbin.org/status/200", "https://httpbin.org/status/500"]

def check(url: str) -> tuple[str, str]:
    try:
        r = requests.get(url, timeout=5)
        return url, "UP" if r.ok else f"DOWN ({r.status_code})"
    except requests.RequestException as e:
        return url, f"ERROR ({type(e).__name__})"

def check_all(urls):
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
        return list(ex.map(check, urls))

if __name__ == "__main__":
    for url, status in check_all(HOSTS):
        print(f"{status:20} {url}")
```

---

*End of file. Rehearse A1-A14 out loud — the goal is to say the exact API calls (`list_buckets`, `describe_instances`, `list_pod_for_all_namespaces`, `psutil.disk_usage`) without hesitation, and to reach for the `kubernetes`/`boto3` clients instead of `subprocess` every time.*

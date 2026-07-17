# SRE & Incident Management — Interview Q&A

Consolidated from Akshay's real interviews (HDFC, Accion, Pure-SW, PwC, Shell, Persistent, HTC). Each entry keeps his faithful answer, then an authoritative correct answer plus a runnable snippet/checklist to rehearse. Weak spots are flagged with 🔻 so they get nailed before the next round.

---

# 1. Incident Lifecycle & Triage

## Q1. An alert you integrated fires at 2 AM — what do you do first, where do you check?
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
Alerts are designed to trigger to a specific Slack channel with the error message and a relevant runbook (a Confluence page with standard troubleshooting steps). The on-call engineer receives it, checks which app component/cluster/namespace has the issue, logs into that cluster, gets the logs, and starts troubleshooting. For P1 failures they integrated xMatters for a phone call. Teams were split India/US (follow-the-sun) for 24x5 monitoring with handovers.

**✅ Correct answer:**
Good answer. Sharpen it into an explicit triage-first ordering that a panel wants to hear: **Acknowledge → Assess blast radius → Stabilize → Diagnose → Communicate.** Ack the page so escalation stops. Then read the *signal itself* before touching infra: what is the alert measuring (symptom-based alerts fire on user pain — error rate, latency, saturation), what is the error code, is it one namespace or many. Pull the linked runbook, check the dashboard for the golden signals (latency, traffic, errors, saturation), and correlate against the deploy timeline ("what changed in the last hour?" is the single highest-yield question). Only then log into the cluster. Mitigation (rollback / scale / failover) comes *before* root cause — restore service first, understand later. Keep a comms cadence to stakeholders throughout.

```bash
# 2 AM on-call triage sequence — run top-to-bottom
kubectl get events -n $NS --sort-by=.lastTimestamp | tail -30   # what changed?
kubectl rollout history deploy/$APP -n $NS                       # recent deploy?
kubectl get pods -n $NS -o wide | grep -vE 'Running|Completed'   # unhealthy pods
kubectl top pods -n $NS ; kubectl top nodes                      # saturation
kubectl logs deploy/$APP -n $NS --since=15m | grep -iE 'error|panic|oom|5[0-9][0-9]'
# Decision: if a deploy correlates -> `kubectl rollout undo` FIRST, RCA later.
```

---

## Q2. Walk me through a real P1 incident you led, end to end.
**Asked in:** HDFC, Accion-2, Shell-2, Persistent  |  **My performance:** Correct

**My answer (from transcript):**
A new image version caused pods to get OOMKilled across environments, triggering alerts. As on-call I started a bridge call, pulled in the app team and architect. Inspected resources at pod and node level: pods were exceeding their limit but nodes were healthy; no networking/storage/deployment issue, purely OOMKilled. Showed Prometheus dashboards proving other apps were fine. The architect found a threading issue in the new version causing a memory leak. We opened a hotfix branch, rolled back to the previous version, mitigated, then ran an RCA with 5 Whys, tested through dev/integration/UAT to production. Initial bridge ~40 minutes; full fix took 2 days.

**✅ Correct answer:**
Strong, structured answer — detection → bridge → isolate platform vs app → mitigate by rollback → RCA. To make it land at senior level, name the roles you were playing (you acted as **Incident Commander**: you didn't debug, you coordinated and made the rollback call) and quantify with the incident metrics: MTTD (alert fired within N min of deploy), MTTM/MTTR (mitigated in ~40 min via rollback), and note detection was automated (symptom alert), not a customer report. One refinement: OOMKill immediately after deploy is a textbook "**bad rollout**" signature — a good IC forms that hypothesis in the first 60 seconds and reaches for `rollout undo` before deep-diving, which is exactly what you did.

```text
INCIDENT COMMANDER FLOW (say this out loud in the interview)
 1. DECLARE  — sev, open bridge/channel, assign IC + Comms + Ops
 2. ASSESS   — blast radius (users %, envs), golden signals, "what changed?"
 3. MITIGATE — rollback / scale / failover  (restore service, not root cause)
 4. VERIFY   — signals green, confirm with dashboards, close bridge
 5. LEARN    — blameless postmortem, 5 Whys, action items with owners+dates
Metrics to state: MTTD, MTTM (mitigate), MTTR (resolve), users impacted.
```

---

## Q3. Was the OOM at application start or under heavy usage?
**Asked in:** HDFC  |  **My performance:** Correct

**My answer (from transcript):**
As soon as the app started, within a couple minutes it went OOM because of the memory leak; pods were killed continuously due to K8s configuration.

**✅ Correct answer:**
Correct — and the *timing itself is a diagnostic tool*, which is worth saying explicitly. OOM **immediately at start** = the process's baseline/startup footprint exceeds the container `limits.memory` (bad build, oversized heap/thread pool, or a limit set too low) → symptom is `CrashLoopBackOff` with `OOMKilled` reason and exit code 137. OOM **only under load / hours later** = a genuine leak or unbounded cache/connection growth that climbs with traffic. First case → roll back / raise limit; second → heap profiling. Confirm the cause via `reason: OOMKilled` and the container's `restartCount`.

```bash
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# -> OOMKilled ; exitCode 137 = SIGKILL by cgroup OOM killer
kubectl describe pod $POD -n $NS | grep -A3 -iE 'Last State|Reason|Restart Count'
# Startup-OOM  -> footprint > limits.memory (bad build / limit too low)
# Load-OOM     -> leak / unbounded cache; profile the heap
```

---

## Q4. Is an incident created even for lower environments? How is severity decided?
**Asked in:** HDFC  |  **My performance:** Correct

**My answer (from transcript):**
Yes. Business-critical app = P2, otherwise P3/P4 for lower environments; Production is P1 by default.

**✅ Correct answer:**
Right instinct. Tighten it: severity is driven by **impact × scope**, not environment alone — user-facing impact, number of users/services affected, data loss risk, and whether a workaround exists. Production customer-facing outage = P1/Sev1; degraded-but-working = P2; lower-env breakage that blocks a release train = P2/P3; cosmetic/no user impact = P4. The point of a severity matrix is that it deterministically drives the *response* (who is paged, comms cadence, whether a bridge is opened), so on-call never argues severity mid-incident.

```text
SEVERITY MATRIX
Sev1 (P1): Prod down / data loss / major $ or many users     -> page IC, exec comms, bridge now
Sev2 (P2): Prod degraded, workaround exists, or biz-critical -> page on-call, 30-min updates
Sev3 (P3): Minor impact, single non-critical service/env     -> ticket, business hours
Sev4 (P4): Cosmetic / no user impact / lower-env noise       -> backlog
Rule: impact & scope set severity — environment is only one input.
```

---

## Q5. Give another incident-management example (different failure mode).
**Asked in:** HDFC  |  **My performance:** Correct

**My answer (from transcript):**
An app team shipping a business-critical feature hit CrashLoopBackOff / ImagePullBackOff. ArgoCD logs indicated an image issue. ECR latest tag was e.g. 1.45.6 but the app code referenced 1.46.10 — a tag mismatch. The app team applied the correct tag present in ECR, re-ran the pipeline, fixed.

**✅ Correct answer:**
Good — and it shows you distinguish failure signatures, which interviewers probe for. Be precise on the two states because they have *different* root causes: **ImagePullBackOff / ErrImagePull** = kubelet can't fetch the image (nonexistent tag, wrong registry, missing `imagePullSecret`, rate limit) — a *supply* problem, before the container runs. **CrashLoopBackOff** = image pulled fine but the process starts and exits repeatedly — an *application* problem (bad config, missing env/secret, failed dependency, OOM). Your case was the former (tag not in ECR). The systemic fix is to stop referencing floating tags and pin immutable digests so code and registry can never drift.

```bash
kubectl describe pod $POD -n $NS | grep -A5 Events
# "Back-off pulling image ...:1.46.10" / ErrImagePull -> tag or auth problem
kubectl get pod $POD -n $NS -o jsonpath='{.spec.containers[0].image}{"\n"}'
aws ecr describe-images --repository-name $REPO \
  --query 'imageDetails[].imageTags' --output text     # is the tag actually there?
# Prevent recurrence: reference immutable digest, not a moving tag
#   image: repo@sha256:<digest>
```

---

## Q6. During a bridge there's random debating and poking at different resources — how do you avoid that?
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
First point of contact is checking the error message and its application logs; in most cases that shows which bucket (storage, security, networking, processor, or a combination) the issue is in. Focus on that error, cut the clutter, dig deep to the root cause rather than chasing unrelated areas.

**✅ Correct answer:**
The technique (let the error/log narrow the domain, then focus) is right. The *organizational* answer interviewers want is **Incident Command structure**: one Incumbent Commander owns the call and is the single decision-maker; everyone else is an assigned role (Ops, Comms, Scribe) or a subject expert who speaks only about their domain. The IC drives with structured hypothesis-testing — "here's the current hypothesis, X is verifying it, everyone else hold" — and parks unrelated theories in a "later" list. That converts a debating mob into a serialized, evidence-driven investigation. Symptom-first + IC-owned focus is how you kill the random poking.

```text
KILL THE DEBATE — IC discipline
- ONE IC, ONE decision-maker. Experts advise; IC decides.
- Every claim must cite evidence (a graph, a log line), not a hunch.
- Track: HYPOTHESIS -> who's testing -> result -> next.  (Scribe logs it.)
- Unrelated theories go to a parking lot; revisit only if current one fails.
- Timebox each hypothesis; if disproven, move on — no re-litigating.
```

---

## Q7. A fix took 2 days — how do you ensure action items assigned to different people are done on time?
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
After collecting the 5 Whys in the RCA call, before closing the RCA we verify all proposed problems/solutions are implemented. The app team gives a small demo (old code, old version, new fixed version), explains the steps; we document in Confluence, and only once the proposed solution works as expected do we close the RCA ticket.

**✅ Correct answer:**
Solid — verify-before-close with a demo is exactly right. Add the accountability mechanics a lead is expected to run: every action item is a **tracked ticket with a single owner and a due date** (SMART), classified as *preventive* (stops recurrence) vs *corrective* (cleans up this incident), and prioritized so the high-leverage prevention items don't get abandoned once the fire is out. Review open postmortem actions in a recurring reliability/ops review; SLA-track them so completion rate is visible. The demo-gated closure you described is the acceptance test on top of that.

```text
ACTION-ITEM TRACKING
| ID | Action                          | Owner   | Due     | Type       | State |
|----|---------------------------------|---------|---------|------------|-------|
| A1 | Fix threading memory leak       | app-dev | +2d     | corrective | done  |
| A2 | Add memory-limit + OOM alert    | sre     | +1w     | preventive | open  |
| A3 | Pin immutable image digest      | app-dev | +1w     | preventive | open  |
Close incident only when: every action ticketed, owned, due-dated;
high-priority preventive items reviewed weekly until closed.
```

---

## Q8. Was one team looking at everything, or different teams per component? How did you get answers in ~10 minutes when dashboards aren't 100% efficient?
**Asked in:** Shell-2  |  **My performance:** Correct

**My answer (from transcript):**
Initially one team; my solutions architect joined the bridge. Because it was an OOMKilled error (usually underlying resource constraints), I checked pod-level CPU/memory first, then node-level swap memory, logged into the cluster via CLI to confirm other apps in the namespace were fine, and checked network latency from the platform side. Cross-verified with the architect that the platform was healthy; took 10-15 minutes.

**✅ Correct answer:**
Good — the speed came from **hypothesis-driven differential diagnosis**, not from reading every dashboard. Make that explicit: the OOMKilled signal instantly partitions the problem space (compute-saturation, not network/storage/security), so you test the highest-probability branch first and use "other apps in the namespace are healthy" as the control that rules out shared/platform causes. That's how you compress diagnosis: dashboards give the *symptom*, targeted CLI checks confirm/deny a *specific hypothesis*. When telemetry is thin, you lean on the invariant "what changed?" (a fresh deploy) plus a known-good comparison.

```bash
# Differential diagnosis in ~10 min: confirm the compute hypothesis, rule out platform
kubectl top pod $POD -n $NS                    # this pod at/over limit?  (hypothesis)
kubectl top nodes                              # node healthy? -> not a node problem
kubectl top pods -n $NS | grep -v $APP         # peers healthy? -> not shared/platform
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
# All four together => "app-scoped OOM after deploy" with high confidence.
```

---

## Q9. Were you personally responsible for the uptime and availability of that cluster?
**Asked in:** Shell-1  |  **My performance:** Correct

**My answer (from transcript):**
Yes, that's right.

**✅ Correct answer:**
Fine to confirm ownership, but turn a yes/no into evidence of *how* you owned it: you owned the platform SLOs (control-plane and workload availability), ran the on-call rotation and error-budget reporting, and were accountable for MTTR on cluster incidents. Ownership in SRE terms means you set the reliability targets, instrumented them, got paged against them, and reported the numbers — not just "I kept it up."

```text
"I owned it" = I owned the NUMBERS:
- Availability SLO (e.g. 99.9% control-plane + workload readiness)
- On-call rotation, escalation, and MTTR for cluster incidents
- Error-budget tracking + monthly reliability report to stakeholders
- Capacity/headroom and upgrade/patch cadence
```

---

# 2. RCA & Postmortems

## Q10. 🔻 What makes a postmortem *blameless*?
**Asked in:** HTC-1  |  **My performance:** Partial (described 5-Whys mechanics, missed the no-blame culture)

**My answer (from transcript):**
Start the RCA by asking the 5 Whys to trace from problem to solution, identifying the real failure point (app config, latest version, node resource constraints, firewall issues). Then the responsible team member promptly owns it with a solution so it doesn't become a blame game. (Described the 5 Whys more than the culture of blamelessness.)

**✅ Correct answer:**
5 Whys is the *analysis technique*; "blameless" is a *cultural stance* and that's the actual answer. Blameless means you assume **every engineer acted reasonably given the information, tools, and incentives they had at the time**, so the postmortem attacks the *system* — missing guardrails, confusing UX, absent alerts, gaps in process — never the person. You never write "Bob ran the wrong command"; you write "the tool allowed a destructive command with no confirmation and no dry-run." The purpose is psychological safety: if people fear punishment they hide detail and stop reporting near-misses, which destroys your ability to learn. Blamelessness is what *makes* the 5 Whys honest — human error is treated as a symptom of a system that permitted it, and the output is systemic fixes, not reprimands. Say the phrase: *"blame the system, not the human."*

```text
BLAMELESS POSTMORTEM — rewrite the language
  ❌ "Engineer deployed the wrong tag."
  ✅ "The pipeline let code reference a tag absent from the registry with no
      validation gate; a digest-pin + CI check would prevent it."
Principles:
  - Assume good intent + reasonable action given info available at the time.
  - Human error = a signal of a missing safeguard, not the root cause.
  - Facts + timeline, no punishment -> people share freely -> real learning.
  - Output = systemic action items (guardrails, alerts, automation).
```

---

## Q11. 🔻 Did you capture metrics like MTTR and MTTD for that incident?
**Asked in:** Accion-1  |  **My performance:** Partial (confused MTTR the metric with a percentage)

**My answer (from transcript):**
Incident bridge closed within ~1 hour (rolled back); RCA took ~2-3 hours, then the app team fixed and redeployed. Fumbled the actual MTTR figure ("maybe 30-40%"), confusing the metric with a percentage.

**✅ Correct answer:**
Fix the unit error first: MTTR is a **duration**, not a percentage. "30-40%" is meaningless for MTTR — that's what tripped the interviewer. For that incident you'd report it as clock time and separate the phases: **MTTD** = deploy→alert (a few minutes, automated detection), **MTTM** (mean time to *mitigate*) = detection→rollback restored service (~40-60 min), **MTTR** (mean time to *resolve/recover*) = detection→permanent fix deployed (the app-team fix, hours to ~2 days). Interviewers love the MTTM vs MTTR distinction because rollback restores users long before the true fix ships. These are *means* over many incidents, so a single incident contributes a data point; you track the rolling average to prove trends (your "40% MTTR reduction" story).

```text
ONE INCIDENT'S TIMELINE  (report in TIME, never %)
 t0  deploy pushed
 t0+4m   alert fires        -> MTTD  ≈ 4 min
 t0+45m  rollback restores  -> MTTM  ≈ 41 min (mitigate)
 t0+2d   permanent fix live -> MTTR  ≈ ~2 days (resolve)
"40% MTTR reduction" = the ROLLING AVERAGE fell 40% across incidents.
```

---

## Q12. Explain the template of your 5-Whys RCA meeting.
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
Using the OOMKill example: Why OOMKill? Pod exceeds defined resource limits. Why exceeding limits? Issue with the internal process / Docker image / latest app tag — it was the latest app tag. Why an issue with the latest tag? What recent changes were made in this version. We probed which changes correlate to the memory issue, narrowed from 4 to 2 options, identified threading causing the memory leak, fixed it, recreated the image via CI/CD, and tested dev to production.

**✅ Correct answer:**
Clean chain. Two upgrades make it senior-grade. (1) Push the *last* Why to a **systemic** root cause, not just the technical one: don't stop at "threading bug in the new version" — ask why it reached production, landing on "no memory-limit regression test / no canary," which is the action item that actually prevents recurrence. (2) The 5 Whys can branch — a single symptom often has a *contributing-factors tree*, not one linear chain (why did it break AND why didn't we catch it AND why was blast radius wide). Cover the detection and mitigation branches too, not just the cause branch.

```text
5 WHYS — push to a SYSTEMIC root, branch on detect/mitigate
Symptom: pods OOMKilled after v1.46 deploy
  Why1 process RSS > container memory limit
  Why2 memory leak in the new build
  Why3 threading change allocated unbounded objects
  Why4 no memory-regression/soak test in the pipeline   <- systemic
  Why5 no canary; full-fleet rollout = max blast radius  <- systemic
Branch B (detection): why not caught pre-prod? -> no load/soak stage
Branch C (mitigation): why 40 min? -> rollback was manual, not automated
Action items map 1:1 to the systemic Whys.
```

---

## Q13. Walk me through a blameless postmortem of a major production outage you were involved in.
**Asked in:** Accion-1  |  **My performance:** Correct

**My answer (from transcript):**
After a new app version deployed, pods had OOM/memory-killed issues despite Karpenter + HPA. Mitigation: rolled back to the previous version, scheduled a separate RCA call. Platform side was clean; the app team found a memory leak from threading issues, fixed and tested in lower environments, redeployed with no issue. Emphasized clear cross-team communication showing infra/K8s/CI were healthy and the issue was app-side.

**✅ Correct answer:**
Good narrative and good instinct to prove the platform was healthy (that's how you avoid finger-pointing). To make it a *postmortem* rather than an incident retelling, present it in the canonical document structure and — critically for "blameless" — frame the cause as a **process gap**, not the app team's fault: HPA/Karpenter can't save you from a per-pod leak (autoscaling adds replicas that each leak, sometimes making it worse), and the real root cause is the missing soak test + full-fleet rollout. Include impact, a minute-by-minute timeline, what went well/poorly, and owned action items.

```text
POSTMORTEM  — "v1.46 OOM outage"
Summary   : new build leaked memory; pods OOMKilled fleet-wide post-deploy.
Impact    : app down ~5 min; N users; Sev2->Sev1.
Timeline  : t0 deploy · t+4m alert · t+45m rollback (mitigated) · t+2d fix live.
Root cause: threading change -> unbounded allocation (leak). HPA/Karpenter
            scaled replicas that each leaked -> no help. SYSTEMIC: no soak
            test in CI + non-canary full rollout.
Went well : fast detection, clean IC, rollback restored service quickly.
Went poor : leak shipped to prod; manual rollback.
Actions   : soak test in CI (A1), canary rollout (A2), auto memory alert (A3).
Blameless : cause = missing guardrails, not the engineer who wrote the code.
```

---

# 3. SLO / SLI / Error Budgets

## Q14. 🔻 What is an error budget?
**Asked in:** Accion-1  |  **My performance:** Partial (garbled the numbers; conflated error budget with allowed-error %)

**My answer (from transcript):**
The percentage of error the SLA can accommodate. E.g. if error budget is 2%, the platform should accommodate ~98% uptime; exceeding it breaches the SLA. (Roughly right idea but garbled — said "98 to 19%" and conflated error budget with the allowed error percentage.)

**✅ Correct answer:**
The concept is right but state the definitions cleanly so the numbers stop slipping. **SLI** = the measured signal (e.g. % of successful requests). **SLO** = your internal target for that SLI (e.g. 99.9% success). **Error budget = 100% − SLO** = the *allowed* unreliability (0.1%). The **SLA** is the *external, contractual* promise with penalties, and is deliberately looser than the SLO. So don't say "error budget is 2% so 98% uptime" — say "SLO 99.9% ⇒ error budget 0.1% ⇒ ~43 min/month of allowable downtime." The budget is a *quantity you spend*: as long as you have budget left you can ship features and take risk; when it's exhausted you slow down and prioritize reliability. It reframes reliability from "never fail" to "fail within an agreed, spendable allowance."

```text
SLI  = success_ratio measured        e.g. good/total requests
SLO  = internal target on the SLI    e.g. 99.9%
BUDGET = 100% − SLO = 0.1%           the reliability you may "spend"
SLA  = external contract (looser)    e.g. 99.5%, with penalties

Error budget as TIME (per 30 days):
  99.9%   -> 0.1%   -> ~43 min/month
  99.95%  -> 0.05%  -> ~22 min/month
  99.99%  -> 0.01%  -> ~4.3 min/month
```
```promql
# Availability SLI and remaining error budget over 30d (99.9% SLO)
sli = sum(rate(http_requests_total{code!~"5.."}[30d]))
    / sum(rate(http_requests_total[30d]))

budget_remaining = 1 - (1 - sli) / (1 - 0.999)   # 1.0 = full, 0 = exhausted
```

---

## Q15. 🔻 A PM wants to push a high-priority feature but the error budget is already depleted — how do you handle it?
**Asked in:** Accion-1  |  **My performance:** Partial (never reached the policy answer — freeze/negotiate)

**My answer (from transcript):**
Initially: spin up a P1 bridge, recommend rolling back, deploy features in lower environments, test, then production. When pushed for a middle ground, said I'd assess the problem, split into buckets (storage/network/process/security), fix or escalate, aim to fix within a couple hours. Didn't reach a policy answer.

**✅ Correct answer:**
This isn't a debugging question — it's a **governance / error-budget-policy** question, and that's the answer they were mining for. A pre-agreed policy (signed off by product *and* engineering *before* incidents, so it's not negotiated under pressure) dictates the response: **budget exhausted ⇒ feature freeze — only reliability work and P1 fixes ship until the budget recovers.** You don't argue case-by-case; you point to the policy. The nuance a senior adds: not all changes are equal — you can still ship low-risk changes behind a **feature flag / canary** to a tiny cohort (small, bounded spend), and you *negotiate*: "we can ship this if we first burn down the reliability debt causing the burn, or if leadership formally accepts the risk and raises the budget." The budget converts an emotional argument into a data-driven, policy-driven decision.

```text
ERROR-BUDGET POLICY (agreed up-front, invoked automatically)
  budget > 0            -> ship freely; take normal risk
  budget < 25%          -> slow down; extra review + canary only
  budget exhausted      -> FEATURE FREEZE: reliability work + P1 fixes only
  exec override         -> risk formally accepted & logged; budget raised
"High-priority feature, budget = 0" ->
  1) cite the policy (freeze), don't debate ad hoc
  2) offer canary/flag path for a low-risk slice
  3) trade: fix the burn source first, or get written risk-acceptance.
```

---

## Q16. What is the role of an SRE lead?
**Asked in:** Pure-SW  |  **My performance:** Correct

**My answer (from transcript):**
Once leadership defines the SLA, the SRE lead breaks it into SLOs/SLIs (uptime %, error budgets, latency), defines the important metrics, and coordinates the team to implement them. Set up alerts and dashboards; have an alert mechanism (Slack/phone) that triggers if a pod is in fail state beyond a threshold; auto-attach runbooks into alert messages. This reduces MTTR by 60-70%. Then perform RCA with 5 Whys, gather info from teams, document, and add preventive/reactive solutions (often scripts) to reduce fix time on recurrence.

**✅ Correct answer:**
Excellent, complete answer — SLA→SLO/SLI decomposition, observability, alerting-with-runbooks, RCA, and automation. Two framing additions that signal seniority: (1) an SRE lead owns the **error-budget policy** and uses it to arbitrate the reliability-vs-velocity tension between product and engineering — that's the defining SRE responsibility. (2) The strategic mandate is **eliminating toil through automation** and capping operational work (Google's "≤50% toil" guideline) so the team does engineering, not manual firefighting. So: define/measure reliability, defend it with the budget, automate away toil, and lead incident response + blameless learning.

```text
SRE LEAD — mandate
  MEASURE   translate SLA -> SLI/SLO, error budgets, golden-signal dashboards
  DEFEND    own the error-budget POLICY; arbitrate reliability vs velocity
  DETECT    symptom-based alerting + runbooks; cut MTTD/MTTR
  RESPOND   incident command, on-call health, blameless postmortems
  AUTOMATE  drive out toil (target ≤50%); build self-heal + guardrails
  PLAN      capacity, DR/RTO-RPO, reliability roadmap
```

---

## Q17. A service consumes 70% of its monthly error budget in one day. What do you do?
**Asked in:** HTC-1  |  **My performance:** Correct

**My answer (from transcript):**
Since 70% is large, find the exact failure points contributing to the error budget — deployment failures, availability, or deployment strategies. If availability, ensure the platform and dependencies are configured correctly and CI/CD works; if latency, check contributing parameters (slow nodes, resource constraints, firewall issues). Dissect the problem, troubleshoot, and reduce the error-budget burn.

**✅ Correct answer:**
Right diagnostic instinct. Name the concept: 70% in one day is a **fast burn-rate event** — the budget is being spent far faster than the 30-day pace allows (~23× the sustainable rate), which is exactly what **burn-rate alerting** is designed to catch. So the response is: (1) treat it as an active incident, not a slow trend — page and investigate now; (2) correlate the burn spike to "what changed?" (deploy, dependency, traffic shift); (3) mitigate to *stop the bleed* (rollback/scale/shed) before deep RCA; (4) invoke the error-budget policy — a single-day 70% burn likely warrants a **freeze** on further risky changes until recovered. The key insight you can add: a high burn rate is an *early-warning* signal that lets you act before the SLO is actually breached.

```promql
# Burn rate = how many x faster than the sustainable spend
# 1.0 = on-pace to exactly exhaust budget over the window; >1 = too fast
error_rate = sum(rate(http_requests_total{code=~"5.."}[1h]))
           / sum(rate(http_requests_total[1h]))
burn_rate  = error_rate / (1 - 0.999)      # 0.001 = budget for 99.9% SLO

# 70% of a 30-day budget in 1 day  => burn_rate ≈ 0.70 / (1/30) ≈ 21x
# ALERT: page if burn_rate > 14.4 over 1h (Google fast-burn threshold)
```

---

## Q18. A new feature raises user-facing latency ~20% but you're still within SLA. Is that a problem? What do you do?
**Asked in:** HTC-1  |  **My performance:** Correct

**My answer (from transcript):**
Even within SLA it impacts customer experience since customers report latency, so look into it. Temporarily roll back to the previous version via a hotfix branch; collaborate with app teams to fix latency in lower environments, then merge the hotfix to main. Suggested Canary deployments to target a limited set of users before full rollout.

**✅ Correct answer:**
Correct that "within SLA" ≠ "fine" — user experience degrades before the contractual line, and a 20% regression is *spending latency budget*. Add rigor: (1) look at the **right statistic** — a 20% jump in **p95/p99** matters far more than the mean; averages hide the tail where real users hurt. (2) Decide with data: is this regression *consuming your latency error budget* at a rate that will breach the SLO before month-end? If yes, it's an incident regardless of the current SLA headroom. (3) Correct sequence: mitigate (roll back the feature), reproduce and fix in lower env, and re-release behind a **canary** so the next latency regression is caught on 1-5% of traffic, not 100%. Being within SLA buys you time to fix calmly — it doesn't mean ignore it.

```promql
# Judge on TAIL latency, not average
p99 = histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))

# Latency SLO: 95% of requests < 300ms  -> latency error budget
good = sum(rate(http_request_duration_seconds_bucket{le="0.3"}[30d]))
tot  = sum(rate(http_request_duration_seconds_count[30d]))
latency_sli = good / tot          # must stay >= 0.95; watch its burn rate
```

---

## Q19. Do you know what a Canary release is? Apply it to the earlier problem.
**Asked in:** Accion-1  |  **My performance:** Correct (after a hint)

**My answer (from transcript):**
Initially didn't recall the term. After a hint: route 10-15% of traffic to the new version, test with a separate user group, gather positive feedback, gradually increase (15%→30%→…) while scaling down the old version, and once ~60-70% positive with no issues, cut fully to the new version.

**✅ Correct answer:**
The mechanic is right (progressive traffic shift with gradual rollback of the old version). Level it up: a canary is only useful if promotion is **gated on SLIs, not vibes** — you don't advance on "positive feedback," you advance automatically when the canary's error rate and p99 latency stay within thresholds versus the baseline, and you **auto-rollback** the instant they breach. State the value: canary **bounds blast radius** — a bad build hits 1-5% of users, not 100%, which is exactly what would have contained the OOM incident. Contrast with **blue-green** (instant 100% switch with fast rollback, no gradual soak) so you show you pick strategies deliberately. Progressive delivery tools (Argo Rollouts, Flagger) automate the analysis + rollback.

```yaml
# Argo Rollouts canary — SLI-gated, auto-rollback
strategy:
  canary:
    steps:
      - setWeight: 5           # 5% of traffic to new version
      - pause: {duration: 10m}
      - analysis:              # promote only if metrics pass
          templates: [{templateName: success-rate}]
      - setWeight: 25
      - pause: {duration: 10m}
      - setWeight: 50
      - pause: {duration: 10m}
      - setWeight: 100
# success-rate analysis: successRate >= 0.999 AND p99 < 300ms
#   -> breach = automatic rollback to stable. Blast radius capped at 5%.
```

---

# 4. Reliability Concepts

## Q20. 🔻 Are you aware of the CAP theorem?
**Asked in:** HTC-1  |  **My performance:** Didn't know

**My answer (from transcript):**
Said no, I have not studied the CAP theorem.

**✅ Correct answer:**
CAP is a distributed-systems fundamental — you must have a crisp answer. It states that a distributed data store can guarantee at most **two of three**: **C**onsistency (every read sees the latest write), **A**vailability (every request gets a non-error response), **P**artition tolerance (the system keeps working despite network splits between nodes). The real-world catch: in any distributed system network partitions *will* happen, so **P is non-negotiable** — which means the actual runtime choice is **C vs A during a partition**. **CP** systems (etcd/ZooKeeper, HBase, traditional RDBMS clusters) refuse or block requests to avoid serving stale data — they sacrifice availability for correctness (that's why Kubernetes' etcd is CP: a split-brain control plane would be catastrophic). **AP** systems (Cassandra, DynamoDB, Riak) keep serving, accepting possibly stale reads, and reconcile later (eventual consistency). The SRE tie-in: your consistency choice directly bounds your availability SLO — you can't promise 99.99% availability *and* strong consistency across a partition. PACELC extends it: **E**lse (no partition) you still trade **L**atency vs **C**onsistency.

```text
CAP — pick 2 of 3; P is forced in real networks -> choose C or A on partition
        Consistency          Availability          Partition tolerance
  CP  ✔ latest data        ✘ may reject/block     ✔  (etcd, ZooKeeper, HBase, RDBMS)
  AP  ✘ maybe stale        ✔ always answers       ✔  (Cassandra, DynamoDB, Riak)
  CA  only without partitions -> not real for distributed systems

etcd is CP  -> a partitioned K8s control plane stops writes rather than split-brain.
PACELC: if Partition -> C vs A;  Else -> Latency vs Consistency.
SRE tie-in: strong consistency caps your achievable availability SLO.
```

---

## Q21. 🔻 Explain MTTR, MTBF, and MTTD.
**Asked in:** HTC-1  |  **My performance:** Partial (MTTR/MTTD roughly right; couldn't recall MTBF)

**My answer (from transcript):**
Got MTTR (mean time to restore/resolve) and MTTD (mean time to detect) roughly right but fumbled. Could not recall MTBF (mean time between failures) — said not sure.

**✅ Correct answer:**
Lock all four with a single timeline. **MTTD — Mean Time To Detect:** failure occurs → you become aware (measures monitoring quality). **MTTA — Mean Time To Acknowledge:** alert fires → on-call ack (measures alerting/rotation health). **MTTR — Mean Time To Recover/Repair:** detection → service restored (measures response effectiveness; note: "resolve" = permanent fix vs "mitigate" = restored, worth distinguishing). **MTBF — Mean Time Between Failures:** average uptime *between* consecutive incidents (measures inherent reliability — high MTBF = fails rarely). The mnemonic that fixes MTBF: MTBF is about **frequency** (how often it breaks), MTTR is about **speed** (how fast you fix it). Availability ties them together: **Availability = MTBF / (MTBF + MTTR)** — you raise it either by failing less often (↑MTBF) or recovering faster (↓MTTR). MTTF (mean time *to* failure) is for non-repairable components; MTBF is for repairable systems.

```text
FAILURE TIMELINE
  |<---------- MTBF: uptime between failures ---------->|
  ...running...                                     [FAILURE]
                              detect   ack        recover
                    MTTD ----->|  MTTA->|  MTTR ---->|
  MTBF = how OFTEN it breaks (frequency, ↑ is better)
  MTTR = how FAST you fix it (speed, ↓ is better)
  Availability = MTBF / (MTBF + MTTR)
  e.g. MTBF 720h, MTTR 1h -> 720/721 = 99.86%
```

---

## Q22. 🔻 Do you know what chaos engineering is?
**Asked in:** HTC-1  |  **My performance:** Partial (thought it was load/stress testing — missed fault injection)

**My answer (from transcript):**
Thinks chaos engineering is testing the system to its maximum limit — incoming traffic, load testing, security tests. (Captured "stress the system" but missed the deliberate fault-injection / resilience-validation core.)

**✅ Correct answer:**
Important correction: **chaos engineering is NOT load testing.** Load testing asks "how much *volume* can it handle?"; chaos engineering asks "does it *survive failure* gracefully?" It is the practice of **deliberately injecting faults** into a system — killing pods, adding network latency/packet loss, exhausting CPU/memory, blackholing a dependency, taking down an AZ — to *verify* the system's resilience (failover, retries, degradation) works **before** a real outage forces the test. It's the scientific method: (1) define the **steady-state** (a normal-behavior metric like success rate), (2) **hypothesize** it holds during the fault, (3) inject the fault in production or prod-like, ideally starting with a small **blast radius**, (4) measure — if steady-state breaks you've found a weakness to fix; if it holds you've earned confidence. Netflix's Chaos Monkey (randomly kills instances) is the classic example; tools: Chaos Monkey/Simian Army, Gremlin, LitmusChaos, Chaos Mesh, AWS FIS. Say the one-liner: *"break things on purpose, in a controlled way, to prove the system recovers."*

```yaml
# LitmusChaos experiment: inject pod-kill, verify steady-state holds (NOT load)
kind: ChaosEngine
spec:
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - {name: TOTAL_CHAOS_DURATION, value: "60"}
            - {name: PODS_AFFECTED_PERC,   value: "50"}   # small blast radius
        probe:
          - name: check-availability
            type: promProbe        # steady-state hypothesis
            promProbe/inputs:
              query: sum(rate(http_requests_total{code!~"5.."}[1m]))
                   / sum(rate(http_requests_total[1m]))
              comparator: {criteria: ">=", value: "0.99"}  # must stay 99%+
# Pass = HA/failover works. Fail = a real weakness found before customers do.
```

---

# 5. On-call & Toil

## Q23. How did you enable the Ops/dev team to reduce toil — runbooks/playbooks from past incidents?
**Asked in:** Accion-1  |  **My performance:** Correct

**My answer (from transcript):**
Created runbooks for incident management. On P1/P2 triggers, spin up bridge calls, track RCA, close call, then perform RCA via 5 Whys documented in a Confluence page with a dedicated location. Also created runbooks tied to alerts so the alert message includes a link to the relevant runbook posted to the Slack channel for on-call engineers.

**✅ Correct answer:**
Good — runbook-linked alerts are a real toil reducer (the responder isn't hunting for context at 2 AM). Sharpen the *definition* and the *endgame*, because "toil" is a precise SRE term interviewers test. **Toil = manual, repetitive, automatable, tactical work that scales linearly with service size and has no lasting engineering value** (it's not "hard work" or "overhead"). Runbooks are step one — they make toil *repeatable*; the real goal is to make it *disappear*. The maturity ladder is: **manual → documented runbook → semi-automated script → fully automated self-healing** (the alert triggers remediation with no human). So the strongest version of your answer: I captured recurring incidents as runbooks, then converted the highest-frequency ones into scripts, then into auto-remediation, and I *measured* toil (on-call ticket counts, time spent) to prove it dropped and to keep the team under the ~50% toil cap.

```text
TOIL-REDUCTION LADDER  (goal: automate the runbook out of existence)
  L0 tribal knowledge         -> undocumented, on-call guesses
  L1 runbook (Confluence)     -> repeatable steps, linked in the alert   [you here]
  L2 script / one-click       -> `./remediate.sh`, human triggers
  L3 self-healing             -> alert -> automated remediation, no human
Measure it: toil = %on-call time on manual repetitive work.
  - count recurring ticket types, time per type
  - target ≤ 50% toil; automate the top-frequency items first
```

---

# 6. Troubleshooting Scenarios

## Q24. 🔻 A severe outage at ~2 AM impacts 30-40% of users. How do you handle it?
**Asked in:** HTC-1  |  **My performance:** Partial (answered team-structure/handoff instead of immediate triage)

**My answer (from transcript):**
Focused on follow-the-sun team structure — Indian, Europe, and US teams work their time zones with proper handoffs. Ensure recent deployment/upgrade info is passed on and documented so whoever is on call can refer to updates and start troubleshooting. (Answered team structure rather than the immediate incident triage steps.)

**✅ Correct answer:**
This is where the interviewer wanted **live triage**, and you answered org-chart — the exact reflex to fix. Lead with the incident-response sequence, not the team topology. **Declare a Sev1** (30-40% of users is major) → open the bridge, assign IC/Comms → **assess**: which users/regions/endpoints, then the golden signals and the error codes. Reading **HTTP status codes** is the fastest triage fork and you should name them cold: **5xx = server/our side** (500 app exception/unhandled error, **502/503 = upstream down or overloaded/no healthy backends** → points at a crashed dependency, bad deploy, or saturation, **504 = timeout downstream**); **4xx = client/request side** (400 bad request, 401/403 auth, 429 rate-limited). A wall of **503** screams "backends unhealthy — recent deploy or resource exhaustion," a wall of **500** screams "code path throwing." Then the universal high-yield question — **"what changed?"** (deploy, config, cert expiry, dependency, traffic) → **mitigate first** (rollback / scale / failover / shed load) → verify → *then* RCA. Follow-the-sun and handoffs are how you *staff* on-call, not how you *run* the incident — mention them only as a footnote.

```bash
# 30-40% users down at 2 AM — TRIAGE FIRST (don't jump to infra or org chart)
# 1) What's the failure signature? Read the status codes:
kubectl logs deploy/gw -n $NS --since=10m | grep -oE ' (4|5)[0-9][0-9] ' | sort | uniq -c | sort -rn
#   many 503 -> backends unhealthy / overloaded (deploy? saturation?)
#   many 500 -> app throwing exceptions (bad code path / dependency)
#   many 504 -> downstream timeouts (slow DB / upstream)
#   many 429 -> rate-limited (traffic spike / misconfig)
# 2) What changed?
kubectl rollout history deploy/gw -n $NS | tail -5
kubectl get events -n $NS --sort-by=.lastTimestamp | tail -20
# 3) Mitigate to restore users, THEN RCA:
kubectl rollout undo deploy/gw -n $NS        # or scale / failover / shed load
```
```text
HTTP TRIAGE FORK
 4xx = CLIENT/request side    400 bad · 401/403 auth · 404 missing · 429 rate-limit
 5xx = SERVER/our side        500 app exception · 502 bad gateway ·
                              503 unavailable/no healthy backend · 504 upstream timeout
```

---

## Q25. 🔻 During an 8 PM deploy, v2 gets ImagePullBackOff; rollback triggers to v1 — but v1 can't be pulled because ECR itself is down. How do you restore the deployment?
**Asked in:** PwC-K8s  |  **My performance:** Partial

**My answer (from transcript):**
Keep a mini DR strategy for ECR — a copy of previous images in another ECR. Develop a hotfix branch that pulls the older image from the backup ECR (pipeline-level change) to temporarily restore the previous version; meanwhile fix and test the primary ECR, push images back, re-run the pipeline, and merge the hotfix to main to close the incident.

**✅ Correct answer:**
The backup-registry instinct is correct, but pause on the *fastest* recovery path first, because the interviewer is testing whether you understand how Kubernetes actually serves images. **The image v1 is very likely already cached on the nodes** that were running it — a pull only happens on `imagePullPolicy: IfNotPresent` when the image is absent, or always on `Always`. So the immediate mitigation is: **avoid triggering a pull at all** — keep the existing running pods up (don't delete them), set `imagePullPolicy: IfNotPresent`, and schedule the rollback onto nodes that already have v1 cached (`kubectl rollout undo` reusing cached layers). If a pull is unavoidable, then fail over the registry: point the deployment at your **cross-region ECR replica** (ECR supports cross-region replication) or a pull-through cache/mirror. Longer term this is a **DR gap in your image supply chain** — the registry is a single point of failure in the deploy path, so the postmortem action is registry replication + node image pre-pull/caching + `IfNotPresent` policy. Structure: mitigate via cache/replica → restore ECR → re-push → resume normal pipeline.

```bash
# Registry down mid-rollback — recover WITHOUT a fresh pull first
# 1) Is v1 already cached on the nodes that ran it? (then no pull needed)
kubectl get pods -n $NS -o wide            # find nodes that had v1
crictl images | grep myapp                 # on that node: v1 layers cached?
# 2) Don't force a pull: keep pods, use cached image
#    spec.containers[].imagePullPolicy: IfNotPresent
kubectl rollout undo deploy/myapp -n $NS   # reuse cached v1 on those nodes
# 3) If a pull is unavoidable -> fail over to the cross-region ECR replica:
kubectl set image deploy/myapp app=<acct>.dkr.ecr.us-west-2.amazonaws.com/myapp:v1 -n $NS
# 4) Restore primary ECR, re-push, revert image ref, resume pipeline.
# DR fix: ECR cross-region replication + node pre-pull + IfNotPresent policy.
```

---

## Q26. 🔻 You join a team owning a legacy platform on old/unsupported tech — original engineers gone, unknown app owners — and must drive its decommissioning. Where do you start?
**Asked in:** Shell-2  |  **My performance:** Partial (didn't reach for CMDB until prompted)

**My answer (from transcript):**
I'd analyze the application code and deployment, trace the request flow (DNS/internal network, backend DB or messaging queue), trace the SDLC and network-level request flow to understand the app, assess business value from incoming requests, and check if the service is being migrated elsewhere before gathering platform/app requirements. Did not initially think of CMDB until prompted.

**✅ Correct answer:**
Deep technical discovery is the *expensive* path — the interviewer wanted you to reach for the **system of record first**. Start with the **CMDB (Configuration Management Database)**: it maps the Configuration Item to its **business application ID, service owner, support group, dependencies, and criticality** — that's how you find owners in minutes instead of reverse-engineering traffic for weeks. Then work the paper trail: change/incident history in the ITSM tool (ServiceNow), contracts/licenses, monitoring and access logs (who calls it, who logs in), DNS/load-balancer records, and cost/billing tags (someone owns the bill). Only *then* do code/traffic tracing to fill gaps. Decommissioning method: **discover & confirm owners (CMDB) → map upstream/downstream dependencies → assess business value & find consumers → communicate + get sign-off → the "silent/dark" period** (block traffic, keep it running to catch anyone who screams) → back up data & configs → decommission → update the CMDB. Lead with records, verify with technical discovery — not the reverse.

```text
LEGACY DECOMMISSION — start with the SYSTEM OF RECORD, not code
  1. CMDB          -> CI -> business-app ID, OWNER, support group, criticality, deps
  2. ITSM history  -> ServiceNow changes/incidents; who touches it
  3. Paper trail   -> DNS/LB records, cost tags (who pays?), licenses, access logs
  4. Traffic       -> who calls it? (logs/APM) -> real consumers & value
  5. Confirm + comms + sign-off from owners
  6. SILENT PERIOD -> block traffic, keep running; wait for complaints
  7. Backup data/config -> decommission -> UPDATE THE CMDB
Records first (minutes) beats reverse-engineering traffic (weeks).
```

---

## Q27. Are you familiar with ITSM and CMDB? Why not check the CMDB for owners instead of manual discovery?
**Asked in:** Shell-2  |  **My performance:** Partial (agreed only after prompting)

**My answer (from transcript):**
Familiar with ITSM as a former critical incident manager. Named ServiceNow. Knew CMDB stores application identities like business application numbers. Agreed the CMDB would be a better starting point for finding owners once prompted, rather than doing manual discovery.

**✅ Correct answer:**
Have this crisp so you don't need prompting. **ITSM (IT Service Management)** = the framework/processes (ITIL-based) for delivering IT as services — Incident, Problem, Change, Request, and Configuration management; tools: **ServiceNow** (market leader), Jira Service Management, BMC Remedy, Freshservice. **CMDB (Configuration Management Database)** = the ITSM component that stores **Configuration Items (CIs)** — servers, apps, databases, services — and, crucially, the **relationships and ownership** between them (business-app ID, owner, support group, dependency graph, criticality). Why it's the right first stop for the previous question: the CMDB is the **authoritative system of record for "what exists and who owns it,"** so it answers the ownership/dependency question directly, whereas manual traffic tracing only *infers* it slowly and incompletely. Know the ITIL adjacency too: **Incident** = restore service fast; **Problem** = eliminate the root cause of recurring incidents (this is where blameless RCA lives); **Change** = control how modifications are introduced safely.

```text
ITSM (ITIL processes)                    | CMDB (a component of ITSM)
  Incident  restore service fast          |  CIs: servers, apps, DBs, services
  Problem   kill recurring root causes     |  + OWNER, support group, biz-app ID
  Change    safe controlled modifications  |  + relationships / dependency graph
  Request / Config management              |  + criticality
Tools: ServiceNow (leader), Jira SM,       |  = authoritative "what exists &
       BMC Remedy, Freshservice            |    WHO OWNS IT" — the first stop.
```

---

# 🔺 Advanced Questions to Master (not asked yet — practice these)

## A1. Define an error-budget policy: what concretely happens as the budget depletes, and who signs off?
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
An error-budget policy is a **pre-agreed, written contract between product and engineering** that removes emotion from the reliability-vs-velocity decision. It defines graduated consequences tied to remaining budget and is signed off *before* incidents by both eng leadership and product. The teeth are the enforced consequence — typically a **feature freeze** at exhaustion — plus a defined escalation/override path. Reviewed each SLO period.

```text
ERROR-BUDGET POLICY (signed by Eng + Product up-front)
  budget healthy (>50%)   normal velocity; take product risk
  budget low (<25%)       mandatory canary + extra review; defer risky changes
  budget exhausted (0)    FREEZE: only reliability work + P1 fixes ship
  repeated exhaustion     reliability sprint; SLO re-negotiation
  override                exec risk-acceptance, logged + time-boxed
```

---

## A2. Design multi-window, multi-burn-rate SLO alerting. Why not a single threshold?
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
A single static error-rate threshold is either too noisy (pages on blips) or too slow (misses slow burns). The Google SRE approach pages on **burn rate** across **two windows simultaneously** — a long window for significance and a short window for "is it still happening now?" — with **multiple severities**: a fast-burn alert (14.4× over 1h *and* 5m) pages immediately for budget-threatening spikes; a slow-burn alert (3× over 6h, or 1× over 3d) opens a ticket for gradual erosion. The dual window prevents both false alarms and firing long after the incident ended.

```promql
# FAST burn (page): 14.4x over 1h AND 5m  -> burns ~2% of 30d budget in 1h
( err_rate[1h] > 14.4*0.001 ) and ( err_rate[5m]  > 14.4*0.001 )
# SLOW burn (ticket): 3x over 6h AND 30m
( err_rate[6h] > 3*0.001   ) and ( err_rate[30m] > 3*0.001 )
# err_rate = sum(rate(reqs{code=~"5.."}[w])) / sum(rate(reqs[w])); 0.001 = 99.9% budget
```

---

## A3. How do you measure toil quantitatively, and what's your target?
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Toil is measurable, not a feeling. Instrument it: **count and time-track operational work** — tickets/alerts handled, time spent per recurring task, on-call interrupt frequency — and express it as a **percentage of engineering time on manual/repetitive/automatable work**. Google's guidance is to keep it **≤ 50%**; above that the team ossifies into ops and stops improving reliability. Attack the **highest frequency × highest time** items first (automate them out), and report the trend to justify the automation investment.

```text
toil% = (hours on manual, repetitive, automatable, no-lasting-value work)
        / (total engineering hours)
Instrument: ticket counts by type, mins/ticket, on-call interrupts/shift.
Target ≤ 50%. Prioritize automation by frequency × time-per-occurrence.
Not toil: project work, design, one-off investigation, permanent fixes.
```

---

## A4. Walk me through defining SLIs and SLOs for a checkout service from scratch.
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Start from the **user journey**, not the infrastructure. Identify what a user cares about → pick SLIs on the **golden signals** framed as good-event ratios: **availability** (fraction of non-5xx checkout requests), **latency** (fraction served under a threshold at p95/p99), and **correctness** (orders processed without error). Set SLO **targets that reflect user tolerance and cost** — not 100% (unaffordable and unnecessary). Measure at the point closest to the user (load balancer / client). Derive the error budget, then attach burn-rate alerts. Iterate targets with real data.

```yaml
# Checkout SLO spec
slis:
  availability: good = requests{path="/checkout",code!~"5.."} / total
  latency:      good = requests{path="/checkout"} served < 500ms (p95)
  correctness:  good = orders_completed / orders_submitted
slos:
  availability: 99.9%   # -> 0.1% budget, ~43 min/month
  latency:      99% of requests < 500ms
  correctness:  99.95%
measured_at: load balancer (closest to user)
alerting: multi-window burn-rate on each budget
```

---

## A5. Explain incident command roles (IC, Ops, Comms, Scribe) and why they exist.
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Structured incident response (ICS-derived) separates **coordination from investigation** so a major incident doesn't dissolve into chaos. The **Incident Commander** owns the incident and makes decisions — but does *not* debug; they delegate. **Ops/Tech Lead** does the hands-on investigation and mitigation. **Comms Lead** owns stakeholder/customer updates on a cadence so the IC isn't interrupted. **Scribe** maintains the timeline (decisions, actions, timestamps) — invaluable for the postmortem. Clear roles prevent the two classic failures: everyone debugging and no one coordinating, or everyone assuming someone else owns it.

```text
INCIDENT COMMAND ROLES
  IC       owns the incident; decides & delegates; does NOT debug
  Ops/Tech investigates & executes mitigations (hands on keyboard)
  Comms    stakeholder/customer updates on a cadence; shields IC
  Scribe   timeline: decisions, actions, timestamps -> feeds postmortem
Why: separate COORDINATION from INVESTIGATION; single decision-maker;
     no gaps, no overlap, no "I thought you had it."
```

---

## A6. Design a chaos experiment for a payment service. What's your steady state, hypothesis, and blast-radius control?
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Follow the scientific method with production safety. **Steady state** = a user-centric metric that defines "healthy" (e.g. payment success rate ≥ 99.9%, p99 < 800ms). **Hypothesis** = "if the primary payment DB replica is lost, failover holds steady state within N seconds." **Inject** the specific fault (kill the replica / add latency to the gateway / blackhole a dependency), starting with the **smallest blast radius** (one instance, 1% of traffic, off-peak) with an **abort/rollback condition** wired up (auto-halt if success rate drops below X). **Measure** against steady state; a break = a resilience gap to fix; holding = earned confidence. Graduate blast radius only as confidence grows. Always have a kill switch.

```yaml
experiment: payment-db-failover
steady_state: payment_success_rate >= 0.999 AND p99_latency < 800ms
hypothesis:  "losing the primary DB replica keeps steady state (failover < 30s)"
fault:       kill primary DB replica
blast_radius: 1 instance, off-peak, 1% traffic     # start tiny
abort_if:    payment_success_rate < 0.99           # auto-halt kill switch
measure:     steady_state during + recovery time
graduate:    widen only after a clean run; always keep the kill switch
```

---

## A7. How do you approach capacity planning and headroom for a growing service?
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Capacity planning is **demand forecasting + headroom, driven by data**. Establish the resource-per-unit-of-load ratio via **load testing** (find where latency/error SLOs break = max safe throughput). **Forecast demand** from historical growth + known events (launches, seasonal peaks, marketing). Provision to peak-plus-headroom (commonly **N+1 / N+2 redundancy** and enough buffer to absorb a spike or an AZ loss without breaching SLO — often target ~50-70% steady-state utilization so you have room). Combine autoscaling (HPA/Karpenter) for elasticity with a **static floor** for baseline and cold-start protection. Review continuously against actuals.

```text
CAPACITY PLANNING
  1. Load test -> max safe throughput before SLO breaks (req/s per replica)
  2. Forecast  -> historical growth + events (launch, seasonal, campaigns)
  3. Headroom  -> peak + buffer for spike/AZ-loss; N+1/N+2; ~50-70% target util
  4. Elastic   -> HPA/Karpenter autoscale + static min floor (cold-start guard)
  5. Review    -> actual vs forecast; adjust; watch saturation (golden signal)
```

---

## A8. What is graceful degradation and load shedding, and when do you use them?
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Both keep a system **partially useful under stress instead of collapsing entirely**. **Graceful degradation** = shed non-essential functionality to protect the core: serve stale cache if the DB is slow, hide personalized recommendations but keep checkout working, drop to a read-only mode. **Load shedding** = when overloaded, deliberately **reject a fraction of requests early** (return 429/503 fast) to protect the rest from a total meltdown — better to serve 90% well than 100% badly and crash. Prioritize by request criticality (shed low-priority traffic first). This is the opposite of the failure mode where retries + saturation cascade into full collapse.

```text
UNDER OVERLOAD — degrade, don't die
  Graceful degradation: drop non-essential features, keep the core path
    - serve stale cache, disable recommendations, read-only mode
  Load shedding: reject early to protect capacity
    - return 429/503 fast for low-priority traffic
    - prioritize by criticality; protect the core user journey
  Goal: 90% served well  >  100% served badly then total collapse
```

---

## A9. Explain retries, exponential backoff with jitter, and circuit breakers. How do they interact?
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
These are the client-side resilience patterns — and misused retries *cause* outages. **Retries** handle transient failures but naive immediate retries create a **retry storm** that hammers a struggling dependency. **Exponential backoff** spaces retries with growing delays (1s, 2s, 4s…); **jitter** randomizes them so thousands of clients don't retry in lockstep (the "thundering herd"). A **circuit breaker** wraps a dependency: after a failure threshold it **trips open** and fails fast (no calls) for a cool-down, giving the dependency room to recover, then goes **half-open** to test with a trickle before closing. Together: backoff+jitter throttle retries, the breaker stops them entirely when the dependency is down — preventing cascading failure. Always cap retries and set timeouts.

```text
RESILIENCE STACK (client side)
  timeout        bound every call; never wait forever
  retry (capped) only on transient/idempotent; max N attempts
  backoff+jitter delay = min(cap, base * 2^attempt) * random(0.5..1.5)
  circuit breaker CLOSED -(failures>threshold)-> OPEN (fail fast, cool down)
                  OPEN --(after timeout)--> HALF-OPEN (trickle test) --> CLOSED
  Why: stop retry storms + thundering herd -> prevent cascading failure.
```

---

## A10. Explain RTO and RPO and how they shape a DR strategy.
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Two independent DR targets. **RTO (Recovery Time Objective)** = the maximum acceptable **downtime** — how fast you must be back up (a *time* budget). **RPO (Recovery Point Objective)** = the maximum acceptable **data loss** — how far back the recovery point can be (a *data* budget); it's set by backup/replication frequency. Tight RTO drives *compute* strategy (warm standby, active-active); tight RPO drives *data* strategy (sync vs async replication, backup cadence). They map to a cost/strategy ladder: backup-restore (cheap, hours) → pilot light → warm standby → active-active/multi-region (expensive, near-zero). You pick the tier per service's business criticality — and **test failover regularly** or the numbers are fiction.

```text
RTO = max DOWNTIME tolerated  (time to restore) -> compute strategy
RPO = max DATA LOSS tolerated (last good point) -> replication/backup cadence

DR TIER LADDER          RTO        RPO        cost
  backup & restore      hours      hours      $
  pilot light           ~10s min   minutes    $$
  warm standby          minutes    seconds    $$$
  active-active/multi   ~0         ~0         $$$$
Rule: pick per business criticality; TEST failover or it's fiction.
```

---

## A11. 🔻 What is "shift-left" for reliability, and how do you practice it?
**My answer (from transcript):** *(Not asked — study & rehearse; flagged: you practice this but didn't know the term)*

**✅ Correct answer:**
**Shift-left** means moving reliability, security, and quality checks **earlier ("left") in the software lifecycle** — from post-deploy firefighting toward design, code, and CI — because defects are exponentially cheaper to fix the earlier they're caught. In practice it's what you already do: reliability requirements defined at design time, resource limits/probes/SLOs baked into manifests, security and policy scanning in CI (image scans, `kubeconform`/OPA gates), testing in lower environments before prod, canary/progressive delivery, and observability instrumented before launch rather than bolted on after an incident. The contrast is "shift-right" (test/validate in production via canary, chaos, feature flags) — mature teams do **both**: catch what you can early, validate the rest safely in prod. Name it explicitly next time — you live it, you just lacked the label.

```text
SHIFT-LEFT — catch it earlier where it's cheaper
  DESIGN  reliability/SLO + failure-mode review before building
  CODE    resource limits, probes, timeouts, retries in the manifest
  CI      lint/scan/policy gates: image CVE scan, kubeconform, OPA, tests
  PRE-PROD load/soak/integration tests in lower envs before prod
  vs SHIFT-RIGHT: canary, chaos, feature flags, prod monitoring
  Mature SRE = BOTH. Cost of a bug rises ~10x per stage it survives.
```

---

## A12. How do you design alerts to avoid alert fatigue? Symptom-based vs cause-based alerting.
**My answer (from transcript):** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Alert fatigue (too many noisy/non-actionable pages) is itself a reliability risk — responders start ignoring pages and miss the real one. The fix: **alert on symptoms, not causes.** **Symptom-based** alerts fire on *user-visible pain* — the **golden signals** (latency, traffic, errors, saturation) and SLO burn rate — because that's what actually matters and it catches unknown failure modes. **Cause-based** alerts (CPU 80%, disk 70%) are often noise: high CPU isn't a problem if users are fine. Every alert must be **actionable, urgent, and page-worthy**; if it isn't, make it a ticket or a dashboard, not a page. Add runbook links, dedupe/group related alerts, and tune thresholds against real burn rates. Rule: *page a human only when a human must act now.*

```text
ALERT DESIGN — kill fatigue
  ✅ symptom/SLO-based: burn rate, error ratio, p99 latency, saturation
  ❌ cause-based noise:  raw CPU%, disk%, single pod restart (unless user impact)
  Every PAGE must be: actionable + urgent + needs a human NOW
    else -> ticket or dashboard, not a page
  Also: attach runbook, group/dedupe, tune to burn rate, review noisy alerts.
  Golden signals: Latency · Traffic · Errors · Saturation.
```

---

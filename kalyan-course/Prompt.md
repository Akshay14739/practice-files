# Claude Code Prompt — EKS/Karpenter Course → Study Companion

> Copy everything below the line into Claude Code.

---

## Task

Act as an expert AWS/Kubernetes instructor. Build a complete study companion from my course transcripts, good enough that I learn the entire course from your `.md` files alone, then execute every lab myself with no gaps. Try to keep everything presise and on to the point. Avoid fluff, filler, and repetition. Use tables, diagrams, and code blocks liberally. Make it easy to skim for the key points. your response md files should have all the information needed to understand the concepts, reproduce the labs, and articulate the knowledge from this entire course without missing anything. If any files or folders are missing, create them accordingly & do the necessary steps to ensure the course notes are complete and self-contained.

## Inputs

- `./Transcripts/` — section-wise video transcripts
- `./curriculum.txt` — course index (section → lecture titles). Read this from disk. Do not fetch the Udemy URL — you can't reach it.

## Outputs → `./course-notes/`

- `00-INDEX.md` — every section linked, one-line summary each
- `NN-section-slug.md` — one file per section
- `GLOSSARY.md` — ASR-error map + AWS↔K8s term map
- `PROGRESS.md` — checklist, the resume point for a fresh session

## The transcripts are auto-generated speech-to-text

They contain systematic errors. Normalize silently — never reproduce the garbled form. Seed glossary, extend it as you find more:

| Transcript says | Means |
|---|---|
| cube CTL / cube control | `kubectl` |
| cube system | `kube-system` |
| Alb, amb | ALB |
| ECS cluster *(in K8s context)* | EKS cluster |
| ozone layer four/seven | OSI layer 4/7 |
| SIP service | ClusterIP service |
| Im role, II role | IAM role |
| x pod identity association | EKS Pod Identity Association |
| Pia | Pod Identity Agent |
| carpenter | Karpenter |

If a term is phonetically mangled and you can't resolve it confidently from context, flag it as a GAP — don't guess.

## Workflow — one section at a time, no exceptions

Each transcript is ~2-3 hours of speech. Doing them in bulk silently degrades quality partway through. So:

1. **Survey first.** List transcript files, read `curriculum.txt`, produce `00-INDEX.md` and `PROGRESS.md` (unchecked checklist, one line per section). Report back: section count vs. transcript count, any oversized/corrupted files, your plan. **Wait for my go-ahead before writing Section 1.**
2. **Then, per section:** read the full transcript → write the section `.md` → tick it off in `PROGRESS.md` → next section.
3. **Re-read `PROGRESS.md` before each section** so a fresh session can resume cleanly.
4. **If you feel context pressure, stop** and tell me which sections are done. A clean handoff beats a degraded section.

## Per-section file format (fixed structure, don't reorder or skip)

1. **Objective** — what this lets me *do* that I couldn't before.
2. **Problem Statement** — what's broken/limited without it; what's introduced to fix it.
3. **Why This Approach** — why this over the alternatives. Comparison table wherever the instructor names more than one option.
4. **How It Works — Under the Hood** — the actual machinery, not "what to type." Vocabulary map (AWS↔K8s↔plain English). Mermaid architecture diagram (required). ASCII flow diagram for any request path/provisioning sequence/control loop.
5. **Instructor's Approach** — his sequence, and explicitly *why he ordered it that way* whenever he says so out loud — this is the highest-value content in the transcript.
6. **Code & Commands, Line by Line** — what/why/when for every command; every YAML field inline-commented.
7. **Complete Code Reference** — everything from this section, consolidated, copy-pasteable, in execution order.
8. **Hands-On Labs:**
   - **Lab A — Reproduce** the instructor's exercise.
   - **Lab B — Variation** — same concept, different angle.
   - **Lab C — Break it and fix it** — misconfigure deliberately, observe the exact failure, diagnose, fix. This is where understanding actually forms.
   - Each lab: `Prerequisites → Steps → Expected output → Verify → 🧹 Teardown`.
   - 💰 **Cost warning + mandatory teardown** on any lab touching real AWS resources (EKS, ALB/NLB, EC2, NAT GW, EBS).
   - Give a free **kind/k3d local variant** wherever the concept doesn't actually need AWS.
9. **Troubleshooting** — table: `Symptom → Likely cause → Command to confirm → Fix`. Use exact error text.
10. **Interview Articulation** — a 90-second spoken explanation, plus 5 self-test questions with answers in a collapsed `<details>` block.

## Quality bar

- **Synthesize, never transcribe.** Original explanation in your own words — not paraphrased-but-still-copied.
- **Never invent.** Unclear/incomplete transcript → `> ⚠️ GAP: unclear on X — verify against <docs link>`. A flagged gap beats a confident guess.
- **Flag his errors.** Typo, deprecated flag, wrong fact → `> 🐛 TRANSCRIPT ERROR: he says X, correct is Y`.
- **Flag staleness.** Where current practice has moved on → `> 🔄 CURRENT PRACTICE: ...`.
- **Cover everything, preserve his order.** Nothing dropped as "obvious."

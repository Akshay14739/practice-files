# ✅ PROGRESS — resume point for a fresh session

> Workflow (per Prompt.md): read the FULL transcript → write the section `.md` (fixed 10-part structure) → tick it here → next. Re-read this file before each section.
> Output folder: `README files/` (user override of Prompt.md's `course-notes/`). Transcript→section mapping is in [00-INDEX.md](00-INDEX.md).

## Scaffolding
- [x] Survey: curriculum vs transcripts reconciled (21 sections ↔ 22 transcript files, no gaps; "12)" is a naming skip, not missing content)
- [x] 00-INDEX.md
- [x] PROGRESS.md
- [x] GLOSSARY.md (seeded — extend while writing sections)

## Sections
- [x] 01 Project Overview — transcript `0)` (~9 min)
- [x] 02 Docker Commands — `1)` (~72 min)
- [x] 03 Dockerfile Mastery — `2)` (~44 min)
- [x] 04 Docker Compose — `3)` (~74 min)
- [x] 05 Docker BuildKit/Buildx — `4)` (~45 min)
- [x] 06 Terraform Basics — `5)` + `6)` (~322 min ⚠️ two transcripts, biggest section)
- [x] 07 Terraform EKS Cluster — `7)` (~124 min)
- [x] 08 Kubernetes Foundation — `8)` part 1 (~216 min total in file; foundation portion)
- [x] 09 Kubernetes Secrets — `8)` tail + `9)` + `10)` (~150 min combined)
  - note: transcript `10)` ALSO contains Section 10's 1001 EBS-CSI-install content (its tail) — S10 uses `10)` tail + `11)`
- [x] 10 Kubernetes Persistent Storage — `10)` tail + `11)` (~51 min)
- [x] 11 Kubernetes Ingress — `13)` (~102 min)
- [x] 12 Helm Package Manager — `14)` (~150 min; 1205 full-app-helm content lives in `15)`, cross-covered in S19)
- [x] 13 Terraform EKS with Add-Ons — `15)` part 1 (~306 min total in file)
- [x] 14 Retail Store — AWS Data Plane — `15)` part 2
  - ✅ RECONCILED 2026-07-19 against canonical repo (full clone): `14_02` k8s manifests + `c6_06`/`c9_05` PIA associations ALL exist in the repo (earlier partial clone hadn't checked them out); reconstructions verified to match — flags upgraded to ✅ VERIFIED
- [x] 15 Terraform EKS with ExternalDNS — `16)` part 1 (~66 min total)
- [x] 16 Retail Store with ExternalDNS — `16)` part 2
  - ✅ RECONCILED 2026-07-19: folders `15_…` through `21_…` ALL exist in the canonical repo (the earlier clone's working tree had been wiped to only `01–14` — restored via `git config core.longpaths true` + `git restore`). S15 `c17-*`, S16 http+https ingress, S17 Karpenter `c6_01–08`+CRDs, S18 metrics-server/HPA, S19 `c18` fold-in, S20 ADOT env, S21 CI workflow — all spot-checked to match the reconstructions. Every S14–S21 flag upgraded to ✅ VERIFIED.
- [x] 17 Autoscaling — Karpenter — `17)` (~229 min; transcript is ~5985 lines, read fully in 3 pages)
- [x] 18 Autoscaling — HPA — `18)` (~134 min; transcript's 2nd half duplicates the deploy lecture — processed once)
- [x] 19 Helm Retail Store + AWS Data Plane — `19)` (~102 min; also covers the 1205 gap from S12 in final form)
- [x] 20 Observability — OpenTelemetry — `20)` (~270 min; ⚠ AMG $9/user watch-only warning preserved)
- [x] 21 CI/CD GitOps — `21)` (~122 min)

## ✅ ALL 21 SECTIONS COMPLETE — full course processed (22 transcripts, all read in full)

## Notes for the next session
- Repo folders map ≈ 1:1 to sections (`02_Docker_Commands` … `14_RetailStore_Microservices_with_AWS_Data_Plane`) — pull exact code from there when the transcript's dictated code is garbled.
- Transcript `8)` bleeds into Section 09 (its tail previews Secrets Manager); split at the K8s-Secrets-basics boundary.
- Large files (`15`, `17`, `20`, `5`) may need paged reads (Read tool ~25k-token cap per call).

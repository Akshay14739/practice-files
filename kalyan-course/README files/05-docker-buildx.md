# Section 05 — Docker BuildKit / Buildx (Multi-Platform Images)

> Transcript: `4) Docker Buildx` · ~45 min · Repo: [`../devops-real-world-project-implementation-on-aws/05_Docker_Buildx/`](../devops-real-world-project-implementation-on-aws/05_Docker_Buildx/)

## 0. 🧭 Beginner Follow-Along Guide (start here)

> Read this guide first; dive into the numbered sections after. Tags: **[Terminal]** = a shell (each step says WHICH machine: the amd64 build VM, the arm64 test VM, or your laptop) · **[AWS Console]** = console.aws.amazon.com · **[Browser]** = Docker Hub / the app.
> ⏳ **Plan your session:** the first multi-arch build takes **37–50 minutes** (emulation is slow — that's the lesson, not a bug). Start it, take a break, come back.

### 📊 The whole section at a glance — components & workflow

*Read top to bottom; boxes are components, arrows are the flow (the same shape as your terminal→shell→fork diagram).*

```
┌──────────────────────────────────────────────────────────────────────┐
│            SOURCE + Dockerfile  (on the amd64 build box)             │
│                                                                      │
│ docker buildx build --platform linux/amd64,linux/arm64 --push        │
└──────────────────────────────────────────────────────────────────────┘
                          │                  │
                          ▼                  ▼
                   ┌─────────────┐   ┌──────────────┐
                   │ amd64 stage │   │ arm64 stage  │
                   │ native      │   │ QEMU emul.   │
                   │ (fast)      │   │ (5-10x slow) │
                   └─────────────┘   └──────────────┘
                                    │  --push  (both variants)
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                DOCKER HUB — ONE tag = a MANIFEST LIST                │
│                                                                      │
│ 1.0.0 → { linux/amd64 image , linux/arm64 image }                    │
└──────────────────────────────────────────────────────────────────────┘
                        │                      │
                        ▼                      ▼
              ┌──────────────────┐   ┌──────────────────┐
              │ amd64 host pulls │   │ arm64 host pulls │
              │ → gets amd64     │   │ → gets arm64     │
              └──────────────────┘   └──────────────────┘

  pull auto-selects the variant matching the host's CPU (uname -m)
```

### Where you are in the course

```
S03/S04 built & composed images ─▶ THIS: S05 ONE tag that runs on amd64 AND arm64 ─▶ S06 Terraform
Why bother: Graviton (arm64) nodes are cheaper — Karpenter (S17) will want to use them.
```

**Must already exist/be running:**
```
[ ] The S02 amd64 EC2 box (or your laptop with Docker Desktop — binfmt comes preinstalled there)
[ ] Docker Hub account, logged in (docker login)
```

### Words you'll meet (plain English)

| Word | Plain meaning |
|---|---|
| amd64 vs arm64 | two CPU "languages"; a binary built for one won't run on the other |
| buildx | Docker's builder plugin that can target several CPU types in one command |
| QEMU / binfmt | an emulator letting your amd64 box pretend to be arm64 during the build (5–10× slower) |
| builder | the isolated build engine buildx creates (`docker buildx create`) |
| manifest list | one tag that secretly holds BOTH variants; `docker pull` picks the right one automatically |
| Graviton / t4g | AWS's cheaper arm64 EC2 family |
| `uname -m` | asks a machine its CPU type: `x86_64` = amd64, `aarch64` = arm64 |

### The simplified play-by-play (do this → see that)

1. **[Terminal: build VM]** Confirm where you are: `uname -m` → `x86_64`, and `docker buildx version` answers.
   → **you should see:** you're on amd64 with buildx available.
2. **[Terminal: build VM]** Install the emulator: `docker run --privileged --rm tonistiigi/binfmt --install all` — ⚠️ re-run this after ANY reboot of the box (registration doesn't survive restarts).
   → **you should see:** a list of installed platforms including arm64.
3. **[Terminal: build VM]** Create + start the builder: `docker buildx create --name multiarch --driver docker-container --use` then `docker buildx inspect --bootstrap`.
   → **you should see:** `docker buildx ls` shows `multiarch*` (the ★/`*` = active) with arm64 in its platforms. `(deep dive: §6 setup)`
4. **[Terminal: build VM]** Set your names once: `export DH_USER=<your-dockerhub-username>; export DH_REPO=retail-ui-multiarch; export TAG=1.0.0; export IMAGE=$DH_USER/$DH_REPO:$TAG` and `docker login`. Then fetch source v1.3.0 and `cd …/src/ui` (§6 "Name, login, source").
   → **you should see:** `echo $IMAGE` prints `you/retail-ui-multiarch:1.0.0`.
5. **[Terminal: build VM]** THE build (start it, then go do something else): `docker buildx build --platform linux/amd64,linux/arm64 -t $IMAGE --push .`
   → **you should see:** both platform stages progressing; 37–50 min first time. `--push` is REQUIRED — a multi-arch result can't live in the local store. `(deep dive: §6 the build)`
6. **[Terminal: build VM]** Verify the manifest: `docker buildx imagetools inspect $IMAGE` — and **[Browser]** Docker Hub → your repo → Tags.
   → **you should see:** ONE tag listing BOTH `linux/amd64` and `linux/arm64`.
7. **[AWS Console]** Launch the proof machine: EC2 → Amazon Linux 2023 **64-bit ARM**, **t4g.large**, 30 GB → then **[Terminal: arm64 VM]** SSH in, `uname -m` → `aarch64`, install docker (§6).
8. **[Terminal: arm64 VM]** See the PROBLEM first: `docker run -p 8899:8080 -d stacksimplify/retail-store-sample-ui:1.0.0`
   → **you should see:** `image's platform (linux/amd64) does not match … (linux/arm64/v8)` — the exact pain this section kills.
9. **[Terminal: arm64 VM]** Now the FIX: `docker pull $IMAGE && docker run --name myapp1-arm64 -p 8889:8080 -d $IMAGE`
   → **you should see:** it just runs — same tag, arm64 variant auto-selected. Browser :8889 shows the store.
10. **[Terminal: build VM]** Optional cache payoff (Lab B): make the V2 edit and rebuild as TAG=2.0.0 → ~6 min instead of ~40 (only the jar compile re-runs).
    → **you should see:** `CACHED` on all the dnf layers in the log.

### ✅ Done-check

```
[ ] imagetools inspect shows one tag, two platforms
[ ] the amd64-only image FAILED on the arm64 VM (you saw the mismatch error)
[ ] your multi-arch tag RAN on both VMs, same tag
[ ] you know the reboot trap: binfmt must be reinstalled after restarts
```

🧹 **Teardown before you stop:** **TERMINATE the t4g arm64 VM immediately after the test** (💰 ~$0.067/hr); `docker rm -f` test containers on both machines. The amd64 VM can be stopped/terminated now too — S06 onward is Terraform from your laptop.

---

## 1. Objective

Build **one image tag that runs on both amd64 and arm64** using `docker buildx` + QEMU emulation, push it to Docker Hub as a multi-platform manifest, and prove it: an arm64 EC2 (Graviton) pulls the same tag and automatically gets the arm64 variant.

## 2. Problem Statement

A plain `docker build` on an amd64 EC2 produces an **amd64-only** image. Pull that tag on an arm64 (Graviton) machine and it fails:
```
The requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64/v8)
```
Graviton instances are cheaper — you'll want arm64 nodes later (Karpenter, S17). Your images must run on both.

## 3. Why This Approach

| Option | How | Trade-off |
|---|---|---|
| **buildx + QEMU/binfmt emulation** (this demo) | one machine emulates the other arch during build | simplest setup; **5–10× slower** for the emulated arch (first build 37–50 min!) |
| Native builders per arch (SSH'd together) | buildx farm: arm64 build runs on a real arm64 box | fast native speed; complex setup — the instructor names it as the real-world option |
| Separate images per arch, manual tags | `myimg:1.0.0-amd64`, `-arm64` | pushes complexity to every consumer; defeats the point |

The win: **one build command, one tag** → the registry stores a *manifest list*; `docker pull` auto-selects the right variant per host.

## 4. How It Works — Under the Hood

```mermaid
flowchart LR
    subgraph BUILDVM["amd64 build VM"]
        BX[docker buildx<br/>multiarch builder<br/>driver: docker-container]
        Q[QEMU/binfmt<br/>arm64 emulation]
        BX --> A64["build linux/amd64<br/>(native, fast)"]
        BX --> Q --> R64["build linux/arm64<br/>(emulated, 5-10x slower)"]
    end
    A64 & R64 -- --push --> HUB[(Docker Hub<br/>ONE tag: 1.0.0<br/>manifest list)]
    HUB -- docker pull --> X[amd64 host → gets amd64 layer set]
    HUB -- docker pull --> Y[arm64 host → gets arm64 layer set]
```

```
pull-time selection:
  docker pull stacksimplify/retail-ui-multiarch:1.0.0
     └▶ registry returns the MANIFEST LIST for the tag
         └▶ client matches its own platform (uname -m) → downloads only that variant
```

### Vocabulary map

| Term | Plain English |
|---|---|
| **BuildKit** | Docker's modern build engine (`DOCKER_BUILDKIT=1`) |
| **buildx** | CLI plugin driving BuildKit: builders, multi-platform, cache |
| **builder** (`docker buildx ls`) | a build backend; `docker-container` driver = isolated BuildKit container |
| **QEMU / binfmt** | kernel-level CPU emulation letting amd64 execute arm64 binaries during build |
| **manifest list** | one tag → a list of per-platform images; pull picks by host arch |
| `uname -m` | your arch: `x86_64` = amd64, `aarch64` = arm64 |
| Graviton (T4g) | AWS's arm64 EC2 family — cheaper per unit compute |

## 5. Instructor's Approach

1. **Problem first, live**: he *ends* the demo by pulling the amd64-only image (`retail-store-sample-ui:1.0.0`) on the arm64 VM to show the exact platform-mismatch error — the pain is demonstrated, not just described.
2. Notes the honest caveat: **QEMU is a teaching shortcut**; production farms use native per-arch builders over SSH.
3. **Warns about timing up front:** first multi-arch build ≈ 37–50 min (emulated arm64 Java build); then proves the cache pays off — the v2.0.0 rebuild takes **~6 min** because only the jar compile re-runs; every `dnf install` layer comes from cache.
4. Housekeeping notes he calls out: re-run the binfmt install **after any host reboot**; `buildx ls` sometimes doesn't *list* arm64 on Amazon Linux but builds still work (cosmetic); this demo baselines app source **1.3.0** (not 1.2.4 as in S02).
5. Verifies at *three* levels: Docker Hub tags UI (two platforms under one tag) → `imagetools inspect` (manifest JSON) → actually running containers on both arches.

## 6. Code & Commands, Line by Line

### Setup on the amd64 build VM

```bash
uname -m                                   # x86_64 → we're on amd64
export DOCKER_BUILDKIT=1                   # ensure BuildKit path
docker buildx version                      # plugin present?

# install QEMU/binfmt emulators (ALL supported platforms):
docker run --privileged --rm tonistiigi/binfmt --install all
# --privileged: needs to register binfmt handlers with the kernel
# NOTE: re-run this after a host reboot — emulation registration doesn't persist

docker buildx ls                           # 'default' builder + its platforms
docker buildx create --name multiarch --driver docker-container --use
#                     └ named builder      └ isolated BuildKit container   └ make it active (★)
docker buildx inspect --bootstrap          # start (bootstrap) the builder container
docker buildx ls                           # multiarch ★ = active, platforms incl. arm64
```

### Name, login, source

```bash
export DH_USER=<your-dockerhub-username>
export DH_REPO=retail-ui-multiarch
export TAG=1.0.0
export IMAGE=$DH_USER/$DH_REPO:$TAG        # user/repo:tag — echo $IMAGE to sanity-check
docker login

mkdir demo-multiarch && cd demo-multiarch
wget https://github.com/aws-containers/retail-store-sample-app/archive/refs/tags/v1.3.0.zip
unzip v1.3.0.zip && cd retail-store-sample-app-1.3.0/src/ui       # Dockerfile here (same one from S03)
```

### The multi-platform build

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \    # BOTH architectures in one command
  -t $IMAGE \
  --push \                                 # push straight to the registry (required: a
  .                                        #   multi-arch manifest can't sit in the local store)
# ⏳ FIRST run: 37–50 min (arm64 stage runs under QEMU). Subsequent builds: cached.
```

### Verify the manifest

```bash
docker buildx imagetools inspect $IMAGE
# → manifest list: linux/amd64 + linux/arm64 under the one tag
# Docker Hub UI → repo → Tags → 1.0.0 shows both platforms
```

### Prove it on both architectures

```bash
# on the amd64 build VM:
docker pull $IMAGE && docker run --name myapp1-amd64 -p 8888:8080 -d $IMAGE
# browser :8888 → app up (amd64 variant auto-selected)

# create the arm64 VM: Amazon Linux 2023 (64-bit ARM), t4g.large, 30 GB, SG all-TCP
ssh -i key.pem ec2-user@<arm64-dns>
uname -m                                   # aarch64
sudo dnf install docker -y && sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user           # re-login

# ① the PROBLEM: amd64-only image on arm64
docker pull stacksimplify/retail-store-sample-ui:1.0.0
docker run --name myapp1-amd64-test -p 8899:8080 -d stacksimplify/retail-store-sample-ui:1.0.0
# → "requested image's platform (linux/amd64) does not match … (linux/arm64/v8)"

# ② the SOLUTION: multi-arch tag on arm64
docker pull $IMAGE                          # auto-selects the arm64 variant
docker run --name myapp1-arm64 -p 8889:8080 -d $IMAGE
docker ps && docker logs -f myapp1-arm64    # runs clean; browser :8889 works
```

### v2.0.0 rebuild — the cache payoff (optional lecture)

```bash
cd ~/demo-multiarch && cp -r retail-store-sample-app-1.3.0 v2 && cd v2/src/ui
sed -i 's/The Most Public Secret Shop/The Most Public Secret Shop - V2 version/' \
    src/main/resources/templates/home.html
export TAG=2.0.0 && export IMAGE=$DH_USER/$DH_REPO:$TAG
docker buildx build --platform linux/amd64,linux/arm64 -t $IMAGE --push .
# ≈6 min total: dnf layers CACHED; only the jar compiles (arm64 jar ≈ 344 s under QEMU)
docker run --name myapp1-v2-amd64 -p 8890:8080 -d $IMAGE   # browser :8890 shows V2
```

## 7. Complete Code Reference

```bash
export DOCKER_BUILDKIT=1
docker run --privileged --rm tonistiigi/binfmt --install all
docker buildx create --name multiarch --driver docker-container --use
docker buildx inspect --bootstrap
export DH_USER=<you>; export DH_REPO=retail-ui-multiarch; export TAG=1.0.0
export IMAGE=$DH_USER/$DH_REPO:$TAG
docker login
docker buildx build --platform linux/amd64,linux/arm64 -t $IMAGE --push .
docker buildx imagetools inspect $IMAGE
# per-arch smoke tests:
docker run --name t -p 8888:8080 -d $IMAGE     # on each arch VM
```

## 8. Hands-On Labs

> 💰 **Cost warning:** t4g.large (arm64) ≈ $0.067/hr — **terminate the arm64 VM right after the test** (the instructor does). amd64 VM continues to S06.
> 🆓 Local variant: Docker Desktop ships with binfmt preinstalled — `docker buildx build --platform …` works out of the box; verify with `imagetools inspect`. Skip the arm64 VM (or test on an M-series Mac, which *is* arm64).

### Lab A — Reproduce: multi-arch build + dual verification
- **Prerequisites:** S02 build VM, Docker Hub login.
- **Steps:** §6 in order (budget 40–50 min for the first build).
- **Expected output:** one tag, two platforms in `imagetools inspect`; app serves on both VMs.
- **Verify:** on arm64, `docker image inspect $IMAGE --format '{{.Architecture}}'` → `arm64`.
- 🧹 **Teardown:** terminate the arm64 VM; `docker rm -f` containers; optionally delete the Hub repo.

### Lab B — Variation: measure the cache
- **Steps:** run the v2.0.0 rebuild; record total time and which layers say `CACHED` in the log.
- **Expected:** ~6 min vs ~40; only `mvnw package` layers rebuild.
- **Verify:** Hub tag 2.0.0 exists with both platforms.
- 🧹 as Lab A.

### Lab C — Break it and fix it
1. **Skip binfmt:** on a fresh VM, run the multi-platform build *without* installing the emulator → arm64 stage fails (`exec format error`). **Confirm:** error text names the arch. **Fix:** `docker run --privileged --rm tonistiigi/binfmt --install all`, retry.
2. **The reboot trap:** reboot the build VM → cross-arch builds fail again. **Fix:** re-run the binfmt install (the instructor's explicit note).
3. **`--push` omitted:** build both platforms with `--load` instead → error (local store can't hold a manifest list) or single-platform only. **Lesson:** multi-arch results must go to a registry; `--load` is single-platform.
- 🧹 as Lab A.

## 9. Troubleshooting

| Symptom | Likely cause | Command to confirm | Fix |
|---|---|---|---|
| `image's platform … does not match host platform` | single-arch image on the other arch | `docker buildx imagetools inspect <tag>` — one platform only | rebuild with `--platform linux/amd64,linux/arm64 --push` |
| `exec format error` during arm64 build stage | QEMU/binfmt not installed (or lost after reboot) | `docker buildx ls` platform list | re-run the `tonistiigi/binfmt --install all` container |
| First build absurdly slow | expected: QEMU emulation is 5–10× slower | timing in build log | be patient once; cache handles the rest — or use native arm64 builders |
| `buildx ls` doesn't show arm64 on AL2023 | cosmetic listing quirk (instructor's note) | run an actual build | ignore if builds succeed |
| Multi-arch build fails with local output | `--load` can't store manifest lists | error text | use `--push` (registry) for multi-arch |
| Builder "inactive" | not bootstrapped | `docker buildx ls` | `docker buildx inspect --bootstrap` |

## 10. Interview Articulation

**90-second explanation:**
> "A normal docker build produces an image only for the CPU architecture of the build host — pull an amd64 image on a Graviton box and Docker refuses with a platform-mismatch error. We solve it with buildx: create a docker-container builder, register QEMU binfmt emulators, and run one `buildx build --platform linux/amd64,linux/arm64 --push`. That produces a manifest list — one tag pointing at per-architecture images — so every client's pull automatically resolves to its own platform. The trade-off is that the emulated architecture builds five-to-ten-times slower — our first build took about forty minutes — but BuildKit's layer cache means a code-only change rebuilds in about six, since only the compile layer re-runs. In production you'd replace emulation with native builders per architecture. This matters commercially because arm64 Graviton instances are cheaper — multi-arch images are the prerequisite for letting Karpenter schedule onto them."

<details>
<summary>5 self-test questions</summary>

1. **What exactly does the registry store for a multi-arch tag?** — a manifest list: one tag referencing separate per-platform image manifests; the client picks by host arch at pull time.
2. **Why `--push` instead of `--load`?** — the local image store can't hold a multi-platform manifest list; results must go to a registry.
3. **What breaks after the build VM reboots, and the fix?** — binfmt/QEMU registration is lost; re-run `docker run --privileged --rm tonistiigi/binfmt --install all`.
4. **Why was the second (v2) build ~6 min instead of ~40?** — BuildKit layer cache: all `dnf install`/dependency layers hit cache; only the jar compile re-ran (arm64's under QEMU being the slow part).
5. **What's the production alternative to QEMU emulation?** — a buildx builder farm with native nodes per architecture (e.g., a real arm64 machine attached over SSH), so each platform builds at native speed.

</details>

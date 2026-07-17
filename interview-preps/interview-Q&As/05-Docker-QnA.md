# Docker & Containers — Interview Q&A (from real interviews)

Curated from Akshay's actual Docker interview rounds, deduped and ordered by sub-theme (image/layers → Dockerfile & optimization → commands → networking → volumes → security & golden images → runtime/CRI). Weakest answers are surfaced first in each section, with authoritative corrections and a runnable snippet for every question.

---

## Q1. Are Docker images mutable or immutable? If an image is immutable, how can you modify a file inside a *running* container — what mechanism makes that happen?
**Asked in:** Trianz-K8s  |  **My performance:** Partial (core miss)

**My answer (from transcript):**
Said Docker images are immutable — once built, immutable. When asked how you can then modify a file inside a container, struggled: thought you can't edit at the image level and would need a new image version. Eventually agreed a file inside a running container *can* be modified but could NOT explain the mechanism (copy-on-write / writable container layer). Admitted "I can come up with answers but they might be incorrect."

**✅ Correct answer:**
Both statements are true at the same time, and the reconciling idea is **layers + copy-on-write (CoW)**.

- A Docker **image is immutable**. It is a stack of **read-only layers**, each layer being the filesystem diff produced by one Dockerfile instruction (`FROM`, `COPY`, `RUN`, …). Once built, those layers never change — that is what gives you reproducibility and content-addressable digests (`sha256:…`).
- When you `docker run`, the daemon adds a **thin writable layer on top** of the read-only image layers. This is the **container layer**. All layers are unioned together by a storage driver (default **overlay2**) into a single filesystem the process sees.
- **Copy-on-write:** reads come straight from the underlying read-only layers. The first time a process *writes* to (or modifies) a file, overlay2 **copies that file up** from the read-only layer into the writable container layer, and the change is applied to the copy. The original image layer is untouched — that's why the image stays immutable while the container's view of the file changes.
- Consequences to state in an interview: (1) the change lives only in that container's writable layer and is **lost when the container is removed**; (2) two containers from the same image **share** the read-only layers (disk-efficient) but each has its own writable layer; (3) heavy write workloads should use **volumes** to bypass CoW overhead and persist data.

```bash
# Prove image layers are shared and immutable, and the writable layer is per-container
docker run -d --name c1 nginx
docker exec c1 sh -c 'echo "changed" > /usr/share/nginx/html/index.html'   # copy-on-write: file copied into c1's writable layer

docker run -d --name c2 nginx
docker exec c2 cat /usr/share/nginx/html/index.html   # original content — c2 unaffected, image layer intact

docker diff c1        # shows: C /usr/share/nginx/html/index.html  (C=changed, only in c1's writable layer)
docker rm -f c1 c2    # writable layers destroyed; the nginx image is unchanged
```

---

## Q2. Do you know what a dangling image is in Docker?
**Asked in:** Trianz-K8s  |  **My performance:** Didn't-know

**My answer (from transcript):**
"I've heard of it but I forgot — heard of it a couple of months ago but forgot, sorry." (Did not answer.)

**✅ Correct answer:**
A **dangling image** is an image layer that has **no repository name and no tag** — it shows up as `<none>:<none>`. It happens when you build (or pull) a new version of an image with a tag that already existed: the tag moves to the new image, and the **old image is left untagged** but still on disk (still referenced by its digest, still consuming space).

- Distinguish from **unused images**: a dangling image has no tag *at all*; an unused (or "unreferenced") image may be fully tagged but is not used by any container. `docker image prune` removes dangling only; `docker image prune -a` removes all images not used by a container.
- They accumulate on CI build agents and are a classic cause of "disk full" on build nodes.
- Filter them with `--filter dangling=true`.

```bash
docker images --filter "dangling=true"        # list only <none>:<none> images
docker image prune -f                          # remove dangling images
docker image prune -a -f --filter "until=168h" # also remove any image unused for > 7 days
docker system df                               # see reclaimable space across images/containers/volumes
```

---

## Q3. How can you optimize the startup time of a Docker container hosting a web application?
**Asked in:** HTC  |  **My performance:** Didn't-know

**My answer (from transcript):**
"I'm not sure about that. I don't know."

**✅ Correct answer:**
Startup time = **image pull + container create + process init to "ready"**. Attack each:

1. **Shrink the image** — fewer/smaller layers pull and unpack faster (multi-stage, small/distroless base, `.dockerignore`). Smaller image = faster cold starts, especially on autoscaled nodes.
2. **Pre-pull / warm the cache** — pull images onto nodes ahead of time (K8s `imagePullPolicy: IfNotPresent`, node image pre-pulling, or a pull-through registry mirror close to the cluster) so pull isn't on the hot path.
3. **Cut app init work** — for JVM/.NET/Node, use ahead-of-time compilation / native images (GraalVM, .NET AOT), lazy-load non-critical deps, and avoid running migrations or heavy warmup on every boot.
4. **Right entrypoint** — use `exec` form so the app is PID 1 (no shell wrapper delay, clean signal handling), and keep the entrypoint script minimal.
5. **Readiness signaling** — define a fast, cheap `HEALTHCHECK`/readiness probe so the orchestrator routes traffic the instant the app is actually ready (not a fixed sleep).
6. **Layer ordering for cache** — put rarely-changing layers (deps) before frequently-changing layers (app code) so rebuilds and pulls reuse cached layers.

```dockerfile
# Fast-start image: tiny final layer, exec-form entrypoint, health-gated readiness
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev            # deps layer cached separately from source
COPY . .

FROM gcr.io/distroless/nodejs20  # tiny base → fast pull + unpack
WORKDIR /app
COPY --from=build /app /app
HEALTHCHECK --interval=5s --timeout=2s --start-period=3s CMD ["/nodejs/bin/node","-e","require('http').get('http://localhost:3000/health',r=>process.exit(r.statusCode==200?0:1)).on('error',()=>process.exit(1))"]
CMD ["server.js"]                # exec form → app is PID 1, no shell delay
```

---

## Q4. Beyond multi-stage builds, what base image would you choose, and what about the number of layers? / You have a Docker image that's several GB — what steps to optimize it?
**Asked in:** Pure-SW, Barclays  |  **My performance:** Partial

**My answer (from transcript):**
For the base-image part: the org used a secure company-baked base image ("image bakery") with security parameters/certificates. Did **not** address the layers/trade-off part. On the GBs question: gave multi-stage only, then got stuck and asked for a clue; interviewer supplied `.dockerignore`, combining/reducing `RUN` commands, and using a smaller base image.

**✅ Correct answer:**
Multi-stage is just one lever. The full toolkit for shrinking an image:

1. **Smaller base image** — `alpine` (~5 MB), `debian:slim`, or **distroless** (no shell, no package manager) instead of a full `ubuntu`/`node`. For static binaries, `FROM scratch`.
2. **Reduce layer count / layer size** — each `RUN`, `COPY`, `ADD` creates a layer. **Chain related `RUN` commands with `&&`** and clean up *in the same layer* (deleting files in a later layer doesn't shrink earlier layers — the bytes are still in the image).
3. **`.dockerignore`** — stop sending `.git`, `node_modules`, build artifacts, and secrets into the build context; smaller context = faster builds and no accidental bloat/leaks.
4. **Clean package manager caches in-layer** — `apt-get clean && rm -rf /var/lib/apt/lists/*`, `--no-cache` for apk, `--no-install-recommends`.
5. **Multi-stage** — compile/build in a fat stage, copy only the final artifact into a lean runtime stage.
6. **Only production deps** — `npm ci --omit=dev`, `pip install --no-cache-dir`, no build toolchains in the runtime image.

Layer trade-off nuance the interviewer wanted: **fewer layers = smaller/cleaner image, but too much chaining hurts build-cache reuse**. Group by change frequency — stable dependencies in early cached layers, volatile app code last.

```dockerfile
# Bad: many layers, caches left behind, big base  →  Good below
FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*          # cleanup in the SAME layer, else it doesn't shrink

# .dockerignore (sits next to the Dockerfile)
# .git
# node_modules
# **/*.log
# .env
```

---

## Q5. How do you optimize / reduce the size and dependencies of a Docker image? (multi-stage + distroless)
**Asked in:** Trianz, Pure-SW, GlobalLogic, Trianz-K8s  |  **My performance:** Correct

**My answer (from transcript):**
Use multi-stage builds — multiple `FROM` stages so only the required artifacts pass to the final stage and the rest are discarded; the built image only keeps the last stage, reducing size. Also use distroless or Alpine base images for a smaller footprint. Mentioned Docker Buildx for multi-platform builds copying from the final stage.

**✅ Correct answer:**
Solid answer — reinforce *why* it works and add the mechanics:

- **Multi-stage** = several `FROM` blocks. Earlier ("builder") stages contain compilers, SDKs, and dev deps. The final stage starts from a minimal base and uses `COPY --from=<stage>` to pull **only the compiled artifact**. The intermediate stages are **not** part of the final image, so the toolchain never ships.
- **Distroless** images (`gcr.io/distroless/*`) contain only your app + runtime libs — **no shell, no package manager, no busybox** — which both shrinks size and drastically reduces attack surface (fewer CVEs, nothing to exploit for shell escape).
- **Alpine** is tiny too but uses **musl libc** (not glibc) — watch for compatibility issues with glibc-linked binaries (DNS, some Python wheels).
- Buildx is orthogonal to size but great for **multi-arch** — build the same lean image for `amd64` + `arm64` from one command.

```dockerfile
# Go app: fat builder stage + scratch/distroless final stage
FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download                       # cached dep layer
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app ./cmd/server

FROM gcr.io/distroless/static:nonroot     # no shell, no pkg mgr, runs as nonroot
COPY --from=build /app /app               # ONLY the binary ships
USER nonroot:nonroot
ENTRYPOINT ["/app"]
# Result: tens of MB instead of ~1 GB golang image
```

---

## Q6. Write a Dockerfile for a company standard requiring minimal image size and basic security best practices.
**Asked in:** PwC-K8s  |  **My performance:** Correct

**My answer (from transcript):**
Use multi-stage builds to streamline dependencies and reduce size; use a distroless or Alpine base; install the company's baseline/CA certificates as part of the build. Result is a lean, secure, portable image.

**✅ Correct answer:**
Right ingredients. A complete "standard" Dockerfile combines: **multi-stage**, **minimal/pinned base** (by digest, not floating tag), **non-root `USER`**, **no secrets baked in**, **CA certs**, **least-privilege filesystem**, and a **`HEALTHCHECK`**. Pin versions for reproducibility and scan the result in CI (Trivy).

```dockerfile
# ---- build stage ----
FROM python:3.12-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- runtime stage ----
FROM python:3.12-slim@sha256:<pinned-digest>
# company CA bundle
COPY certs/corp-ca.crt /usr/local/share/ca-certificates/corp-ca.crt
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && update-ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && groupadd -r app && useradd -r -g app -s /usr/sbin/nologin app
COPY --from=build /install /usr/local
COPY --chown=app:app . /app
WORKDIR /app
USER app                                   # never run as root
EXPOSE 8000
HEALTHCHECK CMD ["python","-c","import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/health').status==200 else 1)"]
ENTRYPOINT ["python","-m","gunicorn","-b","0.0.0.0:8000","app:app"]
```

---

## Q7. Explain ENTRYPOINT vs CMD in Docker.
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
ENTRYPOINT has a fixed run command that runs every time the container starts. With CMD, along with the default command a custom command is accepted, so the custom command overrides the default. With ENTRYPOINT only the given command executes every time.

**✅ Correct answer:**
Correct in spirit. Precise version:

- **`CMD`** sets the **default command/arguments**, and is **fully overridden** by whatever you pass to `docker run <image> <args>`.
- **`ENTRYPOINT`** sets the **fixed executable**; args from `docker run` are **appended to** it (not replacing it), unless you override with `docker run --entrypoint`.
- **Best-practice combo:** `ENTRYPOINT` = the binary, `CMD` = default arguments. Then `docker run myimg` uses the defaults, and `docker run myimg --debug` swaps just the arguments.
- Always use **exec form** (`["prog","arg"]`, JSON array), not shell form (`prog arg`). Exec form makes your app **PID 1** so it receives `SIGTERM` directly for graceful shutdown; shell form wraps it in `/bin/sh -c` which swallows signals.

```dockerfile
FROM alpine
ENTRYPOINT ["ping"]        # fixed executable
CMD ["-c", "3", "localhost"]  # default args, overridable
# docker run img                 -> ping -c 3 localhost
# docker run img -c 5 8.8.8.8    -> ping -c 5 8.8.8.8   (CMD replaced, ENTRYPOINT kept)
# docker run --entrypoint sh img -> overrides ENTRYPOINT
```

---

## Q8. What is the difference between `docker run` and `docker start`?
**Asked in:** Trianz  |  **My performance:** Incorrect

**My answer (from transcript):**
"`docker start` helps in starting the docker daemon set, whereas `docker run` helps in starting the Docker container." (Interviewer said no — wrong.)

**✅ Correct answer:**
Neither touches the daemon. The distinction is **create-a-new-container vs restart-an-existing-one**:

- **`docker run`** = `docker create` + `docker start`. It takes an **image**, creates a **brand-new container** (new writable layer, new ID) from it, and starts it. This is where you pass config: `-p`, `-e`, `-v`, `--name`, `--network`, etc.
- **`docker start`** takes an **existing, stopped container** (by name/ID) and **restarts it** with the **same config it was originally created with**. You cannot pass new ports/env/volumes to `docker start` — that config is fixed at create/run time.
- Corollary: running `docker run` five times gives you **five containers**; `docker start` on the same container just brings that one container back up. `docker stop` + `docker start` preserves the writable layer; `docker rm` + `docker run` starts fresh.

```bash
docker run -d --name web -p 8080:80 nginx   # CREATE new container from image + start it
docker stop web                              # container exists but stopped (writable layer intact)
docker start web                             # RESTART the SAME container, same -p 8080:80 config
docker ps -a                                 # still one container "web"
docker run -d --name web2 -p 8081:80 nginx   # a SECOND, separate container
```

---

## Q9. Developers running containers locally can't fetch logs because the container fails and terminates immediately. What do you suggest so logs are available after failure?
**Asked in:** PwC-K8s  |  **My performance:** Partial → Correct

**My answer (from transcript):**
First: use `docker logs <container-id>` to fetch logs; run in detached mode for a live stream. (Interviewer pushed that the container shuts down too quickly / no persistence.) Then correctly: attach a **volume** — create a host directory and mount it into the container so even if the container dies you can read the logs from the host path.

**✅ Correct answer:**
Two layers to the answer:

1. **`docker logs` still works on a stopped container** — as long as the container hasn't been *removed*, `docker logs <id>` (or `--previous` in K8s) returns the captured stdout/stderr. The gotcha is `docker run --rm`, which **deletes the container on exit** and takes the logs with it. So first fix: **don't use `--rm`** while debugging, and inspect the exit with `docker logs` + `docker inspect <id> --format '{{.State.ExitCode}}'`.
2. **For durable logs regardless of container lifecycle**, either:
   - **Write app logs to a mounted volume / bind mount** so they land on the host and survive container death; or
   - **Configure a logging driver** (`--log-driver`) to ship stdout/stderr to `json-file` (default, persisted under `/var/lib/docker/containers/...`), `journald`, `fluentd`, or a remote aggregator.
3. Best practice: apps should log to **stdout/stderr** (12-factor) and let the platform capture/ship them — don't write log files inside the ephemeral container layer.

```bash
# Keep the container so logs survive the crash
docker run --name crasher myapp            # NOT --rm
docker logs crasher                        # readable even after it exits
docker inspect crasher --format '{{.State.ExitCode}} {{.State.Error}}'

# Durable logs via bind mount + persistent logging driver
docker run --name app \
  -v /var/log/myapp:/app/logs \            # logs land on host, survive container removal
  --log-driver=json-file --log-opt max-size=10m --log-opt max-file=3 \
  myapp
```

---

## Q10. What is the host network in Docker? If you run a container with `--network=host`, will the container get its own IP address?
**Asked in:** Trianz-K8s  |  **My performance:** Partial

**My answer (from transcript):**
Host network is the network of the underlying host (e.g. the VPC/network of the EC2 instance Docker runs on). On the IP: "I don't think so, because Docker has its own network and IPs get assigned within that network." (Conclusion right, reasoning muddled.)

**✅ Correct answer:**
With `--network=host` the container **shares the host's network namespace directly** — it does **not** get its own IP, its own `veth` pair, or its own network stack. It uses the **host's IP and ports as-is**.

- **No separate IP:** `hostname -i` inside the container returns the **host's IP**. There is no NAT and no `docker0` bridge in the path.
- **No port mapping:** `-p 8080:80` is **ignored/meaningless** on host networking. If the app binds `:80`, it's on the host's `:80` immediately — so **two host-network containers can't both bind the same port** (port conflict with the host and each other).
- **Contrast with the default `bridge` network:** there, each container gets its **own IP** on the `docker0` subnet (e.g. `172.17.0.x`), isolated in its own netns, and you reach it from outside via **published ports** (NAT/`iptables`).
- **Why use host?** Lower latency / no NAT overhead, or apps needing many/dynamic ports. **Cost:** no network isolation. (Note: host networking is Linux-only; on Docker Desktop for Mac/Windows it behaves differently.)

```bash
# Bridge (default): container gets its OWN IP, needs port publish to be reached
docker run -d --name b nginx
docker inspect -f '{{.NetworkSettings.IPAddress}}' b     # e.g. 172.17.0.2  (its own IP)

# Host: shares host netns, NO separate IP, -p ignored
docker run -d --network=host --name h nginx
docker exec h hostname -i                                 # prints the HOST's IP, not 172.17.x.x
docker port h                                             # empty — publishing doesn't apply
```

---

## Q11. How do you access a container from outside? Does it work on the bridge network?
**Asked in:** Trianz-K8s  |  **My performance:** Partial (brief, essentially correct)

**My answer (from transcript):**
Through port mapping. Confirmed launching the container on the bridge network with port mapping works.

**✅ Correct answer:**
Correct — flesh out the mechanism:

- On the **default bridge network**, a container has a **private IP** (`172.17.0.x`) reachable only from the host/other containers, not from the outside world. To expose it, you **publish a port** with `-p <hostPort>:<containerPort>`.
- Under the hood Docker programs **`iptables` DNAT** rules: traffic hitting `hostIP:hostPort` is NAT'd to `containerIP:containerPort`. The `docker-proxy` process handles some cases (e.g. localhost).
- `EXPOSE` in a Dockerfile is **documentation only** — it does *not* publish anything; you still need `-p` (or `-P` to auto-publish all `EXPOSE`d ports to random host ports).
- **Container-to-container** on a **user-defined bridge** is nicer than the default bridge: you get **automatic DNS resolution by container name**, so services can reach each other by name without publishing ports at all.

```bash
docker network create appnet                              # user-defined bridge (built-in DNS)
docker run -d --name api --network appnet -p 8080:3000 myapi
# Outside world:  curl http://<hostIP>:8080   -> DNAT -> api container :3000
docker run -d --name web --network appnet myweb
docker exec web curl http://api:3000                      # name-based DNS, no port publish needed
```

---

## Q12. How do you handle persistent data in a Docker container so it survives beyond the container lifecycle?
**Asked in:** HTC  |  **My performance:** Correct

**My answer (from transcript):**
Attach/mount volumes and mount the specific volume path to the container so that even if the container is killed, the underlying data is safe in the volume.

**✅ Correct answer:**
Right. Sharpen the vocabulary — Docker has **three** mount types:

1. **Named volumes** (`docker volume create` / `-v mydata:/path`) — managed by Docker under `/var/lib/docker/volumes/`. **Preferred** for persistence: portable, backup-able, decoupled from any container's lifecycle, and they **bypass the copy-on-write layer** (better write performance).
2. **Bind mounts** (`-v /host/path:/container/path`) — map an exact host directory in. Great for local dev and injecting config; tightly coupled to host layout.
3. **tmpfs mounts** — in-memory only, never persisted (for secrets/scratch).

Key point for the interview: **data written to the container's writable layer is destroyed with the container**; volumes/bind mounts live **outside** that layer, so `docker rm` doesn't touch them. Removing a volume is a separate, deliberate action (`docker volume rm`).

```bash
docker volume create pgdata
docker run -d --name db -v pgdata:/var/lib/postgresql/data postgres:16
docker rm -f db                       # container gone...
docker volume ls                      # ...but 'pgdata' volume still here
docker run -d --name db2 -v pgdata:/var/lib/postgresql/data postgres:16  # data intact in new container

# Bind mount (dev) and inspect where a named volume lives on host
docker run -v "$(pwd)/config:/etc/app:ro" myapp
docker volume inspect pgdata --format '{{.Mountpoint}}'
```

---

## Q13. How do you write the Dockerfile so the container runs as a non-privileged user by default instead of root?
**Asked in:** PwC-K8s  |  **My performance:** Partial

**My answer (from transcript):**
Use a `RUN` command with sudo/chmod to create a user group and name, so the image runs only with that group's permissions, not root; anyone logging into the container must be part of that group. (Rambling; did not cleanly state the `USER` directive / `adduser` / `chown`.)

**✅ Correct answer:**
Clean recipe — three moves:

1. **Create a dedicated non-root user/group** in the image: `groupadd`/`useradd` (Debian) or `addgroup`/`adduser` (Alpine). No `sudo` needed — the build runs as root, so you just create the user.
2. **`chown` the app files** to that user (or `COPY --chown=user:group`) so the process can read/write what it needs.
3. **`USER <name>`** — every subsequent instruction and the container's default runtime process runs as that unprivileged user. Put it **near the end**, after installs that need root.

Extra hardening to mention: use a **high UID** (e.g. `10001`) so it maps to a non-privileged UID on the host, a **read-only root filesystem** (`--read-only`), **drop Linux capabilities** (`--cap-drop=ALL`), and `--security-opt=no-new-privileges`. In K8s the equivalent is `securityContext: runAsNonRoot: true, runAsUser: 10001`.

```dockerfile
FROM node:20-alpine
RUN addgroup -S app && adduser -S -u 10001 -G app app   # non-root user, high UID
WORKDIR /app
COPY --chown=app:app . .
RUN npm ci --omit=dev
USER app                                                 # drop to non-root for runtime
EXPOSE 3000
ENTRYPOINT ["node","server.js"]
```
```bash
# Enforce least privilege at run time too
docker run --read-only --cap-drop=ALL --security-opt=no-new-privileges -u 10001 myapp
```

---

## Q14. If asked to build a golden image for Python, what hardening considerations would you make?
**Asked in:** Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
Run in a specific corporate environment/CIDR; install the company-provided certificate in the image; use a non-root user in the Dockerfile; scan the image via Trivy for vulnerabilities. "Those are the aspects I can come up with."

**✅ Correct answer:**
Good start — a complete hardening checklist for a golden/base image:

- **Minimal, pinned base** — `python:3.12-slim` or distroless, pinned **by digest**; strip build tools from the runtime image.
- **Non-root user** with a fixed high UID; **read-only rootfs**-friendly layout.
- **Patch + update** OS packages at build, then **clean caches in the same layer**; rebuild regularly so CVEs don't rot in.
- **Remove attack surface** — no shell/package manager in the final image (distroless), no `curl`/`wget`/compilers left behind, no setuid binaries.
- **No secrets in layers** — use build secrets/BuildKit `--mount=type=secret`, never `ARG`/`ENV` for tokens (they persist in history).
- **CA / corporate trust** baked in via `update-ca-certificates`.
- **Supply-chain**: scan with **Trivy/Grype**, generate an **SBOM** (syft), and **sign the image** (cosign) so downstream builds can verify provenance.
- **Metadata/labels** — OCI labels with source repo + commit SHA for traceability (see Q15).
- **Drop capabilities / no-new-privileges** documented as the intended run profile.

```dockerfile
FROM python:3.12-slim@sha256:<digest>
LABEL org.opencontainers.image.source="https://git.corp/base/python" \
      org.opencontainers.image.revision="$GIT_SHA"
RUN apt-get update && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends ca-certificates \
 && update-ca-certificates \
 && apt-get purge -y --auto-remove \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -r py && useradd -r -u 10001 -g py py
USER py
# Then in CI:  trivy image --exit-code 1 --severity HIGH,CRITICAL corp/python-golden:tag
#              syft corp/python-golden:tag -o spdx-json > sbom.json
#              cosign sign corp/python-golden@sha256:...
```

---

## Q15. After a security incident, an auditor wants to prove what went into a build — how do you trace a running image back to its source code / Dockerfile? (golden base + developer customization)
**Asked in:** Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
Meandered — categorize the concern, compare current vs desired state, walk the CI/CD, trace by error message, fix the golden pipeline, rebuild, redeploy. Never cleanly described using **image metadata / labels / commit SHA / provenance** to reverse-engineer the running image back to its Dockerfile. Interviewer had to guide toward image metadata, provenance.

**✅ Correct answer:**
This is a **supply-chain provenance / traceability** question. The clean answer is: don't rely on error messages — rely on **immutable identifiers and embedded metadata**:

1. **Content digest** — a running image is pinned to `image@sha256:<digest>`. That digest is unique and immutable; get it from `docker inspect` / the pod spec / the registry.
2. **OCI labels** baked at build time — `org.opencontainers.image.revision` (git commit SHA), `.source` (repo URL), `.version`, build timestamp. `docker inspect` reveals them, mapping the image straight back to the exact commit and Dockerfile.
3. **Layer history** — `docker history --no-trunc` shows the instruction that created each layer.
4. **Build provenance / attestations** — SLSA provenance and **SBOM** attached at build (BuildKit `--provenance`, cosign attestations) record base image, sources, and toolchain, cryptographically signed.
5. **Registry + CI records** — the tag→digest mapping in the registry plus the CI run that produced it (pipeline logs, git tag) closes the loop. Both builds (golden base + dev layer) are traceable because the dev image records its **base image digest**.

So: running container → image digest → labels/attestations → commit SHA → repo + Dockerfile + CI run. That's a verifiable chain, not detective work.

```bash
# From a running container back to source
docker inspect <container> --format '{{.Image}}'            # -> sha256:<digest>
docker inspect <image> --format '{{json .Config.Labels}}'  # revision (git SHA), source repo
docker history --no-trunc <image>                          # per-layer instructions
crane digest corp/app:prod                                  # tag -> immutable digest in registry
cosign verify-attestation --type slsaprovenance corp/app@sha256:...   # signed build provenance
syft corp/app@sha256:... -o spdx-json                       # SBOM: exactly what's inside
```

---

## Q16. What measures would you take to improve the security of a Docker container?
**Asked in:** HTC  |  **My performance:** Partial

**My answer (from transcript):**
Disable root access; use distroless/safe base images for leaner containers; use image scanning tools like Trivy to ensure no vulnerabilities; add enterprise-specific certificates as part of the build.

**✅ Correct answer:**
Good foundation. Organize it into **build-time** and **run-time** controls:

**Build-time (image):**
- Minimal/distroless base, pinned by digest; regularly rebuilt/patched.
- **Non-root `USER`**; no secrets in layers (BuildKit secrets, not `ARG`/`ENV`).
- **Scan** (Trivy/Grype) and **fail CI** on HIGH/CRITICAL; generate **SBOM**; **sign** (cosign) and **verify signatures on pull** (admission policy).

**Run-time (container):**
- `--read-only` root filesystem + `tmpfs` for scratch.
- `--cap-drop=ALL` then add back only what's needed; `--security-opt=no-new-privileges`.
- **Seccomp / AppArmor / SELinux** profiles; never `--privileged`; don't mount the Docker socket into containers.
- **Resource limits** (`--memory`, `--cpus`, pids-limit) to contain blast radius/DoS.
- Network segmentation; least-privilege secrets injection at runtime, not baked in.
- Keep the **daemon/host** patched; consider **rootless** Docker.

```bash
docker run -d \
  --read-only --tmpfs /tmp \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --security-opt=no-new-privileges \
  --security-opt seccomp=default.json \
  --memory=512m --cpus=1 --pids-limit=200 \
  -u 10001 \
  myapp:1.4.2@sha256:<digest>
# CI gate:  trivy image --exit-code 1 --severity HIGH,CRITICAL myapp:1.4.2
```

---

## Q17. How familiar are you with golden images? Define a golden image — why is it "golden"?
**Asked in:** Shell-2  |  **My performance:** Correct

**My answer (from transcript):**
Golden means secure/enterprise-grade and containerized/deployable across container environments. Golden images comprise distroless/secure base images, multi-stage builds, company-specific certificates built in, and Trivy scanning, then stored in an image bakery/golden-image repository for other apps to build on. (Noted a separate software team actually built them.)

**✅ Correct answer:**
Strong answer. Tighten the definition:

A **golden image** is a **standardized, pre-hardened, version-controlled base image** that is centrally built, scanned, approved, and published for the whole org to build on. It's "golden" because it's the **single source of truth / blessed baseline** — every downstream app starts from a known-good, compliant foundation rather than a random public image.

What makes it golden:
- **Hardened & compliant** — CIS benchmarks, non-root, minimal surface, corporate CA/certs, patched.
- **Scanned & signed** — no known HIGH/CRITICAL CVEs; SBOM + cosign signature; provenance.
- **Versioned & immutable** — pinned by digest, reproducible, with a lifecycle (rebuild cadence, deprecation).
- **Centrally governed** — produced by a platform/security "image bakery" pipeline, stored in a trusted internal registry, consumed via `FROM golden-registry/base:tag`.

Benefits: consistency, faster audits, one place to patch a CVE for everyone, reduced drift.

```dockerfile
# Downstream teams simply build ON TOP of the golden base
FROM golden-registry.corp/python-golden:3.12@sha256:<digest>
WORKDIR /app
COPY --chown=app:app . .
RUN pip install --no-cache-dir -r requirements.txt
# USER/non-root, certs, hardening already inherited from the golden base
ENTRYPOINT ["python","app.py"]
```

---

## Q18. Vendors sell ready-made, fully-secured golden images free of high/critical vulns. Why build our own instead of buying?
**Asked in:** Shell-2  |  **My performance:** Correct

**My answer (from transcript):**
Initially argued public images are a vulnerability; after being told it's paid/assured, said to install company-specific certificates for extra security, run our own internal tools (Veracode/Trivy) to satisfy internal requirements even if the vendor tests, and to keep images secure, reliable, lean.

**✅ Correct answer:**
Good pivot. The strongest business/security reasons to build (or at least re-bake) your own:

- **Corporate-specific requirements** a vendor can't know: internal **CA certs**, proxy config, compliance agents, org tooling, base-OS standardization.
- **Trust boundary / supply chain** — you don't want to *fully* outsource trust. Even a paid vendor is an added link; you should **verify, not assume** (independent scans with Trivy/Veracode/Grype, SBOM review, signature verification).
- **Patch cadence control** — you decide when/how fast to rebuild for a zero-day, rather than waiting on a vendor SLA.
- **Customization & consistency** — align with your registries, tagging, and internal `FROM` conventions.
- **Auditability/provenance** you own end-to-end.

Balanced take (mature answer): it's often **not either/or** — you can **base on a trusted vendor image and re-bake** a thin org layer (certs, agents, policy), then scan/sign it yourself. That's cheaper than from-scratch while keeping control.

```dockerfile
# Re-bake a vendor "secure" base into a corporate golden image
FROM vendor-secure-registry.io/python:3.12@sha256:<vendor-digest>
COPY certs/corp-ca.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates
# add corp agents / policy, then re-scan & re-sign in OUR pipeline:
#   trivy image --exit-code 1 --severity HIGH,CRITICAL corp/python-golden:tag
#   cosign sign corp/python-golden@sha256:...
```

---

## Q19. Developers deploy many application stacks needing different base images — were you controlling which images they could use, and how? (image bakery / Dockerfile review)
**Asked in:** Shell-1, HCL, GlobalLogic  |  **My performance:** Correct / experience

**My answer (from transcript):**
Yes — an in-house **image bakery** where app teams pick their base image (e.g. a .NET base), build on top, put the resulting Dockerfile in a Git template, and raising a PR kicks off CI/CD. App teams take the base image as the `FROM`, do multi-stage builds, run pipelines, create image tags, update tags in Helm charts per environment, and deploy. (On GlobalLogic: developers wrote the Dockerfiles; SRE received and deployed them — conceptual, limited hands-on.)

**✅ Correct answer:**
Good real-world answer. The governance pattern to articulate crisply:

- **Curated base registry** ("image bakery") — only approved, hardened golden bases are published; teams **must `FROM`** one of them.
- **Enforcement, not just convention:**
  - **Admission / policy control** — an OPA/Gatekeeper or Kyverno policy (or registry allow-list) that **blocks images not derived from an approved base or not from the trusted registry**, and requires **signed images** (cosign verify) at deploy.
  - **CI gates** — pipeline lints the Dockerfile (hadolint), verifies the `FROM` is an approved digest, scans (Trivy), and signs on pass.
  - **PR-driven** — Dockerfile lives in Git; PR triggers the pipeline; tags flow into Helm/values per environment.
- This gives you **standardization + auditability + one-place CVE patching**, while app teams keep autonomy over their app layer.

```yaml
# Kyverno: only allow images from the trusted registry (enforce the "bakery")
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: restrict-registries }
spec:
  validationFailureAction: Enforce
  rules:
  - name: only-golden-registry
    match: { any: [ { resources: { kinds: [Pod] } } ] }
    validate:
      message: "Images must come from golden-registry.corp"
      pattern:
        spec:
          containers:
          - image: "golden-registry.corp/*"
```

---

## Q20. Are your applications containerized, and what is the runtime/architecture of the application?
**Asked in:** Persistent  |  **My performance:** Partial

**My answer (from transcript):**
Applications were containerized; the runtime was on EC2.

**✅ Correct answer:**
The interviewer wants the **full runtime stack**, not just "EC2." Frame it as layers:

- **Where it runs** — e.g. containers on **EKS** (managed K8s) with worker nodes on **EC2** (or Fargate for serverless pods), or plain Docker/ECS on EC2.
- **Container runtime** — on modern K8s nodes the runtime is **containerd** (via the **CRI**), not the Docker Engine. `containerd` uses **runc** (an OCI runtime) to actually create the container (namespaces + cgroups). Docker itself sits on top of containerd.
- **Orchestration** — K8s schedules pods; a **Deployment/StatefulSet** manages replicas; images pulled from ECR by digest.
- **Networking/storage** — CNI plugin (e.g. VPC-CNI) for pod IPs, CSI (EBS/EFS) for volumes.

Mentioning the **CRI → containerd → runc → namespaces/cgroups** chain shows you understand what "containerized on EC2" actually means under the hood (see Q31).

```bash
# On a K8s node, see the actual runtime (not Docker):
kubectl get nodes -o wide          # CONTAINER-RUNTIME column -> containerd://1.7.x
crictl ps                          # CRI-level containers on the node
# runc is what containerd shells out to, creating Linux namespaces + cgroups per container
```

---

## Q21. Do you write Dockerfiles / containerize the application yourself?
**Asked in:** GlobalLogic  |  **My performance:** Didn't-know (honest / experience)

**My answer (from transcript):**
No — did not containerize applications; developers did. We received the Dockerfile and deployed. Have the idea/concept but no hands-on experience.

**✅ Correct answer:**
Honesty is fine, but pair it with **demonstrated competence** so "I didn't own it" doesn't read as "I can't." Better framing:

- "Application Dockerfiles were authored by dev teams from our **golden base images**; as SRE I **owned the platform side** — reviewing Dockerfiles for best practices (non-root, multi-stage, no secrets, pinned bases), the **build/scan/sign pipeline**, image promotion, and deployment via Helm/Argo."
- Then **prove the concept knowledge** by rattling off what a good Dockerfile looks like (the snippet below) — that turns a "no hands-on" into "I understand it well enough to review and improve it."

Actionable takeaway for Akshay: build a couple of Dockerfiles end-to-end locally (a Go static binary + a Python app, multi-stage, non-root, scanned) so this answer becomes "yes, here's one I wrote."

```dockerfile
# The "I can absolutely write one" proof — multi-stage, non-root, minimal
FROM golang:1.22 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app ./...

FROM gcr.io/distroless/static:nonroot
COPY --from=build /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

---

## 🔺 Advanced Questions to Master (not asked yet — practice these)

## Q22. Explain multi-stage builds beyond the basics — how do you copy from external images and named stages, and when do you use `FROM scratch`?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Multi-stage isn't just "builder + runtime." Advanced patterns: **name stages** (`AS build`) and copy selectively between them; **`COPY --from=<image>`** to pull artifacts straight from a *published* image (e.g. `COPY --from=golang:1.22 /usr/local/go /go`); **parallel independent stages** that BuildKit builds concurrently; a **`test` stage** you can `--target` in CI without shipping it; and **`FROM scratch`** for a fully static binary — an empty base with literally nothing but your binary (smallest possible, zero OS CVEs, but no shell/certs, so add `ca-certificates` and a nonroot user explicitly).

```dockerfile
FROM golang:1.22 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app ./cmd/api

FROM build AS test          # reuse build stage; run with: docker build --target test .
RUN go test ./...

FROM scratch                 # nothing but the binary
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /app /app
USER 10001
ENTRYPOINT ["/app"]
```

---

## Q23. What are BuildKit cache mounts and how do they speed up builds?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**BuildKit** is the modern build backend (default in recent Docker). It enables **`RUN --mount=type=cache`**, which mounts a **persistent cache directory** (e.g. `~/.cache/pip`, `/root/.m2`, `/go/pkg/mod`, apt archives) that **survives across builds** without becoming part of the image layer. Result: dependency downloads are reused build-to-build even when the layer cache is invalidated, dramatically cutting rebuild time — and the cache bytes never bloat the final image. Also `--mount=type=secret` injects secrets at build time without baking them into layers, and `--mount=type=bind` mounts context without copying. Enable with `# syntax=docker/dockerfile:1` and `DOCKER_BUILDKIT=1`.

```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt          # pip cache persists across builds, not in image
COPY . .
# Build-time secret without leaking into layers:
# RUN --mount=type=secret,id=npmrc  npm ci
```

---

## Q24. How do you sign container images and verify them (cosign / Sigstore)?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Image signing proves **integrity and provenance** — that an image came from your pipeline and wasn't tampered with. **cosign** (Sigstore) signs an image **by digest** and stores the signature in the registry alongside it. Supports **keyless signing** (short-lived certs tied to an OIDC identity via Fulcio, logged in the Rekor transparency log) or a key pair. You then **enforce verification at admission** (Kyverno/Gatekeeper/Connaisseur) so only signed images from trusted identities can run. Pair with **attestations** (SBOM, SLSA provenance) also signed by cosign.

```bash
# Sign (keyless) by digest
cosign sign --yes registry.corp/app@sha256:<digest>
# Verify in CI / at deploy
cosign verify \
  --certificate-identity=https://github.com/corp/app/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  registry.corp/app@sha256:<digest>
# Attach + sign an SBOM attestation
cosign attest --predicate sbom.json --type spdxjson registry.corp/app@sha256:<digest>
```

---

## Q25. What is an SBOM and how/why do you generate one?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
An **SBOM (Software Bill of Materials)** is a machine-readable inventory of **every package, library, and version** inside an image (standards: **SPDX**, **CycloneDX**). Why it matters: when a new CVE drops (think Log4Shell), you can **instantly query which images contain the affected component** instead of rebuilding/rescanning everything; it's increasingly a **compliance/regulatory** requirement (US EO 14028); and it enables **vulnerability correlation** and license auditing. Generate with **syft** (or `docker sbom`, BuildKit `--sbom=true`), attach it as a **signed attestation**, and scan the SBOM with **grype/trivy**.

```bash
syft registry.corp/app@sha256:<digest> -o spdx-json > sbom.json
grype sbom:sbom.json --fail-on high            # scan the SBOM for CVEs
docker buildx build --sbom=true --provenance=true -t registry.corp/app:1.0 --push .
```

---

## Q26. What is rootless Docker and why use it?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Normally the **Docker daemon runs as root**, so a container escape or a compromised daemon = host root. **Rootless mode** runs the daemon **and** containers as a **non-root user**, using **user namespaces** to map the container's "root" (UID 0) to an **unprivileged host UID**. Even if a process breaks out, it only has that unprivileged user's rights on the host — a big reduction in blast radius. Trade-offs: some features are limited (certain networking/`--privileged`, ports <1024 need extra config, overlay perf via fuse-overlayfs). **Podman** is daemonless and rootless by design and is a common alternative. Complementary hardening: **user-namespace remapping** (`userns-remap`) even in rootful Docker.

```bash
# Install & run rootless
dockerd-rootless-setuptool.sh install
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
docker run -d nginx           # daemon + container run as YOUR user, not root
# Verify UID mapping
docker run --rm alpine id     # uid 0 inside == an unprivileged subordinate UID on the host
```

---

## Q27. What Linux primitives actually make a container? (namespaces & cgroups)
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
A container is **not a VM** — it's just a normal Linux process with **isolation** applied via two kernel features:

- **Namespaces** provide **isolation (what a process can see)**: `pid` (own process tree, its app is PID 1), `net` (own interfaces/IP/ports), `mnt` (own filesystem view), `uts` (own hostname), `ipc`, `user` (UID mapping), `cgroup`, `time`.
- **cgroups (control groups)** provide **resource limits (what it can use)**: CPU, memory, block I/O, pids. `--memory=512m`/`--cpus=1` translate into cgroup limits; OOM-kill happens when the memory cgroup is exceeded.
- Plus **capabilities**, **seccomp**, and **union filesystems (overlay2)** for the layered rootfs. `runc` sets all of this up when it launches the container.

```bash
# See a container's namespaces and cgroup limits from the host
PID=$(docker inspect -f '{{.State.Pid}}' mycontainer)
ls -l /proc/$PID/ns/                         # net, pid, mnt, uts, ipc, user ...
cat /sys/fs/cgroup/memory.max 2>/dev/null    # cgroup v2 memory limit for the container
docker run --rm --memory=256m --cpus=0.5 alpine sh -c 'cat /sys/fs/cgroup/memory.max'
# unshare demonstrates the same primitive manually:
sudo unshare --pid --net --mount --fork --uts bash
```

---

## Q28. What is the OCI, and what are the image spec, runtime spec, and distribution spec?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
The **Open Container Initiative (OCI)** standardizes container formats so images/tools are interoperable across Docker, containerd, Podman, K8s, etc. Three specs:

- **Image spec** — the on-disk/on-registry format: a **manifest** listing layers + a **config** (env, entrypoint, layer digests), all **content-addressed by sha256**. A **manifest list / image index** points to per-architecture manifests (multi-arch).
- **Runtime spec** — how to run a container from an unpacked **filesystem bundle** + `config.json`; **runc** is the reference implementation.
- **Distribution spec** — the **registry API** for push/pull (what `docker push`, ORAS, crane speak).

Takeaway: "Docker image" is really an **OCI image**; that's why containerd/Podman can run images Docker built, and vice-versa.

```bash
# Inspect the OCI manifest (multi-arch index) without pulling
docker manifest inspect --verbose alpine:3.20
crane manifest alpine:3.20 | jq '.mediaType, .manifests[].platform'
# OCI media types: application/vnd.oci.image.manifest.v1+json etc.
```

---

## Q29. How do you debug a distroless container that has no shell?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Distroless images ship **no shell and no package manager**, so `docker exec -it ... sh` fails — that's the point (smaller, safer). To debug:

- **`:debug` variants** — Google distroless publishes `*:debug` tags that include busybox: `gcr.io/distroless/base:debug`.
- **`docker debug` / ephemeral debug container** — attach a temporary container that **shares the target's namespaces** and brings its own tools. In K8s: **`kubectl debug --image=busybox --target=<container>`** (ephemeral containers) to get a shell in the same pid/net namespace without modifying the running image.
- **`nsenter`** from the host into the container's namespaces.
- Or copy files out with `docker cp` and inspect externally.

```bash
# Kubernetes: ephemeral debug container sharing the distroless container's namespaces
kubectl debug -it mypod --image=busybox --target=app -- sh
# Docker: attach a debug toolbox sharing PID + network namespace of the target
docker run -it --rm --pid=container:app --network=container:app nicolaka/netshoot
# From the host straight into the container's namespaces
nsenter -t $(docker inspect -f '{{.State.Pid}}' app) -n -p sh
```

---

## Q30. What's a good layer-caching strategy — how do you order Dockerfile instructions for fast rebuilds?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Docker caches each layer and **invalidates from the first changed instruction downward**. So order instructions from **least-frequently-changing to most-frequently-changing**:

1. Base image + OS packages (change rarely).
2. **Dependency manifest only** (`package.json`, `requirements.txt`, `go.mod`) → install deps. This layer stays cached as long as deps don't change.
3. **Then** copy application source (changes every commit).

The classic mistake is `COPY . .` **before** `npm install` — any source change busts the dependency layer and forces a full reinstall. Also: pin versions (floating tags silently break cache reproducibility), use `.dockerignore` to keep churn out of the context, and leverage **`--cache-from`** / registry cache in CI where the local cache is cold.

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./          # deps manifest FIRST
RUN npm ci --omit=dev          # cached until package*.json changes
COPY . .                       # volatile source LAST — doesn't bust the deps layer
CMD ["node","server.js"]
# CI with shared cache:
#   docker buildx build --cache-from=type=registry,ref=repo/app:cache \
#                       --cache-to=type=registry,ref=repo/app:cache,mode=max -t repo/app:sha .
```

---

## Q31. What is HEALTHCHECK and how does it differ from a Kubernetes readiness/liveness probe?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Dockerfile **`HEALTHCHECK`** defines a command Docker runs periodically to mark a container `healthy`/`unhealthy` (visible in `docker ps` and `docker inspect`). Options: `--interval`, `--timeout`, `--start-period` (grace on boot), `--retries`. It's honored by plain Docker/Swarm/Compose. **Kubernetes ignores the image's `HEALTHCHECK`** — it uses its own **liveness** (restart if failing), **readiness** (remove from Service endpoints until ready), and **startup** probes defined in the pod spec, which are more granular (HTTP/TCP/exec/gRPC, per-probe thresholds). So: `HEALTHCHECK` for Docker/Compose environments; probes for K8s.

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:8080/healthz || exit 1
```
```yaml
# Kubernetes equivalent (image HEALTHCHECK is ignored here)
readinessProbe: { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 5, periodSeconds: 10 }
livenessProbe:  { httpGet: { path: /livez,  port: 8080 }, periodSeconds: 15, failureThreshold: 3 }
```

---

## Q32. How do you build multi-architecture images (buildx), and how does Kubernetes run containers without Docker (CRI/containerd)?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**Multi-arch with buildx:** `docker buildx` uses **QEMU emulation** (or native remote builders) to build the same image for multiple platforms (`linux/amd64`, `linux/arm64`) and push a single **manifest list** — the registry then serves the right variant per pulling node's architecture (e.g. Graviton/ARM vs x86). One tag, many arches, transparent to consumers.

**How K8s runs containers without Docker:** since v1.24 Kubernetes **removed the "dockershim"** and no longer talks to the Docker Engine. The kubelet talks to any runtime implementing the **CRI (Container Runtime Interface)** — commonly **containerd** or **CRI-O**. containerd pulls OCI images and uses **runc** to create the container (namespaces + cgroups). Docker-built images still run fine because they're **OCI images**; you just don't need the Docker daemon on the node. Node inspection uses **`crictl`**, not `docker`.

```bash
# Multi-arch build + push in one shot
docker buildx create --use --name multi
docker buildx build --platform linux/amd64,linux/arm64 \
  -t registry.corp/app:1.0 --push .           # produces a manifest list
docker buildx imagetools inspect registry.corp/app:1.0   # shows both arch variants

# On a K8s node — the runtime is containerd via CRI, not Docker:
kubectl get node <n> -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}'  # containerd://1.7.x
crictl ps ; crictl images                     # CRI-level tooling replaces `docker ps`
```

---

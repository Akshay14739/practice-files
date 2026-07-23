# Package Management — Installing Software Without Breaking the Node

*The distro's supply chain: how a signed tarball on a mirror becomes a trusted binary in your PATH — and why the same mechanism decides whether your kubelet stays exactly on 1.28.5 or silently drifts to 1.28.9 overnight.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** Package management — the system that installs, upgrades, removes, and *tracks* software on a Linux box. It has two layers that people constantly conflate: a **low-level** tool that unpacks one archive and records what it did (`dpkg` on Debian/Ubuntu, `rpm` on RHEL/Fedora), and a **high-level** tool that resolves dependencies, talks to remote **repositories**, verifies signatures, and then drives the low-level tool (`apt`/`apt-get` on Debian, `dnf`/`yum` on RHEL). You will learn how a package gets from a mirror onto your disk, how the system decides to *trust* it, how to install an **exact** version, how to **freeze** that version so nothing bumps it, and how to install a raw binary safely when there is no package at all.

**Why did this land on my desk?** You are building a fresh Kubernetes node with `kubeadm`. The runbook says:

```bash
apt-get install -y kubelet kubeadm kubectl
```

You run it. Six weeks later a routine, well-intentioned `apt-get upgrade` (a security-patch cron, or a teammate "just updating packages") bumps `kubelet` from `1.28.5` to `1.29.2`. The kubelet restarts, refuses to talk to a control plane still on `1.28`, and the node goes `NotReady`. Pods get evicted. Your pager goes off at 02:00. The root cause is not Kubernetes — it is that **you let the package manager treat kubelet like any other upgradable package**, when kubelet's version is load-bearing infrastructure that must move only when *you* say so. Today you learn the machinery that lets you say so: exact-version installs and `apt-mark hold` / `versionlock`.

**What do I already know that transfers?**
- **"Everything is a file"** (see [linux-philosophy](01-linux-philosophy.md)) — a package is just a compressed archive of files plus metadata; installing it is copying those files to the right paths and recording an inventory. The inventory itself lives in files under `/var/lib/dpkg/` or `/var/lib/rpm/`.
- **PATH and the shell** (see [shell-and-environment](02-shell-and-environment.md)) — packages drop executables into `/usr/bin`, `/usr/sbin`, `/usr/local/bin`; whether you can type `kubectl` and have it run is a PATH question.
- **Permissions & ownership** (see [permissions-ownership](05-permissions-ownership.md)) — installing binaries means writing to root-owned dirs with the right mode (`0755`, `root:root`). `install -m 0755` is the tool that does copy + chmod + chown in one atomic step.
- **TLS & signatures** (see [tls-pki-openssl](26-tls-pki-openssl.md)) — repositories are signed with GPG keys; verifying that signature is exactly the same trust-chain idea as verifying a TLS cert, just with a different key format.
- **Kubernetes versioning** — you already know the version-skew policy in your bones: kubelet may be up to *n-3* minor versions behind the API server but **never ahead**. Package pinning is how you enforce that policy on the actual node.

---

## 🔥 Rung 1 — The Pain

**The problem that FORCED package managers to exist: software is a graph of dependencies, and installing it by hand is an unwinnable bookkeeping war.**

Rewind to the mid-1990s. You want to install a program. You download a `.tar.gz` of source, `./configure && make && make install`, and it copies files to wherever it likes. Now multiply that by a hundred programs on one server and ask the questions that ruined weekends:

- **"What depends on what?"** Program A needs `libssl` ≥ 1.0. Program B needs `libssl` < 1.0. You install B's version, A breaks. Nobody wrote down the constraint; you find out at runtime with a cryptic linker error. This is **dependency hell**.
- **"What files did that install even drop?"** `make install` gave no receipt. Six months later you want to remove the program — but which files were *its* files? You either leave orphaned junk forever or delete something shared and break three other tools.
- **"Is this the real thing?"** You downloaded a tarball over plain HTTP from a mirror you'd never heard of. Was it tampered with in transit? Was the mirror compromised? You had no way to know. You ran it as root and hoped.
- **"How do I patch 500 machines?"** A security bug drops in `bash` (remember Shellshock). You need every server updated *today*. Hand-compiling on 500 boxes is not a plan.

**What did people do before, and why did it hurt?**
- **Compile from source, track by memory.** Worked for one machine and one expert. Did not scale, did not survive staff turnover, left no audit trail.
- **Copy binaries around by hand / "golden" tarballs.** Fast to deploy, impossible to know what version is where, and no dependency awareness — the classic "works on my machine."
- **Static everything.** Some shops statically linked every binary to dodge shared-library hell. Huge binaries, and now a `libssl` CVE means rebuilding *every* program instead of patching one shared library.

**Who felt the pain most?** Distribution maintainers and, later, fleet operators. Debian's answer (`dpkg` in 1994, `apt` on top in 1998) and Red Hat's answer (`rpm`, then `yum`, then `dnf`) solved it the same way: **declare dependencies in metadata, sign everything, keep a local database of exactly what is installed, and let a resolver do the graph math.** That is the direct ancestor of how you run a Kubernetes fleet today.

**What breaks in Kubernetes without disciplined package management?** Everything downstream of the node build:
- A node where `kubelet`, `kubeadm`, and `kubectl` drift to *different* minor versions because an unpinned upgrade caught one of them — instant skew violation.
- A `containerd` bumped by a distro upgrade to a version whose default `runc` or cgroup config no longer matches your `/etc/containerd/config.toml` — CRI errors, pods stuck `ContainerCreating`.
- A raw `kubectl` or `crictl` binary someone `curl`ed over HTTP with no checksum — you have no idea if it's the real thing, and now it's running with your kubeconfig's admin credentials.

The engineer who feels this most is **you at 02:00**, when a node that worked yesterday is `NotReady` today and the only thing that changed was a background `apt` run you didn't schedule.

> **Check yourself before Rung 2:** `make install` and `apt-get install` both end with "files land on disk." Name the *one* thing `apt` does that `make install` fundamentally cannot — and explain why that one thing is what makes a fleet manageable at all.

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it:

> **A package manager is a trusted supply chain: a signed remote catalog of versioned archives, a resolver that turns "I want X" into "install these exact files," and a local database that remembers every file it ever placed — so install, upgrade, remove, and *freeze* are all just edits to that database.**

Everything else derives from that one sentence:

- **"signed remote catalog"** → **repositories** publish **metadata** (a list of every package, version, dependency, and checksum) that is **GPG-signed**. Your box downloads the metadata (`apt-get update`), verifies the signature against a **keyring** you chose to trust, and now knows what exists without downloading a single package. Trust the key → trust the catalog → trust the checksums → trust the archives.
- **"versioned archives"** → every package has a name *and* a version (`kubelet=1.28.5-1.1`). "Install kubelet" and "install kubelet 1.28.5-1.1" are different requests. Kubernetes lives or dies on which one you make.
- **"a resolver"** → the high-level tool (`apt`/`dnf`) reads the metadata's dependency graph, computes the full set of packages needed, downloads them, verifies each checksum, then hands them to the low-level tool (`dpkg`/`rpm`) which does the actual unpack-and-record.
- **"a local database that remembers every file"** → `/var/lib/dpkg/` and `/var/lib/rpm/` hold the receipt. `dpkg -l` / `rpm -qa` reads it. Removal is exact because the receipt is exact.
- **"freeze"** → because the database also stores *state flags*, you can mark a package **held** (`apt-mark hold`) or **locked** (`versionlock`). The resolver then treats that version as immovable — an upgrade will route around it or refuse. **This is the entire reason your kubelet stays put.**

If you remember nothing else: **signed catalog → resolver → local receipt → and a hold flag that says "do not touch."** The whole feature falls out of those four moves.

> **Check yourself before Rung 3:** From the one sentence alone, predict what `apt-get update` downloads versus what `apt-get install` downloads. Which one touches the *catalog* and which one touches the *archives*? Why must they be two separate steps?

---

## ⚙️ Rung 3 — The Machinery (the important rung — go slow)

> ### 🧸 Plain-English first (read this before the technical version)
>
> **Installing software works like ordering from a trustworthy mail-order warehouse.** Five parts hand off to each other:
>
> - **The warehouse (the "repository").** A website holding two things: a *catalog* (a list of every product, its version, and what other products it needs) and the *boxes* themselves (the actual software). At the top sits a master table of contents carrying a **wax seal** — a digital signature from the warehouse — that vouches for everything below it. Like a notarized cover page, one trusted seal secures every item you'll download.
> - **Your book of trusted seals (the "keyring").** For the seal check to work, your computer keeps a copy of each warehouse's official stamp. The old habit was one big book where any stamp could vouch for any warehouse — dangerous, because one crooked stamp could then fake anything. The modern way: each warehouse gets its own page, and its stamp can vouch only for *its own* catalog.
> - **Your list of approved warehouses.** A small file naming which warehouses you shop from at all — the only place that list lives.
> - **The "update the catalog" step.** One command fetches a fresh catalog from every warehouse and checks each seal — but downloads *no products yet*. Skip it and you're shopping from last month's catalog: newer items simply aren't offered to you.
> - **The personal shopper and the delivery man.** The high-level tool is the shopper: it reads the catalog, works out everything your order requires, downloads the boxes, and verifies each one against the catalog. It then hands them to the low-level tool — the delivery man — who unpacks, runs the setup chores, puts every file in its place, and writes a detailed **receipt** listing exactly what was installed where. The delivery man is honest but not clever: he never fetches missing pieces himself, which is why you almost always talk to the shopper instead.
>
> **The "do not replace" sticker.** The receipt book also stores a little flag per product: mark something as "held," and future upgrades will leave it untouched — essential when a program must stay at one exact version.
>
> **The Kubernetes tie:** every important program on a cluster machine arrived through exactly this chain — checked seal, planned order, written receipt, and (done right) a hold sticker so nothing swaps it out behind your back.

*Now the original technical deep-dive — the same ideas, in precise form:*

Let's open the hood. There are **five moving parts**, and the magic is in how they hand off to each other.

```
        THE PACKAGE MANAGEMENT SUPPLY CHAIN (Debian/apt shown; RHEL is the mirror image)
        ================================================================================

   REMOTE (a repository on pkgs.k8s.io / archive.ubuntu.com)
   ┌───────────────────────────────────────────────────────────────────────┐
   │   Release        ← top-level index, lists checksums of everything below │
   │   Release.gpg /   ← DETACHED GPG SIGNATURE over Release  (the trust root)│
   │   InRelease           (InRelease = Release + signature in one file)      │
   │   Packages.gz    ← the CATALOG: every pkg name, version, deps, sha256    │
   │   pool/.../kubelet_1.28.5-1.1_amd64.deb   ← the actual ARCHIVE           │
   └───────────────────────────────────────────────────────────────────────┘
                    │  (1) apt-get update: fetch Release + Packages
                    │      verify Release signature against local keyring
                    ▼
   LOCAL BOX
   ┌───────────────────────────────────────────────────────────────────────┐
   │  /etc/apt/sources.list.d/kubernetes.list   ← WHICH repos to trust       │
   │      "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ..."  │
   │  /etc/apt/keyrings/kubernetes-apt-keyring.gpg ← the PUBLIC KEY (trust)   │
   │                                                                          │
   │  /var/lib/apt/lists/   ← cached CATALOG (result of `apt-get update`)     │
   │                                                                          │
   │        │ (2) apt-get install kubelet=1.28.5-1.1                          │
   │        │     resolver reads cached catalog, computes deps, downloads     │
   │        │     .deb into /var/cache/apt/archives, verifies each sha256     │
   │        ▼                                                                 │
   │   ┌──────────────┐  (3) apt hands the verified .deb to dpkg              │
   │   │  apt / apt-  │ ───────────────────────────────►  ┌───────────────┐  │
   │   │  get (HIGH)  │                                    │  dpkg (LOW)   │  │
   │   │  resolver +  │  ◄─── reports back what happened ─ │ unpack +      │  │
   │   │  downloader  │                                    │ run maintainer│  │
   │   └──────────────┘                                    │ scripts +     │  │
   │                                                        │ RECORD files  │  │
   │                                                        └───────┬───────┘  │
   │                                                                │          │
   │   (4) files land:  /usr/bin/kubelet                            ▼          │
   │   (5) receipt written: /var/lib/dpkg/status  +  /var/lib/dpkg/info/*.list │
   │       state flag stored here too:  Status: hold ok installed  ◄── HOLD    │
   └───────────────────────────────────────────────────────────────────────┘
```

Walk each part slowly:

**1. The repository (remote).** A repo is nothing but a directory tree on an HTTP server, laid out by convention. At the top sits a `Release` file (RHEL calls its equivalent `repomd.xml`). `Release` is a small text index that lists the **sha256 of every other metadata file** in the repo. Sitting next to it is a **detached GPG signature** — `Release.gpg`, or the combined `InRelease` which staples the signature inside. This signature is the **trust anchor for the entire repo**: if you trust the key that signed `Release`, and `Release` vouches for the checksum of `Packages.gz`, and `Packages.gz` vouches for the checksum of each `.deb`, then a single trusted signature transitively secures every byte you'll download. This is a **chain of trust**, exactly like a TLS certificate chain (see [tls-pki-openssl](26-tls-pki-openssl.md)) — one root you trust, vouching down a ladder.

**2. The keyring (local trust store).** For your box to verify that signature, it needs the repo's **public key**. Historically everyone dumped keys into one global `apt-key` trust store — which meant *any* key you'd ever added could sign *any* repo. That's a security hole (a compromised third-party key could forge Ubuntu's own packages), so `apt-key` is **deprecated**. The modern way: drop each repo's public key into its own file under `/etc/apt/keyrings/`, and in the repo's source line say `signed-by=<that exact keyring>`. Now the Kubernetes key can *only* validate the Kubernetes repo. On RHEL the analog is `gpgkey=` inside the `.repo` file plus `rpm --import`.

**3. The source definition (which repos exist).** On Debian, `/etc/apt/sources.list` and the drop-in files under `/etc/apt/sources.list.d/*.list` list your repos, one `deb ...` line each. On RHEL, `/etc/yum.repos.d/*.repo` files do the same in INI format. This is the *only* place you declare "these are the catalogs I consult."

**4. `apt-get update` — sync the catalog, verify the signature.** This step downloads `Release`/`InRelease` and `Packages.gz` from each repo, **checks the GPG signature against the matching keyring**, and caches the verified catalog under `/var/lib/apt/lists/`. Crucially, **it downloads no packages** — only the index. After `update`, your box knows every package and version that exists, without having installed anything. Forget to run it and your catalog is stale: `apt-get install` will offer you yesterday's versions or fail to find a new one. (RHEL's `dnf` refreshes metadata automatically on most operations, so an explicit "update the catalog" step is usually implicit.)

**5. The resolver + the low-level installer — the actual install.** When you run `apt-get install kubelet=1.28.5-1.1`, the **high-level** tool (`apt-get`) does the thinking: it reads the cached catalog, walks the dependency graph, and produces a concrete plan — "to satisfy this I must install kubelet 1.28.5-1.1, kubernetes-cni x.y, conntrack, socat." It downloads each `.deb` into `/var/cache/apt/archives/`, **verifies each package's sha256 against the catalog**, then hands the verified archives to the **low-level** tool, `dpkg`. `dpkg` is the one that actually: unpacks the archive, runs the package's **maintainer scripts** (`preinst`/`postinst` — e.g. creating a system user, reloading systemd), copies files to their final paths, and — the part that makes everything reversible — **records the exact file list** into `/var/lib/dpkg/info/kubelet.list` and updates the master inventory `/var/lib/dpkg/status`.

**The low/high split is the whole point.** `dpkg` (and `rpm`) are dumb and honest: give one archive, unpack it, record it — but they will *not* fetch dependencies. Try to `dpkg -i` a package whose dependency is missing and it installs anyway, leaving the system "half-configured." `apt` (and `dnf`) are the smart layer on top: they turn a *wish* ("I want kubelet") into a *complete, ordered, verified plan* and then drive `dpkg` to execute it. You almost always talk to the high layer; you reach for the low layer only to inspect (`dpkg -l`) or to force-install a single downloaded `.deb`.

**Where the hold lives.** The receipt database doesn't only store *what* is installed — it stores a **state flag** per package. `apt-mark hold kubelet` sets that flag to `hold`. On the next `apt-get upgrade`, the resolver sees the flag and treats 1.28.5-1.1 as pinned: it will not upgrade kubelet, and if some other package's upgrade *requires* a newer kubelet, apt will decline that upgrade rather than break the hold. RHEL stores the equivalent as an exclude rule via the `versionlock` plugin. **This flag is the single most important thing in this document for a Kubernetes operator** — it's the difference between a node whose version you control and a node the distro controls.

**The Kubernetes connection, concretely.** Your node's `kubelet` binary at `/usr/bin/kubelet` got there through exactly this chain — from the `pkgs.k8s.io` repo, GPG-verified via a keyring, resolved and installed by `apt`, recorded by `dpkg`, and (if you did it right) frozen with a hold. `containerd`, `runc`, `crictl`, the CNI plugins under `/opt/cni/bin` — same story. When `kubeadm` prints "make sure kubelet is the right version," it's asking you to trust that this supply chain put the version you meant on disk and that nothing will move it out from under you.

> **Check yourself before Rung 4:** A colleague runs `dpkg -i ./kubelet_1.28.5-1.1_amd64.deb` directly (skipping apt) and it "works." What did they *not* get that `apt-get install kubelet=1.28.5-1.1` would have given them? Name two things — one about dependencies, one about trust.

---

## 🏷️ Rung 4 — The Vocabulary Map

Every scary word, pinned to what it actually *is* and which part of the machine it touches.

| Term | What it actually is | Which part of the machinery |
|---|---|---|
| **`dpkg`** | Low-level Debian tool: unpacks ONE `.deb`, runs its scripts, records its files. No dependency resolution. | The low-level installer (part 5) |
| **`rpm`** | Low-level RHEL/Fedora tool: same role as `dpkg` for `.rpm` files. | The low-level installer (part 5) |
| **`apt` / `apt-get`** | High-level Debian tool: talks to repos, resolves deps, verifies, drives `dpkg`. | The resolver + downloader (parts 4-5) |
| **`dnf` / `yum`** | High-level RHEL tool: same role as apt. `dnf` is the modern engine; `yum` is a compatibility alias for it. | The resolver + downloader (parts 4-5) |
| **`.deb` / `.rpm`** | The package archive: a compressed bundle of files + metadata + maintainer scripts. | The versioned archive (part 1) |
| **Repository (repo)** | An HTTP-served directory of packages plus signed metadata. | The remote catalog (part 1) |
| **Metadata / catalog** | `Packages.gz` (deb) / `repomd.xml`+`primary.xml` (rpm): the machine-readable list of every pkg, version, dep, checksum. | The catalog (part 1, cached in part 4) |
| **`Release` / `InRelease`** | Top index file listing checksums of all metadata; `InRelease` has the GPG signature inline. | The trust anchor (part 1) |
| **GPG signing key** | An asymmetric keypair; the repo owner signs `Release` with the private half, you verify with the public half. | The trust chain (parts 1-2) |
| **Keyring** | The file holding the repo's PUBLIC key, e.g. `/etc/apt/keyrings/kubernetes-apt-keyring.gpg`. | The local trust store (part 2) |
| **`gpg --dearmor`** | Converts an ASCII-armored `.key` (base64 text) into the binary keyring format apt wants. | Prepares the keyring (part 2) |
| **`signed-by=`** | Clause in a `deb` source line binding ONE repo to ONE keyring. Scopes trust. | The source definition (part 3) |
| **`sources.list` / `.list`** | Debian's declaration of which repos to consult (`/etc/apt/sources.list.d/`). | The source definition (part 3) |
| **`.repo` file** | RHEL's INI-format repo declaration under `/etc/yum.repos.d/`. | The source definition (part 3) |
| **`apt-get update`** | Downloads + verifies the catalog. Installs NOTHING. | Catalog sync (part 4) |
| **Dependency resolution** | Computing the full set of packages needed to satisfy a request. | The resolver (part 5) |
| **Maintainer scripts** | `preinst`/`postinst`/`prerm` shell scripts inside a package (create users, reload systemd). | Run by dpkg/rpm (part 5) |
| **Local package database** | `/var/lib/dpkg/` (`status`, `info/*.list`) or `/var/lib/rpm/`: the receipt of everything installed + state flags. | The local receipt (part 5) |
| **`apt-mark hold`** | Sets the `hold` state flag so the resolver never upgrades that package. | State flag in the receipt (part 5) |
| **`versionlock`** | RHEL plugin that records an exclude rule pinning a package to a version. | RHEL equivalent of hold (part 5) |
| **Pinning** | The general act of forcing a specific version/holding it (hold, versionlock, apt preferences). | State control over the resolver |
| **`sha256sum --check`** | Verifies a downloaded file's hash against a published `.sha256` — DIY trust when there's no repo. | Manual trust chain (raw binaries) |
| **`install -m 0755`** | Copy + set mode + set owner in one atomic operation. | Placing a raw binary correctly |

**Terms that are the same kind of thing wearing different names:**
- **Low-level installers:** `dpkg` ≡ `rpm`. Same job, different distro family.
- **High-level resolvers:** `apt`/`apt-get` ≡ `dnf`/`yum`. (And `apt` vs `apt-get`: `apt` is the newer human-friendly front-end with a progress bar; `apt-get` is the older, stable, script-safe interface — **use `apt-get` in automation**, as its output format is guaranteed stable.)
- **Package archives:** `.deb` ≡ `.rpm`.
- **Freeze mechanisms:** `apt-mark hold` ≡ `dnf/yum versionlock` ≡ (roughly) `apt` pinning via `/etc/apt/preferences.d/`.
- **Source declarations:** `sources.list.d/*.list` ≡ `yum.repos.d/*.repo`.
- **Trust stores:** apt keyring under `/etc/apt/keyrings/` ≡ rpm's imported GPG keys (`rpm --import`, listed via `rpm -qa gpg-pubkey*`).
- **Catalog top-index:** Debian `Release`/`InRelease` ≡ RHEL `repomd.xml`.

Notice the deep symmetry: **every Debian concept has an exact RHEL twin.** Learn the shape once and you can operate either family.

> **Check yourself before Rung 5:** `apt` and `apt-get` are "the same kind of thing." Given that, why does every Kubernetes install runbook say `apt-get` and never `apt`? (Hint: think about what a script parses.)

---

## 🔬 Rung 5 — The Trace

Let's follow **one concrete action end to end**: installing a pinned kubelet from the Kubernetes repo on a fresh Ubuntu 22.04 node, from zero trust to a held package. Every hop names the component doing the work.

```
   YOU                 apt-get            keyring/GPG        pkgs.k8s.io          dpkg            /var/lib/dpkg
    │                    │                    │                  │                 │                   │
 1) │ add keyring        │                    │                  │                 │                   │
    │───── curl Release.key | gpg --dearmor ─►│ writes           │                 │                   │
    │      -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg       │                 │                   │
    │                    │                    │ (public key now on disk)           │                   │
 2) │ add source line    │                    │                  │                 │                   │
    │──── echo "deb [signed-by=...keyring] .../v1.28/deb/ /"      │                 │                   │
    │     > /etc/apt/sources.list.d/kubernetes.list              │                 │                   │
 3) │ apt-get update     │                    │                  │                 │                   │
    │───────────────────►│── GET Release ─────┼─────────────────►│                 │                   │
    │                    │◄─ Release+sig ─────┼──────────────────│                 │                   │
    │                    │── verify sig against keyring ─►✓       │                 │                   │
    │                    │── GET Packages.gz ─┼─────────────────►│                 │                   │
    │                    │   cache to /var/lib/apt/lists/         │                 │                   │
 4) │ apt-get install kubelet=1.28.5-1.1 ...  │                  │                 │                   │
    │───────────────────►│ read cached catalog, resolve deps     │                 │                   │
    │                    │── GET kubelet_1.28.5-1.1_amd64.deb ───►│                 │                   │
    │                    │◄─ .deb ────────────┼──────────────────│                 │                   │
    │                    │── verify sha256 vs catalog ─►✓         │                 │                   │
    │                    │── hand verified .deb ─────────────────┼────────────────►│ unpack            │
    │                    │                    │                  │                 │ run postinst      │
    │                    │                    │                  │                 │ /usr/bin/kubelet  │
    │                    │                    │                  │                 │── record files ──►│ status,
    │                    │◄─────── done ──────┼──────────────────┼─────────────────│                   │ kubelet.list
 5) │ apt-mark hold kubelet kubeadm kubectl   │                  │                 │                   │
    │─────────────────────────────────────────────────────────────────────────────────── set flag ───►│ Status: hold
```

Step by step, in words:

1. **You add the keyring.** `curl` fetches the repo's ASCII-armored public key; `gpg --dearmor` converts it to binary and writes `/etc/apt/keyrings/kubernetes-apt-keyring.gpg`. **Trust now exists on disk, scoped to nothing yet.**
2. **You add the source line**, binding the Kubernetes repo to *that* keyring via `signed-by=`. Now the trust is scoped: this key validates this repo and no other.
3. **`apt-get update` runs.** `apt-get` GETs `Release` (or `InRelease`) from `pkgs.k8s.io`, hands it to **GPG** which checks the signature against your keyring — ✓ or the whole update aborts with `NO_PUBKEY`. On success it GETs `Packages.gz` and caches the verified catalog under `/var/lib/apt/lists/`. **No packages downloaded yet.**
4. **`apt-get install kubelet=1.28.5-1.1 ...` runs.** The **resolver** reads the cached catalog, sees the exact version you named, computes the dependency closure (kubernetes-cni, cri-tools), downloads each `.deb` to `/var/cache/apt/archives/`, and **verifies each file's sha256 against the catalog** (which GPG already vouched for). It then hands each verified archive to **`dpkg`**, which unpacks it, runs the `postinst` maintainer script (drops the systemd unit, etc.), copies `/usr/bin/kubelet` into place, and **records the exact file list** into `/var/lib/dpkg/info/kubelet.list` while updating `/var/lib/dpkg/status`.
5. **`apt-mark hold ...` runs.** It flips the state flag for each package in `/var/lib/dpkg/status` to `hold`. From now on, any `apt-get upgrade` sees that flag and **leaves kubelet exactly where it is**. Your node's version is now under your control, not the distro's.

The kubelet systemd unit (see [systemd-services](16-systemd-services.md)) that `kubeadm` later enables? It runs `/usr/bin/kubelet` — the very binary this trace placed and froze.

> **Check yourself before Rung 6:** In the trace, GPG verified the signature in step 3 but the individual package sha256 was checked in step 4. Why are there *two* checks and not one? What attack does each one stop that the other doesn't?

---

## ⚖️ Rung 6 — The Contrast

The alternative to a package manager is **installing a raw binary by hand** — `curl` the file, verify it yourself, drop it in PATH. This is not a legacy anti-pattern; for Kubernetes it's a *first-class, recommended* path for tools like `kubectl` and `crictl`, because they're single static Go binaries with no dependencies and their own release cadence.

**What a package manager gives you that a raw binary doesn't:**
- **Dependency resolution** — matters for `containerd`/`runc` (which have shared-lib and config coupling), irrelevant for a static `kubectl`.
- **Automatic trust** — the GPG chain verifies signatures for you; with a raw binary *you* must fetch and check the checksum by hand.
- **A receipt** — `dpkg`/`rpm` know the file exists and can remove it cleanly; a hand-dropped binary is invisible to the database (`dpkg -l kubectl` finds nothing).
- **Fleet-wide upgrades** — `apt-get upgrade` patches everything; raw binaries you re-`curl` one at a time.

**What a raw binary gives you that a package doesn't:**
- **Exact version, instantly, decoupled from any repo's packaging schedule** — grab precisely the `kubectl` that matches your cluster, today, without waiting for a `.deb` to be published.
- **No repo/keyring setup** — one `curl` on an air-gapped-adjacent or minimal box.
- **Trivial multi-version coexistence** — keep `kubectl-1.27` and `kubectl-1.29` side by side under different names; packaging fights you on that.

| Dimension | Package manager (apt/dnf) | Raw binary (curl + checksum + install) |
|---|---|---|
| Dependency handling | Automatic (resolver) | None — you assume it's self-contained |
| Trust mechanism | GPG-signed repo, automatic | Manual `sha256sum --check` against published hash |
| Uninstall / inventory | Clean, tracked in DB | Manual `rm`; invisible to `dpkg -l`/`rpm -qa` |
| Version pinning | `apt-mark hold` / `versionlock` | Inherent — you placed exactly one file |
| Best for | kubelet, kubeadm, containerd, runc, CNI | kubectl, crictl, helm, standalone Go tools |
| Fleet upgrades | One command, all packages | Per-binary, scripted yourself |
| Setup cost | Add repo + keyring first | Zero — just curl |

**When would I NOT use a package manager?** When the software is a single static binary with no dependencies, you need a very specific version *now*, or there's simply no package for it (many CNCF tools ship as GitHub-release tarballs only). Then the raw-binary path with a **mandatory checksum check** is correct and safe.

**Why this over that (one sentence):** Use the package manager for anything with dependencies or that must move in lockstep with the fleet (**kubelet, kubeadm, containerd**), and use the verified-raw-binary path for self-contained client tools you want pinned to an exact release (**kubectl, crictl**) — and in both cases the non-negotiable is *verified trust plus a deliberate, frozen version*.

> **Check yourself before Rung 7:** You need `kubelet` AND `kubectl` on a node. Which one belongs to which install method, and *why* does the method split fall exactly along that line? (Think about dependencies and about who consumes each binary.)

---

## 🧪 Rung 7 — The Prediction Test

Now the hands-on. For each, **commit to the prediction out loud before you run the command.** The value is in being wrong on paper, where it's free. These assume Ubuntu 22.04 (apt) except where noted; RHEL variants are shown.

> ⚠️ These commands modify system state and need `root` (prefix with `sudo`). Run them on a throwaway VM or a node you're building, not a production box you care about.

### Prediction 1 — The normal case: exact-version install then freeze (apt)

**Prediction:** *If I add the Kubernetes repo with a scoped keyring, install kubelet/kubeadm/kubectl at an exact version, and then `apt-mark hold` them, THEN a subsequent `apt-get upgrade` will report those three as "kept back" and leave them on 1.28.5-1.1 — BECAUSE the `hold` state flag in `/var/lib/dpkg/status` tells the resolver they are immovable.*

```bash
# 1. Prereqs and the keyrings directory (0755 so apt can read it)
apt-get update
apt-get install -y curl jq gpg
mkdir -p -m 0755 /etc/apt/keyrings

# 2. Fetch the repo's public key, de-armor it into a scoped keyring
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# 3. Add the source line, binding THIS repo to THAT keyring only
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list

# 4. Sync the (now-trusted) catalog
apt-get update
# ...  Get:5 https://pkgs.k8s.io/core:/stable:/v1.28/deb  InRelease [1189 B]   ← signature verified

# 5. Install the EXACT versions (note the =version suffix — this is the whole game)
apt-get install -y kubelet=1.28.5-1.1 kubeadm=1.28.5-1.1 kubectl=1.28.5-1.1

# 6. Freeze them
apt-mark hold kubelet kubeadm kubectl
# kubelet set on hold.
# kubeadm set on hold.
# kubectl set on hold.
```

**Verify:**
```bash
apt-mark showhold
# kubelet
# kubeadm
# kubectl
dpkg -l kubelet | grep '^hi'    # 'h'=hold, 'i'=installed  ← the state flags, straight from the DB
# hi  kubelet   1.28.5-1.1   amd64  ...
apt-get upgrade                 # dry-run mentally, or run it
# The following packages have been kept back:
#   kubeadm kubectl kubelet     ← proof the hold worked
```
A wrong result — kubelet showing as *upgraded* — would tell you the hold flag never got set (typo in the package name, or you ran `hold` before the install so it applied to nothing). If `apt-get update` had failed with `NO_PUBKEY`, that would teach you the keyring/`signed-by` wiring is broken, not the install.

### Prediction 2 — The edge/failure case: what an unpinned upgrade does, and what a missing exact version does

**Prediction A:** *If I install kubelet WITHOUT a version and WITHOUT a hold, THEN a later `apt-get update && apt-get upgrade` can silently bump its minor version — BECAUSE with no hold flag the resolver always moves to the newest version the catalog offers.* This is the 02:00-pager scenario, reproduced on purpose.

**Prediction B:** *If I ask for a version string that isn't in the catalog, THEN apt refuses with a specific error and installs nothing — BECAUSE the resolver only offers versions present in the cached metadata.*

```bash
# B — ask for a version that doesn't exist
apt-get install -y kubelet=1.28.99-1.1
# E: Version '1.28.99-1.1' for 'kubelet' was not found     ← nothing installed, system unchanged

# See which versions ACTUALLY exist in the catalog before you pick:
apt-cache madison kubelet
#  kubelet | 1.28.5-1.1 | https://pkgs.k8s.io/.../v1.28/deb  Packages
#  kubelet | 1.28.4-1.1 | https://pkgs.k8s.io/.../v1.28/deb  Packages
```

To *demonstrate* Prediction A safely, first release the hold and watch the difference (do this only on a throwaway node):
```bash
apt-mark unhold kubelet
apt-get install --only-upgrade kubelet   # now nothing protects it; it jumps to newest in v1.28 repo
# Re-freeze immediately:
apt-mark hold kubelet
```

**Verify:** In case B, `dpkg -l kubelet` still shows the *previously* installed version — a failed resolve is atomic, it changes nothing. That teaches you that a bad version string is a safe, loud failure, not a silent partial install. In case A, comparing `kubelet --version` before and after the unhold-upgrade shows the drift you're paying `apt-mark hold` to prevent — the whole reason pinning is non-negotiable for nodes.

### Prediction 3 — The Kubernetes raw-binary case: install kubectl with checksum verification, and prove tamper detection

**Prediction:** *If I download the kubectl binary, download its published `.sha256`, and run `sha256sum --check`, THEN it prints "kubectl: OK" and only then do I install it 0755 root-owned into PATH — BECAUSE the checksum is my manual stand-in for the GPG chain a repo would have given me. If the file were altered by even one byte, `--check` prints "FAILED" and I must NOT install it.*

```bash
# 1. Download the binary and its checksum for a pinned version + arch
curl -LO "https://dl.k8s.io/release/v1.28.5/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/v1.28.5/bin/linux/amd64/kubectl.sha256"

# 2. Verify — this is the trust step you MUST NOT skip
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
# kubectl: OK        ← trust established; a raw binary with a matching official hash

# 3. Only NOW install it: copy + chown root:root + chmod 0755, atomically
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# 4. Confirm it runs and is on PATH
kubectl version --client
# Client Version: v1.28.5
```

Now **prove the failure mode** — corrupt the binary and watch the guard fire:
```bash
echo "tampered" >> kubectl          # one appended line = different hash
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
# kubectl: FAILED
# sha256sum: WARNING: 1 computed checksum did NOT match      ← DO NOT install this
```

**RHEL note:** the raw-binary flow is byte-identical (`sha256sum`, `install` are coreutils, present everywhere). Only the *repo* path differs — see Prediction below.

**Verify:** `ls -l /usr/local/bin/kubectl` should read `-rwxr-xr-x 1 root root` — that's `install -m 0755 -o root -g root` doing copy+chmod+chown in one shot, so there's never a window where the file exists but is world-writable. If `--check` prints `FAILED`, the correct response is to **stop** — you've either got a truncated download or a tampered file, and installing it would put unverified code in the path your kubeconfig's admin credentials run against. That's the entire reason the checksum step is mandatory, not optional.

### Prediction 4 (bonus) — The RHEL twin: install and lock on dnf/yum

**Prediction:** *If I write a `.repo` file with `gpgcheck=1`, install kubelet, then `yum versionlock add kubelet`, THEN a `yum update` will exclude kubelet — BECAUSE versionlock injects an exclude rule the resolver honors, exactly as `apt-mark hold` sets a flag apt honors.*

```bash
# 1. Declare the repo (INI format) — note gpgkey and gpgcheck=1
cat <<'EOF' > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
EOF

# 2. Install (dnf refreshes metadata automatically). --disableexcludes lets k8s pkgs through
#    on distros that exclude them by default.
yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

# 3. Lock the versions (install the plugin first on older systems)
yum install -y python3-dnf-plugin-versionlock   # or 'yum-plugin-versionlock' on RHEL 7
yum versionlock add kubelet kubeadm kubectl
```

**Verify:**
```bash
yum versionlock list
#   kubelet-0:1.28.5-*
#   kubeadm-0:1.28.5-*
#   kubectl-0:1.28.5-*
rpm -qa | grep -E 'kubelet|kubeadm|kubectl'    # the low-level DB confirms what's installed
# kubelet-1.28.5-150500.1.1.x86_64
yum update kubelet
# No packages marked for update    ← the lock held, mirror image of apt's "kept back"
```
A wrong result — `yum update` proposing a kubelet bump — would tell you the versionlock plugin isn't loaded (the `yum install ...versionlock` step was skipped), which is the RHEL analog of running `apt-mark hold` on a package that isn't there.

---

## 🏔 Rung 8 — Capstone: Compress It

**One-sentence summary (no notes):** Package management is a signed supply chain — a trusted remote catalog of versioned archives, a resolver that installs the exact files you asked for, and a local receipt with a freeze flag — and for Kubernetes the whole discipline reduces to *install the precise kubelet/kubeadm/kubectl you meant, verify it, and hold it so nothing ever moves it under you.*

**Explain it to a beginner in three sentences:** Instead of downloading random programs and copying files around by hand, your Linux distro runs a trusted "app store" for the command line: signed servers publish a catalog, and a tool (`apt` or `dnf`) reads it, checks the signatures, and installs exactly what you asked for while keeping a list of every file it placed. Because it keeps that list, it can also *freeze* a program at one version — which is critical for Kubernetes, where the `kubelet` running your node must stay on the exact version you chose and never get silently upgraded, or the node breaks. When there's no package, you download the single binary yourself, check its published SHA-256 fingerprint to prove it wasn't tampered with, and install it with the right permissions.

**Sub-capabilities mapped to the one core idea (*signed catalog → resolver → local receipt → freeze flag*):**
| Sub-capability | Where it hangs off the core idea |
|---|---|
| `apt-get update` / `dnf` metadata refresh | Sync + verify the **signed catalog** |
| Adding a repo + keyring (`signed-by`, `.repo` `gpgkey`) | Choosing **which signed catalog** to trust |
| `apt-get install pkg=version` / `yum install` | The **resolver** turning a wish into exact files |
| `dpkg -l` / `rpm -qa` | Reading the **local receipt** |
| `apt-mark hold` / `yum versionlock` | Setting the **freeze flag** — the K8s-critical move |
| `curl -LO` + `sha256sum --check` + `install -m 0755` | The **manual** version of the same chain when there's no repo |

**Which rung to revisit hands-on:** **Rung 7, Predictions 1 and 3.** The muscle memory that actually saves your nodes is (1) the exact-version-install-then-`apt-mark hold` sequence, and (3) the `sha256sum --check` habit before dropping any raw binary into PATH. If you can reproduce those two from memory on a throwaway VM — including deliberately triggering the `kept back` message and the `FAILED` checksum — you own this concept. Revisit **Rung 3** (the machinery diagram) any time you're unsure *why* a broken keyring or a stale catalog is causing an install to misbehave.

---

## Related concepts

- [tls-pki-openssl](26-tls-pki-openssl.md) — GPG repo signing and `sha256sum` verification are the same chain-of-trust idea as x509; both answer "is this really from who it claims?"
- [permissions-ownership](05-permissions-ownership.md) — `install -o root -g root -m 0755` is copy + chown + chmod; understanding the rwx model is why 0755 (not 0777) is correct for a binary.
- [systemd-services](16-systemd-services.md) — the kubelet package drops a systemd unit; a package's maintainer scripts often `systemctl daemon-reload` and enable services.
- [shell-and-environment](02-shell-and-environment.md) — whether `kubectl` runs after install is a PATH question; packages target `/usr/bin`, raw binaries usually `/usr/local/bin`.
- [linux-philosophy](01-linux-philosophy.md) — a package is just files, and the install database (`/var/lib/dpkg`, `/var/lib/rpm`) is just more files you can read.
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — where package pinning sits in the full node-triage picture alongside cgroups, namespaces, and systemd.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** `make install` and `apt-get install` both end with files on disk. What is the one thing `apt` does that `make install` fundamentally cannot, and why does it make a fleet manageable?

**A:** `apt` **records a receipt** — it writes the exact inventory of every file it placed (plus name, version, and state flags) into the local package database at `/var/lib/dpkg/`. `make install` copies files wherever it likes and leaves no record, so you can never later answer "what is installed, at what version, and which files belong to it." That receipt is what makes a fleet manageable: it enables exact removal, version queries (`dpkg -l`), audit of what changed, fleet-wide upgrades, and freeze flags like `apt-mark hold` — none of which are possible when nothing remembers what was installed. (The signed-catalog trust chain and dependency resolution also come with `apt`, but the local database is the foundational thing `make install` structurally lacks.)

### Before Rung 3
**Q:** Predict what `apt-get update` downloads versus what `apt-get install` downloads. Which touches the catalog and which the archives, and why must they be separate steps?

**A:** `apt-get update` downloads only the **catalog** — `Release`/`InRelease` and `Packages.gz`, i.e. the signed metadata listing every package, version, dependency, and checksum — verifies the GPG signature against your keyring, and caches it under `/var/lib/apt/lists/`. It installs nothing. `apt-get install` touches the **archives**: the resolver reads that cached catalog, computes the dependency closure, downloads the actual `.deb` files into `/var/cache/apt/archives/`, verifies each sha256 against the catalog, and hands them to `dpkg`. They must be separate because the box needs to know *what exists and what to trust* before it can sensibly resolve and fetch anything — the catalog is the source of the versions, dependencies, and checksums the install step validates against, and syncing it is a distinct, signature-verified event; skip it and you resolve against yesterday's stale catalog.

### Before Rung 4
**Q:** A colleague runs `dpkg -i ./kubelet_1.28.5-1.1_amd64.deb` directly and it "works." Name two things they did not get — one about dependencies, one about trust.

**A:** Dependencies: `dpkg` is the dumb low-level installer — it does **no dependency resolution**. It will unpack the package even if dependencies (kubernetes-cni, conntrack, socat, ...) are missing, leaving the system "half-configured" instead of computing and installing the full dependency closure the way apt's resolver does. Trust: they skipped the verification chain — `apt-get install` verifies the repo's GPG-signed catalog and then checks each downloaded `.deb`'s sha256 against that catalog before handing it to dpkg; a hand-supplied `.deb` fed straight to `dpkg -i` is installed with no signature or checksum check at all, so nothing proves it is the genuine artifact.

### Before Rung 5
**Q:** `apt` and `apt-get` are "the same kind of thing." Why does every Kubernetes install runbook say `apt-get` and never `apt`?

**A:** Because runbooks are scripts (or destined to become scripts), and scripts parse output. `apt` is the newer human-friendly front-end with progress bars and an output format that may change between releases — it even warns that its CLI is not stable for scripting. `apt-get` is the older, stable, script-safe interface whose output format is guaranteed stable, so automation built on it keeps working across upgrades. Same resolver underneath; the choice is purely about interface stability in automation.

### Before Rung 6
**Q:** GPG verified the signature in step 3 but each package's sha256 was checked in step 4. Why two checks, and what attack does each stop that the other doesn't?

**A:** The GPG check in step 3 authenticates the **catalog**: it proves `Release`/`Packages.gz` really came from the repo owner's private key, stopping a forged or tampered catalog (a malicious mirror or man-in-the-middle publishing fake metadata pointing at malicious versions). But the signature covers only the metadata, not the multi-megabyte `.deb` files themselves. The sha256 check in step 4 extends that trust to the **archives**: each downloaded `.deb` is hashed and compared against the checksum the (already-verified) catalog vouches for, stopping a tampered, substituted, or corrupted package file served in place of the real one. Together they form the transitive chain: trusted key → signed `Release` → checksummed `Packages.gz` → checksummed `.deb` — one trusted signature securing every byte, but only if both links are checked.

### Before Rung 7
**Q:** You need `kubelet` AND `kubectl` on a node. Which install method for each, and why does the split fall exactly there?

**A:** `kubelet` goes through the **package manager** (repo + exact version + `apt-mark hold`): it has real dependencies (kubernetes-cni, conntrack, coupling to containerd/runc), ships a systemd unit via maintainer scripts, and is load-bearing node infrastructure that must move in lockstep with the fleet and the control-plane version — exactly what the resolver, receipt, and hold flag exist for. `kubectl` fits the **raw-binary path** (`curl` + `sha256sum --check` + `install -m 0755`): it is a single static Go binary with zero dependencies, consumed by a human operator rather than by the node itself, and you often want a precise release matching your cluster instantly (or several versions side by side) without depending on a repo's packaging schedule. The line falls exactly at "has dependencies and must be fleet-managed" versus "self-contained client tool you pin yourself" — and on both sides the non-negotiables are verified trust and a deliberately frozen version.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — several setups need `sudo` and some deliberately break things. For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6.

### 🟢 Scenario 1 — "Pune: who put this binary here?" (Easy)
**Setup:**
```bash
mkdir -p /tmp/lab-audit
echo "/usr/bin/mawk" > /tmp/lab-audit/flagged-binary.txt
cat /tmp/lab-audit/flagged-binary.txt
```
**Situation:** A security scan of the Pune node flagged the binary listed in `/tmp/lab-audit/flagged-binary.txt` as "origin unknown". Your lead wants proof from the package database — the receipt, not a guess — of which package placed that file and exactly which version of it is installed.

**Your task:** Query the dpkg database to find the owning package and its exact installed version, then write one line in the form `<package> <version>` to `/tmp/lab-pkg-owner`.

**Verify:**
```bash
[ "$(cat /tmp/lab-pkg-owner)" = "mawk $(dpkg-query -W -f='${Version}' mawk)" ] && echo "SOLVED - receipt matches the database"
# expected: "SOLVED - receipt matches the database"
```

### 🟢 Scenario 2 — "Jaipur: the hold nobody owns" (Easy)
**Setup:**
```bash
sudo apt-mark hold tar mawk
mkdir -p /tmp/lab-audit
echo "policy: only 'tar' is approved to carry an apt hold on this node" > /tmp/lab-audit/hold-policy.txt
```
**Situation:** During a fleet audit of the Jaipur nodes you must reconcile apt **holds** against policy. The policy file (`/tmp/lab-audit/hold-policy.txt`) approves exactly one held package. Somebody has quietly frozen something else too — the kind of stray flag that one day makes a security patch silently skip a package.

**Your task:** List every package currently on hold, compare against the policy, and release **only** the unapproved hold. The approved one must stay frozen.

**Verify:**
```bash
apt-mark showhold | grep -qx mawk && echo "NOT SOLVED - mawk still held" || { apt-mark showhold | grep -qx tar && echo "SOLVED - only the approved hold remains"; }
# expected: "SOLVED - only the approved hold remains"
```

### 🟡 Scenario 3 — "Lucknow: the catalog that won't sync" (Medium)
**Setup:**
```bash
echo 'deb [trusted=yes] http://127.0.0.1:8599/lab-repo stable main' | sudo tee /etc/apt/sources.list.d/lab-internal.list
sudo apt-get update 2>&1 | tail -3
```
**Situation:** Overnight, every `apt-get update` on the Lucknow build box started failing, so this morning's security-patch automation is red across the board. A teammate vaguely remembers "adding our internal mirror" last week. The internal mirror project was cancelled — its server no longer exists.

**Your task:** Diagnose why the catalog sync fails, identify exactly which source definition is at fault, remove (or disable) it, and get `apt-get update` completing successfully again.

**Verify:**
```bash
sudo apt-get update >/dev/null 2>&1 && echo "SOLVED - catalog syncs cleanly" || echo "NOT SOLVED - update still failing"
# expected: "SOLVED - catalog syncs cleanly"
```

### 🟡 Scenario 4 — "Nagpur: the uninvited package" (Medium)
**Setup:**
```bash
mkdir -p /tmp/lab-widget-build/DEBIAN /tmp/lab-widget-build/opt/lab-widget
printf 'Package: lab-widget\nVersion: 1.0-1\nArchitecture: all\nMaintainer: Lab <lab@devopsinminutes.com>\nDescription: mystery lab widget (troubleshooting lab)\n' > /tmp/lab-widget-build/DEBIAN/control
echo "/opt/lab-widget/widget.conf" > /tmp/lab-widget-build/DEBIAN/conffiles
echo "mode=chaos" > /tmp/lab-widget-build/opt/lab-widget/widget.conf
printf '#!/bin/sh\nexec sleep infinity\n' > /tmp/lab-widget-build/opt/lab-widget/widgetd
chmod +x /tmp/lab-widget-build/opt/lab-widget/widgetd
dpkg-deb --build --root-owner-group /tmp/lab-widget-build /tmp/lab-widget_1.0-1_all.deb
sudo dpkg -i /tmp/lab-widget_1.0-1_all.deb
rm -rf /tmp/lab-widget-build
ls /opt/lab-widget/
```
**Situation:** Files nobody recognizes have appeared under `/opt/lab-widget/` on the Nagpur node: a daemon and a config. Nothing in your team's deploy history mentions them. Before you may delete anything, change control demands you (a) prove from the dpkg receipts which package owns these files and what else it shipped, and (b) remove it **completely** — receipts, config file and all — leaving zero trace on disk or in the database.

**Your task:** Use the dpkg database to map the mystery files to their package, inspect the package's full file inventory and status, then remove it so thoroughly that the database no longer knows it and `/opt/lab-widget` is gone. (Hint: plain "remove" is not enough — find out why.)

**Verify:**
```bash
dpkg -s lab-widget >/dev/null 2>&1 && echo "NOT SOLVED - still in the dpkg database" || { [ ! -e /opt/lab-widget ] && echo "SOLVED - purged, receipts and files gone"; }
# expected: "SOLVED - purged, receipts and files gone"
```

### 🟠 Scenario 5 — "Indore: the version that must not move" (Hard)
**Setup:**
```bash
sudo apt-get update -qq && sudo apt-get install -y -qq dpkg-dev
sudo mkdir -p /opt/lab-repo
for V in 1.0-1 2.0-1; do
  rm -rf /tmp/lab-agent-build
  mkdir -p /tmp/lab-agent-build/DEBIAN /tmp/lab-agent-build/opt/lab-agent
  printf 'Package: lab-agent\nVersion: %s\nArchitecture: all\nMaintainer: Lab <lab@devopsinminutes.com>\nDescription: lab node agent (troubleshooting lab)\n' "$V" > /tmp/lab-agent-build/DEBIAN/control
  echo "lab-agent $V" > /tmp/lab-agent-build/opt/lab-agent/BUILD
  dpkg-deb --build --root-owner-group /tmp/lab-agent-build "/tmp/lab-agent_${V}_all.deb" >/dev/null
  sudo mv "/tmp/lab-agent_${V}_all.deb" /opt/lab-repo/
done
rm -rf /tmp/lab-agent-build
( cd /opt/lab-repo && dpkg-scanpackages --multiversion . /dev/null > /tmp/lab-Packages )
gzip -9c /tmp/lab-Packages | sudo tee /opt/lab-repo/Packages.gz >/dev/null && rm -f /tmp/lab-Packages
echo 'deb [trusted=yes] file:/opt/lab-repo ./' | sudo tee /etc/apt/sources.list.d/lab-repo.list
sudo apt-get update -qq
sudo apt-get install -y -qq lab-agent=1.0-1
dpkg -l lab-agent | tail -1
```
**Situation:** `lab-agent` is this node's stand-in for kubelet: the Indore control plane only speaks to agents on **1.0**, but the team's internal repo now also publishes **2.0**. A nightly `apt-get upgrade` job runs on every node at 03:00. Tonight, unprotected, this node's agent drifts to 2.0 and the node goes `NotReady` — the exact 02:00-pager story from Rung 0, reproduced in miniature.

**Your task:** First prove from the catalog which versions the repo offers and which one is the upgrade candidate (`apt-cache madison` / `apt-cache policy`). Then freeze `lab-agent` at `1.0-1` the way you would freeze kubelet, and demonstrate that even an explicit upgrade attempt cannot move it.

**Verify:**
```bash
sudo apt-get install --only-upgrade -y lab-agent >/dev/null 2>&1; [ "$(dpkg-query -W -f='${Version}' lab-agent)" = "1.0-1" ] && apt-mark showhold | grep -qx lab-agent && echo "SOLVED - lab-agent frozen at 1.0-1"
# expected: "SOLVED - lab-agent frozen at 1.0-1" (the upgrade attempt bounced off the hold)
```

### 🔴 Scenario 6 — "Amritsar: the half-configured hostage" (Expert)
**Setup:**
```bash
mkdir -p /tmp/lab-daemon-build/DEBIAN /tmp/lab-daemon-build/opt/lab-daemon
printf 'Package: lab-daemon\nVersion: 3.1-2\nArchitecture: all\nMaintainer: Lab <lab@devopsinminutes.com>\nDescription: lab background daemon (troubleshooting lab)\n' > /tmp/lab-daemon-build/DEBIAN/control
cat > /tmp/lab-daemon-build/DEBIAN/postinst <<'EOF'
#!/bin/sh
set -e
if [ ! -f /opt/lab-daemon/LICENSE-ACCEPTED ]; then
  echo "lab-daemon: FATAL: /opt/lab-daemon/LICENSE-ACCEPTED not found" >&2
  exit 1
fi
exit 0
EOF
chmod 0755 /tmp/lab-daemon-build/DEBIAN/postinst
printf '#!/bin/sh\nexec sleep infinity\n' > /tmp/lab-daemon-build/opt/lab-daemon/daemon.sh
chmod +x /tmp/lab-daemon-build/opt/lab-daemon/daemon.sh
dpkg-deb --build --root-owner-group /tmp/lab-daemon-build /tmp/lab-daemon_3.1-2_all.deb
sudo dpkg -i /tmp/lab-daemon_3.1-2_all.deb || true
rm -rf /tmp/lab-daemon-build
sudo apt-get install -f -y 2>&1 | tail -4
```
**Situation:** A vendor emailed the Amritsar team a `.deb` and someone installed it straight with `dpkg -i` (skipping apt — remember what that skips). Its install script failed halfway, and now the package is wedged in a half-configured state that **every** apt operation trips over: upgrades, installs of unrelated packages, the nightly patch job — all ending in `Sub-process /usr/bin/dpkg returned an error code (1)`. The whole package pipeline on this node is hostage to one broken maintainer script.

**Your task:** Diagnose the package state from the dpkg database (`dpkg -l` state letters, `dpkg --audit`), find and read the failing maintainer script under `/var/lib/dpkg/info/`, understand exactly why it exits non-zero, and un-wedge the node — either by satisfying the script's requirement and completing configuration, or by purging the package. Every pending package must end up configured and the database clean.

**Verify:**
```bash
sudo dpkg --configure -a >/dev/null 2>&1; [ -z "$(dpkg --audit)" ] && echo "SOLVED - dpkg database healthy again" || dpkg --audit
# expected: "SOLVED - dpkg database healthy again"
```

---

## 🔑 Lab Answers — Solutions & Explanations

### 🟢 Scenario 1 — "Pune: who put this binary here?"
**Solution:**
```bash
dpkg -S /usr/bin/mawk                     # -> "mawk: /usr/bin/mawk"  (file -> owning package)
dpkg-query -W -f='${Package} ${Version}\n' mawk   # exact installed version from the receipt DB
echo "mawk $(dpkg-query -W -f='${Version}' mawk)" > /tmp/lab-pkg-owner
# (RHEL twin: rpm -qf /usr/bin/mawk)
```
**Why this works & what it teaches:** `dpkg -S` greps the per-package file inventories under `/var/lib/dpkg/info/*.list` — the exact receipts Rung 3 says dpkg writes at install time — so the answer is the *database's* testimony, not a guess. `dpkg -l`/`dpkg-query -W` read the master inventory `/var/lib/dpkg/status` for the version. Where people go wrong: answering from `mawk --version` (that asks the binary, not the supply chain) — an attacker's replaced binary would happily lie, but the receipt says what apt actually placed.
**Cleanup:** `rm -rf /tmp/lab-audit /tmp/lab-pkg-owner`

### 🟢 Scenario 2 — "Jaipur: the hold nobody owns"
**Solution:**
```bash
apt-mark showhold                         # -> tar, mawk : two frozen packages
cat /tmp/lab-audit/hold-policy.txt        # policy approves only 'tar'
dpkg -l tar mawk | grep '^h'              # 'hi' = hold+installed, the flag in /var/lib/dpkg/status
sudo apt-mark unhold mawk                 # release ONLY the unapproved one
apt-mark showhold                         # -> tar alone remains
```
**Why this works & what it teaches:** A hold is nothing mystical — it is a **state flag** in the local receipt database (`Status: hold ok installed` in `/var/lib/dpkg/status`, the `hi` you see in `dpkg -l`), and `apt-mark showhold`/`unhold` are just reads/writes of that flag. This is Rung 2's "freeze" move in reverse: holds are how kubelet stays put, but *forgotten* holds are how a CVE patch silently skips a package for months. Where people go wrong: `apt-mark unhold` on both packages — the task (like real policy work) is surgical, not wholesale.
**Cleanup:** `sudo apt-mark unhold tar; rm -rf /tmp/lab-audit`

### 🟡 Scenario 3 — "Lucknow: the catalog that won't sync"
**Solution:**
```bash
sudo apt-get update
# Err: http://127.0.0.1:8599/lab-repo stable InRelease -> "Could not connect ... 8599"
# E: Some index files failed to download.        <- the whole update exits non-zero
grep -r 8599 /etc/apt/sources.list /etc/apt/sources.list.d/
# -> /etc/apt/sources.list.d/lab-internal.list : the dead internal mirror
sudo rm /etc/apt/sources.list.d/lab-internal.list    # (or comment the 'deb' line out)
sudo apt-get update                        # all sources now fetch; exit code 0
```
**Why this works & what it teaches:** Rung 3's part 3: the files under `/etc/apt/sources.list.d/` are the *only* place repos are declared, so a failing `apt-get update` is always traceable to one `deb` line — and because `update` must fetch and verify **every** configured catalog, one dead repo turns the whole catalog sync red and breaks automation fleet-wide. Removing the drop-in file is the entire fix; `update` then caches fresh verified catalogs under `/var/lib/apt/lists/`. Where people go wrong: "fixing" it with `apt-get update --allow-...` flags or ignoring the red output — automation checks exit codes, and stale catalogs mean you install yesterday's versions (Rung 3, part 4).
**Cleanup:** already clean — the fix removed the only state the setup added.

### 🟡 Scenario 4 — "Nagpur: the uninvited package"
**Solution:**
```bash
dpkg -S /opt/lab-widget/widgetd           # -> "lab-widget: /opt/lab-widget/widgetd"
dpkg -l lab-widget                        # ii  lab-widget  1.0-1  (installed, from the status DB)
dpkg -L lab-widget                        # full shipped inventory: widget.conf + widgetd
cat /var/lib/dpkg/info/lab-widget.list    # the raw receipt behind dpkg -L
sudo dpkg -P lab-widget                   # PURGE - not 'dpkg -r'
# why not -r? try it: dpkg -r leaves widget.conf behind, because it is a registered
# conffile, and dpkg -s would still show "deinstall ok config-files"
ls /opt/lab-widget 2>/dev/null            # gone
```
**Why this works & what it teaches:** This is the receipt machinery end to end: `dpkg -S` maps file→package, `dpkg -L` package→files, both reading `/var/lib/dpkg/info/*.list` — the "exact removal is possible because the receipt is exact" promise of Rung 2. The twist is remove-vs-purge: `widget.conf` was declared a **conffile**, and `dpkg -r` deliberately keeps conffiles (state `rc`/"config-files") so a reinstall preserves config — only `dpkg -P` (purge) deletes them and erases the package from the database entirely. Where people go wrong: `rm -rf /opt/lab-widget` first — files vanish but the database still lists the package, and the audit finding ("zero trace in the database") stays open.
**Cleanup:** `rm -f /tmp/lab-widget_1.0-1_all.deb`

### 🟠 Scenario 5 — "Indore: the version that must not move"
**Solution:**
```bash
apt-cache madison lab-agent               # catalog offers: 2.0-1 and 1.0-1, from file:/opt/lab-repo
apt-cache policy lab-agent                # Installed: 1.0-1   Candidate: 2.0-1  <- tonight's drift
sudo apt-mark hold lab-agent              # set the freeze flag - the kubelet move
dpkg -l lab-agent | grep '^hi'            # hi = hold + installed, straight from /var/lib/dpkg/status
sudo apt-get install --only-upgrade -y lab-agent
# E: Held packages were changed and -y was used without --allow-change-held-packages.
dpkg-query -W lab-agent                   # still 1.0-1
```
**Why this works & what it teaches:** `apt-cache madison`/`policy` read the cached catalog from `/var/lib/apt/lists/` — they show you what the resolver *would* do (candidate 2.0-1) before it does it. `apt-mark hold` flips the state flag in the receipt database, and from then on the resolver treats 1.0-1 as immovable: `upgrade` reports it "kept back", and even an explicit install-upgrade refuses without `--allow-change-held-packages`. This is Prediction 1 and 2 fused: the exact-version + hold discipline that keeps a kubelet at 1.28.5 while the repo publishes 1.29. Where people go wrong: holding *after* the nightly job has already bumped it — a hold pins whatever version is installed at that moment, so freeze at build time, not after the page.
**Cleanup:** `sudo apt-mark unhold lab-agent; sudo apt-get purge -y lab-agent; sudo rm -f /etc/apt/sources.list.d/lab-repo.list; sudo rm -rf /opt/lab-repo; sudo apt-get update`

### 🔴 Scenario 6 — "Amritsar: the half-configured hostage"
**Solution:**
```bash
dpkg -l lab-daemon                        # iF  lab-daemon  3.1-2   <- unpacked, Failed-config
dpkg --audit                              # "The following packages are only half configured..."
cat /var/lib/dpkg/info/lab-daemon.postinst
# -> the maintainer script demands /opt/lab-daemon/LICENSE-ACCEPTED and exits 1 without it
# Fix path A - satisfy the script, then let dpkg finish the interrupted configure:
sudo touch /opt/lab-daemon/LICENSE-ACCEPTED
sudo dpkg --configure -a                  # "Setting up lab-daemon (3.1-2) ..." -> now 'ii'
# Fix path B (if the package is unwanted junk) - eject it instead:
#   sudo dpkg -P lab-daemon
dpkg --audit                              # silence = healthy database
sudo apt-get install -f -y                # apt operations work again
```
**Why this works & what it teaches:** `dpkg -i` unpacks, then runs the package's **maintainer scripts** (Rung 3, part 5) — and a failing `postinst` strands the package in `iF` (half-configured), a state recorded in `/var/lib/dpkg/status` that apt refuses to step over: every later operation retries the configure and inherits the failure, which is why one bad vendor `.deb` hostages the whole node. The scripts live in plain sight under `/var/lib/dpkg/info/<pkg>.postinst`, so you can read *exactly* why it fails, satisfy it (or purge), and `dpkg --configure -a` — the low-level "finish what was interrupted" command apt itself tells you to run — completes the receipt. Where people go wrong: reinstalling or `apt-get -f install` in a loop without ever reading the script — apt can't fix what the script's own logic forbids; and note this whole mess began by feeding `dpkg -i` a `.deb` that never passed a signed catalog's checksum (the Rung 3 check-yourself).
**Cleanup:** `sudo dpkg -P lab-daemon 2>/dev/null; sudo rm -rf /opt/lab-daemon /tmp/lab-daemon_3.1-2_all.deb`

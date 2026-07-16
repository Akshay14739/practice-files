# SSH & Remote Access

*How one encrypted, authenticated tunnel becomes your shell on a node, your bridge to the API server, and your file pipe to a cluster — and why every `kubeadm` cluster is bootstrapped over it.*

---

## 🪜 Rung 0 — The Setup

**What am I learning?** SSH — the *Secure Shell* — the protocol and toolset that gives you an authenticated, encrypted, interactive shell (and much more) on a remote machine over an untrusted network. "SSH" is three things wearing one name: a **protocol** (how two hosts agree on keys and encrypt bytes), a **client** (`ssh`, `scp`, `rsync-over-ssh`), and a **server** (`sshd`, the daemon listening on TCP 22). You'll also learn its cousins: key-based auth, `~/.ssh/config`, port forwarding, and file transfer.

**Why did it land on my desk?** You're a Kubernetes platform engineer. `kubectl` is your daily driver, but `kubectl` only talks to the **API server** — and the API server can only tell you what Kubernetes *knows*. When a node goes `NotReady`, `kubectl describe node` says "kubelet stopped posting status" and then it goes dark, because the thing that reports status is the very thing that died. The only way in is to open a shell *on the node itself* and ask the OS directly: `journalctl -u kubelet`, `systemctl status containerd`, `df -h`, `dmesg`. That door is SSH. Beyond triage, SSH is woven through the whole platform lifecycle: `kubeadm` bootstraps a fresh control plane over SSH, you `scp` the admin kubeconfig back to your laptop, you `rsync` manifests to nodes, and you tunnel `ssh -L` to reach an internal dashboard or the API server from home.

**What do I already know already (assumed)?**
- From [networking](11-networking.md): TCP ports, `ss -tlnp`, that a server *listens* on a port and a client *connects* to it, DNS resolution, `127.0.0.1` vs a routable IP.
- From [permissions & ownership](05-permissions-ownership.md): the `rwx` model, `chmod 600`, why a file being *group-* or *world-readable* matters. SSH is famously strict about this.
- From [users, groups & sudo](06-users-groups-sudo.md): what a user account is, `~/` home directories, that `root` is uid 0.
- From [TLS/PKI](26-tls-pki-openssl.md) *(sibling)*: the idea of a public/private keypair and asymmetric crypto. SSH keys are the same math, different packaging.
- `kubectl` fluency, and that a node is just a Linux box running `kubelet` + `containerd`.

You do **not** need to already understand cryptography. That's the point — SSH hides it.

---

## 🔥 Rung 1 — The Pain

Rewind to the mid-1990s. You administer machines you cannot physically touch. To log in remotely you used **`telnet`**, **`rlogin`**, and **`rsh`** ("remote shell"), and to copy files, **`rcp`** and **FTP**. Every one of them sent *everything in cleartext* — including your password — across the wire.

```
THE PRE-SSH PAIN  (telnet / rlogin / rsh / ftp)

  admin laptop                    the network                    server
 ┌────────────┐    "login: root"  ~~~~~~~~~~~~~~~~~~   ┌────────────┐
 │  telnet ───┼──▶  "password: hunter2"  ◀── anyone   │   telnetd  │
 └────────────┘         with a packet sniffer          └────────────┘
                        reads your ROOT password
                        in plaintext, verbatim.
```

The specific ways this hurt:

- **Passwords on the wire.** Anyone on any hop between you and the server — a compromised switch, a coffee-shop Wi-Fi, a curious ISP — could run a sniffer and harvest credentials. In 1995 Tatu Ylönen at Helsinki University detected exactly such a password-sniffing attack on his network and wrote the first SSH in response.
- **No server identity.** `telnet` had no way to prove the machine answering was really *your* server. An attacker who could redirect traffic (DNS poisoning, ARP spoofing) could impersonate the server, collect your password, and man-in-the-middle everything. You had *authentication of neither party*.
- **`rsh`/`rlogin` "trust" was IP-based.** The `.rhosts` mechanism said "if the connection *claims* to come from host X as user Y, let them in." Source IPs are trivially forged. Trust built on spoofable addresses is no trust at all.
- **No integrity.** Even if you didn't care about secrecy, nothing detected a packet *modified* in flight. An attacker could inject commands into your session.

**What breaks without it, in Kubernetes terms?** Everything about running a real cluster. `kubeadm init` and every "join a node" workflow assume you have a *secure* shell to each machine — you would never bootstrap a control plane, or copy `/etc/kubernetes/admin.conf` (which contains a client cert that is effectively **root on the entire cluster**), over a cleartext channel. The moment that file crosses the network in the clear, your whole cluster is compromised. Node triage breaks too: the only reason it's safe to `ssh node "cat /var/lib/kubelet/config.yaml"` from your laptop is that SSH encrypts it. Strip SSH out and you're back to standing in the data center with a crash cart.

**Who feels the pain most?** The platform engineer who is *remote by definition*. Your nodes are in a VPC, a bare-metal rack three time zones away, or a managed cloud you never physically see. SSH is the primitive that makes "remote" safe enough to be your normal working mode.

> **Check yourself before Rung 2:** `telnet` and `ssh` both give you a shell prompt on a remote box. Name the *two distinct* guarantees SSH adds that `telnet` cannot — and say which one protects you from a passive eavesdropper and which from an active impersonator.

---

## 💡 Rung 2 — The One Idea

> **SSH is a negotiated, encrypted tunnel between two hosts that first proves *who each side is* using asymmetric keys, then carries *anything you like* — a shell, a copied file, or a forwarded TCP port — as opaque, tamper-proof bytes.**

Memorize that sentence. Everything else is derivation.

Derive the rest from it:

- *"Encrypted tunnel"* → before a single keystroke travels, client and server run a **key exchange** (Diffie-Hellman) to agree on a shared symmetric session key. Nobody watching the wire can derive it. This is *transport security* and it happens on **every** connection, even before you log in.
- *"Proves who each side is"* → **two** authentications, in two directions.
  - The **server** proves itself with its *host key* → this is what `known_hosts` records and why you see "The authenticity of host … can't be established" the first time.
  - **You** prove yourself with either a *password* or, far better, your *public key* → this is `authorized_keys`, `ssh-keygen`, `ssh-copy-id`.
- *"Asymmetric keys"* → a **keypair**: a *private* key you never share and a *public* key you scatter freely. Sign with private, verify with public. No shared secret ever crosses the wire, so there's nothing to sniff.
- *"Carries anything you like"* → once the tunnel exists, SSH multiplexes **channels** inside it. A channel can be an interactive shell, an `scp`/`rsync` file stream, or a **forwarded TCP connection** (`-L`, `-R`, `-D`). Port forwarding isn't a bolt-on; it's the same tunnel carrying a different channel.
- *"Opaque, tamper-proof"* → every packet carries a MAC (message authentication code), so a flipped bit is detected and the connection drops. Integrity comes free with the encryption.

If you internalize "**tunnel first, mutual identity second, arbitrary channels third**," the entire SSH surface — keys, config, forwarding, scp — is just those three ideas in different clothes.

> **Check yourself before Rung 3:** The One Idea packs three moves *in order* — encrypted tunnel, then mutual identity, then arbitrary channels. By the time you first see the "The authenticity of host … can't be established" prompt, which of the three has *already* completed, and which of the three is that prompt actually part of?

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

### 3.1 The cast: client, server daemon, and the files they read

SSH has a strict client/server split.

- On the machine you connect *to*, a daemon called **`sshd`** runs (usually a systemd unit, `ssh.service` on Debian/Ubuntu, `sshd.service` on RHEL). It **listens on TCP port 22** and is configured by **`/etc/ssh/sshd_config`**. Its own identity lives in **host keys** at `/etc/ssh/ssh_host_ed25519_key` (private) and `.pub` (public), generated once when the package installs.
- On the machine you connect *from*, you run the **`ssh`** client, configured per-user by **`~/.ssh/config`** and system-wide by `/etc/ssh/ssh_config`. Your identity lives in **your** keypair, conventionally `~/.ssh/id_ed25519` (private) and `~/.ssh/id_ed25519.pub` (public).

Two files do the bookkeeping that makes key auth work:

| File | Lives on | Holds | Answers the question |
|---|---|---|---|
| `~/.ssh/known_hosts` | **client** | *server* public host keys you've seen | "Is this the same server I trusted last time?" |
| `~/.ssh/authorized_keys` | **server** | *client* public keys allowed to log in as this user | "Is this person allowed in as me?" |

Notice the symmetry: `known_hosts` authenticates the **server to you**; `authorized_keys` authenticates **you to the server**. Same mechanism, opposite directions.

### 3.2 Asymmetric keys in one paragraph

A keypair is two mathematically linked blobs. Anything the **private** key signs, the **public** key can verify — and *only* that matching public key can. You keep the private key secret (mode `600`, never leaves the machine); you copy the public key everywhere. Authentication never sends the private key or a password over the wire. Instead the server sends a random challenge, you sign it with your private key, and the server checks the signature against the public key sitting in its `authorized_keys`. An eavesdropper sees a signature they cannot reuse and cannot reverse. This is why key auth is both **more secure** and **more convenient** than passwords — nothing sniffable ever crosses, and there's nothing to type.

**ed25519 vs rsa 4096.** These are the two key algorithms you'll actually pick:
- **`ed25519`** — a modern elliptic-curve key. Tiny (a 32-byte raw public key, one short line in the `.pub` file), fast, and considered very strong. This is the **default choice today**. `ssh-keygen -t ed25519`.
- **`rsa` with 4096 bits** — the older, universally-supported algorithm. Bigger and slower but works on *everything*, including ancient appliances and some hardware tokens that predate Ed25519. Reach for `ssh-keygen -t rsa -b 4096` only when a target is too old to speak ed25519. (Never use RSA below 2048; 1024 is broken.)

### 3.3 The handshake: what happens before you get a prompt

This is the whiteboard diagram to burn in. Follow a fresh `ssh ubuntu@node1` from cold.

```
   CLIENT (your laptop)                                SERVER (node1, sshd on :22)
   ┌───────────────────┐                               ┌───────────────────────┐
   │ ssh ubuntu@node1  │                               │  sshd listening :22   │
   └─────────┬─────────┘                               └───────────┬───────────┘
             │  1. TCP connect to node1:22                         │
             │────────────────────────────────────────────────────▶
             │  2. version banners "SSH-2.0-OpenSSH_9.x"           │
             │◀───────────────────────────────────────────────────▶
             │                                                     │
             │  3. KEY EXCHANGE (Diffie-Hellman)                   │
             │  ── agree on a shared SESSION KEY nobody else knows │
             │◀═══════════════════════════════════════════════════▶
             │      server also sends its HOST public key ─────────┤
             │                                                     │
   ┌─────────▼──────────┐  4. look up node1 in ~/.ssh/known_hosts  │
   │ known? → continue  │     unknown? → "authenticity can't be    │
   │ changed? → REFUSE  │      established… fingerprint SHA256:…?"  │
   └─────────┬──────────┘     (you type yes → append to known_hosts)
             │                                                     │
             │  ══════ from here ALL traffic is encrypted ═══════  │
             │                                                     │
             │  5. USER AUTH: client offers public key             │
             │────────────────────────────────────────────────────▶
             │        server checks ~ubuntu/.ssh/authorized_keys   │
             │        sends a random challenge to sign             │
             │◀────────────────────────────────────────────────────
             │  6. client signs challenge with PRIVATE key         │
             │────────────────────────────────────────────────────▶
             │        server verifies signature → ACCEPT           │
             │                                                     │
             │  7. open a CHANNEL: request a pty + shell           │
             │◀═══════════════ your prompt appears ═══════════════▶
   ubuntu@node1:~$                                                 │
```

The order matters and explains real symptoms:
- **Transport encryption (step 3) happens before authentication (step 5).** That's why even a *failed* login leaks nothing — your password/key attempt is already inside the encrypted tunnel.
- **The server proves itself (step 3–4) before you prove yourself (step 5–6).** You verify you're talking to the real node *before* you hand over any credential. That's the whole point of `known_hosts`.
- **The shell is just channel #1 (step 7).** Ports forwards and file transfers open *additional* channels inside the same tunnel.

### 3.4 Why file permissions are load-bearing

`sshd` and `ssh` both **refuse to work if key files are too open**, and they do it silently-ish (a cryptic error, then fallback to password or outright rejection). The rule: a private key or a directory that could expose one must not be readable by group or others.

```
~/.ssh/                       drwx------  (700)  only you may enter
~/.ssh/id_ed25519             -rw-------  (600)  PRIVATE key — you only
~/.ssh/id_ed25519.pub         -rw-r--r--  (644)  public, fine to share
~/.ssh/authorized_keys        -rw-------  (600)  who may log in as me
~/.ssh/config                 -rw-------  (600)  your client config
~/.ssh/known_hosts            -rw-r--r--  (644)  servers I've trusted
```

If `~/.ssh` is group-writable, or your private key is `644`, key auth fails and you'll waste an hour. The reason is defensive: a private key another user can read is a private key you must assume is stolen, so SSH treats "readable by others" as "invalid."

### 3.5 The channel multiplexer: how one tunnel carries many things

After auth, the single encrypted connection is a pipe that carries independent **channels**, each tagged with an ID. This is the mechanism behind everything in Rung 3.6:

```
        ONE encrypted TCP connection  (laptop ⇄ node1:22)
   ┌────────────────────────────────────────────────────────┐
   │  channel 0: interactive shell (pty)   ← your prompt     │
   │  channel 1: forwarded TCP  (ssh -L)   ← API server hop  │
   │  channel 2: scp/rsync data stream     ← file bytes      │
   │  channel 3: SOCKS proxy  (ssh -D)     ← browser traffic │
   └────────────────────────────────────────────────────────┘
        all encrypted, all authenticated, all multiplexed
```

### 3.6 Port forwarding: three directions, one tunnel

Port forwarding tells `sshd` to open a *socket* and shovel whatever connects to it through the encrypted channel to some destination. There are exactly three flavors — the letter tells you which end opens the listening socket and which way traffic flows.

**Local forward, `-L` — "pull a remote service to my laptop."**
```
ssh -L 8080:10.96.100.5:80 ubuntu@master
                └── listen on MY laptop:8080
                    forward through master
                    to 10.96.100.5:80 (a ClusterIP, resolved *from master's view*)

 laptop:8080  ──encrypted──▶  master  ──plain, inside cluster──▶  10.96.100.5:80
```
You open `localhost:8080` in your browser; the bytes ride the tunnel to `master`, which then makes a *local* (from its perspective) connection to the ClusterIP. This is how you reach a Kubernetes **dashboard**, a **ClusterIP Service**, or the **API server** from a laptop that can't route into the pod/service network. `ssh -L 6443:localhost:6443 master` puts the API server's own `:6443` onto your laptop's `:6443` — now `kubectl` against `https://localhost:6443` reaches the real control plane through the tunnel.

**Remote forward, `-R` — "push a service from my side to the remote."** The listening socket opens on the *server*; connections there are tunneled back to your laptop (or anywhere your laptop can reach). Used to expose something on your machine to the cluster side, or to punch out from a node that can only reach *you*.

**Dynamic forward, `-D` — "make my laptop a SOCKS proxy into the cluster."**
```
ssh -D 1080 master
        └── open a SOCKS5 proxy on MY laptop:1080
            each request is tunneled to master, which resolves &
            connects on your behalf — to ANY address master can reach

 browser ──SOCKS──▶ laptop:1080 ──encrypted──▶ master ──▶ any 10.96.x.x / 10.244.x.x
```
Unlike `-L` (one fixed destination), `-D` is a *general* proxy: point your browser (or `curl --socks5`) at `localhost:1080` and every cluster IP — ClusterIPs, pod IPs, node-internal dashboards — becomes browsable, because `master` does the connecting. One SOCKS tunnel replaces a dozen `-L` flags.

### 3.7 File transfer: scp vs rsync (both ride SSH)

Neither `scp` nor `rsync` is a new protocol here — both open an SSH channel and stream file bytes through the *same* encrypted tunnel.
- **`scp`** — dumb and simple: copy these bytes there, every time, whole file. Good for one-off copies (`scp admin.conf ~/.kube/config`).
- **`rsync`** — smart: it compares source and destination and transfers **only the differences**, can compress in flight (`-z`), preserve permissions/timestamps (`-a`), and delete files at the destination that no longer exist at the source (`--delete`). Ideal for repeatedly syncing a manifests directory to nodes.

### 3.8 Agent forwarding and the ssh-agent

Typing your key passphrase on every connection is painful, and copying your *private key* onto a jump host is dangerous. Two mechanisms solve this:
- **`ssh-agent`** — a background process that holds your *decrypted* private key in memory. You unlock it once (`ssh-add`), and every `ssh` invocation asks the agent to sign challenges. The key material never leaves the agent.
- **Agent forwarding (`ssh -A`)** — when you SSH from laptop → bastion → node, forwarding lets the *bastion* ask **your laptop's agent** to sign, so you never copy your private key to the bastion. Powerful, but only forward to hosts you trust: root on the bastion can use your forwarded agent while you're connected.

### 3.9 Hardening: what a real node's sshd_config says

`/etc/ssh/sshd_config` is where you shut the doors password auth leaves open. Two lines carry most of the weight:
- **`PasswordAuthentication no`** — disable passwords entirely; only keys work. Kills brute-force and credential-stuffing against port 22 in one stroke.
- **`PermitRootLogin no`** (or `prohibit-password`) — never let anyone log in *directly* as root; force a named user + `sudo`, so actions are attributable and the root password becomes irrelevant to remote attackers.
After editing, `sshd -t` validates the file and `systemctl reload ssh` applies it *without dropping your current session* (so a typo doesn't lock you out — keep a second session open just in case).

> **Check yourself before Rung 4:** Walk the handshake (3.3) from memory. At which numbered step does traffic become encrypted, and name one credential you offer *after* that point that is therefore never exposed even on a failed login. Then explain why the client consults `known_hosts` (server identity) *before* it ever offers your key (your identity), not the other way around.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **`ssh`** | The client program you run to connect | Initiates the handshake (3.3), opens channels |
| **`sshd`** | The server daemon listening on :22 | Accepts connections, checks `authorized_keys` |
| **Host key** | The *server's* keypair (`/etc/ssh/ssh_host_*`) | Proves server identity in step 3–4 |
| **`known_hosts`** | Client file of host keys you've trusted | Server→you authentication (3.1) |
| **`authorized_keys`** | Server file of client public keys allowed in | You→server authentication (3.1) |
| **Keypair** | Linked private + public key | Asymmetric auth (3.2) |
| **Private key** (`id_ed25519`) | Secret half, mode `600`, never shared | Signs the auth challenge (step 6) |
| **Public key** (`id_ed25519.pub`) | Shareable half | Goes into `authorized_keys`; verifies signatures |
| **`ssh-keygen`** | Tool that generates a keypair | Creates your private/public files |
| **`ssh-copy-id`** | Tool that appends your `.pub` to a server's `authorized_keys` | Bootstraps key auth over an existing login |
| **`ed25519`** | Modern elliptic-curve algorithm | The default keypair type |
| **`rsa 4096`** | Older, universal algorithm at 4096 bits | Fallback for legacy targets |
| **`ssh-agent`** | Daemon caching your unlocked private key | Signs challenges without re-entering passphrase (3.8) |
| **Agent forwarding (`-A`)** | Lets a remote host use your local agent | Multi-hop auth without copying the key (3.8) |
| **`~/.ssh/config`** | Per-user client config (Host/HostName/User/IdentityFile) | Names and defaults for connections |
| **Local forward (`-L`)** | Laptop socket → tunnel → remote destination | Pull a remote service local (3.6) |
| **Remote forward (`-R`)** | Remote socket → tunnel → local destination | Push a local service remote (3.6) |
| **Dynamic forward (`-D`)** | Local SOCKS proxy → tunnel → anywhere remote can reach | General cluster browsing (3.6) |
| **Channel** | A multiplexed stream inside the one tunnel | Shell, forward, or file transfer (3.5) |
| **`scp`** | Whole-file copy over SSH | File channel (3.7) |
| **`rsync`** | Delta-based, resumable sync over SSH | File channel, smarter (3.7) |
| **`sshd_config`** | The server daemon's config file | Hardening (3.9) |

**Same kind of thing, different names:**
- **`known_hosts` and `authorized_keys`** are *the same idea* — a file of trusted public keys — pointed in opposite directions. One authenticates the server *to you*, the other authenticates *you to the server*.
- **`-L`, `-R`, `-D`** are all "port forwarding" — the same channel mechanism (3.5) with the listening socket on different ends and a fixed vs. dynamic destination.
- **`scp` and `rsync` and interactive `ssh`** are all *channels on one tunnel* — a shell, a whole-file stream, and a delta stream, respectively.
- **A key's "private/public" halves** are the same relationship as a TLS cert's key/cert and a Kubernetes client cert in `admin.conf` — asymmetric crypto reused everywhere (see [TLS/PKI](26-tls-pki-openssl.md)).

> **Check yourself before Rung 5:** `known_hosts` and `authorized_keys` are "the same idea pointed opposite ways." For *each* file, say which host it lives on and whose public keys it stores — then predict the concrete symptom you'd see if you deleted each one and reconnected.

---

## 🔬 Rung 5 — The Trace

**One concrete action, end to end:** you run, from your laptop, a Kubernetes triage command against a node whose kubelet is misbehaving:

```bash
ssh node1 "journalctl -u kubelet -n 50 --no-pager"
```

You want the last 50 lines of the kubelet's logs *without an interactive session*. Follow every hop.

1. **Client config resolution.** `ssh` reads `~/.ssh/config`, finds a `Host node1` block (or falls back to literal `node1`), resolving `HostName` (e.g. `10.0.1.11`), `User` (e.g. `ubuntu`), and `IdentityFile` (`~/.ssh/id_ed25519`).
2. **DNS + TCP.** The client resolves the hostname and opens a TCP connection to `10.0.1.11:22`, where `sshd` is listening.
3. **Version + key exchange.** Both sides swap version banners and run Diffie-Hellman, deriving a **shared session key**. `sshd` presents its **host key**.
4. **Host verification.** The client hashes the host key and looks it up in `~/.ssh/known_hosts`. It matches a prior entry → no prompt, continue. (If it *didn't* match a stored entry, you'd get the "REMOTE HOST IDENTIFICATION HAS CHANGED" warning and the connection would abort — that's a possible MITM or a rebuilt node.)
5. **From here, everything is encrypted.**
6. **User authentication.** The client offers the public key `id_ed25519.pub`. `sshd` looks in `/home/ubuntu/.ssh/authorized_keys`, finds it, and sends a random challenge. The client (via `ssh-agent`, if loaded) signs it with the **private** key; `sshd` verifies against the public key → **accept**.
7. **Channel: exec, not shell.** Because you passed a command string, the client requests an **exec channel** (not a pty+shell). `sshd` hands `journalctl -u kubelet -n 50 --no-pager` to the user's login shell on `node1`.
8. **The command runs on the node.** `journalctl` reads the systemd journal for the `kubelet.service` unit — the real, local logs, straight from the OS, not from `kubectl`.
9. **Output streams back.** The command's stdout flows back *through the same channel*, encrypted, and the client writes it to your terminal's stdout. stderr comes back on the channel's stderr stream.
10. **Teardown.** `journalctl` exits; `sshd` closes the channel with the exit status; the client exits with that same status (so `&& echo ok` in your shell works). Connection closes.

```
  laptop                                              node1 (sshd)
  ─────────                                           ─────────────
  read ~/.ssh/config  ─┐
  TCP :22 ────────────▶│═══ DH key exchange ═══════▶ host key
  check known_hosts  ◀─┘   (match → silent)
  offer id_ed25519.pub ═══════════════════════════▶ check authorized_keys
  sign challenge (agent) ═════════════════════════▶ verify → ACCEPT
  request exec "journalctl -u kubelet -n50" ══════▶ run in ubuntu's shell
  ubuntu's terminal ◀════ 50 lines of kubelet log ═ journald reads the unit
                    ◀════ exit status 0 ═══════════ channel closes
```

The magic to notice: you got the node's *own* view of the kubelet — the ground truth the API server never sees — over a channel that was encrypted and authenticated before your command was even transmitted.

> **Check yourself before Rung 6:** In this trace `ssh node1 "journalctl …"` opened an *exec* channel, not a pty+shell (step 7). Name one observable difference between passing a command string and running plain `ssh node1`, and explain why your laptop shell's `$?` ended up equal to `journalctl`'s own exit status.

---

## ⚖️ Rung 6 — The Contrast

**The alternative:** the pre-SSH world (`telnet`/`rsh`/`rlogin` + `rcp`/`ftp`), and, within Kubernetes, `kubectl`-based access (`kubectl exec`, `kubectl cp`, `kubectl port-forward`).

**SSH vs. telnet/rsh (the historical alternative):**

| Capability | telnet / rsh / rcp | SSH |
|---|---|---|
| Encrypts traffic | ❌ cleartext | ✅ always |
| Authenticates the server | ❌ none | ✅ host keys / `known_hosts` |
| Authenticates the user | password in clear, or spoofable IP trust | ✅ password-in-tunnel or keypair |
| Detects tampering | ❌ | ✅ per-packet MAC |
| Port forwarding / tunneling | ❌ | ✅ `-L` / `-R` / `-D` |
| Secure file copy | ❌ (ftp/rcp cleartext) | ✅ `scp` / `rsync` |

There is no scenario in 2026 where telnet-for-shell wins. It's dead.

**SSH vs. `kubectl exec`/`port-forward` (the Kubernetes-native alternative):** This is the *real* trade-off you'll weigh daily.

| | `kubectl exec` / `port-forward` | `ssh` to the node |
|---|---|---|
| Reaches | *inside a container/pod* | *the node's OS* |
| Requires | a working API server + kubelet | just `sshd` on :22 |
| Sees kubelet/containerd logs | ❌ (they're on the host) | ✅ `journalctl -u kubelet` |
| Works when the node is `NotReady` | ❌ (kubelet is how exec works) | ✅ (independent of k8s) |
| Auth model | RBAC / kubeconfig | SSH keys / OS users |
| Good for | app-level debugging, tunneling a Service | node triage, bootstrap, host files |

**When would I NOT use SSH?** When the thing you need is *inside a pod* and the cluster is healthy — use `kubectl exec` / `kubectl logs`, which respect RBAC and don't require node access at all. Many managed platforms (EKS/GKE/AKS) actively discourage or block node SSH in favor of SSM/agent-based access; on those, node SSH may be unavailable by design.

**Why this over that, in one sentence:** Use `kubectl` when Kubernetes is healthy and the problem is *in the cluster*; use SSH when Kubernetes itself is the patient and you need the node's ground truth — SSH is the tool that still works after `kubectl` has gone dark.

> **Check yourself before Rung 7:** A node shows `NotReady` and `kubectl describe node` says the kubelet stopped posting status 4 minutes ago. Explain why `kubectl exec` into a pod on that node will likely fail, but `ssh node1 "systemctl status kubelet"` will still work — reference *which* component each path depends on.

---

## 🧪 Rung 7 — The Prediction Test

For each, **commit to the prediction first**, then run, then Verify.

### Example 1 — Normal case: generate a key, install it, log in without a password

**Prediction:** After I generate an ed25519 keypair and copy its *public* half to `node1` with `ssh-copy-id`, the next `ssh` will *not* prompt for a password — BECAUSE the server now has my public key in `~/.ssh/authorized_keys` and can verify a challenge I sign with my private key, so the password path is never needed.

```bash
# Generate a modern keypair (accept the default path, set a passphrase when asked)
ssh-keygen -t ed25519 -C "me@example.com"
#   → creates ~/.ssh/id_ed25519 (private, 600) and ~/.ssh/id_ed25519.pub (public, 644)

# (Legacy target that can't do ed25519? Make an RSA-4096 key instead:)
ssh-keygen -t rsa -b 4096 -C "me@example.com"     # → ~/.ssh/id_rsa[.pub]

# Push the PUBLIC key to the node (this step still uses your password, one last time)
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@node1
#   → "Number of key(s) added: 1"

# Now log in — no password
ssh ubuntu@node1
```

**Verify:** The final `ssh` drops you at `ubuntu@node1:~$` with **no password prompt**. Confirm the server side: `ssh ubuntu@node1 "cat ~/.ssh/authorized_keys"` should show your `.pub` line ending in `me@example.com`. If it *still* asks for a password, run `ssh -v ubuntu@node1` and look for `Offering public key` followed by `Authentications that can continue` — a common cause is wrong permissions; `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys` **on the server** fixes the most frequent failure. That failure teaches the lesson of 3.4: SSH rejects keys guarded by loose permissions.

### Example 2 — Edge/failure case: the host key changed (`known_hosts` mismatch)

**Prediction:** If I rebuild `node1` (fresh OS → new host key) and try to SSH, the client will **refuse to connect** with "REMOTE HOST IDENTIFICATION HAS CHANGED" — BECAUSE the host key it now presents no longer matches the one cached in `~/.ssh/known_hosts`, and SSH treats that as a possible man-in-the-middle rather than trusting blindly.

```bash
ssh ubuntu@node1
#   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#   @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!    @
#   ...
#   Host key verification failed.        ← connection ABORTED

# Inspect what's stored, then remove ONLY the stale entry:
ssh-keygen -F node1                 # shows the offending known_hosts line
ssh-keygen -R node1                 # removes node1's cached host key

# Reconnect: you'll be re-prompted to trust the NEW key (verify the fingerprint!)
ssh ubuntu@node1
#   → "The authenticity of host 'node1' can't be established.
#      ED25519 key fingerprint is SHA256:… . Are you sure you want to continue (yes/no)?"
```

**Verify:** After `ssh-keygen -R node1`, the reconnect prompts you *fresh* (a first-time trust), and after `yes` you get a shell; `known_hosts` now holds the new key. The lesson: this "failure" is SSH working correctly — it protected you from an unverified host. In production, you'd confirm the new fingerprint out-of-band (from your provisioning logs) before typing `yes`; a mismatch you *can't* explain is a genuine security event, not a nuisance.

### Example 3 — Kubernetes case: reach the API server through a `-L` tunnel and fetch the kubeconfig

**Prediction:** If I forward the control plane's `:6443` to my laptop with `ssh -L` and copy `admin.conf` down, then `kubectl --server=https://localhost:6443` will reach the *real* cluster from my laptop — BECAUSE the local forward opens a socket on my laptop that tunnels every connection, encrypted, to the API server that `master` can reach locally, and `admin.conf` carries the client cert that authenticates me to it.

```bash
# One-time: define the node in ~/.ssh/config so you type a name, not flags
cat >> ~/.ssh/config <<'EOF'
Host k8s-master
    HostName 10.0.1.10
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
EOF
chmod 600 ~/.ssh/config

# Copy the cluster-admin kubeconfig down to your laptop (whole-file copy = scp)
scp k8s-master:/etc/kubernetes/admin.conf ~/.kube/config
#   admin.conf points at https://<control-plane>:6443

# Open the tunnel: laptop:6443  ->  (encrypted)  ->  master's own localhost:6443
ssh -L 6443:localhost:6443 k8s-master
#   leave this session running; it IS the tunnel

# --- in a SECOND terminal, point kubectl at the tunnel ---
kubectl --server=https://localhost:6443 get nodes
#   (admin.conf's server URL may already be localhost:6443, in which case plain
#    `kubectl get nodes` just works while the tunnel is up)
```

Bonus Kubernetes reachability patterns (each a *different* channel from 3.6):

```bash
# Pull an in-cluster ClusterIP dashboard to your browser at localhost:8080
ssh -L 8080:10.96.100.5:80 ubuntu@master        # then open http://localhost:8080

# Turn your laptop into a SOCKS proxy that can browse ANY cluster IP
ssh -D 1080 master                               # point browser/curl at socks5://localhost:1080
curl --socks5-hostname localhost:1080 http://10.96.100.5/healthz

# Keep node manifests in sync (delta transfer, delete removed files, compress)
rsync -avz --delete /local/manifests/ node:/etc/kubernetes/manifests/

# Back up the cluster CA/PKI directory recursively
scp -r k8s-master:/etc/kubernetes/pki /backup/

# Node triage without an interactive session
ssh node "systemctl status kubelet"
ssh node1 "journalctl -u kubelet -n 50 --no-pager"

# Run a whole local diagnostic script on the node WITHOUT copying it first:
ssh node bash -s < script.sh
#   `bash -s` reads the script from stdin; the < pipes your LOCAL file into
#   the remote shell. Nothing is left on the node afterward.
```

**Verify:** `kubectl get nodes` through the tunnel returns your real node list — the same output you'd get on the control plane itself — proving the forward reached `:6443`. If it hangs or gives `connection refused`, the tunnel session died or nothing is listening on the node's `:6443`; check the `ssh -L` terminal is still open and that `ss -tlnp | grep 6443` on the master shows the API server. For `ssh node bash -s < script.sh`, verify the script's output streams back to *your* terminal and confirm with `ls` on the node that no copy of `script.sh` was left behind — that's the tell that it ran from stdin, not from a transferred file.

---

## 🏔 Capstone — Compress It

**One-sentence summary:** SSH is an always-encrypted tunnel that first proves both hosts' identities with asymmetric keys, then carries a shell, forwarded ports, or file transfers as authenticated, tamper-proof bytes.

**Explain it to a beginner (3 sentences):** SSH lets you safely control a computer far away over the internet by scrambling everything you send so no one in between can read or change it. Instead of a password you can prove who you are with a keypair — a secret file you keep and a public file you hand to the server — so login is both safer and passwordless. The same secure connection can also carry files or "forward" a port, which is how you reach a private service (like a Kubernetes dashboard or API server) on your own laptop.

**Sub-capability → the one core idea:**

| Sub-capability | How it derives from "encrypted tunnel + mutual identity + arbitrary channels" |
|---|---|
| Public-key login (`ssh-keygen`, `authorized_keys`) | The *mutual identity* half — you prove yourself by signing, not by sending a secret |
| `known_hosts` prompt | The *other* identity direction — the server proves itself before you trust it |
| `~/.ssh/config` | Names and defaults for *which tunnel* to build |
| `-L` / `-R` / `-D` forwarding | *Arbitrary channels* — the tunnel carries a TCP connection instead of a shell |
| `scp` / `rsync` | *Arbitrary channels* — the tunnel carries file bytes (whole vs. delta) |
| `ssh node "cmd"` / `bash -s <` | *Arbitrary channels* — an exec channel instead of an interactive one |
| Agent forwarding, `PermitRootLogin no` | Protecting the *identity* half — keep keys safe, force attributable named logins |

**Which rung to revisit hands-on?** If key auth still feels like magic, live in **Rung 7 Example 1** until passwordless login is muscle memory. If *port forwarding* is the fuzzy part — and for most Kubernetes engineers it is — **Rung 3.6 + Rung 7 Example 3** is your next real session: set up `ssh -L 6443:localhost:6443` and `ssh -D 1080` against a real cluster and watch a browser reach a ClusterIP. That single exercise turns "SSH is for logging in" into "SSH is my network bridge into the cluster."

---

## Related concepts

- [networking](11-networking.md) — ports, `ss`, DNS, and the TCP sockets SSH and its forwards ride on.
- [permissions & ownership](05-permissions-ownership.md) — why `chmod 600` on your private key is not optional.
- [users, groups & sudo](06-users-groups-sudo.md) — the OS accounts SSH authenticates you *into*, and why `PermitRootLogin no` pushes you toward named-user + sudo.
- [TLS, PKI & OpenSSL](26-tls-pki-openssl.md) — the same asymmetric-key math, and where `admin.conf`'s client certificate comes from.
- [systemd & services](16-systemd-services.md) — `sshd` is a unit, and `journalctl -u kubelet` is what you run once SSH lands you on the node.
- [the Linux ↔ Kubernetes map](27-linux-kubernetes-map.md) — where node SSH triage fits in the full debugging playbook.

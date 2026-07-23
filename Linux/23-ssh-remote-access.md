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

> ### 🧸 Plain-English first (read this before the technical version)
>
> **SSH is a secure phone line into a distant building (another computer).** The pieces below, in order:
>
> - **The cast (3.1).** The distant machine runs a permanent receptionist program that listens for calls; your machine runs the caller program. Two little address books do the trust work: on *your* side, a list of buildings you've visited before (so you'd notice if an impostor answered the line); on *their* side, a guest list of people allowed in. Same idea, opposite directions.
> - **Key pairs (3.2).** Instead of a password, you carry two linked items: a private stamp you never show anyone, and a public sample of its mark that you hand out freely. Anyone holding the sample can confirm a mark came from your stamp — but can't forge one. Nothing secret ever travels over the line. Two stamp styles exist: a modern compact one (today's default) and an older, bulkier one kept only for antique equipment.
> - **The handshake (3.3).** When you call: first the line gets scrambled so no eavesdropper can listen; next the *building* proves its identity to you (checked against your address book — that's the "are you sure?" question on a first visit); only *then* do you prove yourself, by stamping a random challenge they send. The order matters: the line is already scrambled before you offer any credential, and you verify the building before showing your ID.
> - **Tidiness rules (3.4).** SSH refuses to work if your private stamp is left where housemates could copy it — a stamp others can read is treated as already stolen.
> - **One line, many conversations (3.5).** The single scrambled call carries several independent streams at once: your typed commands, file transfers, forwarded traffic.
> - **Forwarding (3.6), three flavors:** pull one distant internal service onto your own desk (-L); push something of yours over to their side (-R); or turn the call into a general switchboard (-D) so *anything* their building can reach becomes reachable through it.
> - **Copying files (3.7).** Two couriers ride the same line: a simple one that recopies everything each time, and a clever one that sends only what changed.
> - **The stamp-holder (3.8).** A helper keeps your unlocked stamp in memory so you don't retype its passphrase; "forwarding" the helper lets a middle stop ask *your* machine to stamp things, so the stamp never leaves home — but only through buildings you trust.
> - **Hardening (3.9).** On real servers you turn off password entry entirely (stamps only) and forbid calling in directly as the all-powerful account — and you test new rules before hanging up your current call, so a typo can't lock you out.

*Now the original technical deep-dive — the same ideas, in precise form:*

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

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** `telnet` and `ssh` both give you a remote shell. Name the two distinct guarantees SSH adds — which protects against a passive eavesdropper, and which against an active impersonator?

**A:** SSH adds (1) **encryption** of all traffic and (2) **authentication of the server's identity** (plus per-packet integrity, which rides along with the encryption). Encryption is the guarantee against the *passive* eavesdropper: a sniffer on any hop sees only ciphertext, so your password or key exchange can't be harvested the way telnet's cleartext `password: hunter2` could. Server authentication via host keys and `known_hosts` is the guarantee against the *active* impersonator: an attacker who redirects your traffic (DNS poisoning, ARP spoofing) cannot present the real server's host key, so the client detects the mismatch and refuses instead of handing your credential to a fake. Telnet had neither — no secrecy and no proof of who was answering.

### Before Rung 3
**Q:** By the time you first see "The authenticity of host … can't be established," which of the three moves (encrypted tunnel, mutual identity, arbitrary channels) has already completed, and which is the prompt part of?

**A:** The **encrypted tunnel** has already completed: the TCP connection, version banners, and Diffie-Hellman key exchange have run, and the two sides share a session key — the server presented its host key as part of that exchange. The prompt is part of the second move, **mutual identity**: it is the server-to-you half of authentication, where the client checks the presented host key against `~/.ssh/known_hosts`, finds no entry, and asks you to verify the fingerprint and establish first-time trust. The third move, arbitrary channels (shell, forwards, file transfer), hasn't started — no channel opens until both identity checks (server host key, then your key or password) succeed.

### Before Rung 4
**Q:** Walk the handshake from memory. At which step does traffic become encrypted, and name a credential offered after that point that's never exposed even on failed login. Why is `known_hosts` consulted before your key is offered?

**A:** Traffic becomes encrypted at **step 3**, the Diffie-Hellman key exchange, which derives a shared session key before any authentication happens — steps 5–6 (user auth) run entirely inside the encrypted tunnel. So a credential offered after that point — your password, or your public-key offer and signed challenge — is never visible on the wire, even if the login ultimately fails. The client consults `known_hosts` (steps 3–4, server identity) *before* offering your key (steps 5–6, your identity) because you must verify you're talking to the real server before handing over any credential: if identity checking came second, a man-in-the-middle impersonating the server could collect your authentication attempt first and be unmasked only after the damage was done. Server-proves-itself-first is the whole point of `known_hosts`.

### Before Rung 5
**Q:** For `known_hosts` and `authorized_keys`: which host does each live on, whose public keys does each store, and what symptom appears if you delete each and reconnect?

**A:** `~/.ssh/known_hosts` lives on the **client** and stores the **servers'** public host keys you've previously trusted — it answers "is this the same server I trusted last time?" Delete it and reconnect: the connection still works, but you get the first-time-trust prompt again — "The authenticity of host … can't be established. ED25519 key fingerprint is SHA256:… Are you sure you want to continue?" — because the client has no cached key to compare against. `~/.ssh/authorized_keys` lives on the **server** (in the target user's home) and stores the **clients'** public keys allowed to log in as that user. Delete it and reconnect: key authentication fails — the server has no public key to verify your signed challenge against — so SSH falls back to prompting for a password (or rejects you outright if `PasswordAuthentication no` is set).

### Before Rung 6
**Q:** `ssh node1 "journalctl …"` opened an exec channel, not a pty+shell. Name one observable difference from plain `ssh node1`, and explain why your laptop shell's `$?` equals `journalctl`'s exit status.

**A:** With a command string, you get **no interactive prompt and no pty**: the command runs, its stdout/stderr stream back through the channel, and the connection closes when the command exits — whereas plain `ssh node1` requests a pty+shell and drops you at `ubuntu@node1:~$` waiting for input. (Corollaries: no shell prompt appears, and full-screen/interactive programs would misbehave without a pty.) Your laptop's `$?` matches `journalctl`'s exit status because of the teardown step in the trace: when the remote command exits, `sshd` closes the exec channel *carrying the command's exit status*, and the `ssh` client deliberately exits with that same status — which is exactly why constructs like `ssh node1 "cmd" && echo ok` work as if the command had run locally.

### Before Rung 7
**Q:** A node is `NotReady` because kubelet stopped posting status. Why will `kubectl exec` into a pod on that node likely fail, while `ssh node1 "systemctl status kubelet"` still works? Which component does each path depend on?

**A:** `kubectl exec` depends on the Kubernetes control path: your request goes to the **API server**, which connects to the node's **kubelet**, which drives the container runtime to open the exec session in the pod. The kubelet is precisely the component that has died (it stopped posting status), so the exec path fails — the mechanism that would carry your session is the patient. `ssh node1` depends only on **`sshd`** listening on TCP 22 on the node's OS — it is completely independent of Kubernetes, the API server, and the kubelet. That's why SSH still lands you a shell where you can run `systemctl status kubelet` and `journalctl -u kubelet` to get the node's ground truth: SSH is the tool that still works after `kubectl` has gone dark.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — several setups need `sudo` and some deliberately break things. For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6.
>
> **Lab safety design:** every scenario runs a **second, disposable `sshd`** on a high port (8022–8027) with its own config file, host keys, and PID file under `/opt/lab-ssh/` — your real SSH daemon on port 22 and `/etc/ssh/sshd_config` are **never touched**, so you cannot lock yourself out of the VM no matter how badly a scenario goes.

### 🟢 Scenario 1 — "Mysuru: the key that was left unlocked" (Easy)
**Setup:**
```bash
command -v /usr/sbin/sshd >/dev/null || sudo apt-get install -y openssh-server
sudo mkdir -p /run/sshd /opt/lab-ssh/sc1
sudo useradd -m -s /bin/bash labuser1 2>/dev/null || true
mkdir -p /tmp/lab-ssh-sc1 && chmod 700 /tmp/lab-ssh-sc1
ssh-keygen -q -t ed25519 -N '' -f /tmp/lab-ssh-sc1/mysuru_key
sudo mkdir -p /home/labuser1/.ssh
sudo cp /tmp/lab-ssh-sc1/mysuru_key.pub /home/labuser1/.ssh/authorized_keys
sudo chmod 700 /home/labuser1/.ssh && sudo chmod 600 /home/labuser1/.ssh/authorized_keys
sudo chown -R labuser1:labuser1 /home/labuser1/.ssh
sudo rm -f /opt/lab-ssh/sc1/ssh_host_ed25519_key /opt/lab-ssh/sc1/ssh_host_ed25519_key.pub
sudo ssh-keygen -q -t ed25519 -N '' -f /opt/lab-ssh/sc1/ssh_host_ed25519_key
sudo tee /opt/lab-ssh/sc1/sshd_config >/dev/null <<'CFG'
Port 8022
ListenAddress 127.0.0.1
HostKey /opt/lab-ssh/sc1/ssh_host_ed25519_key
PidFile /opt/lab-ssh/sc1/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PermitRootLogin no
AllowUsers labuser1
CFG
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc1/sshd_config
chmod 644 /tmp/lab-ssh-sc1/mysuru_key      # ← the teammate's "helpful" change
```
**Situation:** A teammate wanted the whole team to share the deploy key for the lab node, so he made it "readable for everyone" before going on leave. Since then, every deploy fails with `Permission denied (publickey)` — even though the public key is definitely installed in `authorized_keys` on the server, and nothing on the server changed.

**Your task:** Run the connection below, work out why the client refuses to authenticate, and fix it so key-based login works again:

```bash
ssh -i /tmp/lab-ssh-sc1/mysuru_key -p 8022 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc1/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser1@127.0.0.1 'echo MYSURU-OK'
```

**Verify:**
```bash
ssh -i /tmp/lab-ssh-sc1/mysuru_key -p 8022 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc1/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser1@127.0.0.1 'echo MYSURU-OK'
# expected: prints MYSURU-OK with NO password prompt and NO key warning
```

### 🟢 Scenario 2 — "Shimla: the server that changed its face" (Easy)
**Setup:**
```bash
command -v /usr/sbin/sshd >/dev/null || sudo apt-get install -y openssh-server
sudo mkdir -p /run/sshd /opt/lab-ssh/sc2
sudo useradd -m -s /bin/bash labuser2 2>/dev/null || true
mkdir -p /tmp/lab-ssh-sc2 && chmod 700 /tmp/lab-ssh-sc2
ssh-keygen -q -t ed25519 -N '' -f /tmp/lab-ssh-sc2/shimla_key
sudo mkdir -p /home/labuser2/.ssh
sudo cp /tmp/lab-ssh-sc2/shimla_key.pub /home/labuser2/.ssh/authorized_keys
sudo chmod 700 /home/labuser2/.ssh && sudo chmod 600 /home/labuser2/.ssh/authorized_keys
sudo chown -R labuser2:labuser2 /home/labuser2/.ssh
sudo rm -f /opt/lab-ssh/sc2/ssh_host_ed25519_key /opt/lab-ssh/sc2/ssh_host_ed25519_key.pub
sudo ssh-keygen -q -t ed25519 -N '' -f /opt/lab-ssh/sc2/ssh_host_ed25519_key
sudo tee /opt/lab-ssh/sc2/sshd_config >/dev/null <<'CFG'
Port 8023
ListenAddress 127.0.0.1
HostKey /opt/lab-ssh/sc2/ssh_host_ed25519_key
PidFile /opt/lab-ssh/sc2/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PermitRootLogin no
AllowUsers labuser2
CFG
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc2/sshd_config
sleep 1
ssh-keyscan -p 8023 127.0.0.1 2>/dev/null > /tmp/lab-ssh-sc2/known_hosts   # "first visit": cache the host key
# --- overnight, the node was reimaged: new OS, NEW host keys, same IP ---
sudo kill "$(sudo cat /opt/lab-ssh/sc2/sshd.pid)"
sudo rm -f /opt/lab-ssh/sc2/ssh_host_ed25519_key /opt/lab-ssh/sc2/ssh_host_ed25519_key.pub
sudo ssh-keygen -q -t ed25519 -N '' -f /opt/lab-ssh/sc2/ssh_host_ed25519_key
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc2/sshd_config
```
**Situation:** Last night the infra team reimaged the lab node (fresh OS image, same IP). This morning your connection is refused before you even get to authenticate, screaming `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` and `Host key verification failed.` A colleague suggests deleting the whole known_hosts file; you know better — that would throw away *every* trusted host, not just this one.

**Your task:** Inspect the cached entry for `[127.0.0.1]:8023` in `/tmp/lab-ssh-sc2/known_hosts`, remove **only** the stale entry (not the file), confirm the new fingerprint against the server's own public host key, and reconnect:

```bash
ssh -i /tmp/lab-ssh-sc2/shimla_key -p 8023 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc2/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser2@127.0.0.1 'echo SHIMLA-OK'
```

**Verify:**
```bash
ssh -i /tmp/lab-ssh-sc2/shimla_key -p 8023 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc2/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser2@127.0.0.1 'echo SHIMLA-OK'
# expected: prints SHIMLA-OK (no "REMOTE HOST IDENTIFICATION HAS CHANGED" warning)
ssh-keygen -f /tmp/lab-ssh-sc2/known_hosts -F '[127.0.0.1]:8023' | grep -c ssh-ed25519
# expected: 1   (exactly one — the NEW — cached entry for the lab host)
```

### 🟡 Scenario 3 — "Udaipur: the guest list that forgot you" (Medium)
**Setup:**
```bash
command -v /usr/sbin/sshd >/dev/null || sudo apt-get install -y openssh-server
sudo mkdir -p /run/sshd /opt/lab-ssh/sc3
sudo useradd -m -s /bin/bash labuser3 2>/dev/null || true
mkdir -p /tmp/lab-ssh-sc3 && chmod 700 /tmp/lab-ssh-sc3
ssh-keygen -q -t ed25519 -N '' -f /tmp/lab-ssh-sc3/udaipur_key
sudo mkdir -p /home/labuser3/.ssh
sudo cp /tmp/lab-ssh-sc3/udaipur_key.pub /home/labuser3/.ssh/authorized_keys
sudo chmod 700 /home/labuser3/.ssh && sudo chmod 600 /home/labuser3/.ssh/authorized_keys
sudo chown -R labuser3:labuser3 /home/labuser3/.ssh
sudo rm -f /opt/lab-ssh/sc3/ssh_host_ed25519_key /opt/lab-ssh/sc3/ssh_host_ed25519_key.pub
sudo ssh-keygen -q -t ed25519 -N '' -f /opt/lab-ssh/sc3/ssh_host_ed25519_key
sudo tee /opt/lab-ssh/sc3/sshd_config >/dev/null <<'CFG'
Port 8024
ListenAddress 127.0.0.1
HostKey /opt/lab-ssh/sc3/ssh_host_ed25519_key
PidFile /opt/lab-ssh/sc3/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PermitRootLogin no
LogLevel VERBOSE
AllowUsers deploybot
CFG
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc3/sshd_config -E /opt/lab-ssh/sc3/sshd.log
```
**Situation:** A hardening ticket was closed yesterday: "restrict lab sshd to approved accounts." Today `labuser3` cannot log in — `Permission denied (publickey)` — although the keypair is fresh, the client-side permissions are perfect, and `authorized_keys` on the server verifiably contains the right public key. `ssh -v` shows the key being *offered* and the server just saying no. The client side is a dead end: the answer is on the **server**.

**Your task:** Use the client's verbose output and the lab daemon's own log (`/opt/lab-ssh/sc3/sshd.log`) to find out why `sshd` rejects `labuser3` before ever checking the key, fix the daemon's config (validate it before restarting!), restart the **lab** sshd, and log in.

**Verify:**
```bash
ssh -i /tmp/lab-ssh-sc3/udaipur_key -p 8024 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc3/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser3@127.0.0.1 'echo UDAIPUR-OK'
# expected: prints UDAIPUR-OK
```

### 🟡 Scenario 4 — "Madurai: the tunnel that was administratively prohibited" (Medium)
**Setup:**
```bash
command -v /usr/sbin/sshd >/dev/null || sudo apt-get install -y openssh-server
command -v curl >/dev/null || sudo apt-get install -y curl
sudo mkdir -p /run/sshd /opt/lab-ssh/sc4/www
sudo useradd -m -s /bin/bash labuser4 2>/dev/null || true
mkdir -p /tmp/lab-ssh-sc4 && chmod 700 /tmp/lab-ssh-sc4
ssh-keygen -q -t ed25519 -N '' -f /tmp/lab-ssh-sc4/madurai_key
sudo mkdir -p /home/labuser4/.ssh
sudo cp /tmp/lab-ssh-sc4/madurai_key.pub /home/labuser4/.ssh/authorized_keys
sudo chmod 700 /home/labuser4/.ssh && sudo chmod 600 /home/labuser4/.ssh/authorized_keys
sudo chown -R labuser4:labuser4 /home/labuser4/.ssh
sudo rm -f /opt/lab-ssh/sc4/ssh_host_ed25519_key /opt/lab-ssh/sc4/ssh_host_ed25519_key.pub
sudo ssh-keygen -q -t ed25519 -N '' -f /opt/lab-ssh/sc4/ssh_host_ed25519_key
sudo tee /opt/lab-ssh/sc4/sshd_config >/dev/null <<'CFG'
Port 8025
ListenAddress 127.0.0.1
HostKey /opt/lab-ssh/sc4/ssh_host_ed25519_key
PidFile /opt/lab-ssh/sc4/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PermitRootLogin no
LogLevel VERBOSE
AllowUsers labuser4
AllowTcpForwarding no
CFG
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc4/sshd_config -E /opt/lab-ssh/sc4/sshd.log
echo 'MADURAI-DASHBOARD-OK' | sudo tee /opt/lab-ssh/sc4/www/marker.txt >/dev/null
nohup python3 -m http.server 8580 --bind 127.0.0.1 --directory /opt/lab-ssh/sc4/www \
    > /tmp/lab-ssh-sc4/dashboard.log 2>&1 &
```
**Situation:** An internal "cluster dashboard" listens on the node's loopback only (`127.0.0.1:8580`) — by design unreachable from outside. The standard workaround is an SSH local forward, exactly like `ssh -L 8080:10.96.100.5:80` in Rung 3.6. But when you build the tunnel and curl through it, the page never loads — curl gets an empty reply — and the tunnel's ssh process whines `open failed: administratively prohibited`. Pretend `127.0.0.1:8580` is unreachable except *through* the tunnel — the point is to make the forward work.

**Your task:** Establish the local forward with
```bash
ssh -i /tmp/lab-ssh-sc4/madurai_key -p 8025 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc4/known_hosts \
    -o StrictHostKeyChecking=accept-new \
    -N -f -L 8581:127.0.0.1:8580 labuser4@127.0.0.1
```
watch it fail on use, find the server-side option that forbids forwarding, fix the **lab** sshd config, restart the daemon, kill the old tunnel, and rebuild it so the dashboard is reachable at `http://127.0.0.1:8581/`.

**Verify:**
```bash
curl -s http://127.0.0.1:8581/marker.txt
# expected: MADURAI-DASHBOARD-OK
ss -tlnp | grep 8581
# expected: the LISTEN socket on 127.0.0.1:8581 is owned by an "ssh" process (the tunnel)
```

### 🟠 Scenario 5 — "Pondicherry: three locks on one door" (Hard)
**Setup:**
```bash
command -v /usr/sbin/sshd >/dev/null || sudo apt-get install -y openssh-server
sudo mkdir -p /run/sshd /opt/lab-ssh/sc5
sudo useradd -m -s /bin/bash labuser5 2>/dev/null || true
mkdir -p /tmp/lab-ssh-sc5 && chmod 700 /tmp/lab-ssh-sc5
ssh-keygen -q -t ed25519 -N '' -f /tmp/lab-ssh-sc5/pondicherry_key
sudo mkdir -p /home/labuser5/.ssh
sudo cp /tmp/lab-ssh-sc5/pondicherry_key.pub /home/labuser5/.ssh/authorized_keys
sudo chmod 600 /home/labuser5/.ssh/authorized_keys
sudo chown -R labuser5:labuser5 /home/labuser5/.ssh
sudo rm -f /opt/lab-ssh/sc5/ssh_host_ed25519_key /opt/lab-ssh/sc5/ssh_host_ed25519_key.pub
sudo ssh-keygen -q -t ed25519 -N '' -f /opt/lab-ssh/sc5/ssh_host_ed25519_key
sudo tee /opt/lab-ssh/sc5/sshd_config >/dev/null <<'CFG'
Port 8026
ListenAddress 127.0.0.1
HostKey /opt/lab-ssh/sc5/ssh_host_ed25519_key
PidFile /opt/lab-ssh/sc5/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys2
PasswordAuthentication no
PermitRootLogin no
LogLevel DEBUG
AllowUsers labuser5
CFG
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc5/sshd_config -E /opt/lab-ssh/sc5/sshd.log
# the three "improvements" made during a rushed migration:
chmod 664 /tmp/lab-ssh-sc5/pondicherry_key      # lock 1 (client side)
sudo chmod 777 /home/labuser5/.ssh              # lock 2 (server side)
# lock 3 is already hiding in the sshd_config above
```
**Situation:** During a rushed node migration, three different people "helped": someone shared the client key with the team, someone "opened up" the service account's `.ssh` directory so a config-management tool could write to it, and someone copied a hardened `sshd_config` template from another fleet. Individually each change looks harmless; together, key auth is stone dead — `Permission denied (publickey)` — and fixing any *one* of them changes nothing, which is exactly what makes this a classic. There are **three independent faults**: one on the client, one in the server's filesystem, one in the daemon's config.

**Your task:** Peel the onion. Use `ssh -vvv` output on the client and `LogLevel DEBUG` output in `/opt/lab-ssh/sc5/sshd.log` on the server, fix **all three** faults (validate the config with `sshd -t -f …` before restarting the lab daemon), and get a passwordless login.

**Verify:**
```bash
ssh -i /tmp/lab-ssh-sc5/pondicherry_key -p 8026 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc5/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser5@127.0.0.1 'echo PONDICHERRY-OK'
# expected: prints PONDICHERRY-OK with no password prompt and no warnings
```

### 🔴 Scenario 6 — "Rishikesh: the passphrase, the agent, and the call home" (Expert)
**Setup:**
```bash
command -v /usr/sbin/sshd >/dev/null || sudo apt-get install -y openssh-server
command -v curl >/dev/null || sudo apt-get install -y curl
sudo mkdir -p /run/sshd /opt/lab-ssh/sc6
sudo useradd -m -s /bin/bash labuser6 2>/dev/null || true
mkdir -p /tmp/lab-ssh-sc6/www && chmod 700 /tmp/lab-ssh-sc6
ssh-keygen -q -t ed25519 -N 'rishikesh-lab-2026' -f /tmp/lab-ssh-sc6/rishikesh_key
echo 'rishikesh-lab-2026' | sudo tee /opt/lab-ssh/sc6/passphrase.txt >/dev/null
sudo mkdir -p /home/labuser6/.ssh
sudo cp /tmp/lab-ssh-sc6/rishikesh_key.pub /home/labuser6/.ssh/authorized_keys
sudo chmod 700 /home/labuser6/.ssh && sudo chmod 600 /home/labuser6/.ssh/authorized_keys
sudo chown -R labuser6:labuser6 /home/labuser6/.ssh
sudo rm -f /opt/lab-ssh/sc6/ssh_host_ed25519_key /opt/lab-ssh/sc6/ssh_host_ed25519_key.pub
sudo ssh-keygen -q -t ed25519 -N '' -f /opt/lab-ssh/sc6/ssh_host_ed25519_key
sudo tee /opt/lab-ssh/sc6/sshd_config >/dev/null <<'CFG'
Port 8027
ListenAddress 127.0.0.1
HostKey /opt/lab-ssh/sc6/ssh_host_ed25519_key
PidFile /opt/lab-ssh/sc6/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PermitRootLogin no
AllowUsers labuser6
CFG
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc6/sshd_config
echo 'RISHIKESH-HOOK-OK' > /tmp/lab-ssh-sc6/www/hook.txt
nohup python3 -m http.server 8690 --bind 127.0.0.1 --directory /tmp/lab-ssh-sc6/www \
    > /tmp/lab-ssh-sc6/hook-server.log 2>&1 &
```
**Situation:** A CI worker (played by the lab sshd on port 8027) must deliver build results to a webhook receiver that runs **on your workstation** on loopback only (`127.0.0.1:8690`) — the worker cannot reach it, so the delivery has to travel *backwards* through a reverse tunnel you open **to** the worker. Security policy adds two twists: the deploy key **must** keep its passphrase (it's in `/opt/lab-ssh/sc6/passphrase.txt`), and all tunnel commands run non-interactively (`BatchMode=yes`), so nothing may ever prompt for that passphrase — type it once into an agent, never again.

**Your task:** (1) Start an `ssh-agent` and load the passphrase-protected key into it. (2) Open a **remote forward** so that port `8691` on the worker side tunnels back to `127.0.0.1:8690` on yours, using `-o BatchMode=yes` (it must succeed *without* any passphrase prompt — proof the agent is doing the signing). (3) Prove delivery works by SSH-ing to the worker and fetching the hook **through the tunnel**.

**Verify:**
```bash
ssh-add -l
# expected: one ED25519 key listed (the rishikesh lab key) — the agent holds it
ssh -i /tmp/lab-ssh-sc6/rishikesh_key -p 8027 -o BatchMode=yes -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc6/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser6@127.0.0.1 \
    'curl -s http://127.0.0.1:8691/hook.txt'
# expected: RISHIKESH-HOOK-OK   (BatchMode forbids prompts — only the agent can sign)
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "Mysuru: the key that was left unlocked"
**Solution:**
```bash
ls -l /tmp/lab-ssh-sc1/mysuru_key          # -rw-r--r-- ← world-readable private key
# Running the connection shows the real error before the denial:
#   WARNING: UNPROTECTED PRIVATE KEY FILE!
#   Permissions 0644 for '/tmp/lab-ssh-sc1/mysuru_key' are too open.
#   This private key will be ignored.
chmod 600 /tmp/lab-ssh-sc1/mysuru_key
ssh -i /tmp/lab-ssh-sc1/mysuru_key -p 8022 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc1/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser1@127.0.0.1 'echo MYSURU-OK'
# MYSURU-OK
```
**Why this works & what it teaches:** This is Rung 3.4 verbatim — permissions on key files are *load-bearing*. The client refuses to even offer a group/world-readable private key, because a private key another user can read must be assumed stolen; with the key ignored and `PasswordAuthentication no` on the server, the only remaining outcome is `Permission denied (publickey)`. `chmod 600` restores the "you only" contract and the challenge-signing flow of Rung 3.3 steps 5–6 proceeds normally. **Where people go wrong:** they read only the *last* line of output (the denial) and start debugging the server, when the client printed the actual cause three lines earlier.
**Cleanup:** `sudo kill "$(sudo cat /opt/lab-ssh/sc1/sshd.pid)"; sudo deluser --remove-home labuser1; sudo rm -rf /opt/lab-ssh/sc1 /tmp/lab-ssh-sc1`

### Scenario 2 — "Shimla: the server that changed its face"
**Solution:**
```bash
# 1. Inspect what is cached for this host:port (note -f for the lab file):
ssh-keygen -f /tmp/lab-ssh-sc2/known_hosts -F '[127.0.0.1]:8023'
# 2. Surgically remove ONLY that stale entry:
ssh-keygen -f /tmp/lab-ssh-sc2/known_hosts -R '[127.0.0.1]:8023'
# 3. Out-of-band fingerprint check — what SHOULD the new key look like?
sudo ssh-keygen -lf /opt/lab-ssh/sc2/ssh_host_ed25519_key.pub
# 4. Reconnect; accept-new caches the new (now verified) key and logs in:
ssh -i /tmp/lab-ssh-sc2/shimla_key -p 8023 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc2/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser2@127.0.0.1 'echo SHIMLA-OK'
# SHIMLA-OK
```
**Why this works & what it teaches:** `known_hosts` is the server-to-you half of mutual identity (Rung 3.1/3.3 step 4): the reimaged node presents a brand-new host key, the client sees it differs from the cached one, and — exactly like Rung 7 Example 2 — refuses rather than risk a man-in-the-middle. `ssh-keygen -F/-R` (with `-f` pointing at the lab file) is the surgical fix; comparing the fresh prompt's fingerprint against `ssh-keygen -lf` on the server's own `.pub` is the out-of-band verification you would do from provisioning logs in production. **Where people go wrong:** `rm ~/.ssh/known_hosts` — it "fixes" the error by throwing away *every* trusted server identity, and hides a genuine MITM the day one actually happens.
**Cleanup:** `sudo kill "$(sudo cat /opt/lab-ssh/sc2/sshd.pid)"; sudo deluser --remove-home labuser2; sudo rm -rf /opt/lab-ssh/sc2 /tmp/lab-ssh-sc2`

### Scenario 3 — "Udaipur: the guest list that forgot you"
**Solution:**
```bash
ssh -v -i /tmp/lab-ssh-sc3/udaipur_key -p 8024 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc3/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser3@127.0.0.1 'true' 2>&1 | tail -5
#   the key IS offered; the server just denies — so look at the SERVER's log:
sudo grep -i allowusers /opt/lab-ssh/sc3/sshd.log
#   "User labuser3 from 127.0.0.1 not allowed because not listed in AllowUsers"
sudo sed -i 's/^AllowUsers deploybot$/AllowUsers labuser3/' /opt/lab-ssh/sc3/sshd_config
sudo sshd -t -f /opt/lab-ssh/sc3/sshd_config          # validate FIRST (Rung 3.9)
sudo kill "$(sudo cat /opt/lab-ssh/sc3/sshd.pid)"
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc3/sshd_config -E /opt/lab-ssh/sc3/sshd.log
ssh -i /tmp/lab-ssh-sc3/udaipur_key -p 8024 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc3/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser3@127.0.0.1 'echo UDAIPUR-OK'
# UDAIPUR-OK
```
**Why this works & what it teaches:** `AllowUsers` is an sshd_config gate (Rung 3.9's hardening family) that rejects the user *before* `authorized_keys` is ever consulted — which is why every client-side check comes back clean and only the daemon's own log names the real reason. The habit this builds is the debugging split from Rung 7 Example 1: `ssh -v` tells you what the *client* did (key offered), the server log tells you what the *server* decided (user not on the list) — you need both halves. The `sshd -t` before restart is the Rung 3.9 typo-safety ritual, and because this is a *lab* daemon on 8024, even a botched restart could never lock you out of the VM. **Where people go wrong:** hours lost regenerating perfectly good keys because "Permission denied (publickey)" *sounds* like a key problem when it's an allow-list problem.
**Cleanup:** `sudo kill "$(sudo cat /opt/lab-ssh/sc3/sshd.pid)"; sudo deluser --remove-home labuser3; sudo rm -rf /opt/lab-ssh/sc3 /tmp/lab-ssh-sc3`

### Scenario 4 — "Madurai: the tunnel that was administratively prohibited"
**Solution:**
```bash
# 1. Build the tunnel (it authenticates fine!) and try it:
ssh -i /tmp/lab-ssh-sc4/madurai_key -p 8025 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc4/known_hosts \
    -o StrictHostKeyChecking=accept-new -N -f -L 8581:127.0.0.1:8580 labuser4@127.0.0.1
curl -s http://127.0.0.1:8581/marker.txt          # empty reply / reset
sudo grep -i 'forwarding\|prohibited' /opt/lab-ssh/sc4/sshd.log | tail -3
# 2. The server forbids it — flip the option and restart the LAB daemon:
sudo sed -i 's/^AllowTcpForwarding no$/AllowTcpForwarding yes/' /opt/lab-ssh/sc4/sshd_config
sudo sshd -t -f /opt/lab-ssh/sc4/sshd_config
sudo kill "$(sudo cat /opt/lab-ssh/sc4/sshd.pid)"
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc4/sshd_config -E /opt/lab-ssh/sc4/sshd.log
# 3. The OLD tunnel still talks to the old child process AND holds port 8581 — replace it:
pkill -f 'ssh.*-L 8581:127.0.0.1:8580'
ssh -i /tmp/lab-ssh-sc4/madurai_key -p 8025 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc4/known_hosts \
    -o StrictHostKeyChecking=accept-new -N -f -L 8581:127.0.0.1:8580 labuser4@127.0.0.1
curl -s http://127.0.0.1:8581/marker.txt
# MADURAI-DASHBOARD-OK
```
**Why this works & what it teaches:** A `-L` forward is just another *channel* on the one tunnel (Rung 3.5/3.6) — and channels can be vetoed by the server: `AllowTcpForwarding no` lets you authenticate and even hold a session, but every attempt to open a forwarded-TCP channel dies with `administratively prohibited`. That's why the failure appears *on use* (at the first curl), not at tunnel creation — a signature worth memorizing. Step 3 matters because killing the master `sshd` does not kill the already-established connection's child, so the stale tunnel both keeps the old policy alive *and* squats on port 8581 (`Address already in use` otherwise). **Where people go wrong:** blaming the dashboard ("service must be down") because `curl` through the tunnel fails, when `ss -tlnp` proves the tunnel listener exists and only the channel open is being refused.
**Cleanup:** `pkill -f "ssh.*-L 8581:127.0.0.1:8580"; sudo kill "$(sudo cat /opt/lab-ssh/sc4/sshd.pid)"; pkill -f "http.server 8580"; sudo deluser --remove-home labuser4; sudo rm -rf /opt/lab-ssh/sc4 /tmp/lab-ssh-sc4`

### Scenario 5 — "Pondicherry: three locks on one door"
**Solution:**
```bash
# LOCK 1 — client: the connection banner itself says the key is ignored:
#   "Permissions 0664 ... are too open ... This private key will be ignored."
chmod 600 /tmp/lab-ssh-sc5/pondicherry_key
# Retry → STILL denied. Move to the server log (LogLevel DEBUG):
sudo tail -20 /opt/lab-ssh/sc5/sshd.log
# LOCK 3 — the log shows sshd looking in the WRONG file:
#   "Could not open user 'labuser5' authorized keys '/home/labuser5/.ssh/authorized_keys2'"
sudo sed -i 's|^AuthorizedKeysFile .ssh/authorized_keys2$|AuthorizedKeysFile .ssh/authorized_keys|' /opt/lab-ssh/sc5/sshd_config
sudo sshd -t -f /opt/lab-ssh/sc5/sshd_config
sudo kill "$(sudo cat /opt/lab-ssh/sc5/sshd.pid)"
sudo /usr/sbin/sshd -f /opt/lab-ssh/sc5/sshd_config -E /opt/lab-ssh/sc5/sshd.log
# Retry → STILL denied. Back to the log:
#   "Authentication refused: bad ownership or modes for directory /home/labuser5/.ssh"
# LOCK 2 — StrictModes rejects the world-writable .ssh directory:
sudo chmod 700 /home/labuser5/.ssh
ssh -i /tmp/lab-ssh-sc5/pondicherry_key -p 8026 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc5/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser5@127.0.0.1 'echo PONDICHERRY-OK'
# PONDICHERRY-OK
```
**Why this works & what it teaches:** All three locks are the same principle from Rung 3.4 applied at different layers: the *client* ignores a too-open private key, the *server's* StrictModes refuses keys guarded by a writable directory (a `.ssh` others can write to means anyone could plant their own key), and `AuthorizedKeysFile` decides where the server even *looks* — the guest list from Rung 3.1 was in the right place, but the doorman was reading the wrong clipboard. The meta-skill is iterative diagnosis: fix one fault, retry, and let the *next* error message surface — with `ssh -vvv` narrating the client and `LogLevel DEBUG` narrating the server, every layer names itself. **Where people go wrong:** fixing one fault, seeing the same `Permission denied`, and concluding the fix "didn't work" — in a multi-fault system the symptom stays constant while the cause moves.
**Cleanup:** `sudo kill "$(sudo cat /opt/lab-ssh/sc5/sshd.pid)"; sudo deluser --remove-home labuser5; sudo rm -rf /opt/lab-ssh/sc5 /tmp/lab-ssh-sc5`

### Scenario 6 — "Rishikesh: the passphrase, the agent, and the call home"
**Solution:**
```bash
# 1. Start an agent in THIS shell and load the key (type the passphrase ONCE):
eval "$(ssh-agent -s)"
ssh-add /tmp/lab-ssh-sc6/rishikesh_key          # passphrase: rishikesh-lab-2026
ssh-add -l                                       # the ED25519 key is now held in memory
# 2. Open the REVERSE tunnel non-interactively — the agent signs, nothing prompts:
ssh -i /tmp/lab-ssh-sc6/rishikesh_key -p 8027 -o BatchMode=yes -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc6/known_hosts \
    -o StrictHostKeyChecking=accept-new \
    -N -f -R 8691:127.0.0.1:8690 labuser6@127.0.0.1
# 3. Prove it end-to-end from the WORKER's side of the tunnel:
ssh -i /tmp/lab-ssh-sc6/rishikesh_key -p 8027 -o BatchMode=yes -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/tmp/lab-ssh-sc6/known_hosts \
    -o StrictHostKeyChecking=accept-new labuser6@127.0.0.1 \
    'curl -s http://127.0.0.1:8691/hook.txt'
# RISHIKESH-HOOK-OK
```
**Why this works & what it teaches:** Three Rung-3 mechanisms interlock. The **agent** (3.8) holds the *decrypted* key in memory after one `ssh-add`, and because `BatchMode=yes` forbids all prompting, a passphrase-protected key is *unusable* without it — the verify command therefore objectively proves the agent is doing the challenge-signing from Rung 3.3 step 6. The **`-R` remote forward** (3.6) is the mirror image of `-L`: the *listening* socket (8691) opens on the far end and traffic flows *back* to your side (8690) — "push a service from my side to the remote," exactly the direction a callback/webhook needs. And both the interactive-less exec channel and the forwarded port are just independent channels multiplexed on one encrypted tunnel (3.5). **Where people go wrong:** running `ssh-agent` without `eval` (the agent starts but this shell never learns `SSH_AUTH_SOCK`, so `ssh-add -l` says "Could not open a connection to your authentication agent"), and mixing up which end of `-R` listens.
**Cleanup:** `pkill -f "ssh.*-R 8691:127.0.0.1:8690"; sudo kill "$(sudo cat /opt/lab-ssh/sc6/sshd.pid)"; pkill -f "http.server 8690"; ssh-add -D; eval "$(ssh-agent -k)"; sudo deluser --remove-home labuser6; sudo rm -rf /opt/lab-ssh/sc6 /tmp/lab-ssh-sc6`

# TLS, PKI & OpenSSL — Encryption, Identity, and the Certificates That Hold a Cluster Together

*The chapter that explains why `kubectl get nodes` suddenly returned `Unable to connect to the server: x509: certificate has expired` — and how the whole cluster is quietly held together by a private certificate authority you never noticed.*

---

## Rung 0 — 🎯 The Setup

**What you're learning:** TLS (Transport Layer Security) — the protocol that turns a plaintext TCP connection into an *encrypted, authenticated* one — and the **PKI** (Public Key Infrastructure) that makes it trustworthy: private keys, public certificates, Certificate Authorities, and the chain of trust. **OpenSSL** is the command-line toolbox you use to create, sign, inspect, and test all of it. TLS is not a Kubernetes feature bolted on for security; it is the *substrate* every Kubernetes component stands on. Every hop — kubelet→apiserver, apiserver→etcd, `kubectl`→apiserver, scheduler→apiserver — is mutual TLS, authenticated with certificates minted by a CA sitting in `/etc/kubernetes/pki`.

**Why it landed on your desk:** It's a Monday. Overnight, `kubectl get nodes` started returning:

```text
Unable to connect to the server: x509: certificate has expired or is not yet valid:
current time 2026-07-16T08:00:00Z is after 2026-07-15T09:12:44Z
```

The cluster is a year and a day old. Nobody rotated anything. The apiserver's serving certificate expired at the one-year mark, and now *nothing* trusts it — not your laptop, not the kubelets, not the controller-manager. Pods that were already running keep running (the kubelet doesn't kill them), but you can't schedule, can't scale, can't `exec`, can't see anything. This is the single most common self-inflicted Kubernetes outage in existence, and the fix — `kubeadm certs renew all` — takes thirty seconds *once you understand what a certificate is and why it expired*. This chapter builds that understanding from the ground up.

**What you already know that transfers:**
- **SSH keys** (`23`): you've already met asymmetric crypto — a private key you guard and a public key you hand out. TLS uses the exact same math; a certificate is *just a public key plus an identity, signed by someone you trust*.
- **Everything is a file** (`01`): keys and certs are files (`ca.crt`, `apiserver.key`). PKI is mostly "which file goes where, and who's allowed to read it" (`05` permissions — a private key is `0600` for a reason).
- **Networking** (`11`): TLS rides on top of a TCP connection. `openssl s_client` is `nc`/`curl`'s security-aware cousin.
- **kubeconfig**: the file you use every day *embeds a client certificate* — that base64 blob under `client-certificate-data` is an x509 cert proving you are `kubernetes-admin`.

---

## Rung 1 — 🔥 The Pain

Rewind to a network with no TLS. Every byte between two machines travels as **plaintext** — readable by anything on the path.

**Two distinct disasters live in that plaintext:**

1. **Eavesdropping (no confidentiality).** Anyone who can see the wire — a compromised switch, a rogue router, someone on the same coffee-shop Wi-Fi, a curious cloud tenant sharing your physical NIC — reads everything. Passwords, session tokens, your etcd's entire contents. In Kubernetes terms: if apiserver↔etcd were plaintext, *anyone sniffing that link reads every Secret in your cluster*, because etcd stores them and they cross that wire.

2. **Impersonation (no identity).** Even if you somehow encrypted the payload, how do you know the machine you connected to is *actually* the apiserver and not an attacker who hijacked the IP (ARP spoofing, DNS poisoning, a malicious pod answering on a Service IP)? Encryption to the *wrong* party is worthless. You'd hand your admin credentials straight to the impostor.

**What people did before, and why it hurt:**
- **Plaintext + "trust the network."** Early internal systems assumed the LAN was safe. That assumption died the moment networks got big, multi-tenant, and cloud-hosted. "The network is hostile" is now the default posture (zero-trust). A flat pod network where any pod can reach any other makes "trust the network" actively dangerous.
- **Shared secrets / symmetric-only schemes.** You *could* pre-share one secret key with everyone. But now every pair needs a unique key (or one leak compromises all), and there's no way to *prove identity* — a shared secret says "someone who knows the secret," not "specifically the apiserver." Key distribution becomes an unsolvable mess at cluster scale (hundreds of components, thousands of connections).

**What breaks without it:** Confidentiality *and* identity, together. You cannot safely run a distributed system on a shared network without both. Kubernetes is *nothing but* components talking over a network — so without TLS there is no safe Kubernetes at all. This is why kubeadm's very first job when it bootstraps a cluster is to **generate a CA and mint a dozen certificates** before a single pod runs.

**Who feels it most:** The platform/security engineer (you). Developers see a working `kubectl`; they never see that every request is wrapped in mutual TLS. But when a cert expires, when an audit asks "is etcd traffic encrypted?", when a mesh rollout needs per-service identity — it's the platform team holding the certificates.

> **Check yourself before Rung 2:** Encryption alone is not enough. In one sentence, explain what an attacker can still do to you even if every byte on the wire is perfectly encrypted — and what property (other than confidentiality) TLS must therefore also provide.

---

## Rung 2 — 💡 The One Idea

> **A certificate is a public key plus an identity, cryptographically signed by an authority both sides already trust; TLS uses it to prove *who* you're talking to and then to agree on a secret key that encrypts everything after.**

Memorize that sentence. Say it out loud. Everything in PKI is derived from it:

- **"a public key plus an identity"** → that's an **x509 certificate**. The identity is the **Subject** (`CN=kube-apiserver`) plus its **SANs** (the DNS names / IPs it's valid for).
- **"cryptographically signed by an authority"** → that's the **CA** (Certificate Authority). Signing = the CA using *its* private key to vouch for your public key + identity.
- **"both sides already trust"** → that's the **trust store**: each side is pre-loaded with the CA's certificate (`ca.crt`). If a cert was signed by a CA I already hold, I trust it. This is the **chain of trust**.
- **"prove who you're talking to"** → the **authentication** half of TLS. The server (and in mTLS, the client too) presents a cert; the other side verifies the signature against its trusted CA.
- **"agree on a secret key that encrypts everything after"** → the **handshake** result: a fast **symmetric** session key, used because asymmetric crypto is too slow for bulk data.

Notice the split baked into that one sentence: **asymmetric crypto (slow, for identity + key exchange) at the start; symmetric crypto (fast, for the actual data) for the rest.** That single trade-off is the shape of every TLS connection.

> **Check yourself before Rung 3:** From the one idea alone, derive *why* a CA is even necessary. Why can't two parties just exchange raw public keys directly and skip the authority? (Hint: how would you know the public key you received actually belongs to the apiserver and not an impostor who handed you *their* key?)

---

## Rung 3 — ⚙️ The Machinery

> ### 🧸 Plain-English first (read this before the technical version)
>
> **Four ideas, in the order this section presents them.**
>
> **(A) Two kinds of locks.** *Shared-key* locking: one key both locks and unlocks — very fast, but how do two strangers each get a copy without a thief intercepting it on the way? *Pair* locking: everyone has a mailbox with a public slot (anyone can drop a message in) and a private key (only the owner can open the box); the private key can also make a tamper-proof signature that anyone can check. Pair locking solves "how do strangers start trusting each other," but it's slow. The trick of TLS (the standard for secure connections): use the slow pair method *once, at the start*, just to secretly agree on a fast shared key — then use the fast method for all the real traffic.
>
> **(B) What a certificate is.** Think of a passport: it states *who this is*, includes their public mailbox slot, names *who issued it*, carries an expiry date (a hard wall — one second past it, everyone refuses the passport, no grace period), and lists exactly which names and addresses it's valid for (show up under a name not on that list and you're turned away). Crucially, the passport contains only *public* information — the matching private key stays home in a separate, closely guarded file and is never sent anywhere. The bottom of the passport carries the issuer's signature over everything above it.
>
> **(C) The chain of trust.** The issuer (a "Certificate Authority" — think passport office) is nothing magical: just its own certificate plus a signing key. "Signing" means the office takes a fingerprint of your document and seals it with its private key; "verifying" means anyone holding the office's public copy checks that the seal matches. The magic is scale: you don't pre-trust thousands of servers individually — you trust *one* passport office, and it vouches for everyone. In a Kubernetes cluster, one such office file is copied to every machine; its private key is the crown jewel, because whoever holds it can forge any identity in the cluster. A "CSR" is the application form: your public key plus your desired name, sent to the office (never your private key!), returned as a signed passport.
>
> **(D) The handshake.** When two programs connect: they say hello and compare options; the server shows its passport; the client checks the seal, the dates, and the name; in *mutual* TLS the client shows its own passport too — and inside Kubernetes, both sides always do; then both derive the same fast shared key without ever sending it across; and from that moment all traffic flows over the fast lock.

*Now the original technical deep-dive — the same ideas, in precise form:*

This is the rung to go slow on. There are four pieces to hold: **(A) the two kinds of crypto and why TLS needs both, (B) what's actually inside a certificate, (C) the chain of trust and how signing/verifying works, and (D) the handshake, hop by hop.**

### (A) Symmetric vs asymmetric crypto — the two tools

```text
SYMMETRIC (one shared key)              ASYMMETRIC (a key PAIR)
┌─────────────────────────┐            ┌──────────────────────────────┐
│  same key locks AND      │           │  PUBLIC key  — share freely    │
│  unlocks                 │           │  PRIVATE key — guard with life │
│                          │           │                                │
│  key ──▶ [ 🔒 encrypt ]  │           │  encrypt with PUBLIC           │
│  key ──▶ [ 🔓 decrypt ]  │           │    → only PRIVATE can decrypt  │
│                          │           │  sign   with PRIVATE           │
│  FAST (AES: GB/s)        │           │    → anyone with PUBLIC verify │
│  problem: how do both    │           │  SLOW (RSA/EC: ~thousands/s)   │
│  sides get the key       │           │  solves: key distribution +    │
│  without sending it in   │           │  identity, WITHOUT a shared    │
│  the clear?              │           │  secret                        │
└─────────────────────────┘            └──────────────────────────────┘
```

The genius of TLS: **use asymmetric crypto once, at the start, to safely agree on a symmetric key — then use fast symmetric crypto for all the real traffic.** Asymmetric solves the chicken-and-egg problem (how do you share a secret over an insecure wire?), and symmetric gives you speed. You get the best of both.

Two things the private key does, which map exactly to the two pains from Rung 1:
- **Decrypt** what was encrypted to your public key → *confidentiality*.
- **Sign** data (encrypt a hash with the private key) so anyone with your public key can verify it came from you → *identity / integrity*.

### (B) What's actually inside an x509 certificate

An x509 cert is a structured file (usually PEM-encoded: `-----BEGIN CERTIFICATE-----` … base64 … `-----END CERTIFICATE-----`). Peel it open and you find:

```text
┌──────────────────── x509 CERTIFICATE ────────────────────┐
│ Subject:        CN = kube-apiserver          ← WHO this is │
│ Subject Public Key: (the public half of a key pair)       │
│ Issuer:         CN = kubernetes              ← WHO signed  │
│ Validity:       Not Before 2025-07-15                     │
│                 Not After  2026-07-15        ← EXPIRY ⏰   │
│ Serial Number:  a3:f1:...                                  │
│ X509v3 extensions:                                        │
│   Subject Alternative Name (SAN):            ← valid FOR   │
│     DNS: kubernetes, kubernetes.default,                  │
│          kubernetes.default.svc,                          │
│          kubernetes.default.svc.cluster.local             │
│     IP:  10.96.0.1, 192.168.1.10                          │
│   Key Usage: Digital Signature, Key Encipherment          │
│   Extended Key Usage: TLS Web Server Authentication       │
│   Basic Constraints: CA:FALSE                             │
├───────────────────────────────────────────────────────────┤
│ Signature: (Issuer's PRIVATE key signed all of the above) │
└───────────────────────────────────────────────────────────┘
```

Critical points people miss:
- **The cert contains only the PUBLIC key.** The matching **private key lives in a separate file** (`apiserver.key`) that *never leaves the server* and is never sent over the wire. Cert = public, shareable. Key = private, `0600`, secret. Confusing these two is the #1 PKI beginner error.
- **The SAN, not the CN, is what modern clients check.** A cert for `kubernetes` will be *rejected* if you connect to it by an IP or name not listed in its SAN — you'll see `x509: certificate is valid for X, not Y`. This is why the apiserver cert lists every name and IP it can be reached by.
- **`Not After` is a hard wall.** The moment the clock passes it, every compliant client refuses the cert. No grace period. This is the expiry outage.

### (C) The chain of trust — signing and verifying

A **CA** is nothing magical: it's just a certificate whose `Basic Constraints` says `CA:TRUE`, plus its private key. "Signing" means the CA computes a hash of your certificate's contents and encrypts that hash with its private key. "Verifying" means a client decrypts that signature with the CA's *public* key (from `ca.crt`) and checks the hash matches. If it does, the cert is authentic and untampered.

```text
THE CHAIN OF TRUST

   ┌─────────────────┐   signs   ┌──────────────────────┐
   │   Root CA       │──────────▶│  apiserver.crt        │
   │  (ca.crt)       │  with its │  Subject: kube-apiserver│
   │  self-signed    │  ca.key   │  Issuer:  kubernetes   │
   │  Issuer=Subject │           └──────────────────────┘
   └─────────────────┘
          ▲
          │ pre-installed in EVERY component's trust store
          │ (kubelet, kubectl, controller-manager all hold ca.crt)
          │
   A client verifies apiserver.crt by:
     1. reading its Issuer  → "kubernetes"
     2. finding that CA in its trust store (ca.crt)
     3. checking the signature with the CA's public key ✓
     4. checking validity dates + SAN match ✓
   → TRUSTED. No prior contact with the apiserver needed.
```

This is the whole trick that makes PKI *scale*: you don't have to pre-trust every server individually. You pre-trust **one** CA, and that CA vouches for thousands of certs. In Kubernetes, `/etc/kubernetes/pki/ca.crt` is that one root, and it's distributed to every node and embedded in every kubeconfig. That single file is the root of trust for the entire cluster — lose or replace `ca.key` and you can forge any identity in the cluster, which is why it's the crown jewel.

A **CSR** (Certificate Signing Request) is the "please sign me" envelope. When a server needs a cert, it generates a key pair, wraps its public key + desired identity into a CSR, and sends the CSR (never the private key!) to the CA. The CA signs it and hands back a certificate. Kubernetes even has a native `CertificateSigningRequest` API object that automates exactly this dance for kubelets joining the cluster.

### (D) The TLS handshake, hop by hop

```text
CLIENT (kubectl / kubelet)                       SERVER (kube-apiserver)
        │                                                 │
        │ 1. ClientHello  (TLS versions, cipher list) ──▶ │
        │                                                 │
        │ ◀── 2. ServerHello (chosen cipher)              │
        │ ◀── 3. Certificate (apiserver.crt + chain)      │
        │                                                 │
   4. VERIFY the cert:                                    │
      • signature chains to my trusted ca.crt?  ✓         │
      • today is within Not Before..Not After? ✓          │
      • SAN matches the host I dialed?          ✓          │
        │                                                 │
        │ ── (mTLS) 3b. Server asks: "your cert too"       │
        │ ── 4b. Client sends its client cert ──────────▶ │  server verifies
        │                                                 │  it against ca.crt
        │ 5. Key exchange (ECDHE): both derive the SAME   │
        │    symmetric session key, never sending it ───▶ │
        │                                                 │
        │ ══════ 6. Symmetric-encrypted channel ══════════ │
        │      all API traffic now flows over AES         │
```

Steps 1–4 are the **asymmetric** phase (identity + key agreement). Step 6 onward is the **symmetric** phase (fast bulk encryption). Step 4b is what makes it **mTLS (mutual TLS)** — *both* sides prove identity, not just the server. **Every internal Kubernetes connection is mTLS**: the kubelet proves it's a node, the apiserver proves it's the apiserver, and each checks the other against the shared CA. This is why a kubelet with an expired client cert gets `Unauthorized` and a kubectl facing an expired serving cert gets `certificate has expired`.

> **Check yourself before Rung 4:** Draw the chain of trust from memory. Then answer: when `kubectl` verifies the apiserver's certificate, which file on *your* machine does it use to check the signature, and does that file contain a public key or a private key? And in *mutual* TLS, what extra step happens that plain TLS skips?

---

## Rung 4 — 🏷️ The Vocabulary Map

Every scary word here is just a label for a piece of the machinery you now hold.

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **TLS** | Protocol for encrypted + authenticated connections (SSL's successor) | The whole handshake (Rung 3D) |
| **SSL** | The obsolete predecessor of TLS; people still say "SSL" to mean TLS | Historical name only — always use TLS |
| **Symmetric key** | One key that both encrypts and decrypts (AES) | The fast session channel (3A, step 6) |
| **Asymmetric / public-key crypto** | A key *pair*: public + private (RSA, EC) | Identity + key exchange (3A, steps 3–5) |
| **Private key** | The secret half; signs and decrypts; `0600`, never shared | Lives on the server (`apiserver.key`) |
| **Public key** | The shareable half; embedded *inside* the certificate | Sent to clients inside the cert |
| **Certificate (x509)** | Public key + identity + validity, signed by a CA | What the server presents (3B) |
| **CN (Common Name)** | The Subject's primary name field | Identity in the cert (legacy for hostnames) |
| **SAN** | Subject Alternative Name: the DNS names/IPs the cert is valid for | What clients actually match on (3B) |
| **CA (Certificate Authority)** | A cert (`CA:TRUE`) + its private key that signs other certs | Root of the chain of trust (3C) |
| **Root CA / self-signed** | A CA whose Issuer == Subject; the top of the chain | `/etc/kubernetes/pki/ca.crt` |
| **Chain of trust** | Verifying a cert by following signatures up to a trusted CA | The verify step (3C, handshake step 4) |
| **Trust store** | The set of CA certs a client pre-trusts | Where `ca.crt` is loaded on each side |
| **CSR** | Certificate Signing Request: public key + identity, unsigned | The "please sign me" envelope (3C) |
| **Signing** | CA hashing a cert and encrypting the hash with its private key | How a CA vouches (3C) |
| **Handshake** | The negotiation that authenticates and agrees a session key | Rung 3D steps 1–5 |
| **mTLS (mutual TLS)** | Both client *and* server present certificates | Step 4b — every internal K8s hop |
| **PEM** | Base64 text encoding with `-----BEGIN...-----` headers | On-disk format of keys/certs |
| **PKI** | The whole system of keys, certs, CAs, and trust | Everything on this rung |
| **Expiry (`notAfter`)** | The hard deadline after which a cert is rejected | The outage cause (3B) |

### The big unlock — which terms are the *same kind of thing*

```text
GROUP 1 — "the secret half vs the shareable half" (one key pair):
   Private key = signs/decrypts, guarded, 0600, apiserver.key
   Public key  = verifies/encrypts, shared — and it LIVES INSIDE the certificate
   → A certificate is just "public key + identity + a CA's signature."

GROUP 2 — "names for identity inside a cert":
   Subject / CN (the primary name)  +  SAN (all valid names/IPs)
   → Modern clients check the SAN. CN alone is legacy.

GROUP 3 — "the authority and its output":
   CA = the signer (cert + private key)
   Signing = what it does;  Chain of trust = following those signatures up
   Trust store = the CA certs you already believe

GROUP 4 — "the two crypto engines TLS switches between":
   Asymmetric (slow, start: prove identity + agree a key)
   Symmetric  (fast, rest: encrypt the actual bytes)

GROUP 5 — "the request-to-be-signed vs the signed result":
   CSR (unsigned request)  →  Certificate (signed result)
```

Hold those five groups and the jargon stops being fifteen unrelated words.

> **Check yourself before Rung 5:** Without looking — which file holds the public key, the certificate or the key file? And which two terms are "the unsigned request" versus "the signed result" of asking a CA for a cert?

---

## Rung 5 — 🔬 The Trace

Let's trace ONE concrete action end to end: **you type `kubectl get nodes`, and the client establishes a mutually-authenticated TLS connection to the apiserver at `https://10.0.0.5:6443`.** This is the exact path that *fails* in the expiry outage — tracing it tells you precisely where.

**Step 1 — kubectl reads your kubeconfig.** From `~/.kube/config` it pulls three things: the apiserver URL, the cluster's `certificate-authority-data` (the CA cert it will trust — this is *your* trust store for this cluster), and your `client-certificate-data` + `client-key-data` (your identity, an x509 cert saying `CN=kubernetes-admin, O=system:masters`). All three are base64-embedded right there in the file.

**Step 2 — TCP connect.** kubectl opens a plain TCP socket to `10.0.0.5:6443`. Nothing is encrypted yet.

**Step 3 — ClientHello.** kubectl announces supported TLS versions and cipher suites.

**Step 4 — apiserver presents its serving cert.** The apiserver sends `/etc/kubernetes/pki/apiserver.crt` (public key + `CN=kube-apiserver`, SAN listing `10.0.0.5`, `kubernetes.default.svc`, etc.), signed by `/etc/kubernetes/pki/ca.crt`.

**Step 5 — kubectl VERIFIES the server cert (the identity check).** Using the CA cert from kubeconfig, kubectl checks: (a) does the signature chain to my trusted CA? (b) is `10.0.0.5` in the SAN? (c) **is today between Not Before and Not After?** *This is the exact check that fails in the outage.* If the apiserver cert expired last night, step 5c fails and kubectl aborts with `x509: certificate has expired` — no data ever flows.

**Step 6 — apiserver requests the client's cert (mTLS).** Because internal K8s is mutual, the apiserver replies "prove who *you* are." kubectl sends your client cert from kubeconfig.

**Step 7 — apiserver verifies YOUR cert** against the same `ca.crt`, reads `O=system:masters` from your Subject, and maps it to the `cluster-admin` authorization group. *This* is how RBAC knows who you are — your identity is cryptographic, carried in the cert.

**Step 8 — key agreement + symmetric channel.** Both sides run ECDHE to derive an identical AES session key without ever transmitting it. From here, the `GET /api/v1/nodes` request and the JSON node list flow **AES-encrypted**.

**Step 9 — apiserver serves the request (itself over mTLS to etcd).** To answer, the apiserver reads node objects from etcd — over *another* mTLS connection using `/etc/kubernetes/pki/apiserver-etcd-client.crt`, verified against `/etc/kubernetes/pki/etcd/ca.crt`. Certs all the way down.

```text
THE TRACE  (each 🔒 = a cert verified)

  kubectl ──TCP──▶ apiserver:6443
     │ reads kubeconfig: CA + client cert + key
     │
     │ ◀── apiserver.crt (SAN, dates)     🔒 step 5: kubectl verifies server
     │                                        └─ EXPIRED? → x509 error, STOP
     │ ── client cert (CN=admin) ──▶       🔒 step 7: apiserver verifies client
     │                                        └─ O=system:masters → cluster-admin
     │ ══ AES session key agreed ══         (symmetric from here)
     │ ── GET /api/v1/nodes ─────▶
     │                              apiserver ──🔒 mTLS──▶ etcd  (reads nodes)
     │ ◀──────── node list (JSON) ──
```

Everything you do with `kubectl` rides this exact path. The "cert expired" outage is simply **step 5c returning false**, cluster-wide, for every client at once.

> **Check yourself before Rung 6:** At which numbered step does the classic expiry outage actually fail, and which side is doing the checking? And at step 7, how does the apiserver know you're allowed to be `cluster-admin` — where does that identity physically come from?

---

## Rung 6 — ⚖️ The Contrast

### The alternative: plaintext, or shared-secret / symmetric-only auth

Before PKI, the options for "secure this connection" were grim:

```text
                    Confidentiality   Identity        Scales to N parties?
─────────────────────────────────────────────────────────────────────────
Plaintext           ❌ none           ❌ none          n/a
Shared secret       ⚠️ if key stays   ⚠️ "someone who   ❌ every pair needs
(symmetric-only)       secret            knows the key"     its own key; one
                                                            leak = total loss
TLS + PKI           ✅ per-session    ✅ cryptographic  ✅ trust ONE CA,
(asymmetric)           AES key           identity via       it vouches for all
                                         signed certs
```

The structural win of PKI: **you distribute trust once (the CA cert), and it covers unlimited parties.** A shared-secret scheme forces O(N²) key management and can never prove *specifically who* — only "somebody holding the secret." That's why Kubernetes, with its hundreds of components and thousands of connections, *must* use a CA-based model. There is no shared-secret design that survives at cluster scale with real identity.

### What TLS/PKI can do that the alternatives can't

| Task | Plaintext | Shared secret | TLS + PKI | Why |
|---|---|---|---|---|
| Hide bytes from a network sniffer | ❌ | ✅* | ✅ | Both encrypt; PKI negotiates a fresh key per session |
| Prove the peer is *specifically* the apiserver | ❌ | ❌ | ✅ | Only a signed cert binds identity to a key |
| Add a new node without re-keying everyone | ❌ | ❌ | ✅ | New node just needs a cert from the existing CA |
| Revoke one compromised identity | ❌ | ❌ (must re-key all) | ✅ | Rotate/deny one cert; others untouched |
| Survive one leaked credential | ❌ | ❌ (all lost) | ✅ | Each holder has its own key pair |

The pattern in the "why" column is always the same: **asymmetric keys + a signing authority let you bind identity to a key and manage trust centrally.** Symmetric-only schemes can encrypt, but they can't *name* anyone.

### When would I NOT reach for full PKI?

- **A quick throwaway/dev endpoint** where you genuinely don't care who connects and there's no sensitive data — plaintext HTTP inside an isolated network namespace can be fine for a lab. (But never for etcd or the apiserver.)
- **Two processes on the same host** talking over a Unix socket with filesystem permissions — the OS already authenticates them; wrapping that in TLS is often over-engineering.
- **Symmetric MACs for message integrity** where you already share a secret and don't need identity (e.g., signing a webhook payload with an HMAC) — lighter than a full cert.

**One-sentence "why this over that":**
> Use TLS + PKI whenever parties who don't already share a secret must talk securely over a hostile network *and* need to prove who each other is — which is every connection in a Kubernetes cluster; fall back to simpler schemes only for same-host or truly trust-nothing-needed cases.

> **Check yourself before Rung 6→7:** Explain to a colleague why a shared-secret scheme *structurally cannot* tell you "I'm specifically talking to the apiserver" — not "it lacks the feature," but why the design makes cryptographic identity impossible. (Hint: what does knowing the secret actually prove about *who* you are?)

---

## Rung 7 — 🧪 The Prediction Test

Write the prediction BEFORE running each command. A wrong prediction is your model repairing itself. All of these run on any modern Linux with `openssl` installed (Ubuntu 22.04: `apt-get install -y openssl`; RHEL family: `dnf install -y openssl` — the OpenSSL 3.x default on both). Work in a scratch directory: `mkdir -p /tmp/pki && cd /tmp/pki`.

---

### Prediction 1 — Build a CA and sign a server cert (the happy path)

> **My prediction:** "If I generate a CA key + self-signed CA cert, then generate a server key and CSR, then sign that CSR with the CA, I'll end up with a `server.crt` whose **Issuer** is my CA and whose **Subject** is my server — *because* signing is the CA vouching for the server's public key + identity, which is exactly what puts the CA's name in the Issuer field."

```bash
# 1. The CA: a private key, then a self-signed cert (Issuer == Subject)
openssl genrsa -out ca.key 2048
openssl req -x509 -new -key ca.key -out ca.crt -days 3650 -subj "/CN=my-ca"
#   (-x509 makes it self-signed; -days sets validity. Default without -days is 30!)

# 2. The server: its own key, then a CSR (public key + desired identity)
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=myserver.example.com"

# 3. The CA signs the CSR → a real certificate
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365

# 4. Look at what you made
openssl x509 -in server.crt -noout -subject -issuer
#   subject=CN = myserver.example.com
#   issuer=CN = my-ca                 ← the CA vouched for it
```

**Verify:** `issuer=CN = my-ca` and `subject=CN = myserver.example.com`. If Issuer and Subject were the *same*, you'd have accidentally made a self-signed cert (step 3 didn't use the CA). The `-CAcreateserial` flag creates `ca.srl` to track serial numbers — a real CA never issues two certs with the same serial.

Modern-OpenSSL note: `openssl genpkey -algorithm RSA -out ca.key -pkeyopt rsa_keygen_bits:2048` is the newer, algorithm-agnostic equivalent of `genrsa` (and how you'd generate an EC key: `-algorithm EC -pkeyopt ec_paramgen_curve:P-256`).

---

### Prediction 2 — Verify the chain, then watch a wrong CA fail (the trust check)

> **My prediction:** "If I run `openssl verify -CAfile ca.crt server.crt` it will print `OK`, but if I verify against an *unrelated* CA it will FAIL with a `unable to get local issuer certificate` error — *because* verification is checking the server cert's signature against the CA's public key, and a different CA's public key won't validate a signature it didn't make."

```bash
# Chains correctly to the CA that signed it:
openssl verify -CAfile ca.crt server.crt
#   server.crt: OK

# Now make an UNRELATED CA and try to verify against it:
openssl genrsa -out other-ca.key 2048
openssl req -x509 -new -key other-ca.key -out other-ca.crt -days 365 -subj "/CN=other-ca"

openssl verify -CAfile other-ca.crt server.crt
#   CN = myserver.example.com
#   error 20 at 0 depth lookup: unable to get local issuer certificate
#   error server.crt: verification failed
```

**Verify:** First is `OK`, second `verification failed`. This *is* the chain of trust in action — and it's exactly why a cluster where you replaced `ca.crt` but not the component certs falls apart: the components no longer chain to the CA the apiserver presents. If both had said OK, your mental model of "any CA can validate any cert" would need repair — only the *signing* CA can.

---

### Prediction 3 — SANs: the cert that's valid for the wrong name (the edge case)

> **My prediction:** "If I sign a cert with a SAN of `DNS:api.internal` and then have a client verify it *as if connecting to* `wrong.host`, verification will fail with a name-mismatch — *because* modern TLS checks the hostname against the SAN list, and `wrong.host` isn't in it. This is the `certificate is valid for X, not Y` error class."

```bash
# Sign a server cert that carries a SAN. Note: `openssl x509 -req` DROPS
# extensions from the CSR unless you feed them in via -extfile.
cat > san.ext <<'EOF'
subjectAltName = DNS:api.internal, IP:10.0.0.5
EOF

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out san.crt -days 365 -extfile san.ext
#   (OpenSSL 3.0+ alternative to preserve CSR extensions: add -copy_extensions copyall)

# Confirm the SAN landed in the cert:
openssl x509 -in san.crt -noout -ext subjectAltName
#   X509v3 Subject Alternative Name:
#       DNS:api.internal, IP Address:10.0.0.5

# Simulate a client checking the WRONG hostname against this cert:
openssl verify -CAfile ca.crt -verify_hostname wrong.host san.crt
#   ... verification failed  (hostname mismatch)

# And the RIGHT name passes:
openssl verify -CAfile ca.crt -verify_hostname api.internal san.crt
#   san.crt: OK
```

**Verify:** `wrong.host` fails, `api.internal` succeeds. If you predicted the CN alone would save you, repair that: the SAN is authoritative for name-matching now, and a missing/wrong SAN is one of the most common "but the cert is valid!" TLS failures in the wild — and exactly why regenerating the apiserver cert requires listing *every* name/IP the apiserver answers to.

---

### Prediction 4 — Inspect Kubernetes' own PKI and check expiry (the K8s case)

> **My prediction:** "On a kubeadm control-plane node, `/etc/kubernetes/pki/apiserver.crt` will be issued by `CN=kubernetes` (the cluster CA), its SAN will list the Service IP `10.96.0.1` and `kubernetes.default.svc...`, and `-enddate` will show a date about one year after the cluster was created — *because* kubeadm generates a self-signed cluster CA and mints a one-year serving cert bound to every apiserver name."

```bash
# Full human-readable dump — Subject, Issuer, SAN, validity, key usage:
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | \
  grep -A1 -E 'Issuer|Subject:|Not (Before|After)|Alternative'
#   Issuer: CN = kubernetes
#   Subject: CN = kube-apiserver
#   Not Before: ...    Not After : ... (≈ +1 year)
#   X509v3 Subject Alternative Name:
#     DNS:kubernetes, DNS:kubernetes.default, ... IP Address:10.96.0.1 ...

# Just the expiry date of any cert file:
sudo openssl x509 -noout -enddate -in /etc/kubernetes/pki/apiserver.crt
#   notAfter=Jul 15 09:12:44 2026 GMT

# The kubeadm-native, whole-PKI view — every cert and when it dies:
sudo kubeadm certs check-expiration
#   CERTIFICATE                EXPIRES                  RESIDUAL TIME  ...
#   apiserver                  Jul 15, 2026 09:12 UTC   3d             ...
#   apiserver-etcd-client      Jul 15, 2026 09:12 UTC   3d             ...
#   etcd-server                Jul 15, 2026 09:12 UTC   3d             ...
#   ...
```

**Verify:** Issuer `CN = kubernetes`, a SAN containing `10.96.0.1`, and `kubeadm certs check-expiration` listing ~10 certs with matching dates. If `RESIDUAL TIME` shows something small like `3d` or `<invalid>`, you're staring at the outage before it happens. Note the **CA** cert itself (`ca.crt`) is valid for *10 years* — it's the leaf certs (apiserver, etcd, kubelet clients) that expire yearly. When they're close, the fix is:

```bash
sudo kubeadm certs renew all        # re-sign every leaf cert with the existing CA
sudo systemctl restart kubelet      # and restart the control-plane static pods
# (apiserver/controller-manager/scheduler are static pods; kubeadm restarts them
#  by rewriting their manifests, or restart kubelet to pick up renewed certs)
```

---

### Prediction 5 — Test the *live* apiserver endpoint with s_client (the network case)

> **My prediction:** "If I point `openssl s_client` at `localhost:6443`, it will complete a TLS handshake and hand me the apiserver's *serving* cert, and piping that into `openssl x509 -noout -dates` will print the same `notAfter` I saw on disk in Prediction 4 — *because* `s_client` is a real TLS client; the cert it receives on the wire is literally `apiserver.crt` being served."

```bash
# Grab the cert the apiserver actually presents on the wire, read its dates:
openssl s_client -connect localhost:6443 </dev/null 2>/dev/null | \
  openssl x509 -noout -dates
#   notBefore=Jul 15 09:12:44 2025 GMT
#   notAfter=Jul 15 09:12:44 2026 GMT

# Same tool, more detail — see the SAN and who issued it, live:
echo | openssl s_client -connect localhost:6443 2>/dev/null | \
  openssl x509 -noout -subject -issuer -ext subjectAltName

# Verify the live cert against the cluster CA (should say "Verify return code: 0"):
openssl s_client -connect localhost:6443 -CAfile /etc/kubernetes/pki/ca.crt \
  </dev/null 2>/dev/null | grep "Verify return code"
#   Verify return code: 0 (ok)
```

**Verify:** The `notAfter` from the wire matches the one from the file — proving `s_client` shows you *ground truth*, what clients actually receive, not what's merely sitting on disk (they can differ if the apiserver wasn't restarted after a renew!). If `Verify return code` is `10 (certificate has expired)`, you've just reproduced the exact outage from Rung 0 with a single command. `</dev/null` (or `echo |`) is essential — it closes stdin so `s_client` doesn't hang waiting for you to type an HTTP request.

---

### The prediction habit, generalized

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. | | | |
| 2. | | | |
| 3. | | | |

---

## Rung 8 — 🏔 Capstone: Compress It

**One sentence, no notes:**
> A certificate is a public key bound to an identity and signed by a trusted CA; TLS uses it to authenticate the peer and negotiate a symmetric session key, and Kubernetes runs entirely on this — every component-to-apiserver and apiserver-to-etcd link is mutual TLS chained to the CA in `/etc/kubernetes/pki`.

**Explain it to a beginner in 3 sentences:**
> 1. Every server that wants secure connections has a secret private key and a public certificate that says "here's my public key and my name," and that certificate is signed by a Certificate Authority everyone already trusts.
> 2. When a client connects, it checks the server's certificate against the trusted CA, confirms the name and expiry match, and then the two sides use slow public-key math *once* to agree on a fast shared key that encrypts the rest of the conversation.
> 3. Kubernetes bootstraps its own private CA and gives every component a certificate, so kubelet, kube-apiserver, and etcd all prove their identities to each other on every request — and when one of those certificates hits its one-year expiry, the whole cluster locks you out until you run `kubeadm certs renew all`.

**Map of sub-capability → the one core idea (it's all one pattern):**

```text
The one idea: "a signed public key proves identity, then bootstraps encryption."

Encrypt traffic         → symmetric session key negotiated in the handshake
Prove server identity   → verify its cert's signature chains to a trusted CA
Prove client identity   → mTLS: client presents its own cert (kubeconfig)
Name matching           → SAN in the cert vs the host you dialed
Trust at scale          → one CA (ca.crt) vouches for thousands of certs
Kubernetes PKI          → kubeadm's CA signs apiserver/etcd/kubelet certs
Service mesh (Istio)    → same primitives, per-workload certs from mesh CA
The expiry outage       → notAfter passes → every client rejects the cert
```

Eight rows, one idea: *a signature from a trusted authority turns a public key into a provable identity.*

**Which rung will I most likely need to revisit hands-on?**
- **Rung 3C (the chain of trust)** — signing vs verifying stays fuzzy until you've built a CA and watched `openssl verify` accept your cert and reject a stranger's (Predictions 1–2). Do those with your own hands.
- **Rung 7, Prediction 5 (`s_client` on the live apiserver)** — the difference between "the cert on disk" and "the cert actually being served" is the subtle thing that bites people *after* a renew when they forgot to restart the apiserver. Run it against a real cluster until "on the wire vs on disk" is instinct.

If either felt shaky on the check-yourself questions, that's your next 30-minute session — build the toy CA first, then go look at `/etc/kubernetes/pki`.

---

## Related concepts

- [ssh-remote-access](23-ssh-remote-access.md) — the same asymmetric key pairs, minus the CA and certificate layer
- [networking](11-networking.md) — the TCP connections TLS wraps; `ss`, ports, and `curl`
- [permissions-ownership](05-permissions-ownership.md) — why a private key must be `0600` and who may read `/etc/kubernetes/pki`
- [linux-philosophy](01-linux-philosophy.md) — keys and certs are just files; PKI is "which file goes where"
- [systemd-services](16-systemd-services.md) — the kubelet unit and static-pod manifests you restart after renewing certs
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — where the cluster PKI sits in the full node-triage picture

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Encryption alone is not enough. What can an attacker still do even if every byte on the wire is perfectly encrypted, and what property must TLS therefore also provide?

**A:** Even with perfect encryption, an attacker who hijacks the connection endpoint (ARP spoofing, DNS poisoning, a malicious pod answering on a Service IP) can **impersonate the server** — you would then encrypt everything flawlessly *to the impostor*, handing them your admin credentials and data, because encryption to the wrong party is worthless. TLS must therefore also provide **identity (authentication)**: cryptographic proof that the peer is specifically who it claims to be, delivered via a certificate signed by an authority both sides already trust.

### Before Rung 3
**Q:** From the one idea alone, derive why a CA is even necessary. Why can't two parties just exchange raw public keys directly?

**A:** Because a raw public key carries no proof of *whose* key it is. If the apiserver sends you "its" public key over the network, a man-in-the-middle can simply substitute *their own* public key — you'd verify signatures and encrypt happily, but to the attacker; you have no way to distinguish the genuine key from the impostor's. The key-exchange step is exactly as vulnerable as the plaintext it was meant to protect. A CA breaks this circle: both sides are *pre-loaded* with one trusted certificate (`ca.crt`), and the CA uses its private key to sign "this public key belongs to kube-apiserver." Now the binding between key and identity is verifiable offline against something you already trust, with no prior contact with the server needed — and one trusted root can vouch for thousands of parties instead of every pair having to solve the problem again.

### Before Rung 4
**Q:** Draw the chain of trust from memory. Which file on your machine does `kubectl` use to check the apiserver cert's signature — public or private key inside it? And what extra step does mutual TLS add?

**A:** The chain: the self-signed Root CA (Issuer == Subject, `ca.crt` + guarded `ca.key`) signs `apiserver.crt`; every component (kubectl, kubelet, controller-manager) is pre-loaded with `ca.crt` in its trust store; a client verifies the apiserver cert by reading its Issuer, finding that CA in its trust store, checking the signature with the CA's public key, then checking validity dates and SAN match. The file `kubectl` uses is the **CA certificate** — embedded in your kubeconfig as `certificate-authority-data` (a copy of `/etc/kubernetes/pki/ca.crt`) — and it contains the CA's **public** key only; the CA's private key never leaves the control plane. Mutual TLS adds step 4b: after the server proves itself, the **server asks the client for a certificate too**, and the client presents its own cert (e.g. `CN=kubernetes-admin`), which the server verifies against the same CA — so *both* sides prove identity, not just the server.

### Before Rung 5
**Q:** Which file holds the public key — the certificate or the key file? And which two terms are "the unsigned request" versus "the signed result"?

**A:** The **certificate** holds the public key — a cert is exactly "public key + identity + a CA's signature," and it is the shareable artifact sent over the wire. The key file (e.g. `apiserver.key`) holds the **private** key: secret, mode `0600`, never transmitted. The unsigned request is the **CSR** (Certificate Signing Request) — the server's public key plus desired identity, wrapped up and sent to the CA (never including the private key); the signed result the CA hands back is the **certificate** itself.

### Before Rung 6
**Q:** At which numbered step of the trace does the classic expiry outage fail, and which side is checking? At step 7, how does the apiserver know you're allowed to be `cluster-admin`?

**A:** The expiry outage fails at **step 5 — specifically check 5c** ("is today between Not Before and Not After?"), and it is the **client** (kubectl) doing the checking: it verifies the apiserver's serving cert against the CA from kubeconfig, sees that `Not After` has passed, and aborts with `x509: certificate has expired` before any data flows. At step 7, your identity comes physically from the **client certificate embedded in your kubeconfig** (`client-certificate-data`): the apiserver verifies it against `ca.crt` and reads the Subject — `CN=kubernetes-admin, O=system:masters` — and RBAC maps the `system:masters` group to `cluster-admin`. Your authorization is cryptographic: it's carried in a CA-signed cert, not in a password or token lookup.

### Before Rung 7
**Q:** Why does a shared-secret scheme *structurally* fail to prove "I'm specifically talking to the apiserver" — why is cryptographic identity impossible in that design?

**A:** Because knowing a shared secret proves only membership, never identity: the secret is by definition held by more than one party, so any proof built on it can be produced by *every* holder equally. A successful "prove you know the key" exchange tells you the peer is "someone who knows the key" — which could be the apiserver, any kubelet holding the same secret, or an attacker who stole it from any one of them — and there is nothing in the math to distinguish which holder you're facing. Naming a *specific* party requires something only that party possesses, i.e. a per-party private key, plus an authority binding that key to a name — exactly what asymmetric crypto and a CA-signed certificate provide and what a symmetric shared secret structurally cannot, since making the secret sharable is the very thing that destroys its ability to name anyone. (It also scales terribly: unique pairwise keys are O(N²), and one leak compromises everyone.)

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — several setups need `sudo` and some deliberately break things. For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6. (Two setups mint deliberately-expired certificates: on OpenSSL ≥ 3.4 they use `-not_before`/`-not_after` natively, and on older versions they fall back to installing `faketime` — the `if` block handles both.)

### 🟢 Scenario 1 — "Wellington: the certificate that died in the night" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-wellington && cd /opt/lab-wellington
sudo openssl genrsa -out ca.key 2048
sudo openssl req -x509 -new -key ca.key -out ca.crt -days 3650 -subj "/CN=lab-wellington-ca"
sudo openssl genrsa -out server.key 2048
sudo openssl req -new -key server.key -out server.csr -subj "/CN=api.devopsinminutes.com"
if openssl x509 -help 2>&1 | grep -q not_after; then
  sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -not_before 20250101000000Z -not_after 20250201000000Z
else
  sudo apt-get install -y faketime >/dev/null
  sudo faketime '2025-01-01 00:00:00' openssl x509 -req -in server.csr -CA ca.crt \
    -CAkey ca.key -CAcreateserial -out server.crt -days 31
fi
echo "setup complete — clients of api.devopsinminutes.com started failing overnight"
```
**Situation:** It's the Monday from Rung 0, in miniature: overnight, every client of `api.devopsinminutes.com` began refusing to connect with `x509: certificate has expired or is not yet valid`. The service itself is healthy; nothing was deployed. The site's PKI lives in `/opt/lab-wellington/` — CA, server key, CSR, and the serving cert.

**Your task:** Prove from the certificate file exactly why clients are rejecting it, then re-issue a valid one-year serving certificate from the same CA — without generating a new key pair — so verification passes again.

**Verify:**
```bash
openssl verify -CAfile /opt/lab-wellington/ca.crt /opt/lab-wellington/server.crt   # expected: server.crt: OK
openssl x509 -in /opt/lab-wellington/server.crt -noout -enddate                    # expected: a notAfter date in the future
```

### 🟢 Scenario 2 — "Christchurch: three authorities walk into a bar" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-christchurch/cas && cd /opt/lab-christchurch
for i in 1 2 3; do
  sudo openssl genrsa -out cas/ca$i.key 2048
  sudo openssl req -x509 -new -key cas/ca$i.key -out cas/ca$i.crt -days 3650 -subj "/CN=platform-root-ca"
done
sudo openssl genrsa -out server.key 2048
sudo openssl req -new -key server.key -out server.csr -subj "/CN=payments.devopsinminutes.com"
sudo openssl x509 -req -in server.csr -CA cas/ca2.crt -CAkey cas/ca2.key -CAcreateserial -out server.crt -days 365
sudo rm -f server.csr
echo "setup complete — one server cert, three identically-named CAs, no notes"
```
**Situation:** During a datacenter migration someone exported "the platform CA" three times, and now `/opt/lab-christchurch/cas/` holds three root certificates — all with the *identical* subject `CN=platform-root-ca`, but generated from three different key pairs. Exactly one of them actually signed `server.crt`. New services need the right one installed in their trust store, and picking wrong means every handshake fails with `unable to get local issuer certificate` (or worse, `certificate signature failure`).

**Your task:** Determine cryptographically — not by reading name fields, which are identical — which CA really signed `server.crt`, and install a copy of it as `/opt/lab-christchurch/trusted-ca.crt`.

**Verify:**
```bash
openssl verify -CAfile /opt/lab-christchurch/trusted-ca.crt /opt/lab-christchurch/server.crt   # expected: server.crt: OK
```

### 🟡 Scenario 3 — "Dunedin: valid for the wrong universe" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-dunedin && cd /opt/lab-dunedin
sudo openssl genrsa -out ca.key 2048
sudo openssl req -x509 -new -key ca.key -out ca.crt -days 3650 -subj "/CN=lab-dunedin-ca"
sudo openssl genrsa -out server.key 2048
sudo openssl req -new -key server.key -out server.csr -subj "/CN=payments-v1.internal"
sudo bash -c 'printf "subjectAltName = DNS:payments-v1.internal\n" > san.ext'
sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san.ext
echo "setup complete — the payments service was just renamed api.devopsinminutes.com"
```
**Situation:** The payments service graduated from its internal name `payments-v1.internal` to the public name `api.devopsinminutes.com`. The cert is not expired, chains perfectly to the CA, and `openssl verify -CAfile ca.crt server.crt` says OK — yet every client connecting by the new name fails with the error class `certificate is valid for payments-v1.internal, not api.devopsinminutes.com`. Old clients using the legacy name must keep working during the transition.

**Your task:** Re-issue the serving certificate (same CA, same key) so that hostname verification succeeds for **both** `api.devopsinminutes.com` and `payments-v1.internal`. Remember the Rung 7 gotcha: `openssl x509 -req` drops extensions unless you feed them in explicitly.

**Verify:**
```bash
openssl verify -CAfile /opt/lab-dunedin/ca.crt -verify_hostname api.devopsinminutes.com /opt/lab-dunedin/server.crt   # expected: server.crt: OK
openssl verify -CAfile /opt/lab-dunedin/ca.crt -verify_hostname payments-v1.internal /opt/lab-dunedin/server.crt      # expected: server.crt: OK
```

### 🟡 Scenario 4 — "Cairns: the key that fits no lock" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-cairns/keys && cd /opt/lab-cairns
sudo openssl genrsa -out ca.key 2048
sudo openssl req -x509 -new -key ca.key -out ca.crt -days 3650 -subj "/CN=lab-cairns-ca"
for i in 1 2 3; do sudo openssl genrsa -out keys/rotation-$i.key 2048; done
sudo openssl req -new -key keys/rotation-2.key -out server.csr -subj "/CN=localhost"
sudo bash -c 'printf "subjectAltName = DNS:localhost, IP:127.0.0.1\n" > san.ext'
sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san.ext
sudo cp keys/rotation-3.key server.key
sudo tee /etc/systemd/system/lab-cairns.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Cairns - TLS endpoint on 8443

[Service]
ExecStart=/usr/bin/openssl s_server -accept 8443 -www -cert /opt/lab-cairns/server.crt -key /opt/lab-cairns/server.key
Restart=on-failure
UNIT
sudo systemctl daemon-reload
sudo systemctl start lab-cairns.service || true
echo "setup complete — the TLS endpoint refuses to come up after last night's key rotation"
```
**Situation:** Last night's automated key rotation minted three candidate keys in `/opt/lab-cairns/keys/`, issued a fresh certificate from one of them, and then the deploy tool "helpfully" installed a key as `/opt/lab-cairns/server.key` — the *wrong* one. Now `lab-cairns.service` (a TLS endpoint on port 8443) crash-loops, and `journalctl -u lab-cairns` shows the smoking gun: `key values mismatch`. A certificate and a private key are only a pair if they share the same public key.

**Your task:** Identify — by comparing public keys, not by guessing — which of the three rotation keys actually matches `server.crt`, install it as `/opt/lab-cairns/server.key`, and bring the endpoint up so a TLS handshake verifies cleanly.

**Verify:**
```bash
echo Q | openssl s_client -connect localhost:8443 -CAfile /opt/lab-cairns/ca.crt 2>/dev/null | grep "Verify return code"   # expected: Verify return code: 0 (ok)
```

### 🟠 Scenario 5 — "Brisbane: the middle of the chain is missing" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-brisbane && cd /opt/lab-brisbane
sudo openssl genrsa -out root-ca.key 2048
sudo openssl req -x509 -new -key root-ca.key -out root-ca.crt -days 3650 -subj "/CN=lab-brisbane-root-ca"
sudo openssl genrsa -out intermediate.key 2048
sudo openssl req -new -key intermediate.key -out intermediate.csr -subj "/CN=lab-brisbane-intermediate-ca"
sudo bash -c 'printf "basicConstraints = critical, CA:TRUE, pathlen:0\nkeyUsage = critical, keyCertSign, cRLSign\n" > int.ext'
sudo openssl x509 -req -in intermediate.csr -CA root-ca.crt -CAkey root-ca.key \
  -CAcreateserial -out intermediate.crt -days 1825 -extfile int.ext
sudo openssl genrsa -out server.key 2048
sudo openssl req -new -key server.key -out server.csr -subj "/CN=localhost"
sudo bash -c 'printf "subjectAltName = DNS:localhost, IP:127.0.0.1\n" > leaf.ext'
sudo openssl x509 -req -in server.csr -CA intermediate.crt -CAkey intermediate.key \
  -CAcreateserial -out server.crt -days 365 -extfile leaf.ext
sudo tee /etc/systemd/system/lab-brisbane.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Brisbane - TLS endpoint on 8444

[Service]
ExecStart=/usr/bin/openssl s_server -accept 8444 -www -cert /opt/lab-brisbane/server.crt -key /opt/lab-brisbane/server.key
Restart=on-failure
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now lab-brisbane.service
echo "setup complete — clients that trust only the root CA cannot verify this endpoint"
```
**Situation:** Security mandated a two-tier PKI: an offline root CA that signs an intermediate CA, which signs all leaf certs — so clients are configured to trust **only** `root-ca.crt`. The new endpoint on port 8444 came up fine, its cert is valid and unexpired, yet every client fails with `Verify return code: 21 (unable to verify the first certificate)`. The server is presenting *something* — but clients can't build a path from what they receive up to the root they trust.

**Your task:** Diagnose what's missing from the server's handshake (look at the certificate *chain* `s_client` prints — how many certs, at which depths?), then fix the **server side** so that a client trusting only `root-ca.crt` verifies the connection with return code 0.

**Verify:**
```bash
echo Q | openssl s_client -connect localhost:8444 -CAfile /opt/lab-brisbane/root-ca.crt 2>/dev/null | grep "Verify return code"   # expected: Verify return code: 0 (ok)
```

### 🔴 Scenario 6 — "Adelaide: the kubelet that knocked with a dead badge" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-adelaide && cd /opt/lab-adelaide
sudo openssl genrsa -out ca.key 2048
sudo openssl req -x509 -new -key ca.key -out ca.crt -days 3650 -subj "/CN=lab-adelaide-cluster-ca"
sudo openssl genrsa -out server.key 2048
sudo openssl req -new -key server.key -out server.csr -subj "/CN=lab-apiserver"
sudo bash -c 'printf "subjectAltName = DNS:localhost, IP:127.0.0.1\n" > san.ext'
sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san.ext
sudo openssl genrsa -out kubelet-client.key 2048
sudo openssl req -new -key kubelet-client.key -out kubelet-client.csr -subj "/CN=system:node:lab-node-1"
if openssl x509 -help 2>&1 | grep -q not_after; then
  sudo openssl x509 -req -in kubelet-client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out kubelet-client.crt -not_before 20250101000000Z -not_after 20250201000000Z
else
  sudo apt-get install -y faketime >/dev/null
  sudo faketime '2025-01-01 00:00:00' openssl x509 -req -in kubelet-client.csr -CA ca.crt \
    -CAkey ca.key -CAcreateserial -out kubelet-client.crt -days 31
fi
sudo tee /etc/systemd/system/lab-adelaide.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Adelaide - mTLS apiserver-sim on 8445

[Service]
ExecStart=/usr/bin/openssl s_server -accept 8445 -www -cert /opt/lab-adelaide/server.crt -key /opt/lab-adelaide/server.key -CAfile /opt/lab-adelaide/ca.crt -Verify 2 -verify_return_error
Restart=on-failure
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now lab-adelaide.service
echo "setup complete — the node's client identity stopped working and nobody knows why"
```
**Situation:** This "apiserver" on port 8445 enforces **mutual** TLS: every client must present a certificate signed by the cluster CA, exactly like a kubelet authenticating as `system:node:...`. The node's client credentials sit in `/opt/lab-adelaide/` — and this morning the node dropped out. The maddening part: `openssl s_client` with the client cert *appears* to handshake fine and even prints `Verify return code: 0 (ok)` — but the server hangs up without ever sending a byte of application data. (That code-0 is the *client* verifying the *server*; under TLS 1.3 the server's rejection of *your* badge only surfaces when the response never comes.)

**Your task:** Diagnose why the server is rejecting the client identity, then mint a replacement client certificate from the cluster CA — reusing the **existing key and CSR** (the private key never needs to travel or change) — and prove the node can fetch data over mTLS again, while a certificate-less client still gets refused.

**Verify:**
```bash
printf 'GET / HTTP/1.0\r\n\r\n' | timeout 5 openssl s_client -connect localhost:8445 \
  -CAfile /opt/lab-adelaide/ca.crt -cert /opt/lab-adelaide/kubelet-client.crt \
  -key /opt/lab-adelaide/kubelet-client.key -quiet 2>/dev/null | grep -c 'HTTP/1.0 200'
# expected: 1   (and the same command WITHOUT -cert/-key prints 0 — anonymous clients stay locked out)
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "Wellington: the certificate that died in the night"
**Solution:**
```bash
cd /opt/lab-wellington
openssl x509 -in server.crt -noout -dates      # diagnose: notAfter is in the past — the hard wall from Rung 3B
openssl verify -CAfile ca.crt server.crt       # error 10: certificate has expired — reproduces the client failure
# Renewal = re-signing. The CSR (public key + identity) is still on disk; sign it again with a future window:
sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 365
openssl verify -CAfile ca.crt server.crt       # server.crt: OK
```
**Why this works & what it teaches:** `Not After` is a hard wall — one second past it every compliant client refuses the cert, no grace period (the Rung 0 outage in miniature). Renewal never touches the private key: the CSR still holds the same public key and identity, so re-signing it produces a fresh validity window while every client keeps working unchanged — which is exactly what `kubeadm certs renew all` does to a cluster's leaf certs. **Where people go wrong:** generating a whole new key pair in a panic (harmless here, but operationally noisier) — or renewing the file on disk and forgetting the serving process must reload it (Prediction 5's on-disk vs on-the-wire gap). **Cleanup:** `sudo rm -rf /opt/lab-wellington`

### Scenario 2 — "Christchurch: three authorities walk into a bar"
**Solution:**
```bash
cd /opt/lab-christchurch
for c in cas/ca1.crt cas/ca2.crt cas/ca3.crt; do echo "== $c"; openssl verify -CAfile "$c" server.crt; done
#   == cas/ca1.crt  ... verification failed
#   == cas/ca2.crt  server.crt: OK          ← the actual signer
#   == cas/ca3.crt  ... verification failed
sudo cp cas/ca2.crt trusted-ca.crt
openssl verify -CAfile trusted-ca.crt server.crt   # server.crt: OK
```
**Why this works & what it teaches:** All three CAs carry the identical Subject, so the cert's `Issuer: CN=platform-root-ca` field is *useless* for telling them apart — the Issuer string is a label, not proof. What actually discriminates is Rung 3C's mechanism: `openssl verify` checks the leaf's signature against each candidate's **public key**, and only the key pair that produced the signature validates it. Trust is cryptographic, never nominal — the same reason a cluster whose `ca.crt` was replaced (but whose leaf certs weren't re-signed) falls apart despite every name field looking right. **Where people go wrong:** matching on `-issuer`/`-subject` output, which here is identical for all three. **Cleanup:** `sudo rm -rf /opt/lab-christchurch`

### Scenario 3 — "Dunedin: valid for the wrong universe"
**Solution:**
```bash
cd /opt/lab-dunedin
openssl x509 -in server.crt -noout -ext subjectAltName   # diagnose: SAN lists ONLY payments-v1.internal
openssl verify -CAfile ca.crt -verify_hostname api.devopsinminutes.com server.crt   # hostname mismatch — the bug
# Re-issue with a SAN covering BOTH names (x509 -req drops extensions unless -extfile supplies them):
sudo bash -c 'printf "subjectAltName = DNS:api.devopsinminutes.com, DNS:payments-v1.internal\n" > san-new.ext'
sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san-new.ext
openssl x509 -in server.crt -noout -ext subjectAltName   # both DNS names present
```
**Why this works & what it teaches:** Modern clients match the hostname they dialed against the **SAN list**, not the CN (Rung 3B) — a chain-valid, unexpired cert still fails if the name isn't listed, producing the `valid for X, not Y` error class. Listing both old and new names in one cert is the standard zero-downtime rename pattern, and it's precisely why the kube-apiserver cert enumerates every DNS name and IP it can ever be reached by. **Where people go wrong:** putting the new name in the CSR's subject or SAN and signing with plain `openssl x509 -req` — which silently strips CSR extensions, shipping a cert with no SAN at all; always confirm with `-ext subjectAltName` after signing. **Cleanup:** `sudo rm -rf /opt/lab-dunedin`

### Scenario 4 — "Cairns: the key that fits no lock"
**Solution:**
```bash
cd /opt/lab-cairns
journalctl -u lab-cairns.service --no-pager | tail -n 5   # "key values mismatch" — cert and key disagree
openssl x509 -in server.crt -noout -pubkey | sha256sum    # the cert's embedded public key, fingerprinted
for k in keys/rotation-1.key keys/rotation-2.key keys/rotation-3.key; do
  echo "$k: $(sudo openssl pkey -in "$k" -pubout | sha256sum)"
done
# rotation-2.key produces the SAME hash as the cert → that's the pair
sudo cp keys/rotation-2.key server.key
sudo systemctl reset-failed lab-cairns.service
sudo systemctl restart lab-cairns.service
echo Q | openssl s_client -connect localhost:8443 -CAfile ca.crt 2>/dev/null | grep "Verify return code"
```
**Why this works & what it teaches:** A certificate is "public key + identity + signature" (Rung 2), so cert and private key are a pair *if and only if* the public key inside the cert equals the public key derived from the private key — comparing `x509 -pubkey` against `pkey -pubout` hashes is the canonical test, and the same trick (with `-modulus` on older tooling) debugs every nginx/haproxy/apiserver "key mismatch" startup failure. The server refused to even start because OpenSSL runs this exact consistency check when loading the pair. **Where people go wrong:** matching key to cert by file timestamps or names ("rotation-3 is newest, must be it") — exactly how the wrong key got installed. **Cleanup:** `sudo systemctl disable --now lab-cairns.service; sudo rm /etc/systemd/system/lab-cairns.service; sudo systemctl daemon-reload; sudo rm -rf /opt/lab-cairns`

### Scenario 5 — "Brisbane: the middle of the chain is missing"
**Solution:**
```bash
# Diagnose: the server presents ONLY the leaf — one cert at depth 0, issued by an
# intermediate the client has never seen, so path-building dies one hop up:
echo Q | openssl s_client -connect localhost:8444 -CAfile /opt/lab-brisbane/root-ca.crt 2>/dev/null | grep -E '^ +[0-9] s:|i:|Verify return'
# Confirm the chain itself is sound (client-side proof, not the fix):
openssl verify -CAfile /opt/lab-brisbane/root-ca.crt -untrusted /opt/lab-brisbane/intermediate.crt /opt/lab-brisbane/server.crt   # OK
# The FIX is server-side: present the intermediate in the handshake via -cert_chain:
sudo sed -i 's|-key /opt/lab-brisbane/server.key|-key /opt/lab-brisbane/server.key -cert_chain /opt/lab-brisbane/intermediate.crt|' /etc/systemd/system/lab-brisbane.service
sudo systemctl daemon-reload
sudo systemctl restart lab-brisbane.service
echo Q | openssl s_client -connect localhost:8444 -CAfile /opt/lab-brisbane/root-ca.crt 2>/dev/null | grep "Verify return code"
```
**Why this works & what it teaches:** TLS servers must send the **whole chain below the root** — leaf *plus* intermediates — because clients hold only root CAs in their trust store and build the path from what arrives in the handshake (Rung 3C/3D); a missing intermediate yields the infamous return code 21 even though nothing is expired or mis-issued. `openssl verify -untrusted` proves the chain is mathematically fine and isolates the fault to *what the server serves*; the fix for `s_server` is `-cert_chain` (nginx/haproxy achieve the same by concatenating leaf+intermediate into one file — note `s_server -cert` does **not** honor extra certs appended to the file, which is exactly how this outage gets deployed). **Where people go wrong:** "it works in my browser" — browsers cache intermediates and use AIA fetching, masking the broken chain that strict clients (openssl, curl, kubelets) correctly reject. **Cleanup:** `sudo systemctl disable --now lab-brisbane.service; sudo rm /etc/systemd/system/lab-brisbane.service; sudo systemctl daemon-reload; sudo rm -rf /opt/lab-brisbane`

### Scenario 6 — "Adelaide: the kubelet that knocked with a dead badge"
**Solution:**
```bash
cd /opt/lab-adelaide
openssl x509 -in kubelet-client.crt -noout -dates -subject   # diagnose: the CLIENT cert's notAfter is in the past
journalctl -u lab-adelaide.service --no-pager | tail -n 5    # server side logs the certificate_expired rejection
# Mint a replacement from the SAME CSR — same key, same CN=system:node:lab-node-1, new validity window:
sudo openssl x509 -req -in kubelet-client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out kubelet-client.crt -days 365
# Prove mTLS works again:
printf 'GET / HTTP/1.0\r\n\r\n' | timeout 5 openssl s_client -connect localhost:8445 \
  -CAfile ca.crt -cert kubelet-client.crt -key kubelet-client.key -quiet 2>/dev/null | grep -c 'HTTP/1.0 200'   # 1
# Prove anonymous clients are still refused:
printf 'GET / HTTP/1.0\r\n\r\n' | timeout 5 openssl s_client -connect localhost:8445 \
  -CAfile ca.crt -quiet 2>/dev/null | grep -c 'HTTP/1.0 200'   # 0
```
**Why this works & what it teaches:** This is handshake step 4b (mTLS) failing in the *other* direction from Wellington: the server's cert is fine, so the client's own verification passes — but the **server** rejects the expired *client* cert, the mirror of a kubelet with an expired client cert getting `Unauthorized` from the apiserver (Rung 3D). The TLS 1.3 wrinkle is diagnostic gold: client auth happens after the client believes the handshake succeeded, so the only client-side symptom is a connection that dies before application data — when you see "handshake OK but instant hangup" against an mTLS endpoint, suspect *your own* certificate, and check *both* ends' dates. Re-signing the stored CSR renews the identity without the private key ever moving — the same dance Kubernetes automates with its `CertificateSigningRequest` API (Rung 3C). **Where people go wrong:** staring at the server cert because `Verify return code: 0 (ok)` "proves" TLS is fine — that code only ever describes the peer's cert, not yours. **Cleanup:** `sudo systemctl disable --now lab-adelaide.service; sudo rm /etc/systemd/system/lab-adelaide.service; sudo systemctl daemon-reload; sudo rm -rf /opt/lab-adelaide`

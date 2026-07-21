# TLS/SSL — Encryption in Transit

*How two strangers on a hostile network agree on a secret nobody else can read — and prove they are who they claim to be.*

---

## 🎬 Rung 0 — The Setup

**What am I learning?** How TLS (Transport Layer Security — the protocol formerly, and still loosely, called SSL) turns a plaintext TCP stream into an encrypted, tamper-proof, authenticated channel. You already met HTTP in [10-http-and-https.md](10-http-and-https.md); the "S" in HTTPS *is* TLS wrapped around HTTP. This file is about that wrapper.

**Why did it land on my desk?** Pick the one that stings:

- Your security team ran a scan and flagged that traffic between the ALB and your pods is **plaintext HTTP inside the VPC**. Auditors want "encryption in transit" for **SOC2 / HIPAA / GDPR** and "it's a private subnet" is no longer an accepted answer.
- `cert-manager` failed to renew a Let's Encrypt cert and at 2 a.m. every browser hitting your Ingress threw `NET::ERR_CERT_DATE_INVALID`. The cert **expired**.
- You enabled **Istio mTLS** in `STRICT` mode and half your services started returning `503 UC` because one workload had no sidecar and couldn't present a client certificate.
- `kubectl` suddenly says `x509: certificate signed by unknown authority` after someone rotated the cluster CA, and you need to understand what "the chain of trust" actually means.

**What do I already know?**

- TCP gives you a reliable byte stream (SYN → SYN-ACK → ACK, then data, then FIN). See [07-transport-layer-tcp-udp.md](07-transport-layer-tcp-udp.md).
- HTTP rides on top of TCP on port **80**; HTTPS on port **443**.
- A pod has an IP, a Service has a stable ClusterIP, an Ingress/ALB fronts them.
- You've typed `curl -k https://...` to "skip the cert error" without fully knowing what you were skipping. By the end of this file, `-k` will feel like disarming a smoke detector.

TLS lives **above** TCP and **below** the application (HTTP, gRPC, Postgres, Kafka). It is a *session* the two endpoints negotiate once, then reuse.

```
  Application  (HTTP, gRPC, Postgres wire protocol...)
  ─────────────────────────────────────────────────
  TLS          ← you are here: encrypt/decrypt, auth
  ─────────────────────────────────────────────────
  TCP          (port 443, reliable byte stream)
  IP           (routing, TTL)
  Ethernet     (MAC, the local wire)
```

---

## 🔥 Rung 1 — The Pain

Imagine the early web: HTTP in the clear. Every byte — your password, your session cookie, your credit card — travels as readable ASCII across every switch, router, coffee-shop Wi-Fi AP, and ISP between you and the server.

Three distinct disasters, and TLS exists to stop all three:

**1. Eavesdropping (no confidentiality).** Anyone on the path runs `tcpdump` and reads your login POST body verbatim.

```
POST /login HTTP/1.1
Host: bank.example.com
Content-Type: application/x-www-form-urlencoded

user=akshay&password=hunter2      ← the attacker at the coffee shop just read this
```

**2. Tampering (no integrity).** A router in the middle flips bytes — changes the payee account number in a wire transfer, injects a `<script>` into a page, swaps a download for malware. Plain TCP checksums stop *accidental* corruption, not *malicious* edits, because an attacker recomputes the checksum after editing.

**3. Impersonation (no authentication).** You typed `bank.example.com`, but DNS was poisoned or you're on a rogue AP, and you're actually talking to an attacker's server. Nothing in plain HTTP proves the server on the far end is really the bank.

**What did people do before?** For a while: nothing — the web was academic and trusting. Then ad-hoc fixes (SSH tunnels, VPNs, application-level crypto that everyone got wrong). None composed. You cannot ask every app author to reinvent key exchange correctly. History is a graveyard of home-rolled crypto.

**Who feels the pain most in cloud/K8s?**

- **Compliance owners.** GDPR Art. 32, HIPAA, PCI-DSS, SOC2 all say *encryption in transit*. "It's a private VPC subnet" fails a serious audit — the internal network is a *shared* medium and lateral movement is real.
- **Platform engineers.** The Kubernetes control plane is TLS end to end for a reason: **kube-apiserver** talks to **etcd** over mTLS, **kubelet** (port **10250**) is authenticated by cert, and the whole thing collapses if any leg is plaintext. Anyone who reads etcd reads *every Secret in the cluster in base64*.
- **App teams behind Istio**, who suddenly must present client certs they didn't know existed.

> **Check yourself before Rung 2:** Plain TCP already has a checksum. Name the *specific* threat that a checksum does **not** defend against, and say why encryption alone (without authentication) would still leave you exposed on a rogue Wi-Fi network.

---

## 💡 Rung 2 — The One Idea

> **TLS uses slow public-key (asymmetric) crypto *once* — to authenticate the server and safely agree on a shared secret — then switches to fast symmetric crypto for the actual data.**

Memorize that sentence. Say it out loud. Everything else is a footnote to it.

Derive the whole protocol from it:

- "**Agree on a shared secret**" → there must be a **key exchange / handshake**.
- "**Authenticate the server**" → the server must **prove identity** → hence **certificates**, **Certificate Authorities**, and the **chain of trust**.
- "**Fast symmetric crypto for the data**" → after the handshake, both sides hold the same **session key** and use AES/ChaCha20 → confidentiality *and* integrity (via AEAD) for every record.
- "**Once**" → the expensive asymmetric math happens only at connection start; that's why TLS 1.3 obsesses over cutting handshake **round trips**.
- Want *both* sides authenticated, not just the server? Have the *client* present a cert too → **mutual TLS (mTLS)**.

Three guarantees fall out, and it's worth naming them as the acronym **C-I-A**:

| Guarantee | Meaning | Mechanism |
|---|---|---|
| **Confidentiality** | Nobody on the path can read it | Symmetric session key (AES-GCM / ChaCha20-Poly1305) |
| **Integrity** | Nobody can silently modify it | AEAD authentication tag on every record |
| **Authentication** | You're really talking to who you think | X.509 certificate signed by a trusted CA |

> **Check yourself before Rung 3:** If asymmetric crypto can already encrypt data, *why* does TLS bother switching to a symmetric key at all? Answer from the One Idea, not from memory.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

### 3.1 Two kinds of crypto, and why we need both

**Symmetric encryption** — *one* shared key both encrypts and decrypts. Think of a padlock where the same key locks and unlocks. Algorithms: **AES-256-GCM**, **ChaCha20-Poly1305**. It is *fast* — hardware AES does gigabytes per second — but it has one fatal chicken-and-egg problem: **how do two strangers agree on the shared key without an eavesdropper seeing it?** You can't email the key; the eavesdropper reads the email.

**Asymmetric (public-key) encryption** — a *key pair*: a **public key** you hand out freely and a **private key** you never reveal. Their magic property: something encrypted with the public key can *only* be decrypted with the private key, and a signature made with the private key can be *verified* by anyone holding the public key. Algorithms: **RSA**, **ECDSA**, and for key agreement, **(EC)DHE** (Elliptic-Curve Diffie-Hellman Ephemeral). It is *slow* (big-integer math) — too slow to encrypt a video stream.

The One Idea is the marriage: **use slow asymmetric crypto only to bootstrap a fast symmetric session key.** Padlock analogy: the server ships you an *open padlock* (its public key); you snap your secret inside and click it shut; only the server's private key opens it. Now you both share the secret, and you switch to the fast padlock for everything after.

> A subtlety worth knowing: modern TLS doesn't literally "encrypt the secret with the server's public key" (that was old RSA key transport). It runs an **ephemeral Diffie-Hellman** exchange where both sides *contribute* to the secret and the private key is used to *sign* the exchange. The effect is the same for your mental model — asymmetric bootstraps symmetric — but ephemeral keys give you **forward secrecy**: steal the server's private key tomorrow and you *still* can't decrypt traffic you captured today. TLS 1.3 makes ephemeral DH mandatory.

### 3.2 The certificate — an ID card the network can check

A session key you agreed with *a* server is worthless if that server is an impostor. Authentication is solved by an **X.509 certificate**: a signed digital document that binds a **public key** to an **identity** (a hostname).

```
┌──────────────────── X.509 Certificate ────────────────────┐
│ Subject:        CN = shop.example.com                      │
│ Subject Alt Names (SAN):  ← the field browsers ACTUALLY use│
│      DNS: shop.example.com                                 │
│      DNS: www.shop.example.com                             │
│      DNS: *.api.example.com     (wildcard)                 │
│ Public Key:     <the server's public key, e.g. ECDSA P-256>│
│ Not Before:     2026-07-01                                 │
│ Not After:      2026-09-29   ← EXPIRY. cert-manager renews │
│ Issuer:         CN = R3, O = Let's Encrypt                 │
│ ── Signature by the Issuer's private key ────────────────  │
└───────────────────────────────────────────────────────────┘
```

Key facts that trip people up:

- The identity check uses the **SAN (Subject Alternative Name)** list, *not* the old `CN` (Common Name). Modern browsers and Go (hence `kubectl`, `curl` on many systems) ignore CN entirely. A cert whose SAN doesn't include the hostname you dialed → **name mismatch** error.
- `*.api.example.com` matches `a.api.example.com` but **not** `api.example.com` and **not** `a.b.api.example.com` — wildcards cover exactly one label.
- A cert has an **expiry**. This is the single most common production TLS outage. `cert-manager` exists to renew automatically before this hits.

### 3.3 The chain of trust — why you believe the ID card

Anyone can generate a cert claiming `CN=shop.example.com`. What makes it *trustworthy* is that a **Certificate Authority (CA)** — an organization your system already trusts — **signed** it with the CA's private key. Your OS/browser ships with a **trust store**: a bundle of ~150 **root CA** certificates (on Linux, `/etc/ssl/certs/ca-certificates.crt`).

Roots don't sign your cert directly. There's a **chain**:

```
   Root CA  (self-signed, in your OS trust store, offline, super-guarded)
      │  signs
      ▼
  Intermediate CA  (e.g. Let's Encrypt "R3")
      │  signs
      ▼
  Leaf / server cert   (CN/SAN = shop.example.com)   ← the server presents this
```

Verification walks *up* the chain: the leaf is signed by R3, R3 is signed by a root you already trust → chain valid. **The server must send the leaf *and* the intermediate(s)**; forgetting to bundle the intermediate is a classic "works in Chrome (it cached the intermediate) but fails in `curl`/Go/Java" bug. The root is not sent — the client already has it.

In Kubernetes you meet **private CAs** constantly:

- The **cluster CA** signs the API server's serving cert and every component's client cert. `kubectl` trusts it via the `certificate-authority-data` blob in your kubeconfig — that's the cluster's *own* root, not a public one.
- **Istio's `istiod`** (the old name **Citadel** is the CA component) is a private CA that issues short-lived certs to every Envoy sidecar for mesh mTLS.

### 3.4 The handshake — conceptual, step by step

Here is the TLS **1.2** handshake (two round trips) as a whiteboard drawing. This is the heart of the machinery.

```
   CLIENT (curl / browser / Envoy)                 SERVER (nginx / ALB / pod)
        │                                                 │
        │ ─────────────  ClientHello  ──────────────────▶ │   RTT 1
        │   "I speak TLS 1.2/1.3; here are the cipher      │
        │    suites I support; here's a random number;     │
        │    SNI = shop.example.com" (which site I want)   │
        │                                                 │
        │ ◀────────  ServerHello + Certificate  ────────── │
        │   "Let's use TLS 1.2 + AES-256-GCM + ECDHE.       │
        │    Here's my random number.                       │
        │    Here's my X.509 cert chain (leaf+intermediate).│
        │    Here's my ephemeral DH public key, SIGNED      │
        │    with my cert's private key."                   │
        │                                                 │
        │   ── client verifies chain to a trusted root,    │
        │      checks SAN == shop.example.com, checks       │
        │      Not After date, checks the signature ──      │
        │                                                 │
        │ ─────  ClientKeyExchange + Finished  ──────────▶ │   RTT 2
        │   "Here's MY ephemeral DH public key."            │
        │   Both sides now combine the two DH keys +        │
        │   the two randoms → derive the SAME session key.  │
        │   "Finished" = a MAC over the whole handshake,    │
        │   proving nothing was tampered mid-flight.        │
        │                                                 │
        │ ◀───────────────  Finished  ──────────────────── │
        │                                                 │
        │ ═══════ Application data, AES-GCM encrypted ════▶ │
        │ ◀═══════ Application data, AES-GCM encrypted ════ │
```

Notice: the certificate is delivered **during** the handshake, in the clear (it's public info anyway). The *session key* is never transmitted — both sides *derive* it independently from the DH exchange. An eavesdropper sees both DH *public* keys and still cannot compute the secret (that's the discrete-log hardness DH rests on).

### 3.5 TLS 1.3 — fewer round trips

TLS 1.3 (2018) cut the fat. The client *guesses* the server's likely DH parameters and sends its key share in the **very first** ClientHello. The server replies with its share and can start sending encrypted data immediately.

```
  TLS 1.2:  2 round trips before app data     TLS 1.3: 1 round trip (1-RTT)
  ─────────────────────────────────           ────────────────────────────
  C → ClientHello                             C → ClientHello + key_share
  C ← ServerHello + Cert + KeyExch            C ← ServerHello + Cert + Finished
  C → KeyExch + Finished                          (app data can flow now)
  C ← Finished                                C → Finished + app data
       (now app data flows)
```

TLS 1.3 also **dropped all the broken/legacy ciphers** (no RSA key transport, no CBC, no RC4, no SHA-1) — the negotiation itself is safer because there's less to negotiate. It even supports **0-RTT** resumption (send data on the *first* packet of a *resumed* session), at a small replay-risk cost. Net effect for your users: a faster first byte, especially noticeable on high-latency mobile links.

### 3.6 Where TLS terminates — the cloud-critical decision

"TLS termination" = the point where the encrypted tunnel is decrypted back to plaintext. **Where** this happens is an architecture decision with compliance teeth.

```
  (A) Terminate at the Load Balancer  ── "edge termination"
  ──────────────────────────────────────────────────────────
   Client ══TLS══▶ [ ALB / Ingress ] ──plaintext HTTP──▶ Pod
                    decrypts here          inside VPC

   + Simple: cert lives in ONE place (ACM / cert-manager Secret)
   + LB can inspect L7 (path routing, WAF) because it sees plaintext
   - Traffic LB→Pod is CLEARTEXT. Auditors may reject this.


  (B) End-to-end / re-encrypt  ── "TLS passthrough" or "re-encrypt"
  ──────────────────────────────────────────────────────────
   Client ══TLS══▶ [ NLB passthrough ] ══TLS══▶ Pod (terminates)
             or
   Client ══TLS══▶ [ ALB ] ══new TLS══▶ Pod   (re-encrypt)

   + Encrypted all the way to the workload → satisfies strict "in transit"
   - More cert management; LB may not see L7 (passthrough)


  (C) Service mesh  ── mTLS everywhere, transparently
  ──────────────────────────────────────────────────────────
   Client ─plain─▶ [Envoy]══mTLS══▶[Envoy] ─plain─▶ App
                   sidecar         sidecar
   The app speaks plaintext to its OWN sidecar over loopback;
   Envoys upgrade every hop to mTLS. istiod issues the certs.
```

- **AWS ACM** (Certificate Manager) provisions and auto-renews the cert for an **ALB/NLB**; you never touch the private key — pattern (A), and (B) if you configure re-encrypt to targets.
- **`cert-manager`** in-cluster does the same for **Ingress**: watches an `Ingress`/`Certificate`, talks ACME to Let's Encrypt, drops the cert+key into a `kubernetes.io/tls` **Secret**, and renews ~30 days before expiry.
- **Istio** gives you (C) for free: **STRICT** mode means every pod-to-pod hop is mTLS, both sides presenting `istiod`-issued certs, with *zero* app code changes.

### 3.7 SNI — one IP, many certs

A single load balancer IP hosts hundreds of HTTPS sites. But the server must present the *right* certificate *before* it knows which site you want — chicken and egg, because the Host header is inside the (not-yet-encrypted) HTTP request. **SNI (Server Name Indication)** solves it: the client puts the target hostname **in the ClientHello, in the clear**, so the server (or ALB, or Envoy) can select the matching cert.

```
  ClientHello { ..., server_name = "shop.example.com" }
                                   └── SNI: lets the ALB pick which cert to serve
```

This is exactly how an ALB routes HTTPS to multiple certs, and how Istio's gateway matches TLS. It's also why `openssl s_client` needs `-servername` — omit it and a virtual-hosted server may hand you the *wrong* (default) cert and you'll misdiagnose a "name mismatch."

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery |
|---|---|---|
| **TLS / SSL** | The protocol securing a TCP stream. "SSL" is the dead ancestor; everyone says SSL, means TLS | The whole layer above TCP |
| **Symmetric key / session key** | One shared secret, encrypts + decrypts, fast (AES-GCM) | Bulk data encryption after handshake |
| **Asymmetric key pair** | Public + private key, slow, math-based (RSA/ECDSA/ECDHE) | Bootstrap only: auth + key agreement |
| **Handshake** | The negotiation that authenticates and derives the session key | ClientHello → ServerHello → Finished |
| **ClientHello / ServerHello** | First two messages: versions, ciphers, randoms, SNI / cert | Handshake, RTT 1 |
| **Cipher suite** | The agreed bundle of algorithms, e.g. `TLS_AES_256_GCM_SHA384` | Negotiated in Hellos |
| **(EC)DHE** | Ephemeral Diffie-Hellman key agreement → forward secrecy | Key exchange step |
| **X.509 certificate** | Signed doc binding a public key to a hostname + validity dates | Server identity, sent in handshake |
| **SAN** | Subject Alternative Name — the hostname list clients actually check | Cert identity validation |
| **CN** | Common Name — legacy identity field, now ignored for matching | Cert (historical) |
| **CA (Certificate Authority)** | Trusted org that signs certs (Let's Encrypt; or a private cluster CA) | Root of the chain of trust |
| **Chain of trust** | Leaf ← intermediate ← root, each signing the next | Cert verification |
| **Trust store** | The set of root CAs your system pre-trusts (`ca-certificates.crt`) | Where verification terminates |
| **mTLS (mutual TLS)** | Both client *and* server present certs | Handshake + a CertificateRequest |
| **TLS termination** | The point where the tunnel is decrypted to plaintext | LB vs pod vs sidecar |
| **SNI** | Target hostname sent in the clear in ClientHello | Cert selection on multi-site hosts |
| **Forward secrecy** | Past traffic stays safe even if the private key later leaks | Ephemeral DH property |
| **0-RTT / 1-RTT** | How many round trips before app data flows | TLS 1.3 speed |
| **AEAD** | Authenticated Encryption — encrypts *and* integrity-tags in one step | Every application-data record |

**"Same kind of thing wearing different names":**

- **SSL = TLS** (marketing/history vs the real protocol). Port 443, `s_client`, "SSL cert" — all TLS.
- **Session key = symmetric key = shared secret** — three names for the fast key derived post-handshake.
- **Leaf cert = server cert = end-entity cert = the thing in your `tls.crt` Secret.**
- **Citadel = istiod's CA component = the mesh's private CA** (Citadel was the old standalone name).
- **ACM cert = cert-manager Secret cert = the ID card the LB/pod presents** — same role, different issuer/automation.
- **Termination point = "where it decrypts"** — whether that word is used for an ALB, an Envoy sidecar, or the pod itself.

> **Check yourself before Rung 5:** Someone says "our SSL cert's CN is right but curl still says name mismatch." Using the vocabulary map, explain what's *actually* being checked and why the CN being right doesn't save them.

---

## 🔬 Rung 5 — The Trace

Follow **one** HTTPS request end to end: `curl https://shop.example.com` hitting an EKS cluster, terminating at an ALB, re-encrypting to an Istio-meshed pod. Every hop named.

```
  1. DNS           shop.example.com → 52.x.x.x (ALB).  See 09-dns.md.
  2. TCP handshake to 52.x.x.x:443   SYN → SYN-ACK → ACK.  See 07.
  3. TLS ClientHello ─────────────────────────────────────▶ ALB
        - offers TLS 1.3, cipher suites, a client random
        - SNI = "shop.example.com"  ← ALB uses this to pick the ACM cert
  4. ALB ── ServerHello + Certificate (ACM leaf + intermediate)
        + its ephemeral key_share  ───────────────────────▶ client
  5. client verifies:
        chain → Amazon Root CA (in OS trust store) ✓
        SAN contains shop.example.com ✓
        Not After in the future ✓
     → both derive the SESSION KEY (TLS 1.3, 1-RTT).
  6. client ── HTTP GET / (AES-GCM encrypted) ────────────▶ ALB
  7. ALB DECRYPTS (termination point A).  Now plaintext HTTP.
        Applies WAF rules, path routing (it can SEE the request).
  8. ALB opens a NEW TLS session to the target pod / Envoy
        gateway (re-encrypt, pattern B) ───────────────────▶
  9. Inside the mesh: sender Envoy ══ mTLS ══▶ receiver Envoy
        Both present istiod-issued certs; each verifies the
        OTHER's cert against the mesh CA (SPIFFE identity).
 10. receiver Envoy ── plaintext over loopback ──▶ app container
        (the app never knew TLS happened — it heard localhost).
 11. Response retraces the path, re-encrypted at each TLS hop.
```

Whiteboard view of the termination hops:

```
  curl ══TLS 1.3══▶ [ ALB ]══new TLS══▶ [Envoy]══mTLS══▶[Envoy]──plain──▶ app
        (public       decrypt,           sidecar         sidecar   loopback
         ACM cert)    re-encrypt         (istiod cert)   (istiod cert)
        └── hop 3-6 ──┘└─ hop 7-8 ─┘     └──── hop 9 ────┘└─ hop 10 ─┘
```

The crucial insight: **there are three independent TLS sessions on this path**, each with its own certs and its own derived session key: client↔ALB, ALB↔Envoy-gateway, Envoy↔Envoy. "Encryption in transit" is only truly end-to-end if *no* hop leaves plaintext on the wire — which is exactly what the mesh guarantees for the in-cluster hops, and why hop 7's brief plaintext-inside-the-ALB moment is the part auditors scrutinize.

---

## ⚖️ Rung 6 — The Contrast

**The alternative: plaintext + a network-layer tunnel (or nothing).** Before ubiquitous TLS, the fallbacks were "trust the private network," an **IPsec/VPN** tunnel wrapping everything, or SSH port-forwards.

| Dimension | TLS (this file) | IPsec / VPN tunnel | Plaintext "trusted network" |
|---|---|---|---|
| Layer | Above TCP (per-connection, L4-ish) | Below IP (L3, per-packet) | — |
| Authenticates *the server/app* | ✅ via X.509 cert + SAN | ❌ authenticates the *gateway/host*, not the app | ❌ nothing |
| Granularity | Per service / per connection | Whole network segment | — |
| End-to-end into a pod | ✅ (mesh mTLS) | Usually only host-to-host | ❌ |
| App awareness | App or sidecar handles it | Transparent to app | Transparent |
| Compliance "in transit" | ✅ the standard answer | ✅ but coarse | ❌ fails audit |
| Identity model | Hostname / SPIFFE identity | IP / tunnel endpoint | — |

What TLS does that a VPN can't: it authenticates the **specific service** you're talking to (the SAN matches the hostname), survives across any network path without a tunnel, and — with mTLS — gives every workload a cryptographic **identity** independent of its IP. What a VPN does that TLS doesn't: encrypt *all* traffic (DNS, ICMP, arbitrary UDP) transparently with zero app changes. They compose — you often run both.

**When would I NOT reach for TLS?** Genuinely never on any network you don't 100% control end to end — and in zero-trust you control none. Legitimate *exceptions*: intra-host loopback (`127.0.0.1`, e.g. app↔sidecar), or a throwaway local dev call. Even "it's a private VPC subnet" is not a good enough reason anymore — see [30-network-security-zero-trust-ids-ips.md](30-network-security-zero-trust-ids-ips.md).

**Why this over that, in one sentence:** TLS gives you per-service confidentiality, integrity, *and* verifiable identity over any untrusted path, which a network tunnel's coarse host-to-host encryption cannot.

> **Check yourself before Rung 7:** Your traffic already runs over an IPsec VPN between two VPCs. Give one concrete attack that TLS still stops but the VPN does not.

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction **before** running the command. A wrong prediction is the most valuable thing that can happen here — it means the mechanism in your head is off.

### Example 1 — The normal case: watch a real handshake and read the cert

**Prediction:** `openssl s_client` will print the presented certificate chain, the negotiated TLS version and cipher, and a `Verify return code: 0 (ok)` — **because** the server sends its leaf+intermediate during the handshake and my OS trust store can walk the chain to a root it already trusts.

```bash
# Connect and dump the negotiated session + cert chain.
# -servername sends SNI so a virtual-hosted server picks the RIGHT cert.
openssl s_client -connect example.com:443 -servername example.com </dev/null
```

```text
# What to look for in the output:
# ---
# Certificate chain
#  0 s:CN=example.com          ← leaf, the SAN you care about
#    i:C=US, O=DigiCert Inc...  ← issued by an intermediate
#  1 s:C=US, O=DigiCert Inc...  ← intermediate (server sent it — good)
# ---
# SSL-Session:
#     Protocol  : TLSv1.3
#     Cipher    : TLS_AES_256_GCM_SHA384
# ---
# Verify return code: 0 (ok)      ← chain valid, name matched, not expired
```

**Verify:** See `TLSv1.3`, an AEAD cipher (`_GCM_` or `CHACHA20`), and `Verify return code: 0 (ok)`. Pull *just* the SAN and dates:

```bash
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates -ext subjectAltName
# subject=CN=example.com
# notBefore=... notAfter=Sep 29 2026 ...   ← the expiry clock
# X509v3 Subject Alternative Name: DNS:example.com, DNS:www.example.com
```

If `Verify return code` is non-zero, the chain didn't reach a trusted root — often a **missing intermediate** the server forgot to bundle.

### Example 2 — The failure case: name mismatch and expiry

**Prediction A (name mismatch):** Dialing an IP/hostname whose name is **not** in the cert's SAN will fail verification with a *hostname mismatch*, **because** the client checks the SAN list against the name it dialed, and finding no match aborts trust — even though the encryption itself would work fine.

`badssl.com` runs deliberately-broken endpoints for exactly this drill:

```bash
# The cert here is valid but issued for a DIFFERENT name → SAN mismatch.
curl -v https://wrong.host.badssl.com/ 2>&1 | grep -Ei 'subject|SAN|SSL|certificate'
# * SSL: no alternative certificate subject name matches target host name 'wrong.host.badssl.com'
# curl: (60) SSL certificate problem ...
```

**Prediction B (expired):** An endpoint past its `Not After` date fails with a *certificate expired* error, **because** the client checks validity dates and rejects a cert outside its window — the #1 real-world TLS outage, and exactly what a stalled `cert-manager` renewal produces.

```bash
curl -v https://expired.badssl.com/ 2>&1 | grep -Ei 'expired|date|SSL certificate'
# * SSL certificate problem: certificate has expired
# curl: (60) SSL certificate problem: certificate has expired
```

**Verify:** Both fail *before* any HTTP response — the handshake never completes. Now the dangerous lesson: `curl -k` (or `--insecure`) makes both "succeed":

```bash
curl -k https://expired.badssl.com/ -o /dev/null -s -w '%{http_code}\n'   # 200
```

`-k` disables verification. You still get encryption, but you have thrown away **authentication and integrity-of-identity** — you no longer know *who* you're talking to. Understand that `-k` is why you must never paste it into anything touching real data.

### Example 3 — The Kubernetes/cloud case: inspect the API server and a Service, plus mTLS

**Prediction A (API server serving cert):** `kubectl` trusts the EKS API server because its serving cert is signed by the **cluster CA** embedded in my kubeconfig — a *private* root, not a public one. So `s_client` against the API endpoint will show a chain that a public trust store rejects, yet `kubectl` accepts, **because** verification terminates at whichever root *you* trust.

```bash
# The API server listens on 6443. Grab its serving cert's SAN + issuer.
API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's#https://##')
openssl s_client -connect "$API" -servername "${API%%:*}" </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -ext subjectAltName
# issuer=CN=kubernetes           ← the cluster's private CA, not Let's Encrypt
# X509v3 Subject Alternative Name: DNS:kubernetes, DNS:kubernetes.default,
#     DNS:...eks.amazonaws.com, IP Address:10.100.0.1  ← the ClusterIP of the svc
```

**Verify:** The issuer is your cluster CA (`CN=kubernetes` or an EKS-managed CA), and the SAN lists the internal Service names + the `kubernetes` ClusterIP (usually `10.96.0.1` or `10.100.0.1`). That's why `kubectl exec` into a pod and curling `https://kubernetes.default.svc` works with the mounted CA at `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`.

**Prediction B (mTLS in the mesh):** Curling an Istio `STRICT`-mTLS service *without* a client cert will be **rejected at the TLS layer** (connection reset / `503 UC`), **because** the receiving Envoy sends a `CertificateRequest` and aborts when the client presents none — mTLS requires *both* sides to authenticate.

```bash
# From a NON-meshed pod (no sidecar), hit a STRICT-mTLS service on its port.
kubectl run probe --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sS -m 5 http://productpage.default.svc.cluster.local:9080/ ; echo "exit=$?"
# curl: (56) Recv failure: Connection reset by peer   → the Envoy demanded a client cert
```

Then confirm the mesh policy that caused it:

```bash
kubectl get peerauthentication -A
# NAMESPACE   NAME      MODE
# istio-system default   STRICT     ← every hop must be mTLS, both certs required
```

**Verify:** From a *meshed* pod (with the sidecar injected) the same curl succeeds, because that pod's Envoy presents an `istiod`-issued client cert. Watching the two behaviors side by side is the clearest possible demonstration of the "**both sides present certs**" definition of mTLS. See [29-service-mesh-and-sidecars.md](29-service-mesh-and-sidecars.md).

---

## 🏔️ Capstone — Compress It

**One sentence:** TLS uses slow asymmetric crypto once to authenticate the server via a CA-signed X.509 cert and agree on a shared secret, then uses fast symmetric crypto for all data — giving confidentiality, integrity, and authentication over any untrusted network.

**Three-sentence beginner explanation:** When you connect to an HTTPS site, the server proves its identity by showing a certificate signed by an authority your computer already trusts, and the two of you secretly agree on a key that no eavesdropper can figure out. From then on, everything you send is scrambled with that key so nobody on the network can read it or tamper with it. Mutual TLS just adds a second step where *you* also show a certificate, so both sides are sure who they're talking to.

**Sub-parts mapped to the One Idea ("asymmetric bootstraps symmetric, plus prove identity"):**

- Handshake / ClientHello-ServerHello-Finished → *the bootstrap conversation.*
- X.509 cert + CA + chain of trust + SAN → *the "prove identity" half.*
- (EC)DHE key exchange → *how the shared secret is agreed without revealing it.*
- Session key + AES-GCM/AEAD → *the fast symmetric half doing the actual work.*
- TLS 1.3 fewer round trips → *doing the bootstrap more cheaply.*
- mTLS → *running the identity proof in both directions.*
- Termination point / SNI → *where the tunnel opens and how the right cert is chosen.*

**Which rung to revisit hands-on:** **Rung 7, Example 3.** Reading about mTLS is easy; the concept only truly clicks when you watch a non-meshed pod get its connection *reset* and the same request from a meshed pod *succeed* — that reset is the definition of "both sides must present certs" made physical. Pair it with Rung 3's handshake diagram open beside you.

---

## Related concepts

- [HTTP & HTTPS](10-http-and-https.md) — TLS is the "S"; this is the protocol it wraps.
- [Transport Layer: TCP & UDP](07-transport-layer-tcp-udp.md) — the reliable stream TLS rides on (port 443 over TCP).
- [DNS](09-dns.md) — resolves the name whose match against the cert's SAN you verify.
- [Kubernetes Ingress & Gateway API](27-kubernetes-ingress-gateway-api.md) — TLS termination and cert-manager auto-renewal in practice.
- [Service Mesh & Sidecars](29-service-mesh-and-sidecars.md) — Envoy/istiod transparent mTLS everywhere.
- [Network Security & Zero Trust](30-network-security-zero-trust-ids-ips.md) — why "private subnet" no longer excuses plaintext.
- [Linux: TLS, PKI & OpenSSL](../Linux/26-tls-pki-openssl.md) — hands-on cert/key generation and OpenSSL depth.
- [Istio deep-dive](../Istio_Learning_Ladder.md) — the mesh CA (Citadel/istiod) and STRICT mTLS end to end.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Plain TCP already has a checksum — name the specific threat a checksum does *not* defend against, and why encryption alone (without authentication) still leaves you exposed on a rogue Wi-Fi network.

**A:** A TCP checksum only catches *accidental* corruption; it does not defend against **malicious tampering**, because an attacker who edits bytes in flight simply recomputes the checksum afterward so the segment still looks valid. Encryption alone fixes eavesdropping but not **impersonation**: on a rogue Wi-Fi AP (or with poisoned DNS) you could establish a perfectly encrypted channel *directly to the attacker's server*, who happily decrypts everything you send. Without authentication — a CA-signed X.509 certificate proving the far end really is `bank.example.com` — you have a private conversation with an unknown party, which is exactly the third disaster (impersonation) TLS exists to stop.

### Before Rung 3
**Q:** If asymmetric crypto can already encrypt data, why does TLS bother switching to a symmetric key at all?

**A:** Straight from the One Idea: asymmetric (public-key) crypto is *slow* — big-integer math far too expensive to encrypt a bulk data stream like a video or a busy API's traffic — while symmetric crypto (AES-GCM, ChaCha20-Poly1305) is *fast*, with hardware AES pushing gigabytes per second. Symmetric crypto's only weakness is the chicken-and-egg key-distribution problem: two strangers can't agree on a shared key with an eavesdropper watching. So TLS uses the slow asymmetric math exactly *once*, at the handshake, to authenticate the server and safely agree on a shared session key, then switches to fast symmetric crypto for all application data. Asymmetric bootstraps symmetric; everything else is a footnote to that sentence.

### Before Rung 5
**Q:** "Our SSL cert's CN is right but curl still says name mismatch." What is *actually* being checked, and why doesn't a correct CN save them?

**A:** Modern clients validate the hostname against the **SAN (Subject Alternative Name)** list, not the legacy **CN (Common Name)** — browsers and Go-based tools (`kubectl`, many `curl` builds) ignore CN entirely for matching. So if the name they dialed is not present in the cert's SAN entries, verification fails with a name mismatch no matter what the CN says: the cert must list the exact hostname (or a matching wildcard, remembering `*.api.example.com` covers exactly one label — not `api.example.com` and not `a.b.api.example.com`). The fix is to reissue the cert with the dialed hostname in the SAN list. Also worth checking: when testing with `openssl s_client`, omit `-servername` and a virtual-hosted server may present the wrong (default) cert via SNI, producing a misleading "mismatch."

### Before Rung 7
**Q:** Your traffic already runs over an IPsec VPN between two VPCs. Give one concrete attack that TLS still stops but the VPN does not.

**A:** A VPN authenticates and encrypts only **gateway-to-gateway** (the tunnel endpoints), not the specific application you're talking to. Concrete attack: a compromised host inside the far VPC — or an attacker who has moved laterally onto that "trusted" segment — impersonates your database or API service (e.g., via ARP/DNS spoofing or by squatting on the service's IP); the VPN happily delivers your plaintext to it because the tunnel itself is intact. TLS stops this because the client verifies the server's X.509 certificate — the SAN must match the hostname dialed and chain to a trusted CA — so an impostor without the right private key fails the handshake. In short: the VPN encrypts the *path between networks*; TLS authenticates the *specific service*, and with mTLS, both workloads.
